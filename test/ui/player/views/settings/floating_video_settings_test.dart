import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/ui/core/components/app_toggle_switch.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/settings/floating_video_settings.dart';
import 'package:mpvson/ui/player/views/settings/settings_shared_widgets.dart';

import '../../../../support/app_harness.dart';

void main() {
  group('FloatingVideoSettings', () {
    testWidgets(
      'renders tabs, switches tabs, and triggers onClose on close button',
      (tester) async {
        final playback = FakePlaybackService();
        final controller = PlayerController(
          playback: playback,
          sessions: SessionRepository(),
        );
        bool closed = false;
        bool openedFull = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  FloatingVideoSettings(
                    controller: controller,
                    pickSubtitle: () async => null,
                    onClose: () => closed = true,
                    onOpenFullSettings: () => openedFull = true,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Header is rendered
        expect(find.text('Video Settings'), findsOneWidget);

        // Tabs are rendered
        expect(find.text('Audio & Subs'), findsOneWidget);
        expect(find.text('Picture'), findsOneWidget);
        expect(find.text('Playback'), findsOneWidget);
        expect(find.text('Display'), findsOneWidget);

        // Switch to Picture tab
        await tester.tap(find.text('Picture'));
        await tester.pumpAndSettle();

        expect(find.text('Hardware decoding'), findsOneWidget);
        expect(find.text('Color calibration'), findsOneWidget);
        expect(find.byType(AppToggleSwitch), findsWidgets);

        // Switch to Playback tab
        await tester.tap(find.text('Playback'));
        await tester.pumpAndSettle();

        expect(find.text('Playback speed'), findsOneWidget);
        expect(find.text('1.0× (Normal)'), findsOneWidget);

        // Switch to Display tab
        await tester.tap(find.text('Display'));
        await tester.pumpAndSettle();

        expect(find.text('Control bar size'), findsOneWidget);

        // Test footer full settings button
        await tester.tap(
          find.byKey(const ValueKey('floating-settings-full-button')),
        );
        await tester.pumpAndSettle();

        expect(closed, isTrue);
        expect(openedFull, isTrue);

        controller.dispose();
      },
    );

    testWidgets('triggers onClose on Escape key', (tester) async {
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
      bool closed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                FloatingVideoSettings(
                  controller: controller,
                  pickSubtitle: () async => null,
                  onClose: () => closed = true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(closed, isTrue);

      controller.dispose();
    });

    testWidgets('triggers onClose when tapping outside floating panel', (
      tester,
    ) async {
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
      bool closed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                FloatingVideoSettings(
                  controller: controller,
                  pickSubtitle: () async => null,
                  onClose: () => closed = true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap at the left side of the screen (outside the right-aligned floating panel)
      await tester.tapAt(const Offset(50, 200));
      await tester.pumpAndSettle();

      expect(closed, isTrue);

      controller.dispose();
    });

    testWidgets('draft follows external playback settings changes', (
      tester,
    ) async {
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                FloatingVideoSettings(
                  controller: controller,
                  pickSubtitle: () async => null,
                  onClose: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Picture tab shows the calibration sliders.
      await tester.tap(find.text('Picture'));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsWidgets);

      // An external edit (full settings dialog, hotkey) must reach the open
      // panel: the brightness slider now shows the new value.
      await controller.setPlaybackSettings(
        controller.playbackSettings.copyWith(brightness: 40),
      );
      await tester.pumpAndSettle();

      expect(find.text('+40'), findsOneWidget);

      controller.dispose();
    });

    testWidgets('display tab follows external preference changes', (
      tester,
    ) async {
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
      final prefs = MemoryPreferences();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                FloatingVideoSettings(
                  controller: controller,
                  appPreferences: prefs,
                  pickSubtitle: () async => null,
                  onClose: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Display'));
      await tester.pumpAndSettle();

      bool switchValue(String title) {
        final tile = find.ancestor(
          of: find.text(title),
          matching: find.byType(SettingsSwitchTile),
        );
        return tester
            .widget<AppToggleSwitch>(
              find.descendant(of: tile, matching: find.byType(AppToggleSwitch)),
            )
            .value;
      }

      expect(switchValue('OLED pure black'), isFalse);

      // External change (e.g. the full settings dialog) reaches the panel.
      await prefs.setOledBlack(true);
      await tester.pumpAndSettle();

      expect(switchValue('OLED pure black'), isTrue);

      controller.dispose();
    });
  });
}
