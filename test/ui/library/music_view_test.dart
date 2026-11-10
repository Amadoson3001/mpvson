import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/library/views/music_view.dart';

import '../../support/app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MusicView drilldown state retention', () {
    testWidgets(
      'album drilldown is preserved across library notifications and favorite toggles',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final items = [
          track(
            1,
            title: 'Come Together',
            artist: 'The Beatles',
            album: 'Abbey Road',
            favorite: false,
          ),
          track(
            2,
            title: 'Something',
            artist: 'The Beatles',
            album: 'Abbey Road',
            favorite: false,
          ),
          track(
            3,
            title: 'Time',
            artist: 'Pink Floyd',
            album: 'The Dark Side of the Moon',
            favorite: false,
          ),
        ];

        final harness = Harness.create(items: items);
        addTearDown(() => harness.shutdown(tester));

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: MusicView(
                repository: harness.library,
                controller: harness.controller,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Navigate to Albums subtab
        await tester.tap(find.text('Albums'));
        await tester.pumpAndSettle();

        expect(find.text('Abbey Road'), findsWidgets);
        expect(find.text('The Dark Side of the Moon'), findsOneWidget);

        // Tap on Abbey Road card to drill down
        await tester.tap(find.text('Abbey Road').first);
        await tester.pumpAndSettle();

        // Verify we are in the Album detail view
        expect(find.byTooltip('Back to albums'), findsOneWidget);
        expect(find.text('Come Together'), findsOneWidget);
        expect(find.text('Something'), findsOneWidget);
        // Dark Side of the Moon should not be in Abbey Road detail view
        expect(find.text('The Dark Side of the Moon'), findsNothing);

        // Tap favorite icon on "Come Together"
        final favButtons = find.byTooltip('Add to favorites');
        expect(favButtons, findsWidgets);
        await tester.tap(favButtons.first);
        await tester.pumpAndSettle();

        // Verify: Still in Album detail view!
        expect(find.byTooltip('Back to albums'), findsOneWidget);
        expect(find.text('Come Together'), findsOneWidget);
        expect(find.byTooltip('Remove favorite'), findsOneWidget);
        expect(find.text('The Dark Side of the Moon'), findsNothing);

        // Trigger a generic library notification (e.g. scan progress or another update)
        harness.library.notifyListeners();
        // Wait for throttle duration (200ms) and settle
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();

        // Verify: Still in Album detail view!
        expect(find.byTooltip('Back to albums'), findsOneWidget);
        expect(find.text('Come Together'), findsOneWidget);

        // Tapping 'Back to albums' returns to the albums grid
        await tester.tap(find.byTooltip('Back to albums'));
        await tester.pumpAndSettle();

        expect(find.byTooltip('Back to albums'), findsNothing);
        expect(find.text('Abbey Road'), findsWidgets);
        expect(find.text('The Dark Side of the Moon'), findsOneWidget);
      },
    );

    testWidgets(
      'artist drilldown is preserved across library notifications and favorite toggles',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final items = [
          track(
            1,
            title: 'Come Together',
            artist: 'The Beatles',
            album: 'Abbey Road',
            favorite: false,
          ),
          track(
            2,
            title: 'Hey Jude',
            artist: 'The Beatles',
            album: 'Past Masters',
            favorite: false,
          ),
          track(
            3,
            title: 'Time',
            artist: 'Pink Floyd',
            album: 'The Dark Side of the Moon',
            favorite: false,
          ),
        ];

        final harness = Harness.create(items: items);
        addTearDown(() => harness.shutdown(tester));

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: MusicView(
                repository: harness.library,
                controller: harness.controller,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Navigate to Artists subtab
        await tester.tap(find.text('Artists'));
        await tester.pumpAndSettle();

        expect(find.text('The Beatles'), findsOneWidget);
        expect(find.text('Pink Floyd'), findsOneWidget);

        // Tap on The Beatles
        await tester.tap(find.text('The Beatles'));
        await tester.pumpAndSettle();

        // Verify in Artist detail view
        expect(find.byTooltip('Back to artists'), findsOneWidget);
        expect(find.text('Come Together'), findsOneWidget);
        expect(find.text('Hey Jude'), findsOneWidget);
        expect(find.text('Pink Floyd'), findsNothing);

        // Tap favorite icon on "Come Together"
        final favButtons = find.byTooltip('Add to favorites');
        expect(favButtons, findsWidgets);
        await tester.tap(favButtons.first);
        await tester.pumpAndSettle();

        // Verify: Still in Artist detail view!
        expect(find.byTooltip('Back to artists'), findsOneWidget);
        expect(find.text('Come Together'), findsOneWidget);
        expect(find.byTooltip('Remove favorite'), findsOneWidget);

        // Trigger library notification
        harness.library.notifyListeners();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();

        // Verify: Still in Artist detail view!
        expect(find.byTooltip('Back to artists'), findsOneWidget);
        expect(find.text('Come Together'), findsOneWidget);

        // Tap Back to artists
        await tester.tap(find.byTooltip('Back to artists'));
        await tester.pumpAndSettle();

        expect(find.byTooltip('Back to artists'), findsNothing);
        expect(find.text('The Beatles'), findsOneWidget);
        expect(find.text('Pink Floyd'), findsOneWidget);
      },
    );

    testWidgets('subtab change clears album or artist drilldown', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final items = [
        track(
          1,
          title: 'Come Together',
          artist: 'The Beatles',
          album: 'Abbey Road',
          favorite: false,
        ),
        track(
          2,
          title: 'Something',
          artist: 'The Beatles',
          album: 'Abbey Road',
          favorite: false,
        ),
      ];

      final harness = Harness.create(items: items);
      addTearDown(() => harness.shutdown(tester));

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: MusicView(
              repository: harness.library,
              controller: harness.controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Navigate to Albums subtab
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();

      // Drill down into Abbey Road
      await tester.tap(find.text('Abbey Road').first);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Back to albums'), findsOneWidget);

      // Trigger didUpdateWidget by updating with a new widget instance
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: MusicView(
              repository: harness.library,
              controller: harness.controller,
              searchQuery: 'something',
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      // Changing searchQuery clears drilldown
      expect(find.byTooltip('Back to albums'), findsNothing);
    });
  });
}
