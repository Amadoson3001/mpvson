import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/ui/library/views/home_view.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/widgets/empty_library.dart';

import '../../support/app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerController recent management', () {
    late FakePlaybackService playback;
    late SessionRepository sessions;
    late PlayerController controller;

    final entry1 = MediaEntry(
      id: 'video-1',
      path: '/media/video1.mp4',
      title: 'Video One',
      duration: const Duration(minutes: 10),
      position: const Duration(minutes: 2),
      lastPlayed: DateTime(2026, 1, 1),
    );
    final entry2 = MediaEntry(
      id: 'video-2',
      path: '/media/video2.mkv',
      title: 'Video Two',
      duration: const Duration(minutes: 20),
      position: const Duration(minutes: 5),
      lastPlayed: DateTime(2026, 1, 2),
    );
    final entry3 = MediaEntry(
      id: 'video-3',
      path: '/media/video3.mp4',
      title: 'Video Three',
      duration: const Duration(minutes: 30),
      position: Duration.zero,
      lastPlayed: DateTime(2026, 1, 3),
    );

    setUp(() {
      playback = FakePlaybackService();
      sessions = SessionRepository();
      controller = PlayerController(playback: playback, sessions: sessions);
      // Preload recent history
      controller.restoreRecentList([entry1, entry2, entry3]);
    });

    tearDown(() {
      controller.dispose();
    });

    test('removeRecent removes a video by entry and returns index & entry', () {
      expect(controller.recent.length, 3);
      expect(controller.recent[1].title, 'Video Two');

      final result = controller.removeRecent(entry2);
      expect(result, isNotNull);
      expect(result!.$1, 1);
      expect(result.$2.title, 'Video Two');

      expect(controller.recent.length, 2);
      expect(controller.recent.map((e) => e.title), [
        'Video One',
        'Video Three',
      ]);
    });

    test('removeRecentById removes video by id or path', () {
      expect(controller.recent.length, 3);
      final result = controller.removeRecentById(entry1.path);
      expect(result, isNotNull);
      expect(result!.$1, 0);
      expect(controller.recent.length, 2);
      expect(controller.recent.first.title, 'Video Two');
    });

    test('restoreRecent inserts removed video back at original index', () {
      final removed = controller.removeRecent(entry2);
      expect(controller.recent.length, 2);

      controller.restoreRecent(removed!.$1, removed.$2);
      expect(controller.recent.length, 3);
      expect(controller.recent[1].title, 'Video Two');
    });

    test(
      'clearRecent removes all videos and restoreRecentList restores them',
      () {
        expect(controller.recent.length, 3);
        final cleared = controller.clearRecent();
        expect(cleared.length, 3);
        expect(controller.recent, isEmpty);

        controller.restoreRecentList(cleared);
        expect(controller.recent.length, 3);
      },
    );
  });

  group('HomeView recently played UI', () {
    late FakePlaybackService playback;
    late SessionRepository sessions;
    late PlayerController controller;
    late InMemoryMediaLibraryRepository repository;

    final videoEntry = MediaEntry(
      id: 'vid-solo',
      path: '/movies/film.mp4',
      title: 'Solo Feature Film',
      duration: const Duration(hours: 1, minutes: 45),
      position: const Duration(minutes: 30),
      lastPlayed: DateTime(2026, 2, 1),
    );

    setUp(() {
      playback = FakePlaybackService();
      sessions = SessionRepository();
      repository = InMemoryMediaLibraryRepository();
      controller = PlayerController(playback: playback, sessions: sessions);
      controller.restoreRecentList([videoEntry]);
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets(
      'renders video in Recently played section with action menu and remove button',
      (tester) async {
        MediaEntry? removedEntry;
        bool clearedAll = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomeView(
                recent: [videoEntry],
                repository: repository,
                controller: controller,
                onOpenFiles: () {},
                onOpenUrl: () {},
                onOpenRecent: (_) {},
                onRemoveRecent: (e) => removedEntry = e,
                onClearRecent: () => clearedAll = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Verify "Recently played" header and items count
        expect(find.text('Recently played'), findsOneWidget);
        expect(find.text('1 item'), findsOneWidget);
        expect(find.text('Clear all'), findsOneWidget);

        // Verify the video title is rendered
        expect(find.text('Solo Feature Film'), findsOneWidget);

        // Find action popup menu button (3 dots)
        final actionMenu = find.byTooltip('Actions');
        expect(actionMenu, findsOneWidget);

        // Tap action menu to open popup
        await tester.tap(actionMenu);
        await tester.pumpAndSettle();

        // Popup should contain "Resume" and "Remove from recently played"
        expect(find.text('Resume'), findsOneWidget);
        expect(find.text('Remove from recently played'), findsOneWidget);

        // Select "Remove from recently played"
        await tester.tap(find.text('Remove from recently played'));
        await tester.pumpAndSettle();

        expect(removedEntry, isNotNull);
        expect(removedEntry!.id, 'vid-solo');

        // Test "Clear all" button
        await tester.tap(find.text('Clear all'));
        await tester.pumpAndSettle();
        expect(clearedAll, isTrue);
      },
    );

    testWidgets(
      'Quick remove button on thumbnail overlay triggers onRemoveRecent',
      (tester) async {
        MediaEntry? removedEntry;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomeView(
                recent: [videoEntry],
                repository: repository,
                controller: controller,
                onOpenFiles: () {},
                onOpenUrl: () {},
                onOpenRecent: (_) {},
                onRemoveRecent: (e) => removedEntry = e,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Hover over the tile to reveal the quick-remove button
        final tileFinder = find.text('Solo Feature Film');
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(tileFinder));
        await tester.pumpAndSettle();

        final removeBtn = find.byTooltip('Remove from recently played');
        expect(removeBtn, findsOneWidget);

        await tester.tap(removeBtn);
        await tester.pumpAndSettle();

        expect(removedEntry, isNotNull);
        expect(removedEntry!.id, 'vid-solo');
      },
    );

    testWidgets('recent tiles expose button semantics and 44×44 controls', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeView(
              recent: [videoEntry],
              repository: repository,
              controller: controller,
              onOpenFiles: () {},
              onOpenUrl: () {},
              onOpenRecent: (_) {},
              onRemoveRecent: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The tile announces itself as an actionable media button.
      expect(
        find.bySemanticsLabel(RegExp('Video: Solo Feature Film')),
        findsOneWidget,
      );

      // The overflow control is a full-size hit target.
      final actionsButton = find.byTooltip('Actions');
      final actionsSize = tester.getSize(actionsButton);
      expect(actionsSize.width, greaterThanOrEqualTo(44));
      expect(actionsSize.height, greaterThanOrEqualTo(44));

      // Hovering reveals the quick-remove control, also 44×44.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Solo Feature Film')));
      await tester.pumpAndSettle();

      final removeButton = find.byTooltip('Remove from recently played');
      expect(removeButton, findsOneWidget);
      final removeSize = tester.getSize(removeButton);
      expect(removeSize.width, greaterThanOrEqualTo(44));
      expect(removeSize.height, greaterThanOrEqualTo(44));

      // The framework verifies handle disposal before teardowns run, so the
      // handle is released here at the end of the body.
      semantics.dispose();
    });
  });

  group('EmptyLibrary recently played UI', () {
    final videoEntry = MediaEntry(
      id: 'vid-empty',
      path: '/movies/empty_demo.mp4',
      title: 'Empty Screen Video',
      duration: const Duration(minutes: 15),
      position: const Duration(minutes: 3),
      lastPlayed: DateTime(2026, 2, 1),
    );

    testWidgets(
      'Hovering over item in EmptyLibrary shows remove button and triggers onRemoveRecent',
      (tester) async {
        MediaEntry? removedEntry;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmptyLibrary(
                recent: [videoEntry],
                onOpenFiles: () {},
                onOpenUrl: () {},
                onOpenRecent: (_) {},
                onRemoveRecent: (e) => removedEntry = e,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Recent media'), findsOneWidget);
        expect(find.text('Empty Screen Video'), findsOneWidget);

        // Hover over entry
        final entryFinder = find.text('Empty Screen Video');
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(entryFinder));
        await tester.pumpAndSettle();

        final removeBtn = find.byTooltip('Remove from recently played');
        expect(removeBtn, findsOneWidget);

        await tester.tap(removeBtn);
        await tester.pumpAndSettle();

        expect(removedEntry, isNotNull);
        expect(removedEntry!.id, 'vid-empty');
      },
    );
  });
}
