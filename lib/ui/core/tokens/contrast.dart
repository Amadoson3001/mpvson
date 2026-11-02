import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';

/// WCAG contrast helpers used to keep accent colors usable as both a fill
/// (with `onPrimary` text on top) and as text or an icon on the app surfaces.
abstract final class AppContrast {
  /// Minimum ratio for normal-size text (WCAG AA).
  static const double text = 4.5;

  /// Contrast ratio between two opaque colors, from 1 to 21.
  static double ratio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Returns [accent], moved along lightness only as far as needed so that it
  /// reaches [minimum] contrast against [onAccent] and every one of [surfaces].
  ///
  /// Dark themes lighten the accent and light themes darken it; hue and
  /// saturation are kept, so presets that already pass are returned untouched.
  static Color readableAccent(
    Color accent, {
    required Brightness brightness,
    required Color onAccent,
    required Iterable<Color> surfaces,
    double minimum = text,
  }) {
    bool passes(Color c) =>
        ratio(c, onAccent) >= minimum &&
        surfaces.every((surface) => ratio(c, surface) >= minimum);

    if (passes(accent)) return accent;
    final hsl = HSLColor.fromColor(accent);
    final step = brightness == Brightness.dark ? 0.01 : -0.01;
    var lightness = hsl.lightness;
    var candidate = accent;
    while (!passes(candidate) && lightness > 0 && lightness < 1) {
      lightness = (lightness + step).clamp(0.0, 1.0);
      candidate = hsl.withLightness(lightness).toColor();
    }
    return candidate;
  }
}
