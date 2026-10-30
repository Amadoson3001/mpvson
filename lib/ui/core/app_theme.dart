import 'package:flutter/material.dart';
import 'tokens/colors.dart';
import 'tokens/radii.dart';
import 'tokens/space.dart';
import 'tokens/type.dart';
export 'tokens/colors.dart';
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
        : lightTheme(accent: accent ?? const Color(0xFFD97706));
  }

  static ThemeData get dark => darkTheme();

  static ThemeData get light => lightTheme();

  static ThemeData darkTheme({
    Color accent = AppColors.lamp,
    bool oledBlack = false,
  }) {
    // Local mirrors of the dark palette so the theme factory never depends on
    // the (now removed) static chrome constants.
    const background = AppColors.ground;
    const surface = AppColors.layer;
    const card = AppColors.raised;
    const hover = AppColors.hover;
    const border = AppColors.line;
    const borderStrong = AppColors.lineStrong;
    const text = AppColors.ink;
    const secondaryText = AppColors.inkMuted;
    const muted = AppColors.inkDim;
    const accentForeground = Color(0xFF09090B);
    const danger = AppColors.rose;

    final bg = oledBlack ? Colors.black : background;
    final surf = oledBlack ? const Color(0xFF0C0C0C) : surface;
    final crd = oledBlack ? const Color(0xFF141414) : card;
    final hvr = oledBlack ? const Color(0xFF1E1E1E) : hover;
    final bdr = oledBlack ? const Color(0xFF262626) : border;
    final bdrStrong = oledBlack ? const Color(0xFF383838) : borderStrong;

    final colorScheme = ColorScheme.dark(
      primary: accent,
      onPrimary: accentForeground,
      secondary: accent,
      onSecondary: accentForeground,
      surface: surf,
      surfaceContainerLowest: bg,
      surfaceContainerLow: surf,
      surfaceContainer: crd,
      surfaceContainerHigh: crd,
      surfaceContainerHighest: hvr,
      surfaceTint: Colors.transparent,
      outline: bdrStrong,
      outlineVariant: bdr,
      onSurface: text,
      onSurfaceVariant: secondaryText,
      error: danger,
      onError: accentForeground,
      scrim: AppColors.scrim,
    );

    final darkPalette = MediaAccentPalette(
      dominant: accent,
      vibrant: HSLColor.fromColor(accent).withHue((HSLColor.fromColor(accent).hue + 25) % 360).toColor(),
      muted: HSLColor.fromColor(accent).withSaturation(0.25).withLightness(0.18).toColor(),
    );

    return ThemeData(
      useMaterial3: true,
      extensions: [
        MediaAccent(color: accent),
        darkPalette,
      ],
      brightness: Brightness.dark,
      fontFamily: 'Onest',
      fontFamilyFallback: const ['Noto Sans', 'DejaVu Sans', 'sans-serif'],
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      cardColor: crd,
      dividerColor: bdr,
      dividerTheme: DividerThemeData(color: bdr, thickness: 1),
      badgeTheme: BadgeThemeData(
        backgroundColor: hvr,
        textColor: accent,
      ),
      splashColor: accent.withValues(alpha: 0.10),
      highlightColor: accent.withValues(alpha: 0.06),
      focusColor: accent.withValues(alpha: 0.16),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? AppColors.inkFaint
              : bdrStrong,
        ),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
      ),
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          color: text,
          fontSize: AppType.display,
          fontWeight: FontWeight.w600,
          letterSpacing: -1.2,
          height: 1.15,
        ),
        headlineMedium: TextStyle(
          color: text,
          fontSize: AppType.title,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.6,
          height: 1.2,
        ),
        titleLarge: TextStyle(
          color: text,
          fontSize: AppType.title,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(
          color: text,
          fontSize: AppType.body,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: TextStyle(
          color: text,
          fontSize: AppType.small,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(
          color: secondaryText,
          fontSize: AppType.body,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          color: secondaryText,
          fontSize: AppType.small,
          height: 1.4,
        ),
        bodySmall: TextStyle(
          color: muted,
          fontSize: AppType.caption,
          height: 1.4,
        ),
        labelLarge: TextStyle(
          color: text,
          fontSize: AppType.small,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: TextStyle(color: secondaryText, fontSize: AppType.caption),
        labelSmall: TextStyle(color: muted, fontSize: AppType.caption),
      ),
      iconTheme: const IconThemeData(color: secondaryText, size: 20),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accentForeground
              : secondaryText,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : crd,
        ),
        trackOutlineColor: WidgetStatePropertyAll(bdr),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          iconSize: const WidgetStatePropertyAll(20),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.focused)
                  ? accent
                  : Colors.transparent,
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ||
                    states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? hvr
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? muted
                : states.contains(WidgetState.selected)
                ? accent
                : secondaryText,
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: crd,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: bdrStrong),
        ),
        textStyle: const TextStyle(color: text, fontSize: AppType.caption),
        waitDuration: const Duration(milliseconds: 450),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bg,
        hintStyle: const TextStyle(color: muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: AppSpace.sm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          borderSide: BorderSide(color: bdr),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          borderSide: BorderSide(color: bdr),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          borderSide: BorderSide(color: accent, width: 1.3),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: bdrStrong,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.14),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: bdr,
        circularTrackColor: bdr,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surf,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          side: BorderSide(color: bdr),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: crd,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          side: BorderSide(color: bdr),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: crd,
        contentTextStyle: const TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          0,
          AppSpace.lg,
          128,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          side: BorderSide(color: bdrStrong),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: accentForeground,
          backgroundColor: accent,
          disabledForegroundColor: accentForeground.withValues(alpha: 0.5),
          disabledBackgroundColor: accent.withValues(alpha: 0.35),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
              foregroundColor: accentForeground,
              backgroundColor: accent,
              disabledForegroundColor: muted,
              disabledBackgroundColor: accent.withValues(alpha: 0.28),
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ).copyWith(
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? const BorderSide(color: text, width: 2)
                    : BorderSide.none,
              ),
            ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              foregroundColor: text,
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
              side: BorderSide(color: bdr),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ).copyWith(
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused)
                    ? hvr
                    : Colors.transparent,
              ),
              side: WidgetStateProperty.resolveWith(
                (states) => BorderSide(
                  color: states.contains(WidgetState.focused)
                      ? accent
                      : bdrStrong,
                ),
              ),
            ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
    );
  }

  static ThemeData lightTheme({
    Color accent = const Color(0xFFD97706),
  }) {
    const bg = Color(0xFFF8FAFC);
    const sidebar = Color(0xFFF1F5F9);
    const card = Color(0xFFFFFFFF);
    const hover = Color(0xFFE2E8F0);
    const border = Color(0xFFE2E8F0);
    const borderStrong = Color(0xFFCBD5E1);
    const text = Color(0xFF0F172A);
    const secTxt = Color(0xFF64748B);
    const mtd = Color(0xFF94A3B8);
    const onAccent = Colors.white;

    final colorScheme = ColorScheme.light(
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      surface: sidebar,
      surfaceContainerLowest: bg,
      surfaceContainerLow: sidebar,
      surfaceContainer: card,
      surfaceContainerHigh: card,
      surfaceContainerHighest: hover,
      surfaceTint: Colors.transparent,
      outline: borderStrong,
      outlineVariant: border,
      onSurface: text,
      onSurfaceVariant: secTxt,
      error: AppColors.rose,
      onError: onAccent,
      scrim: const Color(0x66000000),
    );

    final lightPalette = MediaAccentPalette(
      dominant: accent,
      vibrant: HSLColor.fromColor(accent).withHue((HSLColor.fromColor(accent).hue + 25) % 360).toColor(),
      muted: HSLColor.fromColor(accent).withSaturation(0.2).withLightness(0.88).toColor(),
    );

    return ThemeData(
      useMaterial3: true,
      extensions: [
        MediaAccent(color: accent),
        lightPalette,
      ],
      brightness: Brightness.light,
      fontFamily: 'Onest',
      fontFamilyFallback: const ['Noto Sans', 'DejaVu Sans', 'sans-serif'],
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      cardColor: card,
      dividerColor: border,
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      badgeTheme: BadgeThemeData(
        backgroundColor: hover,
        textColor: accent,
      ),
      splashColor: accent.withValues(alpha: 0.10),
      highlightColor: accent.withValues(alpha: 0.06),
      focusColor: accent.withValues(alpha: 0.16),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? const Color(0xFF8C93A0)
              : borderStrong,
        ),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
      ),
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          color: text,
          fontSize: AppType.display,
          fontWeight: FontWeight.w600,
          letterSpacing: -1.2,
          height: 1.15,
        ),
        headlineMedium: TextStyle(
          color: text,
          fontSize: AppType.title,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.6,
          height: 1.2,
        ),
        titleLarge: TextStyle(
          color: text,
          fontSize: AppType.title,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(
          color: text,
          fontSize: AppType.body,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: TextStyle(
          color: text,
          fontSize: AppType.small,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(
          color: secTxt,
          fontSize: AppType.body,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          color: secTxt,
          fontSize: AppType.small,
          height: 1.4,
        ),
        bodySmall: TextStyle(
          color: mtd,
          fontSize: AppType.caption,
          height: 1.4,
        ),
        labelLarge: TextStyle(
          color: text,
          fontSize: AppType.small,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: TextStyle(color: secTxt, fontSize: AppType.caption),
        labelSmall: TextStyle(color: mtd, fontSize: AppType.caption),
      ),
      iconTheme: const IconThemeData(color: secTxt, size: 20),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? onAccent
              : secTxt,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : hover,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(border),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          iconSize: const WidgetStatePropertyAll(20),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.focused)
                  ? accent
                  : Colors.transparent,
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ||
                    states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? hover
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? mtd
                : states.contains(WidgetState.selected)
                ? accent
                : secTxt,
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: borderStrong),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        textStyle: const TextStyle(color: text, fontSize: AppType.caption),
        waitDuration: const Duration(milliseconds: 450),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        hintStyle: const TextStyle(color: mtd),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: AppSpace.sm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          borderSide: BorderSide(color: accent, width: 1.3),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: borderStrong,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.14),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: border,
        circularTrackColor: border,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          side: const BorderSide(color: border),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          side: const BorderSide(color: border),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: const TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          0,
          AppSpace.lg,
          128,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          side: const BorderSide(color: borderStrong),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: onAccent,
          backgroundColor: accent,
          disabledForegroundColor: onAccent.withValues(alpha: 0.5),
          disabledBackgroundColor: accent.withValues(alpha: 0.35),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
              foregroundColor: onAccent,
              backgroundColor: accent,
              disabledForegroundColor: mtd,
              disabledBackgroundColor: accent.withValues(alpha: 0.28),
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ).copyWith(
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? const BorderSide(color: text, width: 2)
                    : BorderSide.none,
              ),
            ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              foregroundColor: text,
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
              side: const BorderSide(color: border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ).copyWith(
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused)
                    ? hover
                    : Colors.transparent,
              ),
              side: WidgetStateProperty.resolveWith(
                (states) => BorderSide(
                  color: states.contains(WidgetState.focused)
                      ? accent
                      : borderStrong,
                ),
              ),
            ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
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
  Color get faint => secondaryText.withValues(alpha: 0.7);

  // --- Accent ---------------------------------------------------------------
  Color get accent => scheme.primary;
  Color get accentForeground => scheme.onPrimary;
  Color get danger => scheme.error;

  // --- Typography -----------------------------------------------------------
  TextStyle get pageTitle => TextStyle(
    color: text,
    fontSize: AppType.display,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.2,
  );

  TextStyle get albumTitle => TextStyle(
    color: text,
    fontSize: AppType.title,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.25,
  );

  TextStyle get sectionTitle => TextStyle(
    color: text,
    fontSize: AppType.body,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  );

  TextStyle get rowPrimary => TextStyle(
    color: text,
    fontSize: AppType.small,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );

  TextStyle get rowSecondary => TextStyle(
    color: secondaryText,
    fontSize: AppType.caption,
    fontWeight: FontWeight.normal,
    height: 1.3,
  );

  TextStyle get metadata => TextStyle(
    color: muted,
    fontSize: AppType.caption,
    fontWeight: FontWeight.normal,
    height: 1.3,
  );

  TextStyle get badge => TextStyle(
    color: text,
    fontSize: AppType.caption,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );
}

/// `context.palette.background` reads a chrome color that always matches the
/// theme the user picked in Settings → Appearance.
extension AppThemeContext on BuildContext {
  AppPalette get palette => AppPalette(Theme.of(this).colorScheme);
}
