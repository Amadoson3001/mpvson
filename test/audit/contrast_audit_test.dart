import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/ui/core/app_theme.dart';

double _lin(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double luminance(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

double contrast(Color a, Color b) {
  final la = luminance(a);
  final lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Color _tint(Color color, Color surface, [double alpha = 0.16]) =>
    Color.alphaBlend(color.withValues(alpha: alpha), surface);

void main() {
  test('contrast report', () {
    final rows = <String>[];
    for (final preset in AppAccentPreset.all) {
      for (final dark in [true, false]) {
        final theme = dark
            ? AppTheme.darkTheme(accent: preset.color)
            : AppTheme.lightTheme(accent: preset.lightColor);
        final p = AppPalette(theme.colorScheme);
        final buttonStyle = theme.filledButtonTheme.style!;
        const disabled = {WidgetState.disabled};
        final disabledFg = buttonStyle.foregroundColor!.resolve(disabled)!;
        final disabledBg = buttonStyle.backgroundColor!.resolve(disabled)!;
        final pairs = <String, (Color, Color, double)>{
          'accent on bg': (p.accent, p.background, 4.5),
          'accent on sidebar': (p.accent, p.sidebar, 4.5),
          'accent on card': (p.accent, p.card, 4.5),
          'onAccent on accent': (p.accentForeground, p.accent, 4.5),
          'secondary on bg': (p.secondaryText, p.background, 4.5),
          'secondary on card': (p.secondaryText, p.card, 4.5),
          'secondary on sidebar': (p.secondaryText, p.sidebar, 4.5),
          'text on bg': (p.text, p.background, 7),
          'bodySmall on card': (theme.textTheme.bodySmall!.color!, p.card, 4.5),
          'muted/faint on bg': (p.faint, p.background, 3),
          'success on card': (p.success, p.card, 4.5),
          'warning on card': (p.warning, p.card, 4.5),
          'info on card': (p.info, p.card, 4.5),
          'danger on card': (p.danger, p.card, 4.5),
          'success pill': (p.success, _tint(p.success, p.card), 4.5),
          'warning pill': (p.warning, _tint(p.warning, p.card), 4.5),
          'danger pill': (p.danger, _tint(p.danger, p.card), 4.5),
          'disabled button': (disabledFg, disabledBg, 4.5),
          'busy button': (
            p.text,
            Color.alphaBlend(p.accent.withValues(alpha: 0.18), p.card),
            4.5,
          ),
        };
        pairs.forEach((name, v) {
          final c = contrast(v.$1, v.$2);
          if (c < v.$3) {
            rows.add(
              '${dark ? 'dark ' : 'light'} ${preset.id.padRight(9)} '
              '${name.padRight(22)} ${c.toStringAsFixed(2)} (need ${v.$3})',
            );
          }
        });
      }
    }
    // ignore: avoid_print
    print('CONTRAST FAILURES (${rows.length})\n${rows.join('\n')}');
    expect(rows, isEmpty, reason: rows.join('\n'));
  });

  test('palette text styles keep the app font', () {
    for (final theme in [AppTheme.darkTheme(), AppTheme.lightTheme()]) {
      final p = AppPalette(theme.colorScheme);
      for (final style in [
        p.pageTitle,
        p.albumTitle,
        p.sectionTitle,
        p.rowPrimary,
        p.rowSecondary,
        p.metadata,
        p.badge,
      ]) {
        expect(style.fontFamily, AppType.family);
      }
    }
  });
}
