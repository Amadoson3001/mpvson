import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reopening a pre-is_in_library database migrates before indexing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mpvson-migration-',
      );
      final dbPath = p.join(directory.path, 'library.db');
      try {
        // The previous schema: every current column except is_in_library.
        final old = sqlite3.open(dbPath);
        old.execute('''
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
        old.execute(
          'INSERT INTO media (id, canonical_source, path, kind, title, added_at) '
          "VALUES ('1', 'file:///old.mp4', '/old.mp4', 'video', 'Old video', 1)",
        );
        old.close();

        final db = await LibraryDatabase.open(path: dbPath);
        try {
          final columns = await db.selectRaw('PRAGMA table_info(media)');
          expect(
            columns.map((column) => column['name']),
            contains('is_in_library'),
          );
          final indexes = await db.selectRaw(
            "SELECT name FROM sqlite_master WHERE type = 'index'",
          );
          expect(
            indexes.map((row) => row['name']),
            contains('idx_media_library_kind_added_at'),
          );
          final rows = await db.selectRaw(
            'SELECT title, is_in_library FROM media',
          );
          expect(rows.single['title'], 'Old video');
          expect(rows.single['is_in_library'], 1);
        } finally {
          await db.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
