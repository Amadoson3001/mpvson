import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/data/repositories/media_library_repository_impl.dart';
import 'package:mpvson/data/services/media_probe_service.dart';
import 'package:mpvson/data/services/media_scanner_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:path/path.dart' as p;

class FakeMediaProbeService implements MediaProbeService {
  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) async {
    return ProbeResult(
      canonicalSource: filePath,
      path: filePath,
      kind: MediaCatalog.kindFromExtension(filePath),
      metadata: MediaMetadata(
        title: p.basenameWithoutExtension(filePath),
        artist: 'Test Artist',
        album: 'Test Album',
      ),
      fileSize: 1024,
      modifiedAt: DateTime.now(),
    );
  }

  @override
  Future<String?> resolveArtwork(String filePath, {bool embeddedOnly = false}) async =>
      null;

  @override
  void cancelAll() {}

  @override
  void dispose() {}
}

void main() {
  group('MediaLibraryRepositoryImpl', () {
    late Directory tempDir;
    late LibraryDatabase database;
    late FakeMediaProbeService fakeProbe;
    late MediaScannerService scannerService;
    late MediaLibraryRepositoryImpl repository;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('mpvson_repo_test_');
      database = await LibraryDatabase.open(inMemory: true);
      fakeProbe = FakeMediaProbeService();
      scannerService = MediaScannerService(
        probeService: fakeProbe,
        database: database,
      );
      repository = MediaLibraryRepositoryImpl(
        database: database,
        scannerService: scannerService,
      );
      await repository.initialize();
    });

    tearDown(() async {
      await repository.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('initializes cleanly and exposes ready state', () {
      expect(repository.isReady, isTrue);
      expect(repository.initializationError, isNull);
      expect(repository.folders, isEmpty);
      expect(repository.scanStatus.isScanning, isFalse);
    });

    test('addFolder and removeFolder update database and notify listeners', () async {
      int notifications = 0;
      repository.addListener(() {
        notifications++;
      });

      final musicFolder = Directory(p.join(tempDir.path, 'Music'))..createSync();
      File(p.join(musicFolder.path, 'song.mp3')).writeAsStringSync('audio data');

      await repository.addFolder(musicFolder.path);

      final folders = await repository.getFolders();
      expect(folders.length, equals(1));
      expect(folders.first.path, equals(p.normalize(p.absolute(musicFolder.path))));
      expect(notifications, greaterThan(0));

      // Discovered files should have been scanned and added
      final media = await repository.queryMedia();
      expect(media.length, equals(1));
      expect(media.first.title, equals('song'));
      expect(media.first.artist, equals('Test Artist'));

      // Remove folder
      await repository.removeFolder(musicFolder.path);
      final remainingFolders = await repository.getFolders();
      expect(remainingFolders, isEmpty);
    });

    test('queryMedia filters by kind, artist, album, favorites, and search query', () async {
      final file1 = p.join(tempDir.path, 'rock_anthem.mp3');
      final file2 = p.join(tempDir.path, 'ambient_drone.flac');
      final file3 = p.join(tempDir.path, 'trailer.mp4');

      await repository.upsertDiscoveredFiles(<String>[file1, file2, file3]);

      await repository.updateMediaMetadata(
        file1,
        kind: MediaKind.audio,
        metadata: const MediaMetadata(
          title: 'Rock Anthem',
          artist: 'The Rockers',
          album: 'Debut Album',
        ),
        fileSize: 2048,
        modifiedAt: DateTime.now(),
      );

      await repository.updateMediaMetadata(
        file2,
        kind: MediaKind.audio,
        metadata: const MediaMetadata(
          title: 'Ambient Drone',
          artist: 'Quiet Sound',
          album: 'Silence',
        ),
        fileSize: 4096,
        modifiedAt: DateTime.now(),
      );

      await repository.updateMediaMetadata(
        file3,
        kind: MediaKind.video,
        metadata: const MediaMetadata(
          title: 'Action Movie Trailer',
          artist: 'Director X',
          album: 'Cinema Hits',
        ),
        fileSize: 8192,
        modifiedAt: DateTime.now(),
      );

      // Filter by kind
      final audioOnly = await repository.queryMedia(kind: MediaKind.audio);
      expect(audioOnly.length, equals(2));

      final videoOnly = await repository.queryMedia(kind: MediaKind.video);
      expect(videoOnly.length, equals(1));
      expect(videoOnly.first.title, equals('Action Movie Trailer'));

      // Filter by artist
      final rockers = await repository.queryMedia(artist: 'The Rockers');
      expect(rockers.length, equals(1));
      expect(rockers.first.title, equals('Rock Anthem'));

      // Filter by search query (FTS5)
      final searchHits = await repository.queryMedia(searchQuery: 'Ambient');
      expect(searchHits.length, equals(1));
      expect(searchHits.first.title, equals('Ambient Drone'));

      // Toggle favorite
      final item = audioOnly.first;
      await repository.toggleFavorite(item.id, true);

      final favorites = await repository.queryMedia(onlyFavorites: true);
      expect(favorites.length, equals(1));
      expect(favorites.first.id, equals(item.id));

      // Record playback
      await repository.recordPlayback(item.canonicalSource);
      final playedItem = await repository.getMediaById(item.id);
      expect(playedItem?.playCount, equals(1));
      expect(playedItem?.lastPlayedAt, isNotNull);

      // Get distinct artists and albums
      final distinctArtists = await repository.getDistinctArtists();
      expect(distinctArtists, contains('The Rockers'));
      expect(distinctArtists, contains('Quiet Sound'));

      final distinctAlbums = await repository.getDistinctAlbums(artist: 'The Rockers');
      expect(distinctAlbums, contains('Debut Album'));
    });

    test('manages playlists and ordered entries', () async {
      int notifications = 0;
      repository.addListener(() {
        notifications++;
      });

      final file1 = p.join(tempDir.path, 'track_a.mp3');
      final file2 = p.join(tempDir.path, 'track_b.mp3');
      await repository.upsertDiscoveredFiles(<String>[file1, file2]);

      final mediaList = await repository.queryMedia();
      expect(mediaList.length, equals(2));

      // Create playlist
      final playlist = await repository.createPlaylist('Roadtrip Mix');
      expect(playlist.title, equals('Roadtrip Mix'));

      var playlists = await repository.getPlaylists();
      expect(playlists.length, equals(1));
      expect(playlists.first.title, equals('Roadtrip Mix'));

      // Add songs to playlist
      final ids = mediaList.map((m) => m.id).toList();
      await repository.addToPlaylist(playlist.id, ids);

      var entries = await repository.getPlaylistEntries(playlist.id);
      expect(entries.length, equals(2));
      expect(entries[0].mediaId, equals(ids[0]));
      expect(entries[1].mediaId, equals(ids[1]));

      // Reorder playlist entries
      await repository.reorderPlaylist(playlist.id, 0, 1);
      entries = await repository.getPlaylistEntries(playlist.id);
      expect(entries[0].mediaId, equals(ids[1]));
      expect(entries[1].mediaId, equals(ids[0]));

      // Remove single entry
      await repository.removeFromPlaylist(playlist.id, entries.first.id);
      entries = await repository.getPlaylistEntries(playlist.id);
      expect(entries.length, equals(1));

      // Rename playlist
      await repository.renamePlaylist(playlist.id, 'Chill Mix');
      playlists = await repository.getPlaylists();
      expect(playlists.first.title, equals('Chill Mix'));

      // Delete playlist
      await repository.deletePlaylist(playlist.id);
      playlists = await repository.getPlaylists();
      expect(playlists, isEmpty);

      expect(notifications, greaterThan(0));
    });

    test('marks folder availability without deleting records', () async {
      final musicFolder = Directory(p.join(tempDir.path, 'MusicFolder'))..createSync();
      File(p.join(musicFolder.path, 'track.mp3')).writeAsStringSync('mp3');

      await repository.addFolder(musicFolder.path);

      var media = await repository.queryMedia();
      expect(media.length, equals(1));
      expect(media.first.isAvailable, isTrue);

      // Mark folder unavailable (e.g. drive unplugged)
      await repository.markFolderAvailability(musicFolder.path, false);

      var folders = await repository.getFolders();
      expect(folders.first.isAvailable, isFalse);

      media = await repository.queryMedia();
      expect(media.length, equals(1));
      expect(media.first.isAvailable, isFalse); // Marked unavailable, NOT deleted!

      // Reconnect drive / folder
      await repository.markFolderAvailability(musicFolder.path, true);
      media = await repository.queryMedia();
      expect(media.first.isAvailable, isTrue);
    });

    test('scanStatusStream exposes live scanner events', () async {
      final statuses = <LibraryScanStatus>[];
      final sub = repository.scanStatusStream.listen(statuses.add);

      final folder = Directory(p.join(tempDir.path, 'LiveScan'))..createSync();
      File(p.join(folder.path, 'tune.mp3')).writeAsStringSync('music');

      await repository.addFolder(folder.path);

      await sub.cancel();
      expect(statuses, isNotEmpty);
      expect(statuses.any((s) => s.phase == ScanPhase.discovering || s.phase == ScanPhase.enriching), isTrue);
    });
  });
}
