import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

/// Creates a legacy (pre-FTS5-rework) database file with media rows and an
/// old-shaped search table (filename column, no album_artist/path). The media
/// table mirrors the schema as it existed before the FTS rework: no
/// is_in_library column yet.
Database _createLegacyDatabase(String path) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE media (
      id TEXT PRIMARY KEY,
      canonical_source TEXT UNIQUE NOT NULL,
      path TEXT NOT NULL,
      kind TEXT NOT NULL,
      title TEXT,
      artist TEXT,
      album_artist TEXT,
      album TEXT,
      genre TEXT,
      year INTEGER,
      track_number INTEGER,
      disc_number INTEGER,
      duration_ms INTEGER,
      artwork_uri TEXT,
      audio_codec TEXT,
      sample_rate INTEGER,
      channels INTEGER,
      bitrate INTEGER,
      bits_per_sample INTEGER,
      file_size INTEGER NOT NULL DEFAULT 0,
      modified_at INTEGER,
      is_available INTEGER NOT NULL DEFAULT 1,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      added_at INTEGER NOT NULL,
      last_played_at INTEGER,
      play_count INTEGER NOT NULL DEFAULT 0
    );
  ''');
  db.execute('''
    CREATE VIRTUAL TABLE media_fts USING fts5(
      title,
      filename,
      content=media,
      content_rowid=rowid
    );
  ''');
  final stmt = db.prepare('''
    INSERT INTO media (id, canonical_source, path, kind, title, artist, album, added_at)
    VALUES (?, ?, ?, 'audio', ?, 'Queen', 'A Night At The Opera', 1000)
  ''');
  try {
    stmt.execute([
      'id-1',
      r'c:\music\bohemian.mp3',
      r'C:\Music\bohemian.mp3',
      'Bohemian Rhapsody',
    ]);
    stmt.execute([
      'id-2',
      r'c:\music\hotel.mp3',
      r'C:\Music\hotel.mp3',
      'Hotel California',
    ]);
  } finally {
    stmt.close();
  }
  return db;
}

int _userVersion(Database db) =>
    (db.select('PRAGMA user_version;').first.values.first as int?) ?? 0;

bool _ftsHasFilenameColumn(Database db) {
  final cols = db.select("PRAGMA table_info('media_fts')");
  return cols.any((c) => c['name'] == 'filename');
}

void main() {
  test(
    'a crash mid-migration rolls back cleanly and a retry makes FTS search work',
    () async {
      final dir = await Directory.systemTemp.createTemp('mpvson-fts-mig-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on Object {
          // Best-effort cleanup; temp dir may already be gone.
        }
      });
      final path = p.join(dir.path, 'library.db');
      final db = _createLegacyDatabase(path);
      try {
        expect(_userVersion(db), 0);
        expect(_ftsHasFilenameColumn(db), isTrue);

        // Simulated crash: the migration fails after the DDL and rebuild
        // steps, before user_version is recorded.
        expect(
          () => debugRunSchemaMigrationForTesting(
            db,
            midMigrationFaultForTesting: (db) =>
                throw StateError('simulated crash mid-migration'),
          ),
          throwsStateError,
        );

        // The transaction rolled back: still version 0, legacy FTS intact,
        // media rows untouched.
        expect(_userVersion(db), 0);
        expect(_ftsHasFilenameColumn(db), isTrue);
        expect(db.select('SELECT count(*) AS c FROM media').first['c'], 2);

        // Retry without the injected fault completes and rebuilds the index.
        debugRunSchemaMigrationForTesting(db);
        expect(_userVersion(db), 2);
        expect(_ftsHasFilenameColumn(db), isFalse);

        final hits = db.select(
          "SELECT rowid FROM media_fts WHERE media_fts MATCH 'rhapsody'",
        );
        expect(hits, isNotEmpty);
        final artistHits = db.select(
          "SELECT rowid FROM media_fts WHERE media_fts MATCH 'hotel'",
        );
        expect(artistHits, isNotEmpty);
      } finally {
        db.close();
      }
    },
  );

  test(
    'opening a legacy database through LibraryDatabase migrates and searches',
    () async {
      final dir = await Directory.systemTemp.createTemp('mpvson-fts-open-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on Object {
          // Best-effort cleanup; temp dir may already be gone.
        }
      });
      final path = p.join(dir.path, 'library.db');
      final raw = _createLegacyDatabase(path);
      raw.close();

      final db = await LibraryDatabase.open(path: path);
      addTearDown(db.close);

      final results = await db.queryMedia(searchQuery: 'bohemian');
      expect(results, isNotEmpty);
      expect(results.first.title, 'Bohemian Rhapsody');

      // A second open takes the fast path (version already current) and
      // search keeps working.
      await db.close();
      final reopened = await LibraryDatabase.open(path: path);
      addTearDown(reopened.close);
      final again = await reopened.queryMedia(searchQuery: 'hotel');
      expect(again, isNotEmpty);
      expect(again.first.title, 'Hotel California');
    },
  );
}
