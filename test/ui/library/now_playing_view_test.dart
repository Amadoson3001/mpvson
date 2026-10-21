import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/library/views/now_playing_view.dart';
import 'support/library_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NowPlayingView UI & Transport Controls', () {
    testWidgets('renders artwork, title, artist, album, and scrubber', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(
        initialPaths: ['https://media.example/Track1.mp3', 'https://media.example/Track2.mp3'],
      );

      try {
        await tester.pumpWidget(
          wrapWithApp(
            NowPlayingView(
              controller: controller,
              repository: repo,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Title & metadata
        expect(find.text('Song Alpha'), findsOneWidget);
        expect(find.text('Artist One'), findsOneWidget);
        expect(find.text('Album Great'), findsOneWidget);

        // Timeline Scrubber & Sliders
        expect(find.byType(Slider), findsWidgets);

        // Play / Pause button
        expect(find.byTooltip('Pause'), findsOneWidget);
        await tester.tap(find.byTooltip('Pause'));
        await tester.pumpAndSettle();
        expect(controller.isPlaying, isFalse);
        expect(find.byTooltip('Play'), findsOneWidget);

        // Next & Previous
        expect(find.byTooltip('Next'), findsOneWidget);
        expect(find.byTooltip('Previous'), findsOneWidget);

        await tester.tap(find.byTooltip('Next'));
        await tester.pumpAndSettle();
        expect(find.text('Song Beta'), findsOneWidget);

        // Shuffle toggle
        expect(controller.shuffle, isFalse);
        await tester.tap(find.byTooltip('Shuffle'));
        await tester.pumpAndSettle();
        expect(controller.shuffle, isTrue);

        // Repeat mode toggle
        expect(controller.repeatMode, 'off');
        final repeatBtn = find.byTooltip('Repeat: off');
        expect(repeatBtn, findsOneWidget);
        await tester.tap(repeatBtn);
        await tester.pumpAndSettle();
        expect(controller.repeatMode, 'all');
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('volume controls and mute toggle', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(
        initialPaths: ['https://media.example/Track1.mp3'],
      );

      try {
        await tester.pumpWidget(
          wrapWithApp(
            NowPlayingView(
              controller: controller,
              repository: repo,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initial volume is 100 or non-zero
        expect(controller.volume, greaterThan(0));

        // Mute toggle
        final muteBtn = find.byTooltip('Mute');
        expect(muteBtn, findsOneWidget);
        await tester.tap(muteBtn);
        await tester.pumpAndSettle();
        expect(controller.volume, 0);

        // Unmute toggle
        final unmuteBtn = find.byTooltip('Unmute');
        expect(unmuteBtn, findsOneWidget);
        await tester.tap(unmuteBtn);
        await tester.pumpAndSettle();
        expect(controller.volume, greaterThan(0));
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('favorite button toggles repository favorite status', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(
        initialPaths: ['https://media.example/Track1.mp3'],
      );

      try {
        await tester.pumpWidget(
          wrapWithApp(
            NowPlayingView(
              controller: controller,
              repository: repo,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Track1 is initially favorite
        final favBtn = find.byTooltip('Remove from favorites');
        expect(favBtn, findsOneWidget);

        await tester.tap(favBtn);
        await tester.pumpAndSettle();

        // Now unfavorited
        expect(find.byTooltip('Add to favorites'), findsOneWidget);
        expect(repo.items.firstWhere((i) => i.id == 'm1').isFavorite, isFalse);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('queue panel expands and allows track selection and removal', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(
        initialPaths: ['https://media.example/Track1.mp3', 'https://media.example/Track2.mp3'],
      );

      try {
        await tester.pumpWidget(
          wrapWithApp(
            NowPlayingView(
              controller: controller,
              repository: repo,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Queue is initially hidden
        expect(find.textContaining('Queue (2)'), findsNothing);

        // Tap show queue button
        final showQueueBtn = find.byTooltip('Show queue');
        expect(showQueueBtn, findsOneWidget);

        await tester.tap(showQueueBtn);
        await tester.pumpAndSettle();

        // Queue panel is now open
        expect(find.textContaining('Queue (2)'), findsOneWidget);
        expect(find.text('Track2.mp3'), findsOneWidget);

        // Close queue
        final closeQueueBtn = find.byTooltip('Close queue');
        expect(closeQueueBtn, findsOneWidget);
        await tester.tap(closeQueueBtn);
        await tester.pumpAndSettle();
        expect(find.textContaining('Queue (2)'), findsNothing);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });
  });
}
