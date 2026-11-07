import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/media_probe_service_impl.dart';

/// Minimal valid 1x1 PNG used as artwork payload.
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

class _FakeEngine implements MediaProbeEngine {
  _FakeEngine(this.artworkByCall);

  /// Artwork returned per successive [extractEmbeddedArtwork] call. The last
  /// entry repeats once the list is exhausted.
  final List<Uint8List?> artworkByCall;
  int calls = 0;

  @override
  Future<DiscoveredMediaInfo?> inspect(
    String filePath, {
    required bool isAudioHint,
    CancellationToken? cancellationToken,
  }) async => null;

  @override
  Future<Uint8List?> extractEmbeddedArtwork(
    String filePath, {
    CancellationToken? cancellationToken,
  }) async {
    if (calls >= artworkByCall.length) {
      return artworkByCall.isEmpty ? null : artworkByCall.last;
    }
    final result = artworkByCall[calls];
    calls++;
    return result;
  }

  @override
  void dispose() {}
}

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('mpvson-probe-artwork-test-');

MediaProbeServiceImpl _service(Directory cacheRoot, _FakeEngine engine) {
  return MediaProbeServiceImpl(
    engine: engine,
    cacheDirectory: Directory('${cacheRoot.path}${Platform.pathSeparator}'),
    imageNormalizer: (bytes, {int maxDimension = 1024}) async => bytes,
  );
}

void main() {
  late Directory cacheRoot;
  late Directory mediaDir;
  late File mediaFile;

  setUp(() async {
    cacheRoot = await _tempDir();
    mediaDir = await _tempDir();
    mediaFile = File('${mediaDir.path}${Platform.pathSeparator}track.mp3');
    mediaFile.writeAsStringSync('fake audio bytes');
  });

  tearDown(() async {
    for (final dir in <Directory>[cacheRoot, mediaDir]) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // Temp cleanup is best-effort.
      }
    }
  });

  group('resolveArtwork mode isolation', () {
    test('embedded-only failure does not poison the full lookup', () async {
      final engine = _FakeEngine(<Uint8List?>[
        null,
        Uint8List.fromList(_tinyPng),
      ]);
      final service = _service(cacheRoot, engine);

      final failed = await service.resolveArtwork(
        mediaFile.path,
        embeddedOnly: true,
      );
      expect(failed, isNull);
      expect(engine.calls, 1);

      // The failure is negatively cached for the embedded-only mode only.
      final retried = await service.resolveArtwork(
        mediaFile.path,
        embeddedOnly: true,
      );
      expect(retried, isNull);
      expect(engine.calls, 1, reason: 'failure cache must suppress re-probing');

      // The full lookup for the same file must not be blocked.
      final resolved = await service.resolveArtwork(mediaFile.path);
      expect(resolved, isNotNull);
      expect(engine.calls, 2);
      expect(File(resolved!).existsSync(), isTrue);
    });

    test(
      'full-mode failure does not poison the embedded-only lookup',
      () async {
        final engine = _FakeEngine(<Uint8List?>[
          null,
          Uint8List.fromList(_tinyPng),
        ]);
        final service = _service(cacheRoot, engine);

        expect(await service.resolveArtwork(mediaFile.path), isNull);
        expect(engine.calls, 1);
        expect(await service.resolveArtwork(mediaFile.path), isNull);
        expect(
          engine.calls,
          1,
          reason: 'failure cache must suppress re-probing',
        );

        final resolved = await service.resolveArtwork(
          mediaFile.path,
          embeddedOnly: true,
        );
        expect(resolved, isNotNull);
        expect(engine.calls, 2);
      },
    );

    test(
      'each mode stores its own cache file and leaves no .tmp behind',
      () async {
        final engine = _FakeEngine(<Uint8List?>[
          Uint8List.fromList(_tinyPng),
          Uint8List.fromList(_tinyPng),
        ]);
        final service = _service(cacheRoot, engine);

        final fullPath = await service.resolveArtwork(mediaFile.path);
        final embeddedPath = await service.resolveArtwork(
          mediaFile.path,
          embeddedOnly: true,
        );

        expect(fullPath, isNotNull);
        expect(embeddedPath, isNotNull);
        expect(
          fullPath != embeddedPath,
          isTrue,
          reason: 'modes must not share cache entries',
        );

        final cacheDir = Directory(
          '${cacheRoot.path}${Platform.pathSeparator}artwork_cache',
        );
        final names = cacheDir.listSync().map((e) => e.path).toList();
        expect(names.where((n) => n.endsWith('.png')), hasLength(2));
        expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
      },
    );
  });

  group('startup artwork cache prune', () {
    test(
      'removes stale entries and orphaned .tmp files, keeps fresh ones',
      () async {
        final cacheDir = Directory(
          '${cacheRoot.path}${Platform.pathSeparator}artwork_cache',
        );
        cacheDir.createSync(recursive: true);
        final stale = File('${cacheDir.path}${Platform.pathSeparator}stale.png')
          ..writeAsBytesSync(_tinyPng);
        final fresh = File('${cacheDir.path}${Platform.pathSeparator}fresh.png')
          ..writeAsBytesSync(_tinyPng);
        final orphan = File(
          '${cacheDir.path}${Platform.pathSeparator}orphan.tmp',
        )..writeAsBytesSync(<int>[1, 2, 3]);
        stale.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 40)),
        );

        final engine = _FakeEngine(<Uint8List?>[Uint8List.fromList(_tinyPng)]);
        final service = _service(cacheRoot, engine);
        final resolved = await service.resolveArtwork(mediaFile.path);

        expect(resolved, isNotNull);
        expect(
          stale.existsSync(),
          isFalse,
          reason: 'entries untouched for 30 days must be pruned at startup',
        );
        expect(fresh.existsSync(), isTrue);
        expect(
          orphan.existsSync(),
          isFalse,
          reason: 'orphaned temp files must be pruned at startup',
        );
      },
    );
  });
}
