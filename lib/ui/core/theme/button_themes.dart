import 'package:flutter/material.dart';

import '../tokens/radii.dart';
import '../tokens/space.dart';
import '../tokens/type.dart';
import 'app_chrome.dart';
import 'text_styles.dart';

const Size _minimumSize = Size(44, 44);
const double _focusRingWidth = 2;

RoundedRectangleBorder _controlShape() => const RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(AppRadii.control)),
);

/// Hover, focus and pressed tints drawn from [base] over the button.
WidgetStateProperty<Color?> _overlay(Color base) =>
    WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return base.withValues(alpha: 0.16);
      }
      if (states.contains(WidgetState.hovered)) {
        return base.withValues(alpha: 0.08);
      }
      if (states.contains(WidgetState.focused)) {
        return base.withValues(alpha: 0.12);
      }
      return null;
    });

ButtonStyle _base(AppChrome c) => ButtonStyle(
  // Named family: a style passed here replaces the ambient text style.
  textStyle: WidgetStatePropertyAll(
    appTextStyle(size: AppType.small, weight: FontWeight.w600),
  ),
  minimumSize: const WidgetStatePropertyAll(_minimumSize),
  padding: const WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: AppSpace.md),
  ),
  shape: WidgetStatePropertyAll(_controlShape()),
  elevation: const WidgetStatePropertyAll(0),
  shadowColor: const WidgetStatePropertyAll(Colors.transparent),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  splashFactory: NoSplash.splashFactory,
  animationDuration: const Duration(milliseconds: 120),
);

ButtonStyle _accentFilled(AppChrome c) {
  return _base(c).copyWith(
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? c.disabledForeground
          : c.onAccent,
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? c.hover : c.accent,
    ),
    overlayColor: _overlay(c.onAccent),
    side: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(color: c.onAccent, width: _focusRingWidth)
          : BorderSide.none,
    ),
  );
}

FilledButtonThemeData filledButtonTheme(AppChrome c) =>
    FilledButtonThemeData(style: _accentFilled(c));

ElevatedButtonThemeData elevatedButtonTheme(AppChrome c) =>
    ElevatedButtonThemeData(style: _accentFilled(c));

OutlinedButtonThemeData outlinedButtonTheme(AppChrome c) {
  return OutlinedButtonThemeData(
    style: _base(c).copyWith(
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? c.disabledForeground
            : c.text,
      ),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      overlayColor: _overlay(c.text),
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return BorderSide(color: c.border);
        }
        if (states.contains(WidgetState.focused)) {
          return BorderSide(color: c.accent, width: _focusRingWidth);
        }
        if (states.contains(WidgetState.hovered)) {
          return BorderSide(color: c.muted);
        }
        return BorderSide(color: c.borderStrong);
      }),
    ),
  );
}

TextButtonThemeData textButtonTheme(AppChrome c) {
  return TextButtonThemeData(
    style: _base(c).copyWith(
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? c.disabledForeground
            : c.accent,
      ),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      overlayColor: _overlay(c.accent),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: c.accent, width: _focusRingWidth)
            : BorderSide.none,
      ),
    ),
  );
}

IconButtonThemeData iconButtonTheme(AppChrome c) {
  return IconButtonThemeData(
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(_minimumSize),
      iconSize: const WidgetStatePropertyAll(20),
      shape: WidgetStatePropertyAll(_controlShape()),
      splashFactory: NoSplash.splashFactory,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      animationDuration: const Duration(milliseconds: 120),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color:
              states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.disabled)
              ? c.accent
              : Colors.transparent,
          width: _focusRingWidth,
        ),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return Colors.transparent;
        if (states.contains(WidgetState.pressed)) return c.pressedFill;
        if (states.contains(WidgetState.selected) ||
            states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return c.hover;
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return c.disabledForeground;
        if (states.contains(WidgetState.selected)) return c.accent;
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed)) {
          return c.text;
        }
        return c.secondaryText;
      }),
    ),
  );
}

SegmentedButtonThemeData segmentedButtonTheme(AppChrome c) {
  return SegmentedButtonThemeData(
    style: ButtonStyle(
      textStyle: WidgetStatePropertyAll(
        appTextStyle(size: AppType.small, weight: FontWeight.w600),
      ),
      shape: WidgetStatePropertyAll(_controlShape()),
      splashFactory: NoSplash.splashFactory,
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return BorderSide(color: c.accent, width: _focusRingWidth);
        }
        return BorderSide(color: c.borderStrong);
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return c.accent;
        if (states.contains(WidgetState.hovered)) return c.hover;
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return c.disabledForeground;
        if (states.contains(WidgetState.selected)) return c.onAccent;
        return c.text;
      }),
      overlayColor: _overlay(c.text),
    ),
  );
}
