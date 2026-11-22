part of 'library_database.dart';

/// Schema version tracked in PRAGMA user_version.
///
/// Version 2 describes the FTS5 external-content search table with
/// album_artist and path columns; version 0 (or 1) marks a database that still
/// needs the migration (or was left mid-migration by a crash).
const int _currentSchemaVersion = 3;

int _readUserVersion(Database db) {
  final rows = db.select('PRAGMA user_version;');
  return (rows.first.values.first as int?) ?? 0;
}

void _initializeSchema(Database db) {
  if (_readUserVersion(db) >= _currentSchemaVersion) {
    _createSchema(db);
    return;
  }

  // The migration runs as a single transaction (D-6): a crash part-way rolls
  // back to the previous consistent state, is tracked by user_version, and is
  // retried whole on the next open instead of leaving a half-built search
  // index (an external-content FTS table committed without its rebuild stays
  // empty forever).
  db.execute('BEGIN IMMEDIATE;');
  try {
    final userVersion = _readUserVersion(db);
    var rebuildFts = userVersion < 2;
    final ftsCheck = db.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'media_fts'",
    );
    if (ftsCheck.isNotEmpty) {
      final ftsCols = db.select("PRAGMA table_info('media_fts')");
      final hasFilename = ftsCols.any((c) => c['name'] == 'filename');
      final hasAlbumArtist = ftsCols.any((c) => c['name'] == 'album_artist');
      final hasPath = ftsCols.any((c) => c['name'] == 'path');
      if (hasFilename || !hasAlbumArtist || !hasPath) {
        db.execute('DROP TRIGGER IF EXISTS media_ai');
        db.execute('DROP TRIGGER IF EXISTS media_ad');
        db.execute('DROP TRIGGER IF EXISTS media_au');
        db.execute('DROP TABLE IF EXISTS media_fts');
        rebuildFts = true;
      }
    } else {
      rebuildFts = true;
    }

    // Pre-migration media tables may lack is_in_library; add it before the
    // schema script creates the index that references the column. A fresh
    // database gets the column from the CREATE TABLE below.
    final mediaTableExists = db
        .select(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'media'",
        )
        .isNotEmpty;
    if (mediaTableExists) {
      final columns = db
          .select('PRAGMA table_info(media)')
          .map((column) => column['name'] as String)
          .toSet();
      const migrations = <String, String>{
        'is_in_library': 'INTEGER NOT NULL DEFAULT 1',
        'video_codec': 'TEXT',
        'video_width': 'INTEGER',
        'video_height': 'INTEGER',
        'video_fps': 'REAL',
        'video_bitrate': 'INTEGER',
      };
      for (final entry in migrations.entries) {
        if (!columns.contains(entry.key)) {
          db.execute(
            'ALTER TABLE media ADD COLUMN ${entry.key} ${entry.value}',
          );
        }
      }
    }

    _createSchema(db);

    if (!rebuildFts) {
      final mediaCount =
          db.select('SELECT count(*) AS c FROM media').first['c'] as int;
      if (mediaCount > 0) {
        int ftsCount = 0;
        final docsizeExists = db
            .select(
              "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'media_fts_docsize'",
            )
            .isNotEmpty;
        if (docsizeExists) {
          ftsCount =
              db
                      .select('SELECT count(*) AS c FROM media_fts_docsize')
                      .first['c']
                  as int;
        } else {
          try {
            ftsCount =
                db.select('SELECT count(*) AS c FROM media_fts').first['c']
                    as int;
          } catch (_) {
            ftsCount = 0;
          }
        }
        if (ftsCount == 0) {
          rebuildFts = true;
        }
      }
    }

    if (rebuildFts) {
      final mediaCount =
          db.select('SELECT count(*) AS c FROM media').first['c'] as int;
      if (mediaCount > 0) {
        db.execute("INSERT INTO media_fts(media_fts) VALUES('rebuild');");
      }
    }

    db.execute('PRAGMA user_version = $_currentSchemaVersion;');
    db.execute('COMMIT;');
  } catch (_) {
    db.execute('ROLLBACK;');
    rethrow;
  }
}

void _createSchema(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS folders (
      path TEXT PRIMARY KEY,
      added_at INTEGER NOT NULL,
      last_scanned_at INTEGER,
      is_available INTEGER NOT NULL DEFAULT 1,
      file_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS media (
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
      video_codec TEXT,
      video_width INTEGER,
      video_height INTEGER,
      video_fps REAL,
      video_bitrate INTEGER,
      file_size INTEGER NOT NULL DEFAULT 0,
      modified_at INTEGER,
      is_available INTEGER NOT NULL DEFAULT 1,
      is_in_library INTEGER NOT NULL DEFAULT 1,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      added_at INTEGER NOT NULL,
      last_played_at INTEGER,
      play_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_media_path ON media(path);
    CREATE INDEX IF NOT EXISTS idx_media_kind ON media(kind);
    CREATE INDEX IF NOT EXISTS idx_media_artist ON media(artist);
    CREATE INDEX IF NOT EXISTS idx_media_album ON media(album);
    CREATE INDEX IF NOT EXISTS idx_media_is_favorite ON media(is_favorite);
    CREATE INDEX IF NOT EXISTS idx_media_is_available ON media(is_available);
    CREATE INDEX IF NOT EXISTS idx_media_added_at ON media(added_at);
    CREATE INDEX IF NOT EXISTS idx_media_title ON media(title COLLATE NOCASE);
    CREATE INDEX IF NOT EXISTS idx_media_last_played ON media(last_played_at);
    CREATE INDEX IF NOT EXISTS idx_media_kind_added_at ON media(kind, added_at DESC);
    CREATE INDEX IF NOT EXISTS idx_media_library_kind_added_at ON media(is_in_library, kind, added_at DESC);
    CREATE INDEX IF NOT EXISTS idx_media_album_track ON media(album, track_number);
    CREATE INDEX IF NOT EXISTS idx_media_album_disc_track ON media(album, disc_number, track_number);
    CREATE INDEX IF NOT EXISTS idx_media_lib_avail_kind_added ON media(is_in_library, is_available, kind, added_at DESC);
    CREATE INDEX IF NOT EXISTS idx_media_lib_avail_kind_title ON media(is_in_library, is_available, kind, title COLLATE NOCASE);
    CREATE INDEX IF NOT EXISTS idx_media_lib_avail_kind_artist ON media(is_in_library, is_available, kind, artist COLLATE NOCASE, track_number);
    CREATE INDEX IF NOT EXISTS idx_media_lib_avail_kind_album ON media(is_in_library, is_available, kind, album COLLATE NOCASE, disc_number, track_number);
    CREATE INDEX IF NOT EXISTS idx_media_lib_avail_kind_last_played ON media(is_in_library, is_available, kind, last_played_at DESC);
    CREATE INDEX IF NOT EXISTS idx_media_lib_avail_kind_play_count ON media(is_in_library, is_available, kind, play_count DESC);
    CREATE INDEX IF NOT EXISTS idx_media_lib_avail_kind_duration ON media(is_in_library, is_available, kind, duration_ms);
    CREATE INDEX IF NOT EXISTS idx_media_lib_avail_kind_year ON media(is_in_library, is_available, kind, year DESC);

    CREATE TABLE IF NOT EXISTS playlists (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS playlist_entries (
      id TEXT PRIMARY KEY,
      playlist_id TEXT NOT NULL,
      media_id TEXT NOT NULL,
      position INTEGER NOT NULL,
      added_at INTEGER NOT NULL,
      FOREIGN KEY (playlist_id) REFERENCES playlists (id) ON DELETE CASCADE,
      FOREIGN KEY (media_id) REFERENCES media (id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_playlist_entries_playlist ON playlist_entries (playlist_id, position);
    CREATE INDEX IF NOT EXISTS idx_playlist_entries_media ON playlist_entries (media_id);

    CREATE VIRTUAL TABLE IF NOT EXISTS media_fts USING fts5(
      title,
      artist,
      album_artist,
      album,
      path,
      content=media,
      content_rowid=rowid
    );

    CREATE TRIGGER IF NOT EXISTS media_ai AFTER INSERT ON media BEGIN
      INSERT INTO media_fts(rowid, title, artist, album_artist, album, path)
      VALUES (new.rowid, new.title, new.artist, new.album_artist, new.album, new.path);
    END;

    CREATE TRIGGER IF NOT EXISTS media_ad AFTER DELETE ON media BEGIN
      INSERT INTO media_fts(media_fts, rowid, title, artist, album_artist, album, path)
      VALUES('delete', old.rowid, old.title, old.artist, old.album_artist, old.album, old.path);
    END;

    DROP TRIGGER IF EXISTS media_au;
    CREATE TRIGGER media_au AFTER UPDATE OF title, artist, album_artist, album, path ON media BEGIN
      INSERT INTO media_fts(media_fts, rowid, title, artist, album_artist, album, path)
      VALUES('delete', old.rowid, old.title, old.artist, old.album_artist, old.album, old.path);
      INSERT INTO media_fts(rowid, title, artist, album_artist, album, path)
      VALUES (new.rowid, new.title, new.artist, new.album_artist, new.album, new.path);
    END;
  ''');
}
