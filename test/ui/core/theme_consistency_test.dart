import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/theme/app_chrome.dart';
import 'package:mpvson/ui/core/theme/surface_themes.dart';

void main() {
  group('Theme Consistency & Context Menu Styling', () {
    test('AppTheme.buildTheme applies accent consistently to controls', () {
      const testAccent = Color(0xFF38BDF8); // Cyan
      final theme = AppTheme.buildTheme(
        brightness: Brightness.dark,
        accent: testAccent,
        oledBlack: false,
      );

      // Primary colorScheme
      expect(theme.colorScheme.primary, equals(testAccent));

      // RadioTheme fillColor when selected
      final radioColor = theme.radioTheme.fillColor?.resolve({
        WidgetState.selected,
      });
      expect(radioColor, equals(testAccent));

      // CheckboxTheme fillColor when selected
      final checkboxColor = theme.checkboxTheme.fillColor?.resolve({
        WidgetState.selected,
      });
      expect(checkboxColor, equals(testAccent));

      // SwitchTheme trackColor when selected
      final switchTrack = theme.switchTheme.trackColor?.resolve({
        WidgetState.selected,
      });
      expect(switchTrack, equals(testAccent));

      // SliderTheme activeTrackColor
      expect(theme.sliderTheme.activeTrackColor, equals(testAccent));
    });

    test(
      'menuButtonTheme has no border and uses light accent on hover/focus',
      () {
        const testAccent = Color(0xFF38BDF8);
        final chrome = AppChrome.dark(accent: testAccent);
        final menuBtnTheme = menuButtonTheme(chrome);

        // Border must be BorderSide.none across all states
        final focusedSide = menuBtnTheme.style?.side?.resolve({
          WidgetState.focused,
        });
        expect(focusedSide, equals(BorderSide.none));

        final hoveredSide = menuBtnTheme.style?.side?.resolve({
          WidgetState.hovered,
        });
        expect(hoveredSide, equals(BorderSide.none));

        // Background color on hover/focus must be a light tint of the accent
        final hoveredBg = menuBtnTheme.style?.backgroundColor?.resolve({
          WidgetState.hovered,
        });
        expect(hoveredBg, equals(testAccent.withValues(alpha: 0.14)));

        final focusedBg = menuBtnTheme.style?.backgroundColor?.resolve({
          WidgetState.focused,
        });
        expect(focusedBg, equals(testAccent.withValues(alpha: 0.14)));
      },
    );
  });
}
