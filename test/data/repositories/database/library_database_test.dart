import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LibraryDatabase Performance & Composite Indexes', () {
    late Directory tempDir;
    late String dbPath;
    late LibraryDatabase db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mpvson-db-perf-test-');
      dbPath = p.join(tempDir.path, 'library.db');
      db = await LibraryDatabase.open(path: dbPath);
    });

    tearDown(() async {
      await db.close();
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('pragmas are properly configured on initialization', () async {
      final journalMode = await db.getJournalMode();
      expect(journalMode.toLowerCase(), 'wal');

      final synchronous = await db.selectRaw('PRAGMA synchronous;');
      // NORMAL is 1 in SQLite
      expect(synchronous.first.values.first, 1);

      final tempStore = await db.selectRaw('PRAGMA temp_store;');
      // MEMORY is 2 in SQLite
      expect(tempStore.first.values.first, 2);

      final cacheSize = await db.selectRaw('PRAGMA cache_size;');
      expect(cacheSize.first.values.first, -8000);

      final mmapSize = await db.selectRaw('PRAGMA mmap_size;');
      expect(mmapSize.first.values.first, 33554432);

      final foreignKeys = await db.selectRaw('PRAGMA foreign_keys;');
      expect(foreignKeys.first.values.first, 1);

      final busyTimeout = await db.selectRaw('PRAGMA busy_timeout;');
      expect(busyTimeout.first.values.first, 5000);
    });

    test('composite indexes exist in schema', () async {
      final rows = await db.selectRaw(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      );
      final indexNames = rows.map((r) => r['name'] as String).toSet();

      expect(indexNames, contains('idx_media_lib_avail_kind_added'));
      expect(indexNames, contains('idx_media_lib_avail_kind_title'));
      expect(indexNames, contains('idx_media_lib_avail_kind_artist'));
      expect(indexNames, contains('idx_media_lib_avail_kind_album'));
      expect(indexNames, contains('idx_media_lib_avail_kind_last_played'));
      expect(indexNames, contains('idx_media_lib_avail_kind_play_count'));
      expect(indexNames, contains('idx_media_lib_avail_kind_duration'));
      expect(indexNames, contains('idx_media_lib_avail_kind_year'));
      expect(indexNames, contains('idx_playlist_entries_media'));
    });

    test('query planner uses composite indexes for filtered and sorted queries', () async {
      // EXPLAIN QUERY PLAN returns details indicating index usage
      final plans = <String, String>{
        'added_at':
            'SELECT media.* FROM media WHERE media.is_in_library = 1 AND media.is_available = 1 AND media.kind = ? ORDER BY media.added_at DESC',
        'title':
            'SELECT media.* FROM media WHERE media.is_in_library = 1 AND media.is_available = 1 AND media.kind = ? ORDER BY media.title COLLATE NOCASE ASC',
        'artist':
            'SELECT media.* FROM media WHERE media.is_in_library = 1 AND media.is_available = 1 AND media.kind = ? ORDER BY media.artist COLLATE NOCASE ASC, media.track_number ASC',
        'album':
            'SELECT media.* FROM media WHERE media.is_in_library = 1 AND media.is_available = 1 AND media.kind = ? ORDER BY media.album COLLATE NOCASE ASC, media.disc_number ASC, media.track_number ASC',
        'last_played':
            'SELECT media.* FROM media WHERE media.is_in_library = 1 AND media.is_available = 1 AND media.kind = ? ORDER BY media.last_played_at DESC',
        'play_count':
            'SELECT media.* FROM media WHERE media.is_in_library = 1 AND media.is_available = 1 AND media.kind = ? ORDER BY media.play_count DESC',
        'duration':
            'SELECT media.* FROM media WHERE media.is_in_library = 1 AND media.is_available = 1 AND media.kind = ? ORDER BY media.duration_ms ASC',
        'year':
            'SELECT media.* FROM media WHERE media.is_in_library = 1 AND media.is_available = 1 AND media.kind = ? ORDER BY media.year DESC',
      };

      final expectedIndexes = <String, String>{
        'added_at': 'idx_media_lib_avail_kind_added',
        'title': 'idx_media_lib_avail_kind_title',
        'artist': 'idx_media_lib_avail_kind_artist',
        'album': 'idx_media_lib_avail_kind_album',
        'last_played': 'idx_media_lib_avail_kind_last_played',
        'play_count': 'idx_media_lib_avail_kind_play_count',
        'duration': 'idx_media_lib_avail_kind_duration',
        'year': 'idx_media_lib_avail_kind_year',
      };

      for (final entry in plans.entries) {
        final rows = await db.selectRaw(
          'EXPLAIN QUERY PLAN ${entry.value}',
          ['audio'],
        );
        final detail = rows.map((r) => r['detail'].toString()).join('; ');
        final expectedIndex = expectedIndexes[entry.key]!;
        expect(
          detail,
          contains(expectedIndex),
          reason:
              'Query sorted by ${entry.key} should use $expectedIndex. Plan detail: $detail',
        );
        expect(
          detail,
          isNot(contains('USE TEMP B-TREE')),
          reason:
              'Query sorted by ${entry.key} should not require TEMP B-TREE sort when index covers it. Plan detail: $detail',
        );
      }
    });

    test('queryMedia sorts and filters correctly using the indexes', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.batchUpsertDiscoveredFiles([
        'c:\\music\\c_track.mp3',
        'c:\\music\\a_track.mp3',
        'c:\\music\\b_track.mp3',
      ]);

      await db.batchUpdateMetadata([
        MediaEnrichmentData(
          canonicalSource: 'c:\\music\\c_track.mp3',
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Charlie',
            artist: 'Zeta Artist',
            album: 'Gamma Album',
            trackNumber: 3,
            discNumber: 1,
            duration: Duration(milliseconds: 30000),
            year: 2021,
          ),
          fileSize: 3000,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(now),
        ),
        MediaEnrichmentData(
          canonicalSource: 'c:\\music\\a_track.mp3',
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Alpha',
            artist: 'Beta Artist',
            album: 'Alpha Album',
            trackNumber: 1,
            discNumber: 1,
            duration: Duration(milliseconds: 10000),
            year: 2019,
          ),
          fileSize: 1000,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(now),
        ),
        MediaEnrichmentData(
          canonicalSource: 'c:\\music\\b_track.mp3',
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Bravo',
            artist: 'Alpha Artist',
            album: 'Beta Album',
            trackNumber: 2,
            discNumber: 1,
            duration: Duration(milliseconds: 20000),
            year: 2020,
          ),
          fileSize: 2000,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(now),
        ),
      ]);

      // Query sorted by title
      final byTitle = await db.queryMedia(
        kind: MediaKind.audio,
        isAvailable: true,
        sortBy: 'title',
        ascending: true,
      );
      expect(byTitle.map((m) => m.title), ['Alpha', 'Bravo', 'Charlie']);

      // Query sorted by artist
      final byArtist = await db.queryMedia(
        kind: MediaKind.audio,
        isAvailable: true,
        sortBy: 'artist',
        ascending: true,
      );
      expect(byArtist.map((m) => m.artist), [
        'Alpha Artist',
        'Beta Artist',
        'Zeta Artist',
      ]);

      // Query sorted by duration
      final byDuration = await db.queryMedia(
        kind: MediaKind.audio,
        isAvailable: true,
        sortBy: 'duration',
        ascending: true,
      );
      expect(byDuration.map((m) => m.metadata.duration.inMilliseconds), [
        10000,
        20000,
        30000,
      ]);

      // Query sorted by year DESC
      final byYear = await db.queryMedia(
        kind: MediaKind.audio,
        isAvailable: true,
        sortBy: 'year',
        ascending: false,
      );
      expect(byYear.map((m) => m.metadata.year), [2021, 2020, 2019]);
    });

    test('migration creates new composite indexes without losing data', () async {
      final migrationDir = await Directory.systemTemp.createTemp('mpvson-mig-idx-');
      addTearDown(() {
        try {
          migrationDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final oldDbPath = p.join(migrationDir.path, 'legacy.db');
      // Create a legacy database without composite indexes
      final raw = sqlite3.open(oldDbPath);
      raw.execute('''
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
          is_in_library INTEGER NOT NULL DEFAULT 1,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          added_at INTEGER NOT NULL,
          last_played_at INTEGER,
          play_count INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO media (id, canonical_source, path, kind, title, added_at)
        VALUES ('1', 'file:///legacy.mp3', '/legacy.mp3', 'audio', 'Legacy Song', 100);
      ''');
      raw.close();

      // Open with LibraryDatabase, which applies initialization and creates indexes
      final migratedDb = await LibraryDatabase.open(path: oldDbPath);
      try {
        final rows = await migratedDb.selectRaw(
          "SELECT name FROM sqlite_master WHERE type = 'index'",
        );
        final indexNames = rows.map((r) => r['name'] as String).toSet();

        expect(indexNames, contains('idx_media_lib_avail_kind_added'));
        expect(indexNames, contains('idx_media_lib_avail_kind_title'));
        expect(indexNames, contains('idx_media_lib_avail_kind_artist'));
        expect(indexNames, contains('idx_media_lib_avail_kind_album'));
        expect(indexNames, contains('idx_media_lib_avail_kind_last_played'));
        expect(indexNames, contains('idx_media_lib_avail_kind_play_count'));
        expect(indexNames, contains('idx_media_lib_avail_kind_duration'));
        expect(indexNames, contains('idx_media_lib_avail_kind_year'));

        // Existing data preserved
        final media = await migratedDb.getMediaById('1');
        expect(media, isNotNull);
        expect(media!.title, 'Legacy Song');
        expect(media.canonicalSource, 'file:///legacy.mp3');
      } finally {
        await migratedDb.close();
      }
    });

    test('batch operations execute within single transactions', () async {
      // 1. batchUpsertDiscoveredFiles
      await db.batchUpsertDiscoveredFiles([
        'c:\\music\\song1.mp3',
        'c:\\music\\song2.mp3',
        'c:\\music\\song3.mp3',
      ]);
      final count = await db.selectRaw('SELECT COUNT(*) AS c FROM media;');
      expect(count.first['c'], 3);

      // 2. markFolderAvailability operates in transaction
      await db.insertFolder(
        LibraryFolderRecord(
          path: 'c:\\music',
          addedAt: DateTime.now(),
          isAvailable: true,
          fileCount: 3,
        ),
      );
      await db.markFolderAvailability('c:\\music', false);
      final unavailable = await db.selectRaw(
        'SELECT COUNT(*) AS c FROM media WHERE is_available = 0;',
      );
      expect(unavailable.first['c'], 3);

      // 3. addPathsToPlaylist runs in single transaction
      final playlist = await db.createPlaylist('Test Playlist');
      await db.addPathsToPlaylist(
        playlist.id,
        [
          'c:\\music\\song1.mp3',
          'c:\\music\\song2.mp3',
        ],
      );
      final entries = await db.getPlaylistEntries(playlist.id);
      expect(entries.length, 2);
    });
  });
}
