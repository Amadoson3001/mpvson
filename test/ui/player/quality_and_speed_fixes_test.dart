import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/playback_settings.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/widgets/controls/playback_rate_menu.dart';
import 'package:mpvson/ui/player/widgets/player_actions.dart';
import 'package:mpvson/ui/player/widgets/player_control_style.dart';

import '../../support/fake_playback_service.dart';

void main() {
  group('VideoOutputPolicy quality sizing', () {
    test('upscales smaller video to native physical viewport up to 4K', () {
      const policy1080 = VideoOutputPolicy(
        physicalWidth: 1920,
        physicalHeight: 1080,
      );
      final fitted720 = policy1080.fitVideo(width: 1280, height: 720);
      expect(fitted720, (width: 1920, height: 1080));

      const policy1440 = VideoOutputPolicy(
        physicalWidth: 2560,
        physicalHeight: 1440,
      );
      final fitted1080 = policy1440.fitVideo(width: 1920, height: 1080);
      expect(fitted1080, (width: 2560, height: 1440));
    });

    test('downscales 4K video to fit smaller physical viewport', () {
      const policy = VideoOutputPolicy(
        physicalWidth: 1920,
        physicalHeight: 1080,
      );
      final fitted = policy.fitVideo(width: 3840, height: 2160);
      expect(fitted, (width: 1920, height: 1080));
    });

    test('caps upscaling at 4K ceiling for oversized virtual viewports', () {
      const policy = VideoOutputPolicy(
        physicalWidth: 7680,
        physicalHeight: 4320,
      );
      final fitted = policy.fitVideo(width: 1280, height: 720);
      expect(fitted, (width: 3840, height: 2160));
    });
  });

  group('PlaybackSettings renderer properties', () {
    test('uses valid mpv dither and fbo-format values for all presets', () {
      for (final preset in PlaybackQualityPreset.values) {
        final props = PlaybackSettings(
          qualityPreset: preset,
        ).rendererProperties;
        expect(
          const <String>{'no', 'fruit', 'ordered', 'error-diffusion'},
          contains(props['dither']),
          reason: '${preset.name} must use a valid mpv dither mode',
        );
        expect(
          props['fbo-format'],
          isNotNull,
          reason: '${preset.name} must explicitly set fbo-format',
        );
      }
      expect(
        const PlaybackSettings(
          qualityPreset: PlaybackQualityPreset.balanced,
        ).rendererProperties['fbo-format'],
        'auto',
      );
      expect(
        const PlaybackSettings(
          qualityPreset: PlaybackQualityPreset.quality,
        ).rendererProperties['fbo-format'],
        'auto',
      );
    });
  });

  group('PlaybackRateMenu & PlayerActions reactivity', () {
    PlayerController createController() {
      final dir = Directory.systemTemp.createTempSync('mpvson-rate-test-');
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(directory: dir),
      );
      addTearDown(() async {
        await controller.close(discard: true);
        controller.dispose();
        await playback.dispose();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      return controller;
    }

    testWidgets(
      'PlaybackRateMenu updates label when rate changes via menu or controller',
      (tester) async {
        final controller = createController();

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: PlayerControlStyle(
                compact: false,
                child: PlaybackRateMenu(
                  controller: controller,
                  onMenuVisibilityChanged: (_) {},
                ),
              ),
            ),
          ),
        );

        expect(find.text('1×'), findsOneWidget);

        // Open menu and pick 1.5×.
        await tester.tap(
          find.byKey(const ValueKey('playback-rate-menu-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('1.5×'));
        await tester.pumpAndSettle();

        expect(controller.rate, 1.5);
        expect(find.text('1.5×'), findsOneWidget);
        expect(find.text('1×'), findsNothing);

        // Programmatic hotkey adjustment also updates the button immediately.
        await controller.adjustPlaybackRate(delta: 0.25);
        await tester.pump();
        expect(find.text('1.75×'), findsOneWidget);

        await controller.resetPlaybackRate();
        await tester.pump();
        expect(find.text('1×'), findsOneWidget);
      },
    );

    testWidgets(
      'PlayerActions queue badge updates when items are added to queue',
      (tester) async {
        final controller = createController();

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: PlayerControlStyle(
                compact: false,
                child: PlayerActions(
                  controller: controller,
                  onOpenFiles: () {},
                  onOpenUrl: () {},
                  onOpenRecent: (_) {},
                  onToggleQueue: () {},
                  onSettings: () {},
                  onMenuVisibilityChanged: (_) {},
                  queueOpen: false,
                ),
              ),
            ),
          ),
        );

        expect(find.text('1'), findsNothing);

        await controller.openPaths(<String>['https://example.com/a.mp4']);
        await tester.pump();
        expect(find.text('1'), findsOneWidget);

        await controller.addToQueue(<String>['https://example.com/b.mp4']);
        await tester.pump();
        expect(find.text('2'), findsOneWidget);
      },
    );
  });
}
