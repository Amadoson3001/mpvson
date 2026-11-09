import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
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

    testWidgets('deletes playlist from detail view and returns to playlists list', (
      tester,
    ) async {
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
    });

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

    testWidgets('shows empty state with Add files action when playlist is empty', (
      tester,
    ) async {
      repository = _CountingRepository();
      await repository.createPlaylist('Empty Playlist');
      await pumpView(tester);

      await tester.tap(find.text('Empty Playlist'));
      await settle(tester);

      expect(find.text('This playlist is empty'), findsOneWidget);
      expect(find.text('Add files'), findsWidgets);
    });

    testWidgets('removes entry from playlist immediately when clicking remove', (
      tester,
    ) async {
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
    });

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

    testWidgets('formats video artist and title cleanly from filename', (tester) async {
      repository = _CountingRepository(
        initialItems: [
          track(
            1,
            title: 'Alec Benjamin - If We Have Each Other [Official Music Video].mkv',
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
      expect(find.text('If We Have Each Other [Official Music Video]'), findsOneWidget);
      expect(find.text('Alec Benjamin'), findsOneWidget);
      expect(find.text('Unknown artist'), findsNothing);
      expect(find.text('Unknown Artist'), findsNothing);
    });

    testWidgets('probes missing metadata for entries with zero duration', (tester) async {
      repository = _CountingRepository(
        initialItems: [
          track(1, duration: Duration.zero),
        ],
      );
      final playlist = await repository.createPlaylist('Zero Duration');
      await repository.addToPlaylist(playlist.id, ['id1']);
      await pumpView(tester);

      await tester.tap(find.text('Zero Duration'));
      await settle(tester);

      expect(repository.probedCount, greaterThanOrEqualTo(1));
      expect(repository.probedPaths, contains('C:\\Media\\file_1.mp3'));
    });
  });
}
