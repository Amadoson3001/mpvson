import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/thumbnail_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/media_thumbnail.dart';
import 'package:mpvson/ui/core/components/app_dialog.dart';
import 'package:mpvson/ui/library/views/playlists_view.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import '../../support/app_harness.dart';

/// Counts entry lookups so the preview cache can be proven to remove the
/// per-rebuild query storm.
class _CountingRepository extends InMemoryMediaLibraryRepository {
  _CountingRepository({super.initialItems});

  int entryQueries = 0;
  int probedCount = 0;
  final List<String> probedPaths = [];

  @override
  Future<void> probeMedia(String path) async {
    probedCount++;
    probedPaths.add(path);
  }

  @override
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(
    String playlistId,
  ) async {
    entryQueries++;
    return super.getPlaylistEntries(playlistId);
  }
}

class _DelayedClearRepository extends InMemoryMediaLibraryRepository {
  _DelayedClearRepository({required this.clearCompleter, super.initialItems});

  final Completer<void> clearCompleter;

  @override
  Future<void> clearPlaylist(String playlistId) async {
    await clearCompleter.future;
    return super.clearPlaylist(playlistId);
  }
}

class _BlockingProbeRepository extends InMemoryMediaLibraryRepository {
  _BlockingProbeRepository({super.initialItems});

  final List<String> probedPaths = [];
  Completer<void>? probeCompleter;

  @override
  Future<void> probeMedia(String path) async {
    probedPaths.add(path);
    if (probeCompleter != null && !probeCompleter!.isCompleted) {
      await probeCompleter!.future;
    }
  }
}

class _FakeThumbnailService implements ThumbnailService, ThumbnailPeeker {
  final Map<String, MediaThumbnail> cached = {};

  @override
  MediaThumbnail? peekThumbnail(MediaEntry entry) => cached[entry.id];

  @override
  Future<MediaThumbnail?> load(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  }) async => cached[entry.id];

  @override
  void suspend() {}

  @override
  void resume() {}

  @override
  void trimMemory() {}

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlaylistsView', () {
    late _CountingRepository repository;
    late FakePlaybackService playback;
    late PlayerController controller;

    setUp(() {
      playback = FakePlaybackService();
      controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
    });

    tearDown(() {
      controller.dispose();
    });

    Future<PlaylistRecord> seedPlaylist(List<String> mediaIds) async {
      repository = _CountingRepository(
        initialItems: [
          for (var i = 1; i <= mediaIds.length; i++)
            track(i, title: 'Song $i', artist: 'Artist $i'),
        ],
      );
      final playlist = await repository.createPlaylist('Mix');
      await repository.addToPlaylist(playlist.id, [
        for (var i = 1; i <= mediaIds.length; i++) 'id$i',
      ]);
      repository.entryQueries = 0;
      return playlist;
    }

    Future<void> pumpView(WidgetTester tester, {String? searchQuery}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistsView(
              repository: repository,
              controller: controller,
              searchQuery: searchQuery,
            ),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('caches entry previews across rebuilds', (tester) async {
      await seedPlaylist(const ['id1', 'id2', 'id3']);
      await pumpView(tester);

      // One preview request per playlist: the grid renders three entries.
      expect(repository.entryQueries, 1);
      expect(find.text('Mix'), findsOneWidget);

      // A search-driven rebuild re-renders the cards but must reuse the
      // cached preview futures instead of re-querying every playlist.
      await pumpView(tester, searchQuery: 'nomatch');
      expect(repository.entryQueries, 1);

      await pumpView(tester);
      expect(repository.entryQueries, 1);
    });

    testWidgets('reorder applies immediately and persists', (tester) async {
      final playlist = await seedPlaylist(const ['id1', 'id2', 'id3']);
      await pumpView(tester);

      await tester.tap(find.text('Mix'));
      await settle(tester);
      expect(find.text('Song 1'), findsOneWidget);

      final listView = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      // Move the first row two slots down, the raw convention Material uses.
      // ignore: deprecated_member_use
      listView.onReorder!(0, 2);
      await tester.pump();

      // The visible order already reflects the drag before the repository
      // round-trip resolves.
      double topOf(String title) => tester.getTopLeft(find.text(title)).dy;
      expect(topOf('Song 2'), lessThan(topOf('Song 1')));
      expect(topOf('Song 1'), lessThan(topOf('Song 3')));

      await settle(tester);
      final persisted = await tester.runAsync(
        () => repository.getPlaylistEntries(playlist.id),
      );
      expect(persisted!.map((entry) => entry.mediaItem?.title), [
        'Song 2',
        'Song 1',
        'Song 3',
      ]);
    });

    testWidgets('rename runs through AppDialog.show and updates the title', (
      tester,
    ) async {
      final playlist = await seedPlaylist(const ['id1']);
      await pumpView(tester);

      await tester.tap(find.byTooltip('Playlist actions'));
      await settle(tester);
      await tester.tap(find.text('Rename playlist'));
      await settle(tester);

      // The shared dialog shell carries the rename form.
      expect(find.byType(AppDialog), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Renamed Mix');
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(find.text('Renamed Mix'), findsOneWidget);
      final stored = await tester.runAsync(() => repository.getPlaylists());
      expect(
        stored!.firstWhere((pl) => pl.id == playlist.id).title,
        'Renamed Mix',
      );
    });

    testWidgets(
      'deletes playlist from detail view and returns to playlists list',
      (tester) async {
        final playlist = await seedPlaylist(const ['id1']);
        await pumpView(tester);

        // Open detail view
        await tester.tap(find.text('Mix'));
        await settle(tester);
        expect(find.text('Song 1'), findsOneWidget);

        // Tap delete playlist button in header
        await tester.tap(find.byTooltip('Delete playlist'));
        await settle(tester);

        expect(find.byType(AppDialog), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);

        await tester.tap(find.text('Delete'));
        await settle(tester);

        // Returned to playlist list / empty state
        final stored = await tester.runAsync(() => repository.getPlaylists());
        expect(stored!.any((pl) => pl.id == playlist.id), isFalse);
      },
    );

    testWidgets('deletes playlist from card action menu in main view', (
      tester,
    ) async {
      final playlist = await seedPlaylist(const ['id1']);
      await pumpView(tester);

      await tester.tap(find.byTooltip('Playlist actions'));
      await settle(tester);

      await tester.tap(find.text('Delete playlist'));
      await settle(tester);

      expect(find.byType(AppDialog), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await settle(tester);

      final stored = await tester.runAsync(() => repository.getPlaylists());
      expect(stored!.any((pl) => pl.id == playlist.id), isFalse);
    });

    testWidgets(
      'shows empty state with Add files action when playlist is empty',
      (tester) async {
        repository = _CountingRepository();
        await repository.createPlaylist('Empty Playlist');
        await pumpView(tester);

        await tester.tap(find.text('Empty Playlist'));
        await settle(tester);

        expect(find.text('This playlist is empty'), findsOneWidget);
        expect(find.text('Add files'), findsWidgets);
      },
    );

    testWidgets(
      'removes entry from playlist immediately when clicking remove',
      (tester) async {
        final playlist = await seedPlaylist(const ['id1', 'id2']);
        await pumpView(tester);

        await tester.tap(find.text('Mix'));
        await settle(tester);

        expect(find.text('Song 1'), findsOneWidget);
        expect(find.text('Song 2'), findsOneWidget);

        // Tap remove on Song 1
        final btn = find.byTooltip('Remove from playlist').first;
        await tester.tap(btn);
        await settle(tester);

        expect(find.text('Song 1'), findsNothing);
        expect(find.text('Song 2'), findsOneWidget);

        await settle(tester);
        final entries = await tester.runAsync(
          () => repository.getPlaylistEntries(playlist.id),
        );
        expect(entries!.length, 1);
        expect(entries.first.mediaItem?.title, 'Song 2');
      },
    );

    testWidgets('adds tracks from library dialog', (tester) async {
      repository = _CountingRepository(
        initialItems: [
          track(1, title: 'Library Song A'),
          track(2, title: 'Library Song B'),
        ],
      );
      final playlist = await repository.createPlaylist('My Mix');
      await pumpView(tester);

      await tester.tap(find.text('My Mix'));
      await settle(tester);

      // Open From library dialog
      await tester.tap(find.text('From library'));
      await settle(tester);

      expect(find.text('Add from library'), findsOneWidget);
      expect(find.text('Library Song A'), findsOneWidget);

      // Select Song A
      await tester.tap(find.text('Library Song A'));
      await settle(tester);

      // Tap Add (1)
      await tester.tap(find.text('Add (1)'));
      await settle(tester);

      // Song A is now in the playlist
      expect(find.text('Library Song A'), findsOneWidget);
      final entries = await tester.runAsync(
        () => repository.getPlaylistEntries(playlist.id),
      );
      expect(entries!.length, 1);
      expect(entries.first.mediaItem?.title, 'Library Song A');
    });

    testWidgets('formats video artist and title cleanly from filename', (
      tester,
    ) async {
      repository = _CountingRepository(
        initialItems: [
          track(
            1,
            title:
                'Alec Benjamin - If We Have Each Other [Official Music Video].mkv',
            artist: null,
          ),
        ],
      );
      final playlist = await repository.createPlaylist('Music Videos');
      await repository.addToPlaylist(playlist.id, ['id1']);
      await pumpView(tester);

      await tester.tap(find.text('Music Videos'));
      await settle(tester);

      // Verify that extension is stripped, title is song name, and artist is Alec Benjamin
      expect(
        find.text('If We Have Each Other [Official Music Video]'),
        findsOneWidget,
      );
      expect(find.text('Alec Benjamin'), findsOneWidget);
      expect(find.text('Unknown artist'), findsNothing);
      expect(find.text('Unknown Artist'), findsNothing);
    });

    testWidgets('probes missing metadata for entries with zero duration', (
      tester,
    ) async {
      repository = _CountingRepository(
        initialItems: [track(1, duration: Duration.zero)],
      );
      final playlist = await repository.createPlaylist('Zero Duration');
      await repository.addToPlaylist(playlist.id, ['id1']);
      await pumpView(tester);

      await tester.tap(find.text('Zero Duration'));
      await settle(tester);

      expect(repository.probedCount, greaterThanOrEqualTo(1));
      expect(repository.probedPaths, contains('C:\\Media\\file_1.mp3'));
    });

    testWidgets(
      'does not throw setState during build when thumbnail has warm cached duration and DB duration is zero',
      (tester) async {
        final fakeThumbnails = _FakeThumbnailService();
        final fakeThumb = MediaThumbnail(
          bytes: Uint8List(0),
          duration: const Duration(seconds: 120),
        );
        fakeThumbnails.cached['id1'] = fakeThumb;

        final customController = PlayerController(
          playback: playback,
          sessions: SessionRepository(),
          thumbnails: fakeThumbnails,
        );
        addTearDown(customController.dispose);

        repository = _CountingRepository(
          initialItems: [
            track(
              1,
              title: 'Video 1',
              ext: 'mkv',
              kind: MediaKind.video,
              duration: Duration.zero,
            ),
          ],
        );
        final playlist = await repository.createPlaylist('Video Mix');
        await repository.addToPlaylist(playlist.id, ['id1']);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlaylistsView(
                repository: repository,
                controller: customController,
              ),
            ),
          ),
        );
        await settle(tester);

        await tester.tap(find.text('Video Mix'));
        // If setState during build was called, tester.pump() throws FlutterError.
        await tester.pump();
        await settle(tester);

        expect(find.text('Video 1'), findsOneWidget);
      },
    );

    testWidgets(
      'clearPlaylist does not crash if widget is unmounted before database operation completes',
      (tester) async {
        final clearCompleter = Completer<void>();
        final delayedRepo = _DelayedClearRepository(
          clearCompleter: clearCompleter,
          initialItems: [track(1, title: 'Track 1')],
        );
        final playlist = await delayedRepo.createPlaylist('To Clear');
        await delayedRepo.addToPlaylist(playlist.id, ['id1']);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlaylistsView(
                repository: delayedRepo,
                controller: controller,
              ),
            ),
          ),
        );
        await settle(tester);

        await tester.tap(find.text('To Clear'));
        await settle(tester);

        // Tap More actions -> Clear all tracks
        await tester.tap(find.byTooltip('More actions'));
        await settle(tester);
        await tester.tap(find.text('Clear all tracks'));
        await settle(tester);

        expect(find.text('Clear all'), findsOneWidget);
        // Tap confirm "Clear all"
        await tester.tap(find.text('Clear all'));
        await tester.pump();

        // While clear is pending, unmount the PlaylistsView completely
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox())),
        );
        await tester.pump();

        // Complete the database clear
        clearCompleter.complete();
        await tester.pump();
        await settle(tester);

        // No setState after dispose exception
      },
    );

    testWidgets(
      'rapid sequential reorders maintain correct order without corruption',
      (tester) async {
        final playlist = await seedPlaylist(const ['id1', 'id2', 'id3', 'id4']);
        await pumpView(tester);

        await tester.tap(find.text('Mix'));
        await settle(tester);

        final listView = tester.widget<ReorderableListView>(
          find.byType(ReorderableListView),
        );

        // Move row 0 to index 3
        // ignore: deprecated_member_use
        listView.onReorder!(0, 3);
        // Immediately move new row 0 to index 2 without settling
        // ignore: deprecated_member_use
        listView.onReorder!(0, 2);

        await settle(tester);
        final persisted = await tester.runAsync(
          () => repository.getPlaylistEntries(playlist.id),
        );
        final titles = persisted!.map((e) => e.mediaItem?.title).toList();
        expect(titles.length, 4);
      },
    );

    testWidgets(
      'playlist switch aborts in-flight metadata probing for previous playlist',
      (tester) async {
        final probeCompleter = Completer<void>();
        final probeRepo = _BlockingProbeRepository(
          initialItems: [
            track(1, duration: Duration.zero),
            track(2, duration: Duration.zero),
            track(3, duration: Duration.zero),
            track(4, duration: Duration.zero),
          ],
        );
        probeRepo.probeCompleter = probeCompleter;

        final pl1 = await probeRepo.createPlaylist('Playlist 1');
        await probeRepo.addToPlaylist(pl1.id, ['id1', 'id2', 'id3']);

        final pl2 = await probeRepo.createPlaylist('Playlist 2');
        await probeRepo.addToPlaylist(pl2.id, ['id4']);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlaylistsView(
                repository: probeRepo,
                controller: controller,
              ),
            ),
          ),
        );
        await settle(tester);

        // Open Playlist 1 to trigger _probeMissingMetadata
        await tester.tap(find.text('Playlist 1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // First item should be in-flight
        expect(probeRepo.probedPaths, ['C:\\Media\\file_1.mp3']);

        // While id1 is in-flight, navigate back to playlists
        await tester.tap(find.byTooltip('Back to playlists'));
        await tester.pump();

        // Release id1 probe so it finishes
        probeCompleter.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await settle(tester);

        // Probing for Playlist 1 ceased: id2 and id3 were never probed
        expect(probeRepo.probedPaths, ['C:\\Media\\file_1.mp3']);

        // Now open Playlist 2; it should probe id4 normally
        await tester.tap(find.text('Playlist 2'));
        await settle(tester);

        expect(probeRepo.probedPaths, [
          'C:\\Media\\file_1.mp3',
          'C:\\Media\\file_4.mp3',
        ]);
      },
    );

    testWidgets('unmounting PlaylistsView aborts in-flight metadata probing', (
      tester,
    ) async {
      final probeCompleter = Completer<void>();
      final probeRepo = _BlockingProbeRepository(
        initialItems: [
          track(1, duration: Duration.zero),
          track(2, duration: Duration.zero),
        ],
      );
      probeRepo.probeCompleter = probeCompleter;

      final pl1 = await probeRepo.createPlaylist('Playlist 1');
      await probeRepo.addToPlaylist(pl1.id, ['id1', 'id2']);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistsView(repository: probeRepo, controller: controller),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Playlist 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(probeRepo.probedPaths, ['C:\\Media\\file_1.mp3']);

      // Unmount widget
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.pump();

      probeCompleter.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);

      // id2 was never probed
      expect(probeRepo.probedPaths, ['C:\\Media\\file_1.mp3']);
    });
  });
}
