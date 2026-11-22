import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/media_probe_service.dart';
import 'package:mpvson/data/services/media_scanner_service.dart';

void main() {
  test(
    'partial traversal preserves complete stats and clears after recovery',
    () async {
      final root = await Directory.systemTemp.createTemp('mpvson-scan-');
      final sub = await Directory(
        '${root.path}${Platform.pathSeparator}sub',
      ).create();
      await File(
        '${root.path}${Platform.pathSeparator}one.mp4',
      ).writeAsBytes([0]);
      await File(
        '${sub.path}${Platform.pathSeparator}two.mp4',
      ).writeAsBytes([0]);
      var unreadable = false;
      final counts = <int>[];
      var reconciliations = 0;
      final scanner = MediaScannerService(
        probeService: _Probe(),
        listDirectory: (dir) =>
            unreadable && dir.path.toLowerCase() == sub.path.toLowerCase()
            ? Stream.error(const FileSystemException('permission denied'))
            : dir.list(followLinks: false),
        onFolderScanCompleted:
            (_, {required fileCount, required lastScannedAt}) async {
              counts.add(fileCount);
            },
        onFolderReconciled: (_, _) async {
          reconciliations++;
        },
      );
      addTearDown(() async {
        await scanner.dispose();
        await root.delete(recursive: true);
      });

      await scanner.scanFolder(root.path);
      expect(counts, [2]);
      expect(reconciliations, 1);
      unreadable = true;
      await scanner.scanFolder(root.path);
      expect(scanner.scanStatus.isPartial, isTrue);
      expect(counts, [2]);
      expect(reconciliations, 1);
      unreadable = false;
      await scanner.scanFolder(root.path);
      expect(scanner.scanStatus.isPartial, isFalse);
      expect(counts, [2, 2]);
      expect(reconciliations, 2);
    },
  );

  test(
    'missing drive retains stats and a later scan restores availability',
    () async {
      final parent = await Directory.systemTemp.createTemp('mpvson-drive-');
      final root = Directory('${parent.path}${Platform.pathSeparator}drive');
      await root.create();
      var completions = 0;
      final availability = <bool>[];
      final scanner = MediaScannerService(
        probeService: _Probe(),
        onFolderAvailabilityChanged: (_, available) async {
          availability.add(available);
        },
        onFolderScanCompleted:
            (_, {required fileCount, required lastScannedAt}) async {
              completions++;
            },
      );
      addTearDown(() async {
        await scanner.dispose();
        await parent.delete(recursive: true);
      });
      await scanner.scanFolder(root.path);
      await root.delete();
      await scanner.scanFolder(root.path);
      expect(availability.last, isFalse);
      expect(completions, 1);
      await root.create();
      await scanner.scanFolder(root.path);
      expect(availability.last, isTrue);
      expect(completions, 2);
    },
  );
}

class _Probe implements MediaProbeService {
  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) async =>
      throw StateError('no metadata');
  @override
  Future<String?> resolveArtwork(
    String filePath, {
    bool embeddedOnly = false,
  }) async => null;
  @override
  void cancelAll() {}
  @override
  void dispose() {}
}
