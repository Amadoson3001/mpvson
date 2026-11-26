import 'package:flutter/material.dart';

/// Centralized color, opacity, and overlay token constants for Mpvson.
///
/// Replaces repetitive inline `.withOpacity()` and `.withValues(alpha: ...)`
/// calls across video controls, overlay bars, and modal dialogs.
class PlayerColors {
  PlayerColors._();

  /// Heavy black scrim used for modal dialog backdrops and full-screen masks (75% opacity).
  static const Color scrim = Color(0xBF000000);

  /// Medium translucent backdrop for floating pills, toolbars, and badges (45% opacity).
  static const Color overlayMedium = Color(0x73000000);

  /// Subtle translucent backdrop for secondary controls and chips (25% opacity).
  static const Color overlayLight = Color(0x40000000);

  /// Standard hover overlay color on dark surfaces (12% white).
  static const Color hoverWhite = Color(0x1FFFFFFF);
}
