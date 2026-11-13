import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Centralized slider theming for seek bar, volume, and settings controls.
class PlayerSliderTheme {
  PlayerSliderTheme._();

  /// Standard slider theme for volume controls across player and library chrome.
  static SliderThemeData volume(
    BuildContext context, {
    bool compact = false,
    Color? activeColor,
    Color? inactiveColor,
    Color? thumbColor,
    Color? overlayColor,
  }) {
    final palette = context.palette;
    final primary = activeColor ?? Theme.of(context).colorScheme.primary;
    final inactive = inactiveColor ?? palette.muted.withValues(alpha: 0.25);
    final thumb = thumbColor ?? palette.text;
    final overlay = overlayColor ?? primary.withValues(alpha: 0.16);

    return SliderTheme.of(context).copyWith(
      trackHeight: compact ? 3.0 : 3.5,
      trackGap: 0,
      thumbShape: RoundSliderThumbShape(
        enabledThumbRadius: compact ? 4.0 : 5.0,
        elevation: 1.0,
        pressedElevation: 2.5,
      ),
      overlayShape: RoundSliderOverlayShape(
        overlayRadius: compact ? 10.0 : 12.0,
      ),
      activeTrackColor: primary,
      inactiveTrackColor: inactive,
      thumbColor: thumb,
      overlayColor: overlay,
    );
  }

  /// Seek bar theme. Dynamic thumb/track sizes stay with the caller.
  static SliderThemeData seek(
    BuildContext context, {
    required double trackHeight,
    required SliderComponentShape thumbShape,
    SliderTrackShape? trackShape,
    double overlayRadius = 14,
    Color? inactiveColor,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return SliderTheme.of(context).copyWith(
      trackHeight: trackHeight,
      trackShape: trackShape,
      trackGap: 0,
      thumbShape: thumbShape,
      overlayShape: RoundSliderOverlayShape(overlayRadius: overlayRadius),
      activeTrackColor: primary,
      inactiveTrackColor: inactiveColor ?? Colors.white.withValues(alpha: 0.25),
      overlayColor: primary.withValues(alpha: 0.16),
      thumbColor: primary,
      padding: EdgeInsets.zero,
    );
  }

  /// Compact slider theme for settings panels and secondary adjustments.
  static SliderThemeData compact(
    BuildContext context, {
    Color? activeColor,
    Color? inactiveColor,
    Color? thumbColor,
  }) {
    final palette = context.palette;
    final primary = activeColor ?? palette.accent;

    return SliderTheme.of(context).copyWith(
      trackHeight: 2.5,
      thumbShape: const RoundSliderThumbShape(
        enabledThumbRadius: 4.0,
        elevation: 1.0,
      ),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 8.0),
      activeTrackColor: primary,
      inactiveTrackColor: inactiveColor ?? palette.border,
      thumbColor: thumbColor ?? primary,
      overlayColor: primary.withValues(alpha: 0.12),
    );
  }
}
