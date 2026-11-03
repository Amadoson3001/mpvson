import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/player_hotkeys.dart';
import 'package:mpvson/ui/library/views/library_shell.dart';
import 'package:mpvson/ui/player/views/mini_player_overlay.dart';
import 'package:mpvson/ui/player/views/player_layout_manager.dart';
import 'package:mpvson/ui/player/views/player_stage.dart';

import '../../../audit/player_harness.dart';
import '../../../support/app_harness.dart';
import '../../../support/audit_helpers.dart';

void main() {
  group('In-App Mini Video Player', () {
    testWidgets(
      'MiniPlayerOverlay provides clean unobstructed video and handles click to expand',
      (tester) async {
        final h = Harness.create();
        await openMedia(tester, h, ['test_video.mp4']);

        bool expanded = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 88,
                height: 50,
                child: MiniPlayerOverlay(
                  controller: h.controller,
                  onExpand: () => expanded = true,
                ),
              ),
            ),
          ),
        );
        await settle(tester);

        // Verify that exit, pause, and enlarge icons are NOT present
        expect(find.byIcon(Icons.close_rounded), findsNothing);
        expect(find.byIcon(Icons.pause_rounded), findsNothing);
        expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
        expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);

        // Tap the mini player to expand
        await tester.tap(find.byType(MiniPlayerOverlay));
        await settle(tester);
        expect(expanded, isTrue);

        await h.shutdown(tester);
      },
    );

    testWidgets(
      'PlayerStage renders mini overlay and suppresses heavy chrome when miniProgress > 0.5',
      (tester) async {
        final h = Harness.create();
        await openMedia(tester, h, ['test_video.mp4']);

        bool expanded = false;
        bool dismissed = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                height: 180,
                child: PlayerStage(
                  controller: h.controller,
                  videoBuilder: (_, _) => const ColoredBox(color: Colors.black),
                  contextMenu: MenuController(),
                  videoSurfaceKey: GlobalKey(),
                  controlsFocusScope: FocusScopeNode(),
                  controlsVisible: true,
                  controlMenuOpen: false,
                  draggingFiles: false,
                  feedbackLabel: null,
                  feedbackIcon: Icons.volume_up_rounded,
                  feedbackProgress: null,
                  feedbackCentered: false,
                  isFullscreen: false,
                  isMiniPlayer: false,
                  miniProgress: 1.0,
                  onExpandFromMini: () => expanded = true,
                  onDismissMini: () => dismissed = true,
                  queueOpen: false,
                  desktopWindow: true,
                  nativeWindow: true,
                  hasLibraryRepository: true,
                  hotkeys: PlayerHotkeys.defaults,
                  onPointerSignal: (_) {},
                  onVideoTap: () {},
                  onVideoDoubleTap: () {},
                  onControlsPointerEnter: (_) {},
                  onControlsPointerExit: (_) {},
                  onMenuVisibilityChanged: (_) {},
                  onControlInteractionChanged: (_) {},
                  onVolumeChanged: (_) {},
                  onBackToHome: () {},
                  onExitMiniPlayer: () {},
                  onTopBarFocusChange: (_) {},
                  onOpenFiles: () {},
                  onOpenUrl: () {},
                  onOpenRecent: (_) {},
                  onToggleQueue: () {},
                  onSettings: ({bool showMediaLibrary = false}) async {},
                  onPlaybackInfo: () async {},
                  onOpenLibrary: () {},
                  onFullscreen: () {},
                  onToggleMiniPlayer: () {},
                  onLoadSubtitle: () async {},
                  onToggleMute: () {},
                  onAdjustVolume: (_) {},
                  onUpdateViewportDimensions: (_, _) {},
                ),
              ),
            ),
          ),
        );
        await settle(tester);

        // MiniPlayerOverlay is present when miniProgress is 1.0
        expect(find.byType(MiniPlayerOverlay), findsOneWidget);

        // Full controls are suppressed when miniProgress is 1.0
        expect(
          find.byKey(const ValueKey('player-controls-visibility')),
          findsNothing,
        );

        await h.shutdown(tester);
      },
    );

    testWidgets(
      'PlayerLayoutManager syncVideoVisibilityForLibrary respects inAppMiniPlayerActive',
      (tester) async {
        final h = Harness.create();
        await openMedia(tester, h, ['test_video.mp4']);

        bool miniActive = true;
        bool showingLibrary = true;

        final layoutManager = PlayerLayoutManager(
          controller: h.controller,
          desktopWindow: true,
          isShowingLibrary: () => showingLibrary,
          showMessage: (_) {},
          showFeedback: (_, __, {bool centered = false}) {},
          isInAppMiniPlayerActive: () => miniActive,
        );

        // When showing library and mini is active, video policy should remain visible
        layoutManager.syncVideoVisibilityForLibrary();
        expect(h.controller.videoOutputPolicy.visible, isTrue);

        // When mini player is dismissed by user, video policy should become hidden to save GPU
        miniActive = false;
        layoutManager.syncVideoVisibilityForLibrary();
        expect(h.controller.videoOutputPolicy.visible, isFalse);

        // When returning to full video view, video policy becomes visible again
        showingLibrary = false;
        layoutManager.syncVideoVisibilityForLibrary();
        expect(h.controller.videoOutputPolicy.visible, isTrue);

        await h.shutdown(tester);
      },
    );

    testWidgets(
      'Navigating from video to library composes video into mini player and expanding returns to full',
      (tester) async {
        final h = await bootPlayer(
          tester,
          size: const Size(1280, 720),
          names: const ['sample_clip.mp4'],
        );

        // Initially in full player mode
        expect(find.byType(PlayerStage), findsOneWidget);
        expect(find.text('Return to video'), findsNothing);

        // Click Home button in the top bar to navigate to library
        final homeButton = find.text('Home');
        expect(homeButton, findsOneWidget);
        await tester.tap(homeButton);
        await settle(tester);

        // Now in library shell, and the video stage is composed into the mini player!
        expect(find.byType(LibraryShell), findsOneWidget);
        expect(find.byType(MiniPlayerOverlay), findsOneWidget);
        expect(find.text('Return to video'), findsOneWidget);

        // Verify the mini video player is docked in the bottom-left bar next to track name
        final overlayRect = tester.getRect(find.byType(MiniPlayerOverlay));
        expect(overlayRect.left, 16.0);
        expect(overlayRect.top, 720.0 - 79.0);
        expect(overlayRect.width, 88.0);
        expect(overlayRect.height, 50.0);

        // Click 'Return to video' to animate back to full player
        await tester.tap(find.text('Return to video'));
        await settle(tester);

        // Back in full player!
        expect(find.text('Return to video'), findsNothing);
        expect(find.byType(MiniPlayerOverlay), findsNothing);
        expect(find.byType(PlayerStage), findsOneWidget);

        await h.shutdown(tester);
      },
    );

    testWidgets(
      'Tapping on the docked mini player smoothly expands to full video',
      (tester) async {
        final h = await bootPlayer(
          tester,
          size: const Size(1280, 720),
          names: const ['sample_clip.mp4'],
        );

        // Navigate to library
        await tester.tap(find.text('Home'));
        await settle(tester);

        expect(find.byType(MiniPlayerOverlay), findsOneWidget);

        // Tap directly on the docked mini video player
        await tester.tap(find.byType(MiniPlayerOverlay));
        await settle(tester);

        // Video expands back to full screen
        expect(find.byType(MiniPlayerOverlay), findsNothing);
        expect(find.byType(PlayerStage), findsOneWidget);

        await h.shutdown(tester);
      },
    );
  });
}
