import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/player_hotkeys.dart';
import 'package:mpvson/ui/player/views/player_chrome_controller.dart';
import 'package:mpvson/ui/player/views/player_stage.dart';
import 'package:mpvson/ui/player/views/settings/floating_video_settings.dart';

import '../../../support/app_harness.dart';
import '../../../support/audit_helpers.dart';

void main() {
  group('PlayerStage Floating Video Settings', () {
    testWidgets(
      'shows FloatingVideoSettings when video is active and videoSettingsOpen is true',
      (tester) async {
        final h = Harness.create();
        await openMedia(tester, h, ['sample.mp4']);

        bool closed = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlayerStage(
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
                videoSettingsOpen: true,
                onCloseVideoSettings: () => closed = true,
              ),
            ),
          ),
        );
        await settle(tester);

        expect(find.byType(FloatingVideoSettings), findsOneWidget);
        expect(find.text('Video Settings'), findsOneWidget);

        // Tap close button on header
        await tester.tap(find.byTooltip('Close settings (Esc)'));
        await settle(tester);

        expect(closed, isTrue);

        await h.shutdown(tester);
      },
    );

    testWidgets(
      'does not show FloatingVideoSettings when videoSettingsOpen is false',
      (tester) async {
        final h = Harness.create();
        await openMedia(tester, h, ['sample.mp4']);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlayerStage(
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
                videoSettingsOpen: false,
              ),
            ),
          ),
        );
        await settle(tester);

        expect(find.byType(FloatingVideoSettings), findsNothing);

        await h.shutdown(tester);
      },
    );

    testWidgets(
      'keeps FloatingVideoSettings mounted until the slide-out ends',
      (tester) async {
        final h = Harness.create();
        await openMedia(tester, h, ['sample.mp4']);

        var open = true;
        var mountedFlag = true;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return PlayerStage(
                    controller: h.controller,
                    videoBuilder: (_, _) =>
                        const ColoredBox(color: Colors.black),
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
                    videoSettingsOpen: open,
                    videoSettingsMounted: mountedFlag,
                    onCloseVideoSettings: () => setState(() => open = false),
                    onVideoSettingsExitEnd: () =>
                        setState(() => mountedFlag = false),
                  );
                },
              ),
            ),
          ),
        );
        await settle(tester);
        expect(find.byType(FloatingVideoSettings), findsOneWidget);

        await tester.tap(find.byTooltip('Close settings (Esc)'));
        await tester.pump();
        expect(find.byType(FloatingVideoSettings), findsOneWidget);

        await tester.pumpAndSettle();
        expect(find.byType(FloatingVideoSettings), findsNothing);

        await h.shutdown(tester);
      },
    );
  });

  group('PlayerChromeController video settings motion', () {
    test('keeps the panel mounted until the exit animation ends', () {
      final playerFocus = FocusNode();
      final chrome = PlayerChromeController(
        contextMenu: MenuController(),
        playerFocus: playerFocus,
        isFullscreen: () => false,
        reduceMotion: () => false,
      );

      chrome.toggleVideoSettings();
      expect(chrome.videoSettingsOpen, isTrue);
      expect(chrome.videoSettingsMounted, isTrue);

      chrome.closeVideoSettings();
      expect(chrome.videoSettingsOpen, isFalse);
      expect(chrome.videoSettingsMounted, isTrue);

      chrome.handleVideoSettingsExitEnd();
      expect(chrome.videoSettingsMounted, isFalse);

      chrome.dispose();
      playerFocus.dispose();
    });

    test('unmounts immediately when motion is reduced', () {
      final playerFocus = FocusNode();
      final chrome = PlayerChromeController(
        contextMenu: MenuController(),
        playerFocus: playerFocus,
        isFullscreen: () => false,
        reduceMotion: () => true,
      );

      chrome.toggleVideoSettings();
      chrome.closeVideoSettings();
      expect(chrome.videoSettingsOpen, isFalse);
      expect(chrome.videoSettingsMounted, isFalse);

      chrome.dispose();
      playerFocus.dispose();
    });
  });
}
