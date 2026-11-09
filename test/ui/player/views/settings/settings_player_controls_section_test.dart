import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/player_controls_preferences.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/settings/settings_player_controls_section.dart';
import 'package:mpvson/ui/player/widgets/player_controls.dart';

import '../../../../support/app_harness.dart';

void main() {
  group('PlayerControlsPreferences Model', () {
    test('default values are properly initialized', () {
      const prefs = PlayerControlsPreferences();
      expect(prefs.barStyle, PlayerControlBarStyle.floatingPill);
      expect(prefs.backgroundOpacity, 0.88);
      expect(prefs.enableBlur, isTrue);
      expect(prefs.showStopButton, isTrue);
      expect(prefs.showShuffleRepeat, isTrue);
      expect(prefs.showSpeedButton, isTrue);
      expect(prefs.showVolumeSlider, isTrue);
      expect(prefs.showQueueButton, isTrue);
      expect(prefs.showRemainingTime, isFalse);
      expect(prefs.seekBarThickness, SeekBarThickness.standard);
      expect(prefs.autoHideDelaySeconds, 2.8);
    });

    test('JSON serialization roundtrips correctly', () {
      const original = PlayerControlsPreferences(
        barStyle: PlayerControlBarStyle.cinematicGradient,
        backgroundOpacity: 0.75,
        enableBlur: false,
        showStopButton: false,
        showShuffleRepeat: false,
        showSpeedButton: false,
        showVolumeSlider: false,
        showQueueButton: false,
        showRemainingTime: true,
        seekBarThickness: SeekBarThickness.bold,
        autoHideDelaySeconds: 1.5,
      );

      final json = original.toJson();
      final restored = PlayerControlsPreferences.fromJson(json);

      expect(restored.barStyle, PlayerControlBarStyle.cinematicGradient);
      expect(restored.backgroundOpacity, 0.75);
      expect(restored.enableBlur, isFalse);
      expect(restored.showStopButton, isFalse);
      expect(restored.showShuffleRepeat, isFalse);
      expect(restored.showSpeedButton, isFalse);
      expect(restored.showVolumeSlider, isFalse);
      expect(restored.showQueueButton, isFalse);
      expect(restored.showRemainingTime, isTrue);
      expect(restored.seekBarThickness, SeekBarThickness.bold);
      expect(restored.autoHideDelaySeconds, 1.5);
      expect(restored, equals(original));
    });

    test('copyWith updates specified fields only', () {
      const original = PlayerControlsPreferences();
      final updated = original.copyWith(
        barStyle: PlayerControlBarStyle.frostedDocked,
        backgroundOpacity: 0.5,
        showRemainingTime: true,
      );

      expect(updated.barStyle, PlayerControlBarStyle.frostedDocked);
      expect(updated.backgroundOpacity, 0.5);
      expect(updated.showRemainingTime, isTrue);
      expect(updated.enableBlur, isTrue);
      expect(updated.showStopButton, isTrue);
    });
  });

  group('PlayerControlsSettingsSection Widget', () {
    testWidgets('renders all controls and live preview card', (tester) async {
      final preferences = MemoryPreferences();
      final controller = PlayerController(
        playback: FakePlaybackService(),
        sessions: SessionRepository(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PlayerControlsSettingsSection(
              appPreferences: preferences,
              controller: controller,
              compactViewport: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Live preview renders
      expect(
        find.byKey(const ValueKey('player-controls-live-preview')),
        findsOneWidget,
      );

      // Style preset cards render
      expect(find.text('Floating Pill'), findsOneWidget);
      expect(find.text('Cinematic'), findsOneWidget);
      expect(find.text('Frosted Dock'), findsOneWidget);
      expect(find.text('Minimalist'), findsOneWidget);

      // Tapping Cinematic updates preferences immediately without restart
      await tester.tap(find.text('Cinematic'));
      await tester.pumpAndSettle();
      expect(
        preferences.preferences.playerControls.barStyle,
        PlayerControlBarStyle.cinematicGradient,
      );

      // Tapping Frosted Dock updates preferences
      await tester.tap(find.text('Frosted Dock'));
      await tester.pumpAndSettle();
      expect(
        preferences.preferences.playerControls.barStyle,
        PlayerControlBarStyle.frostedDocked,
      );

      // Seekbar thickness selector exists
      expect(
        find.byKey(const ValueKey('seekbar-thickness-selector')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text('Bold'), 100);
      await tester.tap(find.text('Bold'));
      await tester.pumpAndSettle();
      expect(
        preferences.preferences.playerControls.seekBarThickness,
        SeekBarThickness.bold,
      );

      // Toggle switch for remaining time
      await tester.scrollUntilVisible(find.text('Show remaining time'), 100);
      await tester.tap(find.text('Show remaining time'));
      await tester.pumpAndSettle();
      expect(
        preferences.preferences.playerControls.showRemainingTime,
        isTrue,
      );

      // Auto-hide delay selector exists
      expect(
        find.byKey(const ValueKey('autohide-delay-selector')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text('Fast (1.5s)'), 100);
      await tester.tap(find.text('Fast (1.5s)'));
      await tester.pumpAndSettle();
      expect(
        preferences.preferences.playerControls.autoHideDelaySeconds,
        1.5,
      );

      // Reset button resets to defaults
      await tester.scrollUntilVisible(
        find.text('Reset player controls to defaults'),
        100,
      );
      await tester.tap(find.text('Reset player controls to defaults'));
      await tester.pumpAndSettle();
      expect(
        preferences.preferences.playerControls.barStyle,
        PlayerControlBarStyle.floatingPill,
      );
      expect(
        preferences.preferences.playerControls.seekBarThickness,
        SeekBarThickness.standard,
      );

      controller.dispose();
      preferences.dispose();
    });

    testWidgets('hot reloads PlayerControls live when preferences change', (
      tester,
    ) async {
      final preferences = MemoryPreferences();
      final controller = PlayerController(
        playback: FakePlaybackService(),
        sessions: SessionRepository(),
      );

      await tester.pumpWidget(
        ListenableBuilder(
          listenable: preferences,
          builder: (context, _) => AppPreferencesScope(
            preferences: preferences.preferences,
            child: MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(
                body: PlayerControls(
                  controller: controller,
                  showPlaybackControls: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially shuffle and repeat toggles are visible
      expect(find.byKey(const ValueKey('shuffle-toggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('repeat-toggle')), findsOneWidget);

      // Hot reload without restart: turn off shuffle/repeat
      await preferences.updatePlayerControls(
        preferences.preferences.playerControls.copyWith(
          showShuffleRepeat: false,
        ),
      );
      await tester.pumpAndSettle();

      // They disappear immediately without restart!
      expect(find.byKey(const ValueKey('shuffle-toggle')), findsNothing);
      expect(find.byKey(const ValueKey('repeat-toggle')), findsNothing);

      // Hot reload: switch to cinematic gradient
      await preferences.updatePlayerControls(
        preferences.preferences.playerControls.copyWith(
          barStyle: PlayerControlBarStyle.cinematicGradient,
        ),
      );
      await tester.pumpAndSettle();

      // Strip is still rendered with new style
      expect(find.byKey(const ValueKey('player-control-strip')), findsOneWidget);

      controller.dispose();
      preferences.dispose();
    });
  });
}
