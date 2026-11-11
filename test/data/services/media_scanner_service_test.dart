import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/data/services/media_probe_service.dart';
import 'package:mpvson/data/services/media_scanner_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

/// Deterministic in-memory directory watcher used to drive watcher events.
class _FakeWatcher implements DirectoryWatcher {
  _FakeWatcher(this._path);

  final String _path;
  final StreamController<WatchEvent> _controller =
      StreamController<WatchEvent>.broadcast();

  @override
  String get path => _path;

  @override
  String get directory => _path;

  @override
  Stream<WatchEvent> get events => _controller.stream;

  @override
  bool get isReady => true;

  @override
  Future<void> get ready => Future<void>.value();

  void emit(ChangeType type, String path) {
    _controller.add(WatchEvent(type, path));
  }

  Future<void> close() => _controller.close();
}

/// Probe service stub that returns cheap synthetic metadata and can block
/// probes on test-controlled gates.
class _FakeProbeService implements MediaProbeService {
  _FakeProbeService({
    this.gates = const <String, Completer<void>>{},
    this.errorGates = const <String, Completer<void>>{},
  });

  /// Probes whose canonical source has an entry here block until the gate is
  /// completed by the test, then succeed.
  final Map<String, Completer<void>> gates;

  /// Probes whose canonical source has an entry here block until the gate is
  /// completed by the test, then fail (as a cancelled probe would).
  final Map<String, Completer<void>> errorGates;

  final List<String> probeCalls = <String>[];

  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) async {
    final key = MediaEntry.canonicalSource(filePath);
    probeCalls.add(key);
    final errorGate = errorGates[key];
    if (errorGate != null) {
      await errorGate.future;
      throw StateError('probe cancelled for $filePath');
    }
    final gate = gates[key];
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

  test(
    'a folder removed while the registered-folder read is in flight is not resurrected',
    () async {
      final root = await _createTempFolder();
      final aPath = p.join(root.path, 'a.mp3');
      await File(aPath).writeAsBytes(List<int>.filled(16, 7));
      final db = await _openDb();

      final rootKey = MediaEntry.canonicalSource(root.path);
      await db.insertFolder(
        LibraryFolderRecord(
          path: rootKey,
          addedAt: DateTime.now(),
          isAvailable: true,
        ),
      );
      await db.batchUpsertDiscoveredFiles(<String>[aPath]);
      // The user removes the folder: the watcher stops and the files are
      // untracked (soft-deleted) in the database.
      await db.deleteFolder(rootKey);
      expect(await db.queryMedia(), isEmpty);

      // The scanner reads the registered folders; the removal completes after
      // the first (stale) read, so only the second read reflects it.
      var reads = 0;
      final scanner = MediaScannerService(
        probeService: _FakeProbeService(),
        database: db,
        getRegisteredFolders: () async {
          reads++;
          if (reads == 1) {
            return <LibraryFolderRecord>[
              LibraryFolderRecord(
                path: rootKey,
                addedAt: DateTime.now(),
                isAvailable: true,
              ),
            ];
          }
          return const <LibraryFolderRecord>[];
        },
      );

      await scanner.scanAll();

      expect(
        scanner.registeredFolders,
        isEmpty,
        reason:
            'the removed folder must not be re-registered from a stale read',
      );
      expect(
        await db.queryMedia(),
        isEmpty,
        reason:
            'scanning a removed folder would resurrect its files in the library',
      );
    },
  );

  test(
    'cancelling while a watcher enrichment fails preserves the rich metadata',
    () async {
      final root = await _createTempFolder();
      final db = await _openDb();
      final aPath = p.join(root.path, 'a.mp3');

      // Rich metadata as a previous watcher enrichment would have written it.
      await db.insertMedia(
        MediaItemRecord(
          id: MediaEntry.canonicalSource(aPath),
          canonicalSource: MediaEntry.canonicalSource(aPath),
          path: aPath,
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Rich Title',
            artist: 'Rich Artist',
            album: 'Rich Album',
          ),
          fileSize: 16,
          addedAt: DateTime.now(),
        ),
      );

      // The probe blocks until the test releases it, then fails (a cancelled
      // probe surfaces as a failure).
      final errorGate = Completer<void>();
      final fallbackWrites = <String>[];
      final fallbackWriteAttempted = Completer<void>();
      final probeService = _FakeProbeService(
        errorGates: <String, Completer<void>>{
          MediaEntry.canonicalSource(aPath): errorGate,
        },
      );
      final watchers = <String, _FakeWatcher>{};
      final scanner = MediaScannerService(
        probeService: probeService,
        watcherFactory: (path) =>
            watchers.putIfAbsent(path, () => _FakeWatcher(path)),
        database: db,
        onUpdateMetadata:
            (
              source, {
              required kind,
              required metadata,
              required fileSize,
              required modifiedAt,
            }) async {
              fallbackWrites.add(MediaEntry.canonicalSource(source));
              if (!fallbackWriteAttempted.isCompleted) {
                fallbackWriteAttempted.complete();
              }
              await db.updateMediaMetadata(
                source,
                kind: kind,
                metadata: metadata,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
              );
            },
      );
      addTearDown(db.close);

      // Registering arms the (fake) watcher; creating the file and emitting an
      // ADD event triggers the watcher drain into a watcher-driven enrichment
      // (ignoreScanCancellation: true).
      scanner.registerFolder(root.path);
      expect(watchers, isNotEmpty);
      await File(aPath).writeAsBytes(List<int>.filled(16, 7));
      watchers.values.first.emit(ChangeType.ADD, aPath);

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      final watchKey = MediaEntry.canonicalSource(aPath);
      while (!probeService.probeCalls.contains(watchKey)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('watcher enrichment never probed the added file');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // The user cancels while the watcher-driven enrichment is in flight,
      // then the probe fails like a cancelled probe would.
      scanner.cancelScan();
      errorGate.complete();

      // Give the enrichment worker a bounded chance to process the failed
      // probe: a correct implementation never attempts the fallback write, so
      // waiting on the attempt signal simply settles.
      await fallbackWriteAttempted.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );

      // dispose() awaits the in-flight watcher drain before returning.
      await scanner.dispose().timeout(const Duration(seconds: 10));

      expect(
        fallbackWrites,
        isEmpty,
        reason:
            'the fallback write must be skipped for a batch invalidated by a '
            'cancellation',
      );
      final row = await db.getMediaByCanonicalSource(aPath);
      expect(row, isNotNull);
      expect(
        row!.metadata.artist,
        'Rich Artist',
        reason:
            'cancelling must not null watcher-enriched metadata via the '
            'fallback write',
      );
      expect(row.metadata.album, 'Rich Album');
      expect(row.metadata.title, 'Rich Title');
    },
  );

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

  test(
    'removing a folder mid-scan allows subsequent folders in the batch to be scanned',
    () async {
      final baseDir = await _createTempFolder();
      final rootA = Directory(p.join(baseDir.path, 'a'));
      final rootB = Directory(p.join(baseDir.path, 'longer_b'));
      await rootA.create();
      await rootB.create();

      final aPath = p.join(rootA.path, 'a.mp3');
      final bPath = p.join(rootB.path, 'b.mp3');
      await File(aPath).writeAsBytes(List<int>.filled(16, 7));
      await File(bPath).writeAsBytes(List<int>.filled(16, 7));
      final db = await _openDb();

      final completedFolders = <String>[];
      late final MediaScannerService scanner;
      scanner = MediaScannerService(
        probeService: _FakeProbeService(),
        database: db,
        onDiscoveredFiles: (paths) async {
          await db.batchUpsertDiscoveredFiles(paths);
          // When rootA's files are discovered, remove rootA mid-scan.
          final canonicalAPath = MediaEntry.canonicalSource(aPath);
          if (paths.any(
            (p) => MediaEntry.canonicalSource(p) == canonicalAPath,
          )) {
            scanner.unregisterFolder(rootA.path);
          }
        },
        onFolderScanCompleted:
            (folder, {required fileCount, required lastScannedAt}) async {
              completedFolders.add(MediaEntry.canonicalSource(folder));
              await db.updateFolderScanStats(
                folder,
                fileCount: fileCount,
                lastScannedAt: lastScannedAt,
              );
            },
      );

      // Start a multi-folder batch scan containing rootA and rootB.
      // rootA has shorter path length so deduplicateFolderRoots places it first in the batch.
      await scanner.scanAll(folders: <String>[rootA.path, rootB.path]);

      final canonicalA = MediaEntry.canonicalSource(rootA.path);
      final canonicalB = MediaEntry.canonicalSource(rootB.path);

      // rootA was removed mid-scan, so it must not have completed scanning.
      expect(completedFolders, isNot(contains(canonicalA)));

      // rootB in the same batch must still be scanned and completed.
      expect(
        completedFolders,
        contains(canonicalB),
        reason:
            'removing folder A mid-scan must not abort folder B in the same batch',
      );

      // rootB's files must have been discovered and enriched.
      final b = await db.getMediaByCanonicalSource(bPath);
      expect(b, isNotNull);
      expect(b!.metadata.artist, 'Fake Artist');
    },
  );
}

String cFilePath(Directory root) => p.join(root.path, 'c.mp3');
