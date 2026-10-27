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
abstract final class AppTheme {
  static const Color accent = AppColors.lamp;
  static const Color background = AppColors.ground;
  static const Color deepBackground = background;
  static const Color surface = AppColors.layer;
  static const Color card = AppColors.raised;
  static const Color raisedSurface = card;
  static const Color hover = AppColors.line;
  static const Color border = AppColors.line;
  static const Color text = AppColors.ink;
  static const Color primaryText = text;
  static const Color secondaryText = Color(0xFFBDBDC0);
  static const Color muted = AppColors.inkDim;
  static const Color mutedText = muted;
  static const Color success = Color(0xFF83B89C);
  static const Color warning = Color(0xFFD1AA68);
  static const Color danger = Color(0xFFC98282);
  static const Color accentForeground = background;

  // Typography tokens
  static const TextStyle pageTitle = TextStyle(
    color: primaryText,
    fontSize: AppType.display,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.2,
  );

  static const TextStyle albumTitle = TextStyle(
    color: primaryText,
    fontSize: AppType.title,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.25,
  );

  static const TextStyle sectionTitle = TextStyle(
    color: primaryText,
    fontSize: AppType.body,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  );

  static const TextStyle rowPrimary = TextStyle(
    color: primaryText,
    fontSize: AppType.small,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );

  static const TextStyle rowSecondary = TextStyle(
    color: secondaryText,
    fontSize: AppType.caption,
    fontWeight: FontWeight.normal,
    height: 1.3,
  );

  static const TextStyle metadata = TextStyle(
    color: mutedText,
    fontSize: AppType.caption,
    fontWeight: FontWeight.normal,
    height: 1.3,
  );

  static const TextStyle badge = TextStyle(
    color: primaryText,
    fontSize: AppType.caption,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );

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
      extensions: const [MediaAccent()],
      brightness: Brightness.dark,
      fontFamily: 'Onest',
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
          (states) => states.contains(WidgetState.selected) ? accent : card,
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
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: border),
        ),
        textStyle: const TextStyle(color: text, fontSize: AppType.caption),
        waitDuration: const Duration(milliseconds: 450),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: background,
        hintStyle: const TextStyle(color: muted),
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
        backgroundColor: hover,
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
    );
  }
}
