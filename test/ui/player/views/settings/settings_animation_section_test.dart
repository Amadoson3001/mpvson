import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/ui/player/views/settings/settings_animation_section.dart';

void main() {
  group('AnimationSettingsSection', () {
    testWidgets('smooth animations toggle and speed selector update prefs', (
      tester,
    ) async {
      final preferences = AppPreferencesRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimationSettingsSection(appPreferences: preferences),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Smooth animations'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('animation-speed-selector')),
        findsOneWidget,
      );

      // Turning animations off disables the speed selector.
      await tester.tap(find.text('Smooth animations'));
      await tester.pumpAndSettle();
      expect(preferences.preferences.reduceMotion, true);
      expect(find.textContaining('Animations are off'), findsOneWidget);

      await tester.tap(find.text('Slow'));
      await tester.pumpAndSettle();
      expect(preferences.preferences.animationSpeed, AnimationSpeed.normal);

      // Turning them back on re-enables the selector.
      await tester.tap(find.text('Smooth animations'));
      await tester.pumpAndSettle();
      expect(preferences.preferences.reduceMotion, false);
      expect(find.textContaining('Animations are off'), findsNothing);

      await tester.tap(find.text('Slow'));
      await tester.pumpAndSettle();
      expect(preferences.preferences.animationSpeed, AnimationSpeed.slow);
      preferences.dispose();
    });
  });
}
