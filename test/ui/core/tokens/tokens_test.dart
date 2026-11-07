import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/tokens/colors.dart';
import 'package:mpvson/ui/core/tokens/radii.dart';

void main() {
  group('design tokens', () {
    test('AppRadii exposes a dialog radius role', () {
      // Dialogs share the artwork radius today; the role exists so the two
      // can diverge without touching every dialog call site.
      expect(AppRadii.dialog, AppRadii.artwork);
      expect(AppRadii.dialog, isNonNegative);
    });

    test('the lamp accent preset resolves through AppColors', () {
      expect(AppColors.lamp, const Color(0xFFF1A64C));
      expect(AppAccentPreset.lamp.color, AppColors.lamp);
      expect(AppAccentPreset.lamp.lightColor, AppColors.lampLight);
      expect(AppAccentPreset.fromId('lamp').color, AppColors.lamp);
      // The lamp preset is the default accent.
      expect(AppAccentPreset.fromId(null).id, 'lamp');
      expect(AppAccentPreset.fromId('unknown-preset').id, 'lamp');
    });
  });
}
