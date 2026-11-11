import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/control_density.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/settings/settings_appearance_section.dart';

import '../../../../support/app_harness.dart';

void main() {
  group('AppearanceSettingsSection', () {
    testWidgets('renders theme mode cards and selects theme', (tester) async {
      final preferences = AppPreferencesRepository();
      final controller = PlayerController(
        playback: FakePlaybackService(),
        sessions: SessionRepository(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppearanceSettingsSection(
              controller: controller,
              compactViewport: false,
              appPreferences: preferences,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Theme cards render
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);

      // Tap Light mode
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(preferences.preferences.themeMode, ThemeMode.light);

      // Tap Dark mode
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(preferences.preferences.themeMode, ThemeMode.dark);

      // Swatches render
      expect(find.text('Amber Lamp'), findsOneWidget);
      expect(find.text('Jade Aurora'), findsOneWidget);
      expect(find.text('Electric Sky'), findsOneWidget);

      // Tap preset
      await tester.tap(find.text('Jade Aurora'));
      await tester.pumpAndSettle();
      expect(preferences.preferences.accentPreset, 'jade');

      // Density selector exists
      expect(
        find.byKey(const ValueKey('control-density-selector')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text('Normal'), 100);
      await tester.tap(find.text('Normal'));
      await tester.pump(const Duration(seconds: 3));
      expect(controller.controlDensity, ControlDensity.normal);
      controller.dispose();
      preferences.dispose();
    });
  });
}
