import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../player/widgets/player_control_style.dart';

/// Sizing rules for the Now Playing stage.
///
/// The artwork is the only flexible element in the column, so it is sized from
/// the height the rest of the content leaves behind. [contentHeight] measures
/// that remainder — the fixed rows from the extents the controls are built
/// with, and every text row with its real style, string and text scale — so
/// the artwork shrinks by exactly the right amount as the window shrinks and
/// the transport row stays in view.
///
/// This used to be a single estimated constant for the whole column. That
/// estimate was roughly 56 logical pixels short of the real rows, so at the
/// default window size the artwork stayed at its maximum and pushed the
/// transport row below the fold, and any later change to the rows made the
/// guess wrong again. Measuring keeps the two in step.
class NowPlayingLayout {
  const NowPlayingLayout({
    required this.title,
    required this.artist,
    required this.album,
  });

  /// Track title shown in the column.
  final String title;

  /// Artist line shown under the title.
  final String artist;

  /// Album line shown under the artist.
  final String album;

  /// Width the column is allowed to occupy before the stage widens further.
  static const double columnMaxWidth = 680;

  /// Spacer that balances the favorite button beside the title.
  static const double titleBalanceWidth = 48;

  /// Smallest the artwork may shrink before the stage scrolls instead.
  static const double minArtworkSize = 180;

  /// Largest the artwork may grow, per stage width.
  static const double maxArtworkSize = 340;
  static const double maxArtworkSizeNarrow = 260;

  /// Stage width below which the narrower artwork maximum applies.
  static const double narrowBreakpoint = 800;

  /// Edge length for the artwork so the whole column fits the viewport.
  double artworkSize({
    required double viewportWidth,
    required double viewportHeight,
    required double iconButtonExtent,
    required TextScaler textScaler,
  }) {
    final maximum = viewportWidth < narrowBreakpoint
        ? maxArtworkSizeNarrow
        : maxArtworkSize;
    return (viewportHeight -
            contentHeight(
              viewportWidth: viewportWidth,
              iconButtonExtent: iconButtonExtent,
              textScaler: textScaler,
            ))
        .clamp(minArtworkSize, maximum);
  }

  /// Height of the column with the artwork excluded.
  double contentHeight({
    required double viewportWidth,
    required double iconButtonExtent,
    required TextScaler textScaler,
  }) {
    final columnWidth =
        math.min(columnMaxWidth, viewportWidth) - 2 * AppSpace.xl;
    final titleHeight = _textHeight(
      AppTheme.pageTitle,
      title,
      textScaler,
      columnWidth - titleBalanceWidth - iconButtonExtent,
      maxLines: 2,
    );
    // The title row is as tall as its tallest member: the favorite button, or
    // the title itself when it wraps to two lines. The spacer beside it only
    // sets a width, so it never adds height.
    final titleRowHeight = math.max(iconButtonExtent, titleHeight);
    return _fixedRowsHeight(iconButtonExtent) +
        titleRowHeight +
        _textHeight(_artistStyle, artist, textScaler, columnWidth) +
        _textHeight(_albumStyle, album, textScaler, columnWidth);
  }

  /// Height of the rows that never change with the text: the scroll padding,
  /// the back/close row, the gaps, the timeline row and the transport row.
  static double _fixedRowsHeight(double iconButtonExtent) {
    return 2 * AppSpace.lg + // scroll view padding
        iconButtonExtent + // back / close row
        12 + // gap above the artwork
        28 + // gap below the artwork
        8 + // gap below the title row
        4 + // gap below the artist
        AppSpace.xl + // gap above the transport block
        AppSpace.sm + // gap between the timeline and the transport row
        PlayerControlStyle.seekExtent + // timeline row
        PlayerControlStyle.controlExtent; // transport row
  }

  /// Style of the artist line, mirroring the view's text row.
  static final TextStyle _artistStyle = AppTheme.sectionTitle.copyWith(
    color: AppTheme.secondaryText,
    fontWeight: FontWeight.w500,
  );

  /// Style of the album line, mirroring the view's text row.
  static final TextStyle _albumStyle = AppTheme.rowSecondary.copyWith(
    color: AppTheme.mutedText,
  );

  /// Measures a text row exactly as the [Text] widget will lay it out, so the
  /// artwork sizing accounts for the real rows instead of an estimate.
  static double _textHeight(
    TextStyle style,
    String text,
    TextScaler textScaler,
    double maxWidth, {
    int maxLines = 1,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: maxLines,
    );
    painter.layout(maxWidth: math.max(maxWidth, 0));
    final height = painter.height;
    painter.dispose();
    return height;
  }
}
