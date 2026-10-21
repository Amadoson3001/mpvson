import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/library/views/library_shell.dart';
import 'support/library_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LibraryShell Responsive Layout', () {
    testWidgets('renders 208px sidebar, stage, and docked queue at >= 1180px', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(initialPaths: ['https://media.example/Track1.mp3']);

      try {
        await tester.pumpWidget(
          wrapWithApp(
            LibraryShell(
              repository: repo,
              controller: controller,
              initialSection: LibrarySection.music,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Navigation labels visible in 208px wide sidebar
        expect(find.text('Videos'), findsOneWidget);
        expect(find.text('Music'), findsOneWidget);
        expect(find.text('Playlists'), findsOneWidget);
        expect(find.text('Now playing'), findsOneWidget);

        // Docked queue panel visible
        expect(find.textContaining('Queue (1)'), findsOneWidget);

        // Main content stage has music subtabs
        expect(find.text('Songs'), findsOneWidget);
        expect(find.text('Albums'), findsOneWidget);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('renders collapsed rail navigation and on-demand queue at 960px to 1179px', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1000, 700);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(initialPaths: ['https://media.example/Track1.mp3']);

      try {
        await tester.pumpWidget(
          wrapWithApp(
            LibraryShell(
              repository: repo,
              controller: controller,
              initialSection: LibrarySection.music,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Side nav labels are collapsed into rail tooltips/icons
        expect(find.text('Videos'), findsNothing);

        // Queue is on-demand, not initially docked
        expect(find.textContaining('Queue (1)'), findsNothing);

        // On-demand queue toggle button is present
        final queueToggle = find.byTooltip('Open queue');
        expect(queueToggle, findsOneWidget);

        // Tapping queue toggle reveals the on-demand queue panel
        await tester.tap(queueToggle);
        await tester.pumpAndSettle();
        expect(find.textContaining('Queue (1)'), findsOneWidget);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('renders drawer navigation and stacked mini-player at < 960px', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 600);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(initialPaths: ['https://media.example/Track1.mp3']);

      try {
        await tester.pumpWidget(
          wrapWithApp(
            LibraryShell(
              repository: repo,
              controller: controller,
              initialSection: LibrarySection.music,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Hamburger button is present
        final menuButton = find.byTooltip('Open navigation');
        expect(menuButton, findsOneWidget);

        // Stacked bottom mini player is present
        expect(find.text('Now Playing'), findsOneWidget);

        // Tapping hamburger opens drawer with destinations
        await tester.tap(menuButton);
        await tester.pumpAndSettle();
        expect(find.text('Mpvson Library'), findsOneWidget);
        expect(find.text('Videos'), findsOneWidget);
        expect(find.text('Music'), findsOneWidget);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('is fully operational at 720x480 minimum without overflows', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(720, 480);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController(initialPaths: ['https://media.example/Track1.mp3']);

      try {
        await tester.pumpWidget(
          wrapWithApp(
            LibraryShell(
              repository: repo,
              controller: controller,
              initialSection: LibrarySection.music,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(LibraryShell), findsOneWidget);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });
  });

  group('LibraryShell Features and Status', () {
    testWidgets('search bar filters content across stage views', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController();

      try {
        await tester.pumpWidget(
          wrapWithApp(
            LibraryShell(
              repository: repo,
              controller: controller,
              initialSection: LibrarySection.music,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initial state displays Song Alpha and Song Beta
        expect(find.text('Song Alpha'), findsOneWidget);
        expect(find.text('Song Beta'), findsOneWidget);

        // Enter search query
        final searchInput = find.byType(TextField);
        await tester.enterText(searchInput, 'Alpha');
        await tester.pumpAndSettle();

        // Song Alpha matches, Song Beta is filtered out
        expect(find.text('Song Alpha'), findsOneWidget);
        expect(find.text('Song Beta'), findsNothing);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('displays scanning progress indicator and unavailable drive banner', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController();

      try {
        // Set scan status to active
        repo.setScanStatus(const LibraryScanStatus(
          phase: ScanPhase.enriching,
          currentFolder: 'C:/Music',
          discoveredCount: 150,
          enrichedCount: 90,
          totalToEnrich: 150,
        ));

        await tester.pumpWidget(
          wrapWithApp(
            LibraryShell(
              repository: repo,
              controller: controller,
              initialSection: LibrarySection.music,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Scanning indicator is visible
        expect(find.text('Enriching metadata...'), findsOneWidget);
        expect(find.textContaining('150 discovered • 90 of 150 enriched'), findsOneWidget);

        // Unavailable drive banner is visible with non-destructive status
        expect(find.textContaining('Drive unavailable'), findsOneWidget);
        expect(find.text('Items preserved'), findsOneWidget);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });

    testWidgets('switching navigation sections updates stage view', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);

      final repo = createTestMediaLibraryRepository();
      final controller = await createTestPlayerController();

      try {
        await tester.pumpWidget(
          wrapWithApp(
            LibraryShell(
              repository: repo,
              controller: controller,
              initialSection: LibrarySection.music,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Currently on music
        expect(find.text('Songs'), findsOneWidget);

        // Click Videos in sidebar
        await tester.tap(find.text('Videos'));
        await tester.pumpAndSettle();

        // Videos stage displayed
        expect(find.text('Ocean Sunset'), findsOneWidget);

        // Click Playlists in sidebar
        await tester.tap(find.text('Playlists'));
        await tester.pumpAndSettle();

        // Playlists stage displayed
        expect(find.text('Workout Beats'), findsOneWidget);
      } finally {
        await disposeTestPlayerController(tester, controller);
      }
    });
  });
}
