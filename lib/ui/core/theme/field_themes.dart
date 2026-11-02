import 'package:flutter/material.dart';

import '../tokens/radii.dart';
import '../tokens/space.dart';
import '../tokens/type.dart';
import 'app_chrome.dart';
import 'text_styles.dart';

OutlineInputBorder _inputBorder(Color color, [double width = 1]) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.control),
      borderSide: BorderSide(color: color, width: width),
    );

InputDecorationThemeData inputDecorationTheme(AppChrome c) {
  return InputDecorationThemeData(
    filled: true,
    fillColor: c.inputFill,
    hoverColor: Colors.transparent,
    isDense: false,
    hintStyle: appTextStyle(size: AppType.small, color: c.muted),
    labelStyle: appTextStyle(size: AppType.small, color: c.secondaryText),
    floatingLabelStyle: appTextStyle(size: AppType.small, color: c.accent),
    helperStyle: appTextStyle(size: AppType.caption, color: c.secondaryText),
    errorStyle: appTextStyle(size: AppType.caption, color: c.danger),
    prefixIconColor: c.secondaryText,
    suffixIconColor: c.secondaryText,
    contentPadding: const EdgeInsets.symmetric(
      horizontal: AppSpace.inputH,
      vertical: AppSpace.inputV,
    ),
    // One resolver so hover, focus, error and disabled look identical in
    // every theme.
    border: WidgetStateInputBorder.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return _inputBorder(c.border);
      if (states.contains(WidgetState.error)) {
        return _inputBorder(
          c.danger,
          states.contains(WidgetState.focused) ? 2 : 1,
        );
      }
      if (states.contains(WidgetState.focused)) {
        return _inputBorder(c.accent, 2);
      }
      if (states.contains(WidgetState.hovered)) return _inputBorder(c.muted);
      return _inputBorder(c.borderStrong);
    }),
  );
}

TextSelectionThemeData textSelectionTheme(AppChrome c) =>
    TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.32),
      selectionHandleColor: c.accent,
    );

SwitchThemeData switchTheme(AppChrome c) {
  return SwitchThemeData(
    thumbColor: WidgetStateProperty.resolveWith((states) {
      final selected = states.contains(WidgetState.selected);
      if (states.contains(WidgetState.disabled)) {
        return selected ? c.hover : c.disabledForeground;
      }
      return selected ? c.onAccent : c.secondaryText;
    }),
    trackColor: WidgetStateProperty.resolveWith((states) {
      final selected = states.contains(WidgetState.selected);
      if (states.contains(WidgetState.disabled)) {
        return selected ? c.muted.withValues(alpha: 0.3) : c.card;
      }
      return selected ? c.accent : c.hover;
    }),
    trackOutlineColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) return c.accent;
      if (states.contains(WidgetState.selected)) return Colors.transparent;
      return c.borderStrong;
    }),
    trackOutlineWidth: const WidgetStatePropertyAll(1),
    overlayColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)
          ? c.accent.withValues(alpha: 0.12)
          : Colors.transparent,
    ),
  );
}

CheckboxThemeData checkboxTheme(AppChrome c) {
  return CheckboxThemeData(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    fillColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return states.contains(WidgetState.selected)
            ? c.disabledForeground
            : Colors.transparent;
      }
      return states.contains(WidgetState.selected)
          ? c.accent
          : Colors.transparent;
    }),
    checkColor: WidgetStatePropertyAll(c.onAccent),
    side: WidgetStateBorderSide.resolveWith((states) {
      if (states.contains(WidgetState.selected)) return BorderSide.none;
      if (states.contains(WidgetState.disabled)) {
        return BorderSide(color: c.disabledForeground, width: 1.5);
      }
      return BorderSide(
        color: states.contains(WidgetState.hovered) ? c.text : c.muted,
        width: 1.5,
      );
    }),
    overlayColor: WidgetStatePropertyAll(c.accent.withValues(alpha: 0.12)),
  );
}

RadioThemeData radioTheme(AppChrome c) {
  return RadioThemeData(
    fillColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return c.disabledForeground;
      if (states.contains(WidgetState.selected)) return c.accent;
      return states.contains(WidgetState.hovered) ? c.text : c.muted;
    }),
    overlayColor: WidgetStatePropertyAll(c.accent.withValues(alpha: 0.12)),
  );
}

SliderThemeData sliderTheme(AppChrome c) {
  return SliderThemeData(
    activeTrackColor: c.accent,
    inactiveTrackColor: c.borderStrong,
    disabledActiveTrackColor: c.disabledForeground,
    disabledInactiveTrackColor: c.border,
    thumbColor: c.accent,
    disabledThumbColor: c.disabledForeground,
    overlayColor: c.accent.withValues(alpha: 0.14),
    trackHeight: 3,
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
    valueIndicatorColor: c.accent,
    valueIndicatorTextStyle: appTextStyle(
      size: AppType.caption,
      color: c.onAccent,
      weight: FontWeight.w600,
    ),
  );
}

ProgressIndicatorThemeData progressIndicatorTheme(AppChrome c) {
  return ProgressIndicatorThemeData(
    color: c.accent,
    linearTrackColor: c.border,
    circularTrackColor: c.border,
    refreshBackgroundColor: c.card,
  );
}
