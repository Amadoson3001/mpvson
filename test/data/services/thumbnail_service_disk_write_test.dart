import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/thumbnail_service.dart';
import 'package:mpvson/domain/models/media_entry.dart';

/// Minimal valid 1x1 PNG used as an extracted thumbnail.
const List<int> _tinyPng = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x62,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0d,
  0x0a,
  0x2d,
  0xb4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

class _FakeExtractor implements ThumbnailExtractor {
  int extractCalls = 0;

  @override
  Future<ThumbnailExtraction?> extract(
    String source, {
    required Directory outputDirectory,
    ThumbnailCancellation? cancellation,
  }) async {
    extractCalls++;
    return ThumbnailExtraction(
      bytes: Uint8List.fromList(_tinyPng),
      duration: const Duration(seconds: 1),
    );
  }

  @override
  Future<Duration> probeDuration(
    String source, {
    ThumbnailCancellation? cancellation,
  }) async => const Duration(seconds: 1);

  @override
  void requestIdleCleanup() {}

  @override
  Future<void> dispose() async {}
}

MediaEntry _entry(String path) =>
    MediaEntry.fromPath(path, id: 'entry-${path.hashCode}');

Future<void> _waitForFile(File file) async {
  for (var i = 0; i < 300; i++) {
    if (file.existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for ${file.path}');
}

void main() {
  late Directory cacheDir;
  late Directory mediaDir;
  late File mediaFile;
  late _FakeExtractor extractor;
  late Completer<void> writeGate;
  var gateArmed = false;
  MediaKitThumbnailService? service;

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp(
      'mpvson-thumbnail-disk-test-',
    );
    mediaDir = await Directory.systemTemp.createTemp(
      'mpvson-thumbnail-media-test-',
    );
    mediaFile = File('${mediaDir.path}${Platform.pathSeparator}clip.mkv')
      ..writeAsStringSync('fake video bytes');
    extractor = _FakeExtractor();
    writeGate = Completer<void>();
    gateArmed = true;
    service = MediaKitThumbnailService(
      extractor: extractor,
      cacheDirectory: cacheDir,
      imageValidator: (bytes) async => true,
      beforeDiskWrite: () async {
        if (gateArmed) {
          gateArmed = false;
          await writeGate.future;
        }
      },
    );
  });

  tearDown(() async {
    if (!writeGate.isCompleted) writeGate.complete();
    await service?.dispose();
    for (final dir in <Directory>[cacheDir, mediaDir]) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // Temp cleanup is best-effort.
      }
    }
  });

  test(
    'in-flight disk write satisfies concurrent reads without re-extracting',
    () async {
      final current = service!;
      final entry = _entry(mediaFile.path);
      final digest = sha256
          .convert(utf8.encode(MediaEntry.canonicalSource(entry.path)))
          .toString();
      final bytesFile = File(
        '${cacheDir.path}${Platform.pathSeparator}$digest.img',
      );

      // First load extracts and returns immediately; its disk write is stuck
      // behind the gate, proving background work does not block the caller.
      final first = await current.load(entry);
      expect(first, isNotNull);
      expect(extractor.extractCalls, 1);
      expect(
        bytesFile.existsSync(),
        isFalse,
        reason: 'the gated write must run in the background',
      );

      // Evict memory so the second load must go to the disk layer.
      current.trimMemory();
      final second = await current.load(entry);
      expect(second, isNotNull);
      expect(second!.bytes, first!.bytes);
      expect(
        extractor.extractCalls,
        1,
        reason:
            'the queued write must satisfy the read instead of '
            'racing on half-written files',
      );

      // Release the gate; the write lands and later reads come from disk.
      writeGate.complete();
      await _waitForFile(bytesFile);

      current.trimMemory();
      final third = await current.load(entry);
      expect(third, isNotNull);
      expect(third!.bytes, first.bytes);
      expect(extractor.extractCalls, 1);
    },
  );
}
