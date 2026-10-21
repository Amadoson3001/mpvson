import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/library/viewmodels/music_view_model.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:path/path.dart' as p;

import '../player/support/player_test_fakes.dart';
import 'support/fake_media_library_repository.dart';

void main() {
  late Directory tempDir;
  late File fileTrack1;
  late File fileTrack2;
  late File fileTrack3;
  late File fileTrack4;

  late FakePlaybackService playback;
  late BlockingSessionRepository sessions;
  late PlayerController playerController;
  late FakeMediaLibraryRepository repository;

  late MediaItemRecord song1;
  late MediaItemRecord song2;
  late MediaItemRecord song3;
  late MediaItemRecord song4;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('music_vm_test_');
    fileTrack1 = File(p.join(tempDir.path, '01_intro.mp3'))..writeAsStringSync('t1');
    fileTrack2 = File(p.join(tempDir.path, '02_song.mp3'))..writeAsStringSync('t2');
    fileTrack3 = File(p.join(tempDir.path, '03_bonus.mp3'))..writeAsStringSync('t3');
    fileTrack4 = File(p.join(tempDir.path, '04_outro.mp3'))..writeAsStringSync('t4');

    playback = FakePlaybackService();
    sessions = BlockingSessionRepository(
      blockDetailed: false,
      initialResult: const SessionLoadResult(),
    );
    playerController = PlayerController(playback: playback, sessions: sessions);

    song1 = MediaItemRecord(
      id: 'song-1',
      canonicalSource: fileTrack1.path,
      path: fileTrack1.path,
      kind: MediaKind.audio,
      addedAt: DateTime(2026, 1, 1),
      lastPlayedAt: DateTime(2026, 3, 1),
      isFavorite: true,
      metadata: const MediaMetadata(
        title: 'Alpha Song',
        artist: 'Band A',
        album: 'Album One',
        genre: 'Rock',
        discNumber: 1,
        trackNumber: 2,
        duration: Duration(minutes: 3),
        year: 2020,
      ),
    );

    song2 = MediaItemRecord(
      id: 'song-2',
      canonicalSource: fileTrack2.path,
      path: fileTrack2.path,
      kind: MediaKind.audio,
      addedAt: DateTime(2026, 1, 10),
      lastPlayedAt: DateTime(2026, 3, 5),
      isFavorite: false,
      metadata: const MediaMetadata(
        title: 'Beta Track',
        artist: 'Band B',
        album: 'Album One',
        genre: 'Pop',
        discNumber: 1,
        trackNumber: 1,
        duration: Duration(minutes: 4),
        year: 2021,
      ),
    );

    song3 = MediaItemRecord(
      id: 'song-3',
      canonicalSource: fileTrack3.path,
      path: fileTrack3.path,
      kind: MediaKind.audio,
      addedAt: DateTime(2026, 1, 20),
      lastPlayedAt: null,
      isFavorite: true,
      metadata: const MediaMetadata(
        title: 'Gamma Bonus',
        artist: 'Band A',
        album: 'Album Two',
        genre: 'Rock',
        discNumber: 2,
        trackNumber: 1,
        duration: Duration(minutes: 2),
        year: 2019,
      ),
    );

    song4 = MediaItemRecord(
      id: 'song-4',
      canonicalSource: fileTrack4.path,
      path: fileTrack4.path,
      kind: MediaKind.audio,
      addedAt: DateTime(2026, 2, 1),
      lastPlayedAt: DateTime(2026, 2, 20),
      isFavorite: false,
      metadata: const MediaMetadata(
        title: 'Delta Outro',
        artist: 'Band C',
        album: 'Album Two',
        genre: 'Jazz',
        discNumber: 1,
        trackNumber: 3,
        duration: Duration(minutes: 5),
        year: 2022,
      ),
    );

    repository = FakeMediaLibraryRepository(
      mediaItems: [song1, song2, song3, song4],
    );
  });

  tearDown(() async {
    playerController.dispose();
    playback.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('MusicViewModel Subtabs', () {
    test('switches subtabs and exposes appropriate collections', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      await vm.refresh();

      expect(vm.currentSubtab, MusicSubtab.songs);
      expect(vm.currentCollection.length, 4);

      vm.selectSubtab(MusicSubtab.favorites);
      expect(vm.currentSubtab, MusicSubtab.favorites);
      expect(vm.currentCollection.length, 2);
      expect(vm.currentCollection.every((s) => s.isFavorite), isTrue);

      vm.selectSubtab(MusicSubtab.recentlyAdded);
      expect(vm.currentSubtab, MusicSubtab.recentlyAdded);
      expect(vm.currentCollection.first.id, 'song-4');

      vm.selectSubtab(MusicSubtab.recentlyPlayed);
      expect(vm.currentSubtab, MusicSubtab.recentlyPlayed);
      expect(vm.currentCollection.length, 3);
      expect(vm.currentCollection.first.id, 'song-2');

      vm.selectSubtab(MusicSubtab.albums);
      expect(vm.currentSubtab, MusicSubtab.albums);
      expect(vm.albums.length, 2);

      vm.selectSubtab(MusicSubtab.artists);
      expect(vm.currentSubtab, MusicSubtab.artists);
      expect(vm.artists.length, 3);
    });
  });

  group('MusicViewModel Sorting and Filtering', () {
    test('sorts by title, duration, track number, and year', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      // Title A-Z (default)
      vm.setSorting(MusicSortField.title, ascending: true);
      expect(vm.currentCollection.first.title, 'Alpha Song');
      expect(vm.currentCollection.last.title, 'Gamma Bonus');

      // Title Z-A
      vm.toggleSortOrder();
      expect(vm.currentCollection.first.title, 'Gamma Bonus');

      // Duration ascending
      vm.setSorting(MusicSortField.duration, ascending: true);
      expect(vm.currentCollection.first.title, 'Gamma Bonus'); // 2 min
      expect(vm.currentCollection.last.title, 'Delta Outro'); // 5 min

      // Year descending
      vm.setSorting(MusicSortField.year, ascending: false);
      expect(vm.currentCollection.first.metadata.year, 2022);
    });

    test('filters by search query across title, artist, album, filename', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      // Search title
      vm.setFilterQuery('Alpha');
      expect(vm.currentCollection.length, 1);
      expect(vm.currentCollection.first.title, 'Alpha Song');

      // Search artist
      vm.setFilterQuery('Band A');
      expect(vm.currentCollection.length, 2);

      // Search album
      vm.setFilterQuery('Album Two');
      expect(vm.currentCollection.length, 2);

      // Search filename
      vm.setFilterQuery('04_outro');
      expect(vm.currentCollection.length, 1);
      expect(vm.currentCollection.first.title, 'Delta Outro');

      vm.clearFilters();
      expect(vm.currentCollection.length, 4);
    });

    test('filters by artist, album, and genre', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      vm.filterByArtist('Band A');
      expect(vm.currentCollection.length, 2);

      vm.filterByGenre('Rock');
      expect(vm.currentCollection.length, 2);

      vm.filterByAlbum('Album One');
      expect(vm.currentCollection.length, 1);
      expect(vm.currentCollection.first.title, 'Alpha Song');

      vm.clearFilters();
      expect(vm.currentCollection.length, 4);
    });
  });

  group('MusicViewModel Playback Operations', () {
    test('playSongAtIndex starts playing queue at chosen index', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      await vm.playSongAtIndex(2);

      expect(playerController.queue.length, 4);
      expect(playerController.currentIndex, 2);
      expect(playerController.current?.path, vm.currentCollection[2].path);
      expect(playerController.isPlaying, isTrue);
    });

    test('playAlbum orders tracks by disc number, track number, then filename', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      // Album One has:
      // song1: Disc 1, Track 2 (01_intro.mp3)
      // song2: Disc 1, Track 1 (02_song.mp3)
      // Order should be song2 (track 1) then song1 (track 2)
      await vm.playAlbum('Album One');

      expect(playerController.queue.length, 2);
      expect(playerController.queue[0].path, song2.path);
      expect(playerController.queue[1].path, song1.path);
      expect(playerController.currentIndex, 0);
    });

    test('compareAlbumTracks orders by disc number, track number, filename', () {
      final tDisc1Track1 = MediaItemRecord(
        id: '1',
        canonicalSource: 'C:/b.mp3',
        path: 'C:/b.mp3',
        addedAt: DateTime.now(),
        metadata: const MediaMetadata(discNumber: 1, trackNumber: 1),
      );
      final tDisc1Track2 = MediaItemRecord(
        id: '2',
        canonicalSource: 'C:/a.mp3',
        path: 'C:/a.mp3',
        addedAt: DateTime.now(),
        metadata: const MediaMetadata(discNumber: 1, trackNumber: 2),
      );
      final tDisc2Track1 = MediaItemRecord(
        id: '3',
        canonicalSource: 'C:/c.mp3',
        path: 'C:/c.mp3',
        addedAt: DateTime.now(),
        metadata: const MediaMetadata(discNumber: 2, trackNumber: 1),
      );
      final tDisc1Track0A = MediaItemRecord(
        id: '4',
        canonicalSource: 'C:/a_intro.mp3',
        path: 'C:/a_intro.mp3',
        addedAt: DateTime.now(),
        metadata: const MediaMetadata(discNumber: 1),
      );
      final tDisc1Track0B = MediaItemRecord(
        id: '5',
        canonicalSource: 'C:/b_bonus.mp3',
        path: 'C:/b_bonus.mp3',
        addedAt: DateTime.now(),
        metadata: const MediaMetadata(discNumber: 1),
      );

      final list = [
        tDisc2Track1,
        tDisc1Track2,
        tDisc1Track0B,
        tDisc1Track1,
        tDisc1Track0A,
      ];
      list.sort(MusicViewModel.compareAlbumTracks);

      expect(list, [
        tDisc1Track0A, // Disc 1, Track 0, 'a_intro.mp3'
        tDisc1Track0B, // Disc 1, Track 0, 'b_bonus.mp3'
        tDisc1Track1,  // Disc 1, Track 1
        tDisc1Track2,  // Disc 1, Track 2
        tDisc2Track1,  // Disc 2, Track 1
      ]);
    });

    test('playNext inserts item right after the active track', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      // Open initial queue: song1, song2, song3
      await playerController.openPaths([song1.path, song2.path, song3.path]);
      expect(playerController.currentIndex, 0);

      // Play next song4
      await vm.playNext(song4);

      expect(playerController.queue.length, 4);
      expect(playerController.queue[0].path, song1.path);
      expect(playerController.queue[1].path, song4.path); // Inserted next!
      expect(playerController.queue[2].path, song2.path);
      expect(playerController.queue[3].path, song3.path);
      expect(playerController.currentIndex, 0); // Active track untouched
    });

    test('addToQueue appends item to end of playback queue', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      await playerController.openPaths([song1.path, song2.path]);
      expect(playerController.queue.length, 2);

      await vm.addToQueue(song4);

      expect(playerController.queue.length, 3);
      expect(playerController.queue.last.path, song4.path);
    });

    test('toggleFavorite updates repository and reloads', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      expect(song2.isFavorite, isFalse);
      await vm.toggleFavorite(song2);

      expect(repository.toggleFavoriteCalls.last['id'], song2.id);
      expect(repository.toggleFavoriteCalls.last['isFavorite'], isTrue);

      final updated = vm.songs.firstWhere((s) => s.id == song2.id);
      expect(updated.isFavorite, isTrue);
    });
  });

  group('MusicViewModel Playlists Management', () {
    test('creates, renames, adds/removes songs, reorders, and deletes playlists', () async {
      final vm = MusicViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);
      await vm.refresh();

      // 1. Create playlist
      final playlist = await vm.createPlaylist('Favorites Rock');
      expect(vm.playlists.length, 1);
      expect(vm.playlists.first.title, 'Favorites Rock');

      // 2. Rename playlist
      await vm.renamePlaylist(playlist.id, 'Best Rock');
      expect(vm.playlists.first.title, 'Best Rock');

      // 3. Add songs
      await vm.selectPlaylist(vm.playlists.first);
      await vm.addSongsToPlaylist(playlist.id, [song1.id, song2.id, song3.id]);
      expect(vm.playlistEntries.length, 3);
      expect(vm.playlistEntries[0].mediaId, song1.id);
      expect(vm.playlistEntries[1].mediaId, song2.id);
      expect(vm.playlistEntries[2].mediaId, song3.id);

      // 4. Reorder playlist (move index 0 to index 2)
      await vm.reorderPlaylist(playlist.id, 0, 2);
      expect(vm.playlistEntries[0].mediaId, song2.id);
      expect(vm.playlistEntries[1].mediaId, song1.id);

      // 5. Remove song
      final entryToRemove = vm.playlistEntries.first;
      await vm.removeSongFromPlaylist(playlist.id, entryToRemove.id);
      expect(vm.playlistEntries.length, 2);
      expect(vm.playlistEntries.every((e) => e.id != entryToRemove.id), isTrue);

      // 6. Play playlist
      await vm.playPlaylist(playlist.id, startIndex: 1);
      expect(playerController.queue.length, 2);
      expect(playerController.currentIndex, 1);

      // 7. Delete playlist
      await vm.deletePlaylist(playlist.id);
      expect(vm.playlists.isEmpty, isTrue);
      expect(vm.selectedPlaylist, isNull);
      expect(vm.playlistEntries.isEmpty, isTrue);
    });
  });
}
