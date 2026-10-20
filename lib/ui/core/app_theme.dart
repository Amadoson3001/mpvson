import 'package:flutter/material.dart';

/// Shared colors and component styling for Mpvson's desktop interface.
abstract final class AppTheme {
  static const Color accent = Color(0xFF60CDFF);
  static const Color background = Color(0xFF0B1220);
  static const Color deepBackground = background;
  static const Color surface = Color(0xFF111A2C);
  static const Color card = Color(0xFF182238);
  static const Color hover = Color(0xFF223052);
  static const Color border = Color(0xFF2C3A55);
  static const Color text = Color(0xFFF2F5FA);
  static const Color primaryText = text;
  static const Color secondaryText = Color(0xFFC3CCDD);
  static const Color muted = Color(0xFF7E8AA0);
  static const Color mutedText = muted;
  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFF87171);
  static const Color accentForeground = background;

  static ThemeData get dark {
    final colorScheme = const ColorScheme.dark(
      primary: accent,
      onPrimary: accentForeground,
      secondary: accent,
      onSecondary: accentForeground,
      surface: surface,
      surfaceContainer: card,
      surfaceContainerHighest: hover,
      surfaceTint: Colors.transparent,
      outline: border,
      outlineVariant: border,
      onSurface: text,
      error: danger,
      onError: accentForeground,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Noto Sans', 'DejaVu Sans', 'sans-serif'],
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      canvasColor: surface,
      cardColor: card,
      dividerColor: border,
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      badgeTheme: const BadgeThemeData(
        backgroundColor: hover,
        textColor: accent,
      ),
      splashColor: accent.withValues(alpha: 0.08),
      highlightColor: accent.withValues(alpha: 0.05),
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          color: text,
          fontSize: 40,
          fontWeight: FontWeight.w600,
          letterSpacing: -1.2,
          height: 1.15,
        ),
        headlineMedium: TextStyle(
          color: text,
          fontSize: 28,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.6,
          height: 1.2,
        ),
        titleLarge: TextStyle(
          color: text,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(
          color: text,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: TextStyle(
          color: text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: secondaryText, fontSize: 15, height: 1.5),
        bodyMedium: TextStyle(color: secondaryText, fontSize: 13, height: 1.4),
        bodySmall: TextStyle(color: muted, fontSize: 12, height: 1.4),
        labelLarge: TextStyle(
          color: text,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: TextStyle(color: secondaryText, fontSize: 12),
        labelSmall: TextStyle(color: muted, fontSize: 11),
      ),
      iconTheme: const IconThemeData(color: secondaryText, size: 20),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accentForeground
              : secondaryText,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : card,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(border),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          iconSize: const WidgetStatePropertyAll(20),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                ? muted
                : states.contains(WidgetState.selected)
                ? accent
                : secondaryText,
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: hover,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        textStyle: const TextStyle(color: text, fontSize: 12),
        waitDuration: const Duration(milliseconds: 450),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: background,
        hintStyle: const TextStyle(color: muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.3),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: border,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.14),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: border),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: border),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: hover,
        contentTextStyle: const TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(24, 0, 24, 128),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: accentForeground,
          backgroundColor: accent,
          disabledForegroundColor: accentForeground.withValues(alpha: 0.5),
          disabledBackgroundColor: accent.withValues(alpha: 0.35),
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
              foregroundColor: accentForeground,
              backgroundColor: accent,
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
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
              padding: const EdgeInsets.symmetric(horizontal: 16),
              side: const BorderSide(color: border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ).copyWith(
              side: WidgetStateProperty.resolveWith(
                (states) => BorderSide(
                  color: states.contains(WidgetState.focused) ? accent : border,
                ),
              ),
            ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

abstract final class AppSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}
