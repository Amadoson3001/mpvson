import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/library/viewmodels/library_view_model.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:path/path.dart' as p;

import '../player/support/player_test_fakes.dart';
import 'support/fake_media_library_repository.dart';

void main() {
  late Directory tempDir;
  late File file1;
  late File file2;
  late FakePlaybackService playback;
  late BlockingSessionRepository sessions;
  late PlayerController playerController;
  late FakeMediaLibraryRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lib_vm_test_');
    file1 = File(p.join(tempDir.path, 'track1.mp3'))..writeAsStringSync('media1');
    file2 = File(p.join(tempDir.path, 'video1.mp4'))..writeAsStringSync('media2');

    playback = FakePlaybackService();
    sessions = BlockingSessionRepository(
      blockDetailed: false,
      initialResult: const SessionLoadResult(),
    );
    playerController = PlayerController(playback: playback, sessions: sessions);

    repository = FakeMediaLibraryRepository(
      folders: [
        LibraryFolderRecord(
          path: tempDir.path,
          addedAt: DateTime.now(),
          fileCount: 2,
        ),
      ],
      mediaItems: [
        MediaItemRecord(
          id: 'item-1',
          canonicalSource: file1.path,
          path: file1.path,
          kind: MediaKind.audio,
          addedAt: DateTime.now(),
          metadata: const MediaMetadata(
            title: 'Bohemian Rhapsody',
            artist: 'Queen',
            album: 'A Night at the Opera',
          ),
        ),
        MediaItemRecord(
          id: 'item-2',
          canonicalSource: file2.path,
          path: file2.path,
          kind: MediaKind.video,
          addedAt: DateTime.now(),
          metadata: const MediaMetadata(
            title: 'Concert Video',
            artist: 'Queen',
            album: 'Live at Wembley',
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    playerController.dispose();
    playback.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('LibraryViewModel Tabs', () {
    test('defaults to music tab and allows switching tabs', () {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      expect(vm.currentTab, LibraryTab.music);
      expect(vm.selectedTab, LibraryTab.music);

      var notified = false;
      vm.addListener(() => notified = true);

      vm.selectTab(LibraryTab.videos);
      expect(vm.currentTab, LibraryTab.videos);
      expect(notified, isTrue);

      notified = false;
      vm.setTab(LibraryTab.playlists);
      expect(vm.currentTab, LibraryTab.playlists);
      expect(notified, isTrue);

      notified = false;
      vm.currentTab = LibraryTab.nowPlaying;
      expect(vm.currentTab, LibraryTab.nowPlaying);
      expect(notified, isTrue);

      // Same tab is a no-op
      notified = false;
      vm.setTab(LibraryTab.nowPlaying);
      expect(notified, isFalse);
    });
  });

  group('LibraryViewModel Search and Debounce', () {
    test('debounces search query', () async {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
        searchDebounceDuration: const Duration(milliseconds: 50),
      );
      addTearDown(vm.dispose);

      vm.setSearchQuery('Queen');
      expect(vm.searchQuery, 'Queen');
      expect(vm.isSearching, isTrue);
      // Immediately, repository should not have been queried yet
      expect(repository.queryMediaCalls.isEmpty, isTrue);

      // Wait for debounce duration
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(repository.queryMediaCalls.length, 1);
      expect(repository.queryMediaCalls.first['searchQuery'], 'Queen');
      expect(vm.isSearching, isFalse);
      expect(vm.searchResults.length, 2);
    });

    test('immediate search bypasses debounce', () async {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      await vm.search('Bohemian');

      expect(repository.queryMediaCalls.length, 1);
      expect(vm.searchResults.length, 1);
      expect(vm.searchResults.first.title, 'Bohemian Rhapsody');
      expect(vm.isSearching, isFalse);
    });

    test('empty query clears results immediately', () async {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      await vm.search('Bohemian');
      expect(vm.searchResults.isNotEmpty, isTrue);

      vm.setSearchQuery('');
      expect(vm.searchResults.isEmpty, isTrue);
      expect(vm.isSearching, isFalse);
    });

    test('clearSearch resets query and search results', () async {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      await vm.search('Queen');
      expect(vm.searchResults.length, 2);

      vm.clearSearch();
      expect(vm.searchQuery, isEmpty);
      expect(vm.searchResults, isEmpty);
      expect(vm.isSearching, isFalse);
    });

    test('matchesSearch matches on title, artist, album, and filename', () {
      final item = MediaItemRecord(
        id: 'test-1',
        canonicalSource: 'C:/music/track99.flac',
        path: 'C:/music/track99.flac',
        kind: MediaKind.audio,
        addedAt: DateTime.now(),
        metadata: const MediaMetadata(
          title: 'Starman',
          artist: 'David Bowie',
          album: 'Ziggy Stardust',
        ),
      );

      expect(LibraryViewModel.matchesSearch(item, 'star'), isTrue);
      expect(LibraryViewModel.matchesSearch(item, 'bowie'), isTrue);
      expect(LibraryViewModel.matchesSearch(item, 'ziggy'), isTrue);
      expect(LibraryViewModel.matchesSearch(item, 'track99'), isTrue);
      expect(LibraryViewModel.matchesSearch(item, 'unrelated'), isFalse);
    });
  });

  group('LibraryViewModel Folder Management and Scan Status', () {
    test('exposes folders and adds/removes folders', () async {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      expect(vm.folders.length, 1);
      expect(vm.folders.first.path, tempDir.path);

      await vm.addFolder('C:/NewMusic');
      expect(repository.addFolderCalls, contains('C:/NewMusic'));
      expect(vm.folders.length, 2);

      await vm.removeFolder('C:/NewMusic');
      expect(repository.removeFolderCalls, contains('C:/NewMusic'));
      expect(vm.folders.length, 1);
    });

    test('rescans folder, rescans all, and cancels scan', () async {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      expect(vm.isScanning, isFalse);

      await vm.rescanFolder(tempDir.path);
      expect(repository.rescanFolderCalls, contains(tempDir.path));
      expect(vm.isScanning, isTrue);
      expect(vm.scanStatus.currentFolder, tempDir.path);

      await vm.rescanAll();
      expect(repository.rescanAllCalls, 1);
      expect(vm.scanStatus.currentFolder, 'all');

      await vm.cancelScan();
      expect(repository.cancelScanCalls, 1);
      expect(vm.isScanning, isFalse);
    });

    test('reacts to repository scan status changes', () {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      var notified = false;
      vm.addListener(() => notified = true);

      repository.scanStatus = const LibraryScanStatus(
        phase: ScanPhase.enriching,
        discoveredCount: 10,
        enrichedCount: 5,
        totalToEnrich: 10,
      );

      expect(notified, isTrue);
      expect(vm.isScanning, isTrue);
      expect(vm.scanStatus.enrichedCount, 5);
      expect(vm.scanStatus.totalToEnrich, 10);
    });
  });

  group('LibraryViewModel Player Interaction', () {
    test('plays media item and exposes now playing state', () async {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      final item = repository.folders.isEmpty
          ? null
          : (await repository.queryMedia()).first;

      await vm.playMedia(item!);

      expect(playerController.hasMedia, isTrue);
      expect(playerController.current?.path, item.path);
      expect(vm.nowPlaying?.path, item.path);
      expect(vm.isPlaying, isTrue);
      expect(vm.queue.length, 1);
    });

    test('playPaths with initialIndex opens queue and plays target', () async {
      final vm = LibraryViewModel(
        repository: repository,
        playerController: playerController,
      );
      addTearDown(vm.dispose);

      await vm.playPaths([file1.path, file2.path], initialIndex: 1);

      expect(playerController.queue.length, 2);
      expect(playerController.currentIndex, 1);
      expect(playerController.current?.path, file2.path);
    });
  });
}
