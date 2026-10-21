import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('library_db_test_');
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Schema creation and WAL mode', () {
    test('initializes schema and tables in memory', () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      // Verify tables exist
      final tables = await db.selectRaw(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;",
      );
      final tableNames = tables.map((r) => r['name'] as String).toSet();

      expect(tableNames, contains('folders'));
      expect(tableNames, contains('media'));
      expect(tableNames, contains('playlists'));
      expect(tableNames, contains('playlist_entries'));
      expect(tableNames, contains('media_fts'));
    });

    test('enables WAL mode on disk-backed database', () async {
      final dbPath = p.join(tempDir.path, 'library.db');
      final db = await LibraryDatabase.open(path: dbPath);
      addTearDown(db.close);

      final journalMode = await db.getJournalMode();
      expect(journalMode.toLowerCase(), equals('wal'));
    });
  });

  group('Media CRUD and batch operations', () {
    test('inserts, updates, retrieves and deletes media items', () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      final now = DateTime.now();
      final item = MediaItemRecord(
        id: 'media-1',
        canonicalSource: 'file:///music/song.mp3',
        path: '/music/song.mp3',
        kind: MediaKind.audio,
        metadata: const MediaMetadata(
          title: 'Initial Title',
          artist: 'Initial Artist',
          album: 'Initial Album',
          duration: Duration(minutes: 3),
        ),
        fileSize: 1024,
        addedAt: DateTime(2026, 1, 1),
      );

      // Insert
      await db.insertMedia(item);

      // Retrieve by ID
      final retrievedById = await db.getMediaById('media-1');
      expect(retrievedById, isNotNull);
      expect(retrievedById!.title, equals('Initial Title'));
      expect(retrievedById.artist, equals('Initial Artist'));
      expect(retrievedById.fileSize, equals(1024));

      // Retrieve by Canonical Source
      final retrievedBySource = await db.getMediaByCanonicalSource(
        'file:///music/song.mp3',
      );
      expect(retrievedBySource, isNotNull);
      expect(retrievedBySource!.id, equals('media-1'));

      // Retrieve by Path
      final retrievedByPath = await db.getMediaByPath('/music/song.mp3');
      expect(retrievedByPath, isNotNull);
      expect(retrievedByPath!.id, equals('media-1'));

      // Update
      final updatedItem = item.copyWith(
        metadata: item.metadata.copyWith(title: 'Updated Title'),
        lastPlayedAt: now,
        playCount: 5,
      );
      await db.updateMedia(updatedItem);

      final retrievedUpdated = await db.getMediaById('media-1');
      expect(retrievedUpdated!.title, equals('Updated Title'));
      expect(retrievedUpdated.playCount, equals(5));

      // Delete by ID
      await db.deleteMedia('media-1');
      final afterDelete = await db.getMediaById('media-1');
      expect(afterDelete, isNull);
    });

    test('batch upserts discovered files and infers kind', () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      final paths = [
        '/music/track1.mp3',
        '/music/track2.flac',
        '/movies/clip.mp4',
      ];

      await db.batchUpsertDiscoveredFiles(paths);

      final items = await db.queryMedia();
      expect(items.length, equals(3));

      final audioItems = await db.queryMedia(kind: MediaKind.audio);
      expect(audioItems.length, equals(2));

      final videoItems = await db.queryMedia(kind: MediaKind.video);
      expect(videoItems.length, equals(1));
      expect(videoItems.first.path, endsWith('clip.mp4'));

      // Running batchUpsertDiscoveredFiles again is idempotent
      await db.batchUpsertDiscoveredFiles(paths);
      final itemsAfterSecond = await db.queryMedia();
      expect(itemsAfterSecond.length, equals(3));
    });

    test('batch enriches metadata on existing items', () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      final file1 = '/music/bohemian.flac';
      final file2 = '/music/hotel.mp3';
      await db.batchUpsertDiscoveredFiles([file1, file2]);

      final source1 = Uri.file(file1).toString();
      final source2 = Uri.file(file2).toString();

      await db.batchUpdateMetadata([
        MediaEnrichmentData(
          canonicalSource: source1,
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Bohemian Rhapsody',
            artist: 'Queen',
            album: 'A Night at the Opera',
            genre: 'Rock',
            year: 1975,
            trackNumber: 11,
            discNumber: 1,
            duration: Duration(seconds: 354),
            audioInfo: AudioTechnicalInfo(
              codec: 'flac',
              sampleRate: 44100,
              channels: 2,
              bitrate: 900000,
              bitsPerSample: 16,
            ),
          ),
          fileSize: 45000000,
          modifiedAt: DateTime(2026, 1, 1),
        ),
        MediaEnrichmentData(
          canonicalSource: source2,
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Hotel California',
            artist: 'Eagles',
            album: 'Hotel California',
            genre: 'Rock',
            year: 1976,
            trackNumber: 1,
            discNumber: 1,
            duration: Duration(seconds: 391),
          ),
          fileSize: 9500000,
          modifiedAt: DateTime(2026, 1, 2),
        ),
      ]);

      final item1 = await db.getMediaByCanonicalSource(source1);
      expect(item1, isNotNull);
      expect(item1!.title, equals('Bohemian Rhapsody'));
      expect(item1.artist, equals('Queen'));
      expect(item1.album, equals('A Night at the Opera'));
      expect(item1.metadata.audioInfo?.codec, equals('flac'));
      expect(item1.fileSize, equals(45000000));

      final item2 = await db.getMediaByCanonicalSource(source2);
      expect(item2, isNotNull);
      expect(item2!.title, equals('Hotel California'));
      expect(item2.artist, equals('Eagles'));
    });
  });

  group('FTS5 full-text search', () {
    late LibraryDatabase db;

    setUp(() async {
      db = await LibraryDatabase.open(inMemory: true);

      // Populate test media library
      final mediaList = [
        MediaItemRecord(
          id: '1',
          canonicalSource: 'file:///music/rock/bohemian_rhapsody.flac',
          path: '/music/rock/bohemian_rhapsody.flac',
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Bohemian Rhapsody',
            artist: 'Queen',
            album: 'A Night at the Opera',
            year: 1975,
          ),
          addedAt: DateTime(2026, 1, 1),
        ),
        MediaItemRecord(
          id: '2',
          canonicalSource: 'file:///music/rock/hotel_california.mp3',
          path: '/music/rock/hotel_california.mp3',
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Hotel California',
            artist: 'Eagles',
            album: 'Hotel California',
            year: 1976,
          ),
          addedAt: DateTime(2026, 1, 2),
        ),
        MediaItemRecord(
          id: '3',
          canonicalSource: 'file:///music/classical/symphony_no_5.mp3',
          path: '/music/classical/beethoven_symphony_no_5.mp3',
          kind: MediaKind.audio,
          metadata: const MediaMetadata(
            title: 'Symphony No. 5 in C Minor',
            artist: 'Ludwig van Beethoven',
            album: 'Beethoven: Complete Symphonies',
            year: 1808,
          ),
          addedAt: DateTime(2026, 1, 3),
        ),
        MediaItemRecord(
          id: '4',
          canonicalSource: 'file:///videos/live_concert_queen.mp4',
          path: '/videos/live_concert_queen.mp4',
          kind: MediaKind.video,
          metadata: const MediaMetadata(
            title: 'Live at Wembley 1986',
            artist: 'Queen',
            album: 'Live at Wembley',
            year: 1986,
          ),
          addedAt: DateTime(2026, 1, 4),
        ),
      ];

      await db.batchUpsertMedia(mediaList);
    });

    tearDown(() async {
      await db.close();
    });

    test('searches by title', () async {
      final results = await db.queryMedia(searchQuery: 'Bohemian');
      expect(results.length, equals(1));
      expect(results.first.title, equals('Bohemian Rhapsody'));
    });

    test('searches by artist', () async {
      final results = await db.queryMedia(searchQuery: 'Queen');
      expect(results.length, equals(2));
      final ids = results.map((r) => r.id).toSet();
      expect(ids, containsAll(['1', '4']));
    });

    test('searches by album', () async {
      final results = await db.queryMedia(searchQuery: 'Night Opera');
      expect(results.length, equals(1));
      expect(results.first.id, equals('1'));
    });

    test('searches by filename', () async {
      final results = await db.queryMedia(searchQuery: 'hotel_california.mp3');
      expect(results.length, equals(1));
      expect(results.first.id, equals('2'));
    });

    test('searches with special characters without crashing', () async {
      final results = await db.queryMedia(searchQuery: 'Queen (Live) [1986]*!');
      expect(results.length, equals(1));
      expect(results.first.id, equals('4'));
    });

    test('filters search results by kind', () async {
      final results = await db.queryMedia(
        searchQuery: 'Queen',
        kind: MediaKind.video,
      );
      expect(results.length, equals(1));
      expect(results.first.id, equals('4'));
    });

    test('FTS index is updated when media item is modified', () async {
      // Insert an item with a unique title not present in path, artist or album
      final uniqueItem = MediaItemRecord(
        id: 'unique-1',
        canonicalSource: 'file:///music/rock/song_unique.flac',
        path: '/music/rock/song_unique.flac',
        kind: MediaKind.audio,
        metadata: const MediaMetadata(
          title: 'Scaramouche',
          artist: 'Queen',
          album: 'A Night at the Opera',
          year: 1975,
        ),
        addedAt: DateTime(2026, 1, 1),
      );
      await db.insertMedia(uniqueItem);

      // Verify it matches Scaramouche
      final initialResults = await db.queryMedia(searchQuery: 'Scaramouche');
      expect(initialResults.length, equals(1));
      expect(initialResults.first.id, equals('unique-1'));

      // Update title to 'Fandango'
      await db.updateMedia(
        uniqueItem.copyWith(
          metadata: uniqueItem.metadata.copyWith(title: 'Fandango'),
        ),
      );

      // Old title no longer matches
      final oldResults = await db.queryMedia(searchQuery: 'Scaramouche');
      expect(oldResults, isEmpty);

      // New title matches
      final newResults = await db.queryMedia(searchQuery: 'Fandango');
      expect(newResults.length, equals(1));
      expect(newResults.first.id, equals('unique-1'));
    });

    test('FTS index removes entries when media item is deleted', () async {
      await db.deleteMedia('2');
      final results = await db.queryMedia(searchQuery: 'Eagles');
      expect(results, isEmpty);
    });
  });

  group('Playlists and ordered entries', () {
    late LibraryDatabase db;

    setUp(() async {
      db = await LibraryDatabase.open(inMemory: true);

      // Add three media items
      for (var i = 1; i <= 3; i++) {
        await db.insertMedia(
          MediaItemRecord(
            id: 'song-$i',
            canonicalSource: 'file:///music/song$i.mp3',
            path: '/music/song$i.mp3',
            metadata: MediaMetadata(title: 'Song $i', artist: 'Artist $i'),
            addedAt: DateTime(2026, 1, i),
          ),
        );
      }
    });

    tearDown(() async {
      await db.close();
    });

    test('creates playlist, adds entries, and maintains order', () async {
      final playlist = await db.createPlaylist('My Favorites');
      expect(playlist.title, equals('My Favorites'));

      await db.addEntriesToPlaylist(playlist.id, ['song-1', 'song-2', 'song-3']);

      final entries = await db.getPlaylistEntries(playlist.id);
      expect(entries.length, equals(3));
      expect(entries[0].mediaId, equals('song-1'));
      expect(entries[0].position, equals(0));
      expect(entries[0].mediaItem?.title, equals('Song 1'));

      expect(entries[1].mediaId, equals('song-2'));
      expect(entries[1].position, equals(1));

      expect(entries[2].mediaId, equals('song-3'));
      expect(entries[2].position, equals(2));
    });

    test('reorders entries cleanly', () async {
      final playlist = await db.createPlaylist('Reorder Test');
      await db.addEntriesToPlaylist(playlist.id, ['song-1', 'song-2', 'song-3']);

      // Move song-1 (oldIndex: 0) to index: 2
      await db.reorderPlaylistEntries(playlist.id, 0, 2);

      final entries = await db.getPlaylistEntries(playlist.id);
      expect(entries.length, equals(3));
      expect(entries[0].mediaId, equals('song-2'));
      expect(entries[0].position, equals(0));

      expect(entries[1].mediaId, equals('song-3'));
      expect(entries[1].position, equals(1));

      expect(entries[2].mediaId, equals('song-1'));
      expect(entries[2].position, equals(2));
    });

    test('removes entry and compacts remaining positions', () async {
      final playlist = await db.createPlaylist('Remove Test');
      await db.addEntriesToPlaylist(playlist.id, ['song-1', 'song-2', 'song-3']);

      final entriesBefore = await db.getPlaylistEntries(playlist.id);
      final secondEntryId = entriesBefore[1].id;

      await db.removePlaylistEntry(secondEntryId);

      final entriesAfter = await db.getPlaylistEntries(playlist.id);
      expect(entriesAfter.length, equals(2));
      expect(entriesAfter[0].mediaId, equals('song-1'));
      expect(entriesAfter[0].position, equals(0));

      expect(entriesAfter[1].mediaId, equals('song-3'));
      expect(entriesAfter[1].position, equals(1));
    });

    test('renames and deletes playlist cascading entries', () async {
      final playlist = await db.createPlaylist('Original Title');
      await db.addEntriesToPlaylist(playlist.id, ['song-1', 'song-2']);

      await db.renamePlaylist(playlist.id, 'Renamed Title');
      final fetched = await db.getPlaylist(playlist.id);
      expect(fetched?.title, equals('Renamed Title'));

      await db.deletePlaylist(playlist.id);
      final afterDelete = await db.getPlaylist(playlist.id);
      expect(afterDelete, isNull);

      final remainingEntries = await db.getPlaylistEntries(playlist.id);
      expect(remainingEntries, isEmpty);
    });
  });

  group('Disconnected drive / availability marking', () {
    late LibraryDatabase db;

    setUp(() async {
      db = await LibraryDatabase.open(inMemory: true);

      // Add external drive folder
      await db.insertFolder(
        LibraryFolderRecord(
          path: 'D:/ExternalMusic',
          addedAt: DateTime(2026, 1, 1),
          fileCount: 2,
        ),
      );

      // Add local drive folder
      await db.insertFolder(
        LibraryFolderRecord(
          path: 'C:/LocalMusic',
          addedAt: DateTime(2026, 1, 1),
          fileCount: 1,
        ),
      );

      // Add items on external drive
      await db.insertMedia(
        MediaItemRecord(
          id: 'ext-1',
          canonicalSource: 'file:///D:/ExternalMusic/song1.mp3',
          path: 'D:/ExternalMusic/song1.mp3',
          kind: MediaKind.audio,
          addedAt: DateTime(2026, 1, 1),
        ),
      );
      await db.insertMedia(
        MediaItemRecord(
          id: 'ext-2',
          canonicalSource: 'file:///D:/ExternalMusic/sub/song2.mp3',
          path: 'D:/ExternalMusic/sub/song2.mp3',
          kind: MediaKind.audio,
          addedAt: DateTime(2026, 1, 1),
        ),
      );

      // Add item on local drive
      await db.insertMedia(
        MediaItemRecord(
          id: 'loc-1',
          canonicalSource: 'file:///C:/LocalMusic/song3.mp3',
          path: 'C:/LocalMusic/song3.mp3',
          kind: MediaKind.audio,
          addedAt: DateTime(2026, 1, 1),
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('marks external drive unavailable and filters media correctly', () async {
      // Initially all are available
      final initialAvailable = await db.queryMedia(isAvailable: true);
      expect(initialAvailable.length, equals(3));

      // Simulate drive disconnect
      await db.markFolderAvailability('D:/ExternalMusic', false);

      // Check folder state
      final extFolder = await db.getFolder('D:/ExternalMusic');
      expect(extFolder?.isAvailable, isFalse);

      final locFolder = await db.getFolder('C:/LocalMusic');
      expect(locFolder?.isAvailable, isTrue);

      // Query available media only
      final availableMedia = await db.queryMedia(isAvailable: true);
      expect(availableMedia.length, equals(1));
      expect(availableMedia.first.id, equals('loc-1'));

      // Query unavailable media
      final unavailableMedia = await db.queryMedia(isAvailable: false);
      expect(unavailableMedia.length, equals(2));
      final unavailIds = unavailableMedia.map((m) => m.id).toSet();
      expect(unavailIds, equals({'ext-1', 'ext-2'}));

      // Simulate drive reconnect
      await db.markFolderAvailability('D:/ExternalMusic', true);

      final reconnectedFolder = await db.getFolder('D:/ExternalMusic');
      expect(reconnectedFolder?.isAvailable, isTrue);

      final reconnectedMedia = await db.queryMedia(isAvailable: true);
      expect(reconnectedMedia.length, equals(3));
    });

    test('updates folder scan stats', () async {
      final now = DateTime(2026, 2, 1, 10, 30);
      await db.updateFolderScanStats(
        'C:/LocalMusic',
        fileCount: 42,
        lastScannedAt: now,
      );

      final folder = await db.getFolder('C:/LocalMusic');
      expect(folder?.fileCount, equals(42));
      expect(folder?.lastScannedAt, equals(now));
    });
  });

  group('Favorites and play history', () {
    late LibraryDatabase db;

    setUp(() async {
      db = await LibraryDatabase.open(inMemory: true);
      await db.insertMedia(
        MediaItemRecord(
          id: 'fav-test-1',
          canonicalSource: 'file:///fav.mp3',
          path: '/fav.mp3',
          kind: MediaKind.audio,
          addedAt: DateTime(2026, 1, 1),
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('toggles favorite flag', () async {
      await db.setFavorite('fav-test-1', true);
      var item = await db.getMediaById('fav-test-1');
      expect(item?.isFavorite, isTrue);

      var favs = await db.queryMedia(isFavorite: true);
      expect(favs.length, equals(1));

      await db.setFavorite('fav-test-1', false);
      item = await db.getMediaById('fav-test-1');
      expect(item?.isFavorite, isFalse);

      favs = await db.queryMedia(isFavorite: true);
      expect(favs, isEmpty);
    });

    test('records playback history and increments play count', () async {
      final playedTime = DateTime(2026, 3, 15, 14, 0);
      await db.recordPlayHistory('fav-test-1', playedAt: playedTime);

      var item = await db.getMediaById('fav-test-1');
      expect(item?.playCount, equals(1));
      expect(item?.lastPlayedAt, equals(playedTime));

      await db.recordPlayHistoryByCanonicalSource('file:///fav.mp3');
      item = await db.getMediaById('fav-test-1');
      expect(item?.playCount, equals(2));
    });
  });

  group('Proper isolate shutdown', () {
    test('closes database isolate cleanly and rejects further operations', () async {
      final db = await LibraryDatabase.open(inMemory: true);
      expect(db.isClosed, isFalse);

      // Performs normal operation
      final folders = await db.getAllFolders();
      expect(folders, isEmpty);

      // Shutdown
      await db.close();
      expect(db.isClosed, isTrue);

      // Calling operations on closed database throws StateError
      expect(
        () => db.getAllFolders(),
        throwsA(isA<StateError>()),
      );
      expect(
        () => db.queryMedia(),
        throwsA(isA<StateError>()),
      );
    });
  });
}
