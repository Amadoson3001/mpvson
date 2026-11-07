import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/data/services/media_probe_service.dart';
import 'package:mpvson/data/services/media_scanner_service.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/media_kind.dart';
import 'package:mpvson/domain/models/media_metadata.dart';
import 'package:path/path.dart' as p;

/// Probe service stub that returns cheap synthetic metadata.
class _FakeProbeService implements MediaProbeService {
  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) async {
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
    expect(
      availableCanonical,
      contains(MediaEntry.canonicalSource(a.path)),
    );
  });
}

String cFilePath(Directory root) => p.join(root.path, 'c.mp3');
