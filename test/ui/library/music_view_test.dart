import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/library/views/music_view.dart';
import 'support/library_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MusicView Subtabs', () {
    testWidgets('switches between Songs, Albums, Artists, Favorites, Recently Added, Recently Played', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController();

      try {
        await tester.pumpWidget(
          wrapWithApp(
            MusicView(
              repository: repo,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Default subtab is Songs
        expect(find.text('Song Alpha'), findsOneWidget);
        expect(find.text('Song Beta'), findsOneWidget);

        // Switch to Albums
        await tester.tap(find.text('Albums'));
        await tester.pumpAndSettle();
        expect(find.text('Album Great'), findsOneWidget);
        expect(find.text('Solo Echoes'), findsOneWidget);

        // Switch to Artists
        await tester.tap(find.text('Artists'));
        await tester.pumpAndSettle();
        expect(find.text('Artist One'), findsOneWidget);
        expect(find.text('Artist Two'), findsOneWidget);

        // Switch to Favorites
        await tester.tap(find.text('Favorites'));
        await tester.pumpAndSettle();
        // Song Alpha is favorite, Song Beta is not
        expect(find.text('Song Alpha'), findsOneWidget);
        expect(find.text('Song Beta'), findsNothing);

        // Switch to Recently Added
        await tester.tap(find.text('Recently Added'));
        await tester.pumpAndSettle();
        expect(find.text('Song Alpha'), findsOneWidget);

        // Switch to Recently Played
        await tester.tap(find.text('Recently Played'));
        await tester.pumpAndSettle();
        // Initially none played
        expect(find.text('No recently played music'), findsOneWidget);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });
  });

  group('MusicView Playback Actions', () {
    testWidgets('double-clicking a song starts playback from current collection at index', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController();

      try {
        await tester.pumpWidget(
          wrapWithApp(
            MusicView(
              repository: repo,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Double-click on Song Beta (index 1)
        final betaSong = find.text('Song Beta');
        expect(betaSong, findsOneWidget);

        await tester.tap(betaSong);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(betaSong);
        await tester.pumpAndSettle();

        // Controller should have opened collection and be playing Song Beta
        expect(controller.queue.length, greaterThanOrEqualTo(2));
        expect(controller.current?.path, 'https://media.example/Track2.mp3');
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('playing an album orders tracks by disc and track number', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController();

      try {
        await tester.pumpWidget(
          wrapWithApp(
            MusicView(
              repository: repo,
              controller: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Go to Albums tab
        await tester.tap(find.text('Albums'));
        await tester.pumpAndSettle();

        // Tap on Album Great to open Album Detail View
        await tester.tap(find.text('Album Great'));
        await tester.pumpAndSettle();

        // Album Great detail view shows Play album button
        final playAlbumBtn = find.text('Play album');
        expect(playAlbumBtn, findsOneWidget);

        await tester.tap(playAlbumBtn);
        await tester.pumpAndSettle();

        // Track 1 (Song Beta: disc 1, track 1) must be queued before Track 2 (Song Alpha: disc 1, track 2)
        expect(controller.queue.length, 2);
        expect(controller.queue[0].path, 'https://media.example/Track2.mp3');
        expect(controller.queue[1].path, 'https://media.example/Track1.mp3');
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('context menu item actions: play next, add to queue, favorite, show in folder', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(initialPaths: ['https://media.example/Track1.mp3']);
      String? revealedFolder;

      try {
        await tester.pumpWidget(
          wrapWithApp(
            MusicView(
              repository: repo,
              controller: controller,
              onShowInFolder: (path) => revealedFolder = path,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open popup menu on first song
        final actionButtons = find.byType(PopupMenuButton<String>);
        expect(actionButtons, findsWidgets);

        await tester.tap(actionButtons.first);
        await tester.pumpAndSettle();

        expect(find.text('Play now'), findsOneWidget);
        expect(find.text('Play next'), findsOneWidget);
        expect(find.text('Add to queue'), findsOneWidget);
        expect(find.text('Remove favorite'), findsOneWidget);
        expect(find.text('Show in folder'), findsOneWidget);

        // Tap Play next
        await tester.tap(find.text('Play next'));
        await tester.pumpAndSettle();

        // Queue should now contain the played-next item
        expect(controller.queue.length, 2);
        expect(controller.queue[1].path, 'https://media.example/Track1.mp3');

        // Test Show in folder callback
        await tester.tap(actionButtons.first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show in folder'));
        await tester.pumpAndSettle();
        expect(revealedFolder, 'https://media.example/Track1.mp3');

        // Test favorite toggle directly from list row
        expect(repo.items.firstWhere((i) => i.id == 'm2').isFavorite, isFalse);
        final favoriteButtons = find.byTooltip('Add to favorites');
        expect(favoriteButtons, findsWidgets);
        await tester.tap(favoriteButtons.first);
        await tester.pumpAndSettle();

        // Should now be favorited in repo
        expect(repo.items.firstWhere((i) => i.id == 'm2').isFavorite, isTrue);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });
  });
}
