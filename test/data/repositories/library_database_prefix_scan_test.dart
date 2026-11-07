import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:path/path.dart' as p;

/// Root prefix shared by every synthetic library path in these tests.
///
/// The paths never exist on disk; the database only needs them to canonicalize
/// consistently, exactly like the real scanner-provided paths would.
String _folderPath(int index) =>
    p.join(r'C:\mpvson-prefix-scan', 'folder-$index');

String _trackPath(int folder, int track) =>
    p.join(_folderPath(folder), 'track-$track.mp3');

Future<LibraryDatabase> _openDatabase() async {
  final db = await LibraryDatabase.open(inMemory: true);
  addTearDown(() {
    if (!db.isClosed) return db.close();
    return Future<void>.value();
  });
  return db;
}

Future<void> _seedLibrary(
  LibraryDatabase db, {
  required int folderCount,
  required int filesPerFolder,
}) async {
  for (var folder = 0; folder < folderCount; folder++) {
    await db.batchUpsertDiscoveredFiles(
      List<String>.generate(
        filesPerFolder,
        (track) => _trackPath(folder, track),
      ),
    );
  }
}

Future<int> _availabilityOf(LibraryDatabase db, String path) async {
  final rows = await db.selectRaw(
    'SELECT is_available FROM media WHERE canonical_source = ?',
    [MediaEntry.canonicalSource(path)],
  );
  return rows.single['is_available'] as int;
}

void main() {
  test(
    'a watcher reconcile over a 10k-row library stays fast and accurate',
    () async {
      final db = await _openDatabase();
      const folderCount = 10;
      const filesPerFolder = 1000;
      await _seedLibrary(
        db,
        folderCount: folderCount,
        filesPerFolder: filesPerFolder,
      );

      final folderZeroPaths = List<String>.generate(
        filesPerFolder,
        (track) => _trackPath(0, track),
      );

      // Warm-up pass so isolate handshake and statement preparation costs do
      // not land in the measured batch.
      await db.reconcileFolderFiles(_folderPath(0), folderZeroPaths);

      final watch = Stopwatch()..start();
      await db.reconcileFolderFiles(_folderPath(0), folderZeroPaths);
      watch.stop();

      // ignore: avoid_print
      print(
        'D-9 measured: reconcileFolderFiles over a 10k-row library '
        '(${folderCount * filesPerFolder} rows, '
        '$filesPerFolder-file batch) took ${watch.elapsedMilliseconds} ms',
      );

      // The whole-library Dart loop this replaces made the batch scale with
      // every row in the media table. Bound it generously to stay robust on
      // loaded CI machines while still catching a regression to the scan.
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'a 10k-row watcher batch must not scan the whole library',
      );

      // Accuracy: a complete discovered snapshot marks nothing missing.
      for (var track = 0; track < filesPerFolder; track++) {
        expect(
          await _availabilityOf(db, _trackPath(0, track)),
          1,
          reason: 'folder 0 file $track was part of the discovered batch',
        );
      }
    },
  );

  test(
    'a watcher batch marks only the stale files of its own folder',
    () async {
      final db = await _openDatabase();
      const filesPerFolder = 50;
      await _seedLibrary(db, folderCount: 3, filesPerFolder: filesPerFolder);

      // One file vanishes from folder 1's watcher snapshot. Nested files share
      // the folder prefix and must survive the reconcile.
      final partialSnapshot = List<String>.generate(
        filesPerFolder,
        (track) => _trackPath(1, track),
      )..removeLast();

      await db.reconcileFolderFiles(_folderPath(1), partialSnapshot);

      expect(
        await _availabilityOf(db, _trackPath(1, filesPerFolder - 1)),
        0,
        reason: 'the file missing from the snapshot must be marked unavailable',
      );
      expect(
        await _availabilityOf(db, _trackPath(1, 0)),
        1,
        reason: 'sibling files in the snapshot stay available',
      );
      expect(
        await _availabilityOf(db, _trackPath(0, 0)),
        1,
        reason: 'another folder must not be touched by the reconcile',
      );
      expect(
        await _availabilityOf(db, _trackPath(2, filesPerFolder - 1)),
        1,
        reason: 'another folder must not be touched by the reconcile',
      );
    },
  );

  test('marking a folder unavailable marks all of its files', () async {
    final db = await _openDatabase();
    const filesPerFolder = 20;
    await _seedLibrary(db, folderCount: 2, filesPerFolder: filesPerFolder);

    await db.markFolderAvailability(_folderPath(0), false);

    for (var track = 0; track < filesPerFolder; track++) {
      expect(await _availabilityOf(db, _trackPath(0, track)), 0);
    }
    expect(await _availabilityOf(db, _trackPath(1, 0)), 1);
  });

  test(
    'deleting a folder untracks its files and leaves other folders',
    () async {
      final db = await _openDatabase();
      await db.batchUpsertDiscoveredFiles([
        p.join(r'C:\mpvson-prefix-scan', 'keep', 'a.mp3'),
        p.join(r'C:\mpvson-prefix-scan', 'gone', 'b.mp3'),
        p.join(r'C:\mpvson-prefix-scan', 'gone', 'nested', 'c.mp3'),
      ]);

      Future<int> inLibrary(String path) async {
        final rows = await db.selectRaw(
          'SELECT is_in_library FROM media WHERE canonical_source = ?',
          [MediaEntry.canonicalSource(path)],
        );
        return rows.single['is_in_library'] as int;
      }

      await db.deleteFolder(r'C:\mpvson-prefix-scan\gone');

      expect(
        await inLibrary(r'C:\mpvson-prefix-scan\gone\b.mp3'),
        0,
        reason: 'the removed folder must no longer cover this file',
      );
      expect(
        await inLibrary(r'C:\mpvson-prefix-scan\gone\nested\c.mp3'),
        0,
        reason: 'the removed folder must no longer cover nested files',
      );
      expect(
        await inLibrary(r'C:\mpvson-prefix-scan\keep\a.mp3'),
        1,
        reason: 'a file outside the removed folder stays in the library',
      );
    },
  );
}
