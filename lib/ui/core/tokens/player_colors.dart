import 'package:flutter/material.dart';

/// Centralized color, opacity, and overlay token constants for Mpvson.
///
/// Replaces repetitive inline `.withOpacity()` and `.withValues(alpha: ...)`
/// calls across video controls, overlay bars, and modal dialogs.
class PlayerColors {
  PlayerColors._();

  /// Heavy black scrim used for modal dialog backdrops and full-screen masks (75% opacity).
  static const Color scrim = Color(0xBF000000);

  /// Dark overlay backdrop for video controls and bottom transport bars (60% opacity).
  static const Color overlayDark = Color(0x99000000);

  /// Medium translucent backdrop for floating pills, toolbars, and badges (45% opacity).
  static const Color overlayMedium = Color(0x73000000);

  /// Subtle translucent backdrop for secondary controls and chips (25% opacity).
  static const Color overlayLight = Color(0x40000000);

  /// Ultra-subtle backdrop for control borders and dividers (15% opacity).
  static const Color overlaySubtle = Color(0x26000000);

  /// Standard hover overlay color on dark surfaces (12% white).
  static const Color hoverWhite = Color(0x1FFFFFFF);

  /// Standard pressed/active overlay color on dark surfaces (20% white).
  static const Color pressedWhite = Color(0x33FFFFFF);

  /// Subtle white border for cards and panels over video (15% white).
  static const Color borderWhite = Color(0x26FFFFFF);

  /// Muted secondary text color over video surfaces (65% white).
  static const Color textMuted = Color(0xA6FFFFFF);

  /// Dim tertiary text color over video surfaces (45% white).
  static const Color textDim = Color(0x73FFFFFF);
}
