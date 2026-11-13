import 'package:flutter/material.dart';

import 'theme/app_chrome.dart';
import 'theme/button_themes.dart';
import 'theme/field_themes.dart';
import 'theme/surface_themes.dart';
import 'theme/text_styles.dart';
import 'tokens/colors.dart';
import 'tokens/opacity.dart';
import 'tokens/type.dart';
export 'tokens/colors.dart';
export 'tokens/layout.dart';
export 'tokens/opacity.dart';
export 'tokens/player_colors.dart';
export 'tokens/radii.dart';
export 'tokens/space.dart';
export 'tokens/type.dart';

/// Shared colors and component styling for Mpvson's desktop interface.
///
/// Surface, border, text and accent colors used to be hard-coded to the dark
/// "projector room" palette. That made the theme mode, accent preset and OLED
/// black preferences reach only the widgets that happen to call
/// `Theme.of(context)`, so the navigation shell and the player chrome stayed
/// pitch black while the rest of the app turned light.
///
/// Every chrome color is now resolved from the active [ColorScheme] through
/// [AppPalette], so the whole interface follows the selected theme.
///
/// The component themes themselves are assembled by the builder files under
/// `theme/`: [AppChrome] resolves the palette for one brightness/accent/OLED
/// combination (nudging the accent through
/// `AppContrast.readableAccent` so it reads as both a fill and as text),
/// and the per-component builders in `button_themes`, `field_themes`,
/// `surface_themes` and `text_styles` turn that chrome into ThemeData entries.
/// There is no second copy of any component theme here to drift out of sync.
abstract final class AppTheme {
  /// Backdrop behind the projected image. Always dark: in a cinema the screen
  /// is the only thing that should be bright.
  static const Color stage = AppColors.stage;

  /// Primary text color drawn on top of [stage].
  static const Color onStage = AppColors.onStage;

  static const Color success = AppColors.jade;
  static const Color warning = AppColors.gold;
  static const Color info = AppColors.sky;

  /// Build theme for given brightness and accent preference.
  static ThemeData buildTheme({
    required Brightness brightness,
    Color? accent,
    bool oledBlack = false,
  }) {
    return brightness == Brightness.dark
        ? darkTheme(accent: accent ?? AppColors.lamp, oledBlack: oledBlack)
        : lightTheme(accent: accent ?? AppColors.lampLight);
  }

  static ThemeData get dark => darkTheme();

  static ThemeData get light => lightTheme();

  static ThemeData darkTheme({
    Color accent = AppColors.lamp,
    bool oledBlack = false,
  }) => _buildTheme(AppChrome.dark(accent: accent, oledBlack: oledBlack));

  static ThemeData lightTheme({Color accent = AppColors.lampLight}) =>
      _buildTheme(AppChrome.light(accent: accent));

  /// One assembler for every brightness, accent and OLED combination: the
  /// [AppChrome] factories resolve the palette (including the readable
  /// accent) and the builder files provide the component themes.
  static ThemeData _buildTheme(AppChrome chrome) {
    final scheme = chrome.toColorScheme();
    final input = inputDecorationTheme(chrome);

    return ThemeData(
      useMaterial3: true,
      extensions: [
        MediaAccent(color: chrome.accent),
        _mediaPalette(chrome),
      ],
      brightness: chrome.brightness,
      fontFamily: 'Onest',
      fontFamilyFallback: const ['Noto Sans', 'DejaVu Sans', 'sans-serif'],
      colorScheme: scheme,
      scaffoldBackgroundColor: chrome.background,
      canvasColor: chrome.background,
      cardColor: chrome.card,
      dividerColor: chrome.border,
      splashColor: chrome.accent.withValues(alpha: 0.10),
      highlightColor: chrome.accent.withValues(alpha: 0.06),
      focusColor: chrome.accent.withValues(alpha: 0.16),
      iconTheme: IconThemeData(color: chrome.secondaryText, size: 20),
      textTheme: buildAppTextTheme(chrome),
      // Buttons.
      elevatedButtonTheme: elevatedButtonTheme(chrome),
      filledButtonTheme: filledButtonTheme(chrome),
      outlinedButtonTheme: outlinedButtonTheme(chrome),
      textButtonTheme: textButtonTheme(chrome),
      iconButtonTheme: iconButtonTheme(chrome),
      segmentedButtonTheme: segmentedButtonTheme(chrome),
      // Fields and selections.
      inputDecorationTheme: input,
      textSelectionTheme: textSelectionTheme(chrome),
      switchTheme: switchTheme(chrome),
      checkboxTheme: checkboxTheme(chrome),
      radioTheme: radioTheme(chrome),
      sliderTheme: sliderTheme(chrome),
      progressIndicatorTheme: progressIndicatorTheme(chrome),
      // Surfaces and chrome.
      dialogTheme: dialogTheme(chrome),
      cardTheme: cardTheme(chrome),
      popupMenuTheme: popupMenuTheme(chrome),
      menuTheme: menuTheme(chrome),
      menuButtonTheme: menuButtonTheme(chrome),
      dropdownMenuTheme: dropdownMenuTheme(chrome, input),
      tooltipTheme: tooltipTheme(chrome),
      snackBarTheme: snackBarTheme(chrome),
      chipTheme: chipTheme(chrome),
      tabBarTheme: tabBarTheme(chrome),
      listTileTheme: listTileTheme(chrome),
      scrollbarTheme: scrollbarTheme(chrome),
      dividerTheme: dividerTheme(chrome),
      badgeTheme: badgeTheme(chrome),
    );
  }

  /// Fallback media palette when no artwork has been analyzed yet: the
  /// resolved accent plus a hue-shifted vibrant tone and a desaturated wash.
  static MediaAccentPalette _mediaPalette(AppChrome chrome) {
    final hsl = HSLColor.fromColor(chrome.accent);
    return MediaAccentPalette(
      dominant: chrome.accent,
      vibrant: hsl.withHue((hsl.hue + 25) % 360).toColor(),
      muted: chrome.isDark
          ? hsl.withSaturation(0.25).withLightness(0.18).toColor()
          : hsl.withSaturation(0.2).withLightness(0.88).toColor(),
    );
  }
}

/// Semantic chrome palette resolved from the active [ColorScheme].
///
/// Reading through this palette (instead of static constants) is what makes the
/// navigation shell, the player chrome and the library views follow the theme
/// mode, the accent preset and the OLED black preference.
class AppPalette {
  const AppPalette(this.scheme);

  final ColorScheme scheme;

  // --- Surfaces -------------------------------------------------------------
  Color get background => scheme.surfaceContainerLowest;
  Color get canvas => scheme.surfaceContainerLowest;
  Color get deepBackground => background;
  Color get surface => scheme.surface;
  Color get sidebar => scheme.surfaceContainerLow;
  Color get card => scheme.surfaceContainer;
  Color get raisedSurface => card;
  Color get hover => scheme.surfaceContainerHighest;

  // --- Borders --------------------------------------------------------------
  Color get border => scheme.outlineVariant;
  Color get borderStrong => scheme.outline;

  // --- Text -----------------------------------------------------------------
  Color get text => scheme.onSurface;
  Color get primaryText => text;
  Color get secondaryText => scheme.onSurfaceVariant;
  Color get muted => secondaryText;
  Color get mutedText => secondaryText;
  bool get isDark => scheme.brightness == Brightness.dark;
  Color get faint => secondaryText.withValues(alpha: AppOpacity.faint);

  // --- Accent ---------------------------------------------------------------
  Color get accent => scheme.primary;
  Color get accentForeground => scheme.onPrimary;
  Color get danger => scheme.error;
  Color get success => isDark ? AppColors.jade : AppColors.jadeLight;
  Color get warning => isDark ? AppColors.gold : AppColors.goldLight;
  Color get info => isDark ? AppColors.sky : AppColors.skyLight;

  // --- Typography -----------------------------------------------------------
  // These styles replace the ambient style when used in DefaultTextStyle, so
  // they must name the UI font themselves.
  TextStyle get pageTitle => TextStyle(
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    color: text,
    fontSize: AppType.display,
    fontWeight: FontWeight.w600,
    letterSpacing: AppLetterSpacing.tighter,
    height: 1.2,
  );

  TextStyle get albumTitle => TextStyle(
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    color: text,
    fontSize: AppType.title,
    fontWeight: FontWeight.w600,
    letterSpacing: AppLetterSpacing.subtitle,
    height: 1.25,
  );

  TextStyle get sectionTitle => TextStyle(
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    color: text,
    fontSize: AppType.body,
    fontWeight: FontWeight.w600,
    letterSpacing: AppLetterSpacing.tight,
    height: 1.3,
  );

  TextStyle get rowPrimary => TextStyle(
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    color: text,
    fontSize: AppType.small,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );

  TextStyle get rowSecondary => TextStyle(
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    color: secondaryText,
    fontSize: AppType.caption,
    fontWeight: FontWeight.normal,
    height: 1.3,
  );

  TextStyle get metadata => TextStyle(
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    color: muted,
    fontSize: AppType.caption,
    fontWeight: FontWeight.normal,
    height: 1.3,
  );

  TextStyle get badge => TextStyle(
    fontFamily: AppType.family,
    fontFamilyFallback: AppType.familyFallback,
    color: text,
    fontSize: AppType.caption,
    fontWeight: FontWeight.w600,
    letterSpacing: AppLetterSpacing.wide,
  );
}

/// `context.palette.background` reads a chrome color that always matches the
/// theme the user picked in Settings → Appearance.
extension AppThemeContext on BuildContext {
  AppPalette get palette => AppPalette(Theme.of(this).colorScheme);
}
