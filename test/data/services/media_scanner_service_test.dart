import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/data/services/media_probe_service.dart';
import 'package:mpvson/data/services/media_scanner_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/media_kind.dart';
import 'package:mpvson/domain/models/media_metadata.dart';
import 'package:path/path.dart' as p;

/// Probe service stub that returns cheap synthetic metadata and can block
/// probes on test-controlled gates.
class _FakeProbeService implements MediaProbeService {
  _FakeProbeService({this.gates = const <String, Completer<void>>{}});

  /// Probes whose canonical source has an entry here block until the gate is
  /// completed by the test.
  final Map<String, Completer<void>> gates;

  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) async {
    final gate = gates[MediaEntry.canonicalSource(filePath)];
    if (gate != null) {
      await gate.future;
    }
    final stat = await File(filePath).stat();
    return ProbeResult(
      canonicalSource: MediaEntry.canonicalSource(filePath),
      path: filePath,
      kind: MediaCatalog.kindFromExtension(filePath),
      metadata: MediaMetadata(
        title: MediaEntry.titleFromPath(filePath),
        artist: 'Fake Artist',
      ),
      fileSize: stat.size,
      modifiedAt: stat.modified,
    );
  }

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

Future<Directory> _createTempFolder() async {
  final root = await Directory.systemTemp.createTemp('mpvson-scanner-test-');
  addTearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on Object {
      // Watcher handles may keep the directory alive briefly on Windows.
    }
  });
  return root;
}

Future<LibraryDatabase> _openDb() async {
  final db = await LibraryDatabase.open(inMemory: true);
  addTearDown(db.close);
  return db;
}

void main() {
  test('adding a folder while a startup scan runs scans every root', () async {
    final rootA = await _createTempFolder();
    final rootB = await _createTempFolder();
    final aPath = p.join(rootA.path, 'a.mp3');
    await File(aPath).writeAsBytes(List<int>.filled(16, 7));
    await File(
      p.join(rootB.path, 'b.mp3'),
    ).writeAsBytes(List<int>.filled(16, 7));
    final db = await _openDb();

    final gates = <String, Completer<void>>{};
    final scannedFolders = <String>[];
    final scanner = MediaScannerService(
      probeService: _FakeProbeService(gates: gates),
      database: db,
      onFolderScanCompleted:
          (folder, {required fileCount, required lastScannedAt}) async {
            scannedFolders.add(MediaEntry.canonicalSource(folder));
            await db.updateFolderScanStats(
              folder,
              fileCount: fileCount,
              lastScannedAt: lastScannedAt,
            );
          },
    );

    // Startup scan of root A, held in the enrich phase by a gated probe.
    gates[MediaEntry.canonicalSource(aPath)] = Completer<void>();
    final startup = scanner.scanAll(folders: <String>[rootA.path]);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (scanner.scanStatus.phase != ScanPhase.enriching) {
      if (DateTime.now().isAfter(deadline)) {
        fail('startup scan never reached the enrich phase');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // A single-folder rescan of root B must merge into the running scan
    // instead of cancelling it.
    final folderRescan = scanner.scanFolder(rootB.path);

    // Release the gated probe and let both scans finish.
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await startup.timeout(const Duration(seconds: 15));
    await folderRescan.timeout(const Duration(seconds: 15));

    final canonicalA = MediaEntry.canonicalSource(rootA.path);
    final canonicalB = MediaEntry.canonicalSource(rootB.path);
    expect(
      scannedFolders,
      containsAll(<String>[canonicalA, canonicalB]),
      reason: 'every registered root must be scanned',
    );

    // The startup scan's enrichment must not have been aborted: a.mp3 gets
    // its probed metadata instead of the discovery fallback.
    final a = await db.getMediaByCanonicalSource(aPath);
    expect(a, isNotNull);
    expect(a!.metadata.artist, 'Fake Artist');
  });

  test('mid-scan watcher additions survive the stale reconcile', () async {
    final root = await _createTempFolder();
    final db = await _openDb();

    final a = File(p.join(root.path, 'a.mp3'));
    await a.writeAsBytes(List<int>.filled(16, 7));

    var simulatedWatcherAdd = false;
    final scanner = MediaScannerService(
      probeService: _FakeProbeService(),
      database: db,
      onDiscoveredFiles: (paths) async {
        await db.batchUpsertDiscoveredFiles(paths);
        if (!simulatedWatcherAdd) {
          simulatedWatcherAdd = true;
          // Simulate a watcher drain landing between the scan's traversal and
          // its reconcile: a new file is added and upserted into the database.
          final c = File(p.join(root.path, 'c.mp3'));
          await c.writeAsBytes(List<int>.filled(16, 7));
          await db.batchUpsertDiscoveredFiles(<String>[c.path]);
        }
      },
    );

    await scanner.scanFolder(root.path);

    final available = await db.queryMedia(isAvailable: true);
    final availableCanonical = available
        .map((r) => MediaEntry.canonicalSource(r.path))
        .toSet();
    expect(
      availableCanonical,
      contains(MediaEntry.canonicalSource(cFilePath(root))),
      reason:
          'a file added by the watcher mid-scan must not be marked unavailable '
          'by the stale reconcile snapshot',
    );
  });

  test('files that truly disappeared are still marked unavailable', () async {
    final root = await _createTempFolder();
    final db = await _openDb();

    final a = File(p.join(root.path, 'a.mp3'));
    await a.writeAsBytes(List<int>.filled(16, 7));
    final b = File(p.join(root.path, 'b.mp3'));
    await b.writeAsBytes(List<int>.filled(16, 7));

    final scanner = MediaScannerService(
      probeService: _FakeProbeService(),
      database: db,
    );
    await scanner.scanFolder(root.path);

    // b.mp3 disappears from disk after the first scan.
    await b.delete();

    await scanner.scanFolder(root.path);

    final available = await db.queryMedia(isAvailable: true);
    final availableCanonical = available
        .map((r) => MediaEntry.canonicalSource(r.path))
        .toSet();
    expect(
      availableCanonical,
      isNot(contains(MediaEntry.canonicalSource(b.path))),
      reason: 'a deleted file must still be marked unavailable',
    );
    expect(availableCanonical, contains(MediaEntry.canonicalSource(a.path)));
  });
}

String cFilePath(Directory root) => p.join(root.path, 'c.mp3');
