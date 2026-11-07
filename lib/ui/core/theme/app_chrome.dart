import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/contrast.dart';

/// Every color the component themes need, for one brightness and accent.
///
/// Dark, light, OLED black and artwork-tinted themes are all built from this
/// one shape by `buildAppTheme`, so they cannot drift apart.
@immutable
class AppChrome {
  const AppChrome({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.card,
    required this.hover,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.secondaryText,
    required this.muted,
    required this.danger,
    required this.onDanger,
    required this.accent,
    required this.onAccent,
    required this.inputFill,
    required this.scrim,
  });

  factory AppChrome.dark({required Color accent, bool oledBlack = false}) {
    return AppChrome._resolved(
      brightness: Brightness.dark,
      background: oledBlack ? Colors.black : AppColors.ground,
      surface: oledBlack ? const Color(0xFF0C0C0C) : AppColors.layer,
      card: oledBlack ? const Color(0xFF141414) : AppColors.raised,
      hover: oledBlack ? const Color(0xFF1E1E1E) : AppColors.hover,
      border: oledBlack ? const Color(0xFF262626) : AppColors.line,
      borderStrong: oledBlack ? const Color(0xFF383838) : AppColors.lineStrong,
      text: AppColors.ink,
      secondaryText: AppColors.inkMuted,
      muted: AppColors.inkDim,
      danger: AppColors.rose,
      scrim: AppColors.scrim,
      accent: accent,
    );
  }

  factory AppChrome.light({required Color accent}) {
    return AppChrome._resolved(
      brightness: Brightness.light,
      background: AppColors.lightGround,
      surface: AppColors.lightSidebar,
      card: AppColors.lightCard,
      hover: AppColors.lightHover,
      border: AppColors.lightLine,
      borderStrong: AppColors.lightLineStrong,
      text: AppColors.lightInk,
      secondaryText: AppColors.lightInkMuted,
      muted: AppColors.lightInkDim,
      danger: AppColors.roseLight,
      scrim: AppColors.lightScrim,
      accent: accent,
    );
  }

  /// Re-derives the chrome from an existing scheme with a different accent.
  /// Used by the artwork accent scope so it retints every component theme
  /// instead of patching a handful of them.
  factory AppChrome.fromScheme(ColorScheme scheme, Color accent) {
    final dark = scheme.brightness == Brightness.dark;
    return AppChrome._resolved(
      brightness: scheme.brightness,
      background: scheme.surfaceContainerLowest,
      surface: scheme.surface,
      card: scheme.surfaceContainer,
      hover: scheme.surfaceContainerHighest,
      border: scheme.outlineVariant,
      borderStrong: scheme.outline,
      text: scheme.onSurface,
      secondaryText: scheme.onSurfaceVariant,
      muted: dark ? AppColors.inkDim : AppColors.lightInkDim,
      danger: scheme.error,
      scrim: scheme.scrim,
      accent: accent,
    );
  }

  factory AppChrome._resolved({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color card,
    required Color hover,
    required Color border,
    required Color borderStrong,
    required Color text,
    required Color secondaryText,
    required Color muted,
    required Color danger,
    required Color scrim,
    required Color accent,
  }) {
    final dark = brightness == Brightness.dark;
    final onAccent = dark ? AppColors.ground : Colors.white;
    return AppChrome(
      brightness: brightness,
      background: background,
      surface: surface,
      card: card,
      hover: hover,
      border: border,
      borderStrong: borderStrong,
      text: text,
      secondaryText: secondaryText,
      muted: muted,
      danger: danger,
      onDanger: onAccent,
      // The accent is both a button fill and text on every surface, so it is
      // nudged until it reads as both. The surface set matches the pairs the
      // contrast audit checks (background, sidebar, card) plus onAccent, so
      // curated preset accents stay byte-stable and the nudge only fires when
      // a color genuinely fails the WCAG gate.
      accent: AppContrast.readableAccent(
        accent,
        brightness: brightness,
        onAccent: onAccent,
        surfaces: [background, surface, card],
      ),
      onAccent: onAccent,
      inputFill: dark ? background : card,
      scrim: scrim,
    );
  }

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color card;
  final Color hover;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color secondaryText;
  final Color muted;
  final Color danger;
  final Color onDanger;
  final Color accent;
  final Color onAccent;
  final Color inputFill;
  final Color scrim;

  bool get isDark => brightness == Brightness.dark;

  /// A neutral wash for hover on transparent controls.
  Color get hoverWash => text.withValues(alpha: 0.06);

  /// Fill used by the pressed state of quiet controls.
  Color get pressedFill => borderStrong;

  Color get accentWash => accent.withValues(alpha: 0.14);

  /// Clearly dimmer than [secondaryText] in both themes, so a disabled control
  /// never reads as an enabled one.
  ///
  /// The dimming comes from the alpha, but WCAG math ignores alpha, so the
  /// base color itself has to clear 4.5:1 against [hover]. On the bright light
  /// surfaces [muted] only reaches ~4.4:1 there, so light themes start from
  /// [secondaryText] instead.
  Color get disabledForeground =>
      (isDark ? muted : secondaryText).withValues(alpha: 0.55);

  /// Soft surface drop shadow for floating menus only.
  Color get shadow => Colors.black.withValues(alpha: isDark ? 0.45 : 0.14);

  ColorScheme toColorScheme() {
    final base = isDark ? const ColorScheme.dark() : const ColorScheme.light();
    return base.copyWith(
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      surface: surface,
      surfaceContainerLowest: background,
      surfaceContainerLow: surface,
      surfaceContainer: card,
      surfaceContainerHigh: card,
      surfaceContainerHighest: hover,
      surfaceDim: background,
      surfaceBright: card,
      primaryContainer: Color.alphaBlend(accentWash, card),
      onPrimaryContainer: text,
      secondaryContainer: hover,
      onSecondaryContainer: text,
      surfaceTint: Colors.transparent,
      outline: borderStrong,
      outlineVariant: border,
      onSurface: text,
      onSurfaceVariant: secondaryText,
      error: danger,
      onError: onDanger,
      scrim: scrim,
    );
  }
}
