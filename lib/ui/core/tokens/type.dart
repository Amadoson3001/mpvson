abstract final class AppType {
  /// The UI font. Every text style the theme builds names it explicitly, so a
  /// style that replaces the ambient one (`ButtonStyle.textStyle`,
  /// `DefaultTextStyle`) can no longer fall back to the platform font.
  static const String family = 'Onest';
  static const List<String> familyFallback = [
    'Noto Sans',
    'DejaVu Sans',
    'sans-serif',
  ];

  static const double display = 28;
  static const double title = 20;
  static const double body = 15;
  static const double small = 13;
  static const double caption = 11;

  static const double tight = AppLetterSpacing.tight;
  static const double tighter = AppLetterSpacing.tighter;
  static const double tightest = AppLetterSpacing.tightest;
}

abstract final class AppLetterSpacing {
  static const double tightest = -1.2;
  static const double headline = -0.6;
  static const double tighter = -0.5;
  static const double title = -0.4;
  static const double subtitle = -0.3;
  static const double tight = -0.2;
  static const double normal = 0.0;
  static const double wide = 0.2;
}
