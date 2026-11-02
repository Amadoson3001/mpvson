import 'package:flutter/material.dart';

import '../tokens/type.dart';
import 'app_chrome.dart';

/// A text style that always names the UI font.
///
/// Use this (never a bare `TextStyle(fontSize: ...)`) for any style that
/// replaces the ambient one, such as `ButtonStyle.textStyle`.
TextStyle appTextStyle({
  required double size,
  Color? color,
  FontWeight? weight,
  double? height,
  double? letterSpacing,
}) => TextStyle(
  fontFamily: AppType.family,
  fontFamilyFallback: AppType.familyFallback,
  color: color,
  fontSize: size,
  fontWeight: weight,
  height: height,
  letterSpacing: letterSpacing,
);

/// The M3 text theme in Mpvson's scale.
TextTheme buildAppTextTheme(AppChrome c) {
  TextStyle style(
    double size,
    Color color, {
    FontWeight? weight,
    double? height,
    double? letterSpacing,
  }) => appTextStyle(
    size: size,
    color: color,
    weight: weight,
    height: height,
    letterSpacing: letterSpacing,
  );

  return TextTheme(
    displaySmall: style(
      AppType.display,
      c.text,
      weight: FontWeight.w600,
      height: 1.15,
      letterSpacing: AppLetterSpacing.tightest,
    ),
    headlineMedium: style(
      AppType.title,
      c.text,
      weight: FontWeight.w600,
      height: 1.2,
      letterSpacing: AppLetterSpacing.headline,
    ),
    titleLarge: style(
      AppType.title,
      c.text,
      weight: FontWeight.w600,
      letterSpacing: AppLetterSpacing.title,
    ),
    titleMedium: style(AppType.body, c.text, weight: FontWeight.w600),
    titleSmall: style(AppType.small, c.text, weight: FontWeight.w600),
    bodyLarge: style(AppType.body, c.secondaryText, height: 1.5),
    bodyMedium: style(AppType.small, c.secondaryText, height: 1.4),
    bodySmall: style(AppType.caption, c.muted, height: 1.4),
    labelLarge: style(AppType.small, c.text, weight: FontWeight.w600),
    labelMedium: style(AppType.caption, c.secondaryText),
    labelSmall: style(AppType.caption, c.muted),
  );
}
