import 'package:flutter/material.dart';

import '../tokens/radii.dart';
import '../tokens/space.dart';
import '../tokens/type.dart';
import 'app_chrome.dart';
import 'text_styles.dart';

/// Bottom inset that keeps fallback SnackBars above the player controls.
const double snackBarBottomInset = 128;

RoundedRectangleBorder _cardShape(AppChrome c, {Color? border}) =>
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.artwork),
      side: BorderSide(color: border ?? c.border),
    );

RoundedRectangleBorder _controlShape() => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(AppRadii.control),
);

DialogThemeData dialogTheme(AppChrome c) => DialogThemeData(
  backgroundColor: c.card,
  surfaceTintColor: Colors.transparent,
  shadowColor: Colors.transparent,
  elevation: 0,
  iconColor: c.accent,
  shape: _cardShape(c),
  constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
  insetPadding: const EdgeInsets.symmetric(
    horizontal: AppSpace.lg,
    vertical: AppSpace.xl,
  ),
  titleTextStyle: appTextStyle(
    size: AppType.title,
    color: c.text,
    weight: FontWeight.w600,
    height: 1.25,
    letterSpacing: AppLetterSpacing.subtitle,
  ),
  contentTextStyle: appTextStyle(
    size: AppType.small,
    color: c.secondaryText,
    height: 1.5,
  ),
);

CardThemeData cardTheme(AppChrome c) => CardThemeData(
  color: c.card,
  surfaceTintColor: Colors.transparent,
  shadowColor: Colors.transparent,
  elevation: 0,
  margin: EdgeInsets.zero,
  clipBehavior: Clip.antiAlias,
  shape: _cardShape(c),
);

MenuStyle _menuStyle(AppChrome c) => MenuStyle(
  backgroundColor: WidgetStatePropertyAll(c.card),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  shadowColor: WidgetStatePropertyAll(c.shadow),
  elevation: const WidgetStatePropertyAll(4),
  padding: const WidgetStatePropertyAll(
    EdgeInsets.symmetric(vertical: AppSpace.xxs),
  ),
  shape: WidgetStatePropertyAll(_cardShape(c, border: c.borderStrong)),
);

PopupMenuThemeData popupMenuTheme(AppChrome c) {
  final label = appTextStyle(size: AppType.small, color: c.text);
  return PopupMenuThemeData(
    color: c.card,
    surfaceTintColor: Colors.transparent,
    shadowColor: c.shadow,
    elevation: 4,
    iconColor: c.secondaryText,
    textStyle: label,
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? label.copyWith(color: c.disabledForeground)
          : label,
    ),
    shape: _cardShape(c, border: c.borderStrong),
  );
}

MenuThemeData menuTheme(AppChrome c) => MenuThemeData(style: _menuStyle(c));

MenuButtonThemeData menuButtonTheme(AppChrome c) {
  return MenuButtonThemeData(
    style: ButtonStyle(
      textStyle: WidgetStatePropertyAll(
        appTextStyle(size: AppType.small, weight: FontWeight.w500),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(44, 40)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: AppSpace.sm),
      ),
      shape: WidgetStatePropertyAll(_controlShape()),
      side: const WidgetStatePropertyAll(BorderSide.none),
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStatePropertyAll(c.accent.withValues(alpha: 0.08)),
      iconColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? c.disabledForeground
            : states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)
            ? c.text
            : c.secondaryText,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? c.disabledForeground
            : c.text,
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)
            ? c.accent.withValues(alpha: 0.14)
            : Colors.transparent,
      ),
    ),
  );
}

DropdownMenuThemeData dropdownMenuTheme(
  AppChrome c,
  InputDecorationThemeData input,
) => DropdownMenuThemeData(
  textStyle: appTextStyle(size: AppType.small, color: c.text),
  menuStyle: _menuStyle(c),
  inputDecorationTheme: input,
);

TooltipThemeData tooltipTheme(AppChrome c) => TooltipThemeData(
  decoration: BoxDecoration(
    color: c.card,
    borderRadius: BorderRadius.circular(AppRadii.control),
    border: Border.all(color: c.borderStrong),
  ),
  textStyle: appTextStyle(size: AppType.caption, color: c.text, height: 1.3),
  padding: const EdgeInsets.symmetric(
    horizontal: AppSpace.sm,
    vertical: AppSpace.xxs + 2,
  ),
  constraints: const BoxConstraints(maxWidth: 320),
  // Long enough that a pointer crossing the toolbar does not flash tips,
  // short enough that a resting pointer gets one promptly.
  waitDuration: const Duration(milliseconds: 500),
  exitDuration: const Duration(milliseconds: 80),
  showDuration: const Duration(seconds: 3),
);

SnackBarThemeData snackBarTheme(AppChrome c) => SnackBarThemeData(
  backgroundColor: c.card,
  contentTextStyle: appTextStyle(
    size: AppType.small,
    color: c.text,
    height: 1.4,
  ),
  actionTextColor: c.accent,
  disabledActionTextColor: c.disabledForeground,
  closeIconColor: c.secondaryText,
  showCloseIcon: true,
  elevation: 0,
  behavior: SnackBarBehavior.floating,
  insetPadding: const EdgeInsets.fromLTRB(
    AppSpace.lg,
    0,
    AppSpace.lg,
    snackBarBottomInset,
  ),
  shape: _cardShape(c, border: c.borderStrong),
);

ChipThemeData chipTheme(AppChrome c) {
  final selectedFill = Color.alphaBlend(c.accentWash, c.card);
  return ChipThemeData(
    elevation: 0,
    pressElevation: 0,
    shadowColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    shape: _controlShape(),
    color: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) return selectedFill;
      if (states.contains(WidgetState.hovered)) return c.hover;
      return Colors.transparent;
    }),
    side: WidgetStateBorderSide.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return BorderSide(color: c.accent, width: 2);
      }
      if (states.contains(WidgetState.selected)) {
        return BorderSide(color: c.accent);
      }
      return BorderSide(color: c.borderStrong);
    }),
    labelStyle: appTextStyle(
      size: AppType.small,
      color: c.text,
      weight: FontWeight.w500,
    ),
    secondaryLabelStyle: appTextStyle(
      size: AppType.small,
      color: c.text,
      weight: FontWeight.w500,
    ),
    checkmarkColor: c.accent,
    iconTheme: IconThemeData(color: c.secondaryText, size: 16),
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.xxs,
      vertical: AppSpace.xxs,
    ),
  );
}

TabBarThemeData tabBarTheme(AppChrome c) => TabBarThemeData(
  labelColor: c.text,
  unselectedLabelColor: c.secondaryText,
  labelStyle: appTextStyle(size: AppType.small, weight: FontWeight.w600),
  unselectedLabelStyle: appTextStyle(
    size: AppType.small,
    weight: FontWeight.w500,
  ),
  indicatorColor: c.accent,
  indicatorSize: TabBarIndicatorSize.label,
  dividerColor: c.border,
  dividerHeight: 1,
  splashFactory: NoSplash.splashFactory,
  overlayColor: WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)
        ? c.hoverWash
        : Colors.transparent,
  ),
);

ListTileThemeData listTileTheme(AppChrome c) => ListTileThemeData(
  iconColor: c.secondaryText,
  textColor: c.text,
  shape: _controlShape(),
  horizontalTitleGap: AppSpace.sm,
);

ScrollbarThemeData scrollbarTheme(AppChrome c) {
  bool engaged(Set<WidgetState> s) =>
      s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged);
  return ScrollbarThemeData(
    // Both ends visible against the page in dark and light: a mid-gray thumb
    // that firms up under the pointer.
    thumbColor: WidgetStateProperty.resolveWith(
      (states) => c.muted.withValues(alpha: engaged(states) ? 0.9 : 0.5),
    ),
    trackColor: WidgetStateProperty.resolveWith(
      (states) => engaged(states) ? c.hover : Colors.transparent,
    ),
    trackBorderColor: WidgetStateProperty.resolveWith(
      (states) => engaged(states) ? c.border : Colors.transparent,
    ),
    trackVisibility: WidgetStateProperty.resolveWith(engaged),
    thickness: WidgetStateProperty.resolveWith(
      (states) => engaged(states) ? 10 : 6,
    ),
    radius: const Radius.circular(AppRadii.pill),
    minThumbLength: 48,
    crossAxisMargin: 2,
  );
}

DividerThemeData dividerTheme(AppChrome c) =>
    DividerThemeData(color: c.border, thickness: 1, space: 1);

BadgeThemeData badgeTheme(AppChrome c) => BadgeThemeData(
  backgroundColor: c.hover,
  textColor: c.accent,
  textStyle: appTextStyle(size: AppType.caption, weight: FontWeight.w600),
);
