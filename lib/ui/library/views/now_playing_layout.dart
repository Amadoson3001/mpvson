import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../library/widgets/audio_volume_control.dart';
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
  ///
  /// Wide enough that the timeline, the title and the control band all read as
  /// one block, and narrow enough that the artwork stays the visual anchor.
  static const double columnMaxWidth = 768;

  /// Spacer that balances the favorite button beside the title.
  static const double titleBalanceWidth = 48;

  /// Gap between the transport row and the volume row. The volume control
  /// always sits under the transport, so this is a fixed part of the column.
  static const double transportVolumeGap = AppSpace.sm;

  /// Smallest the artwork may shrink on spacious viewports before the stage scrolls.
  static const double minArtworkSize = 140;

  /// Smallest the artwork may shrink on compact viewports to keep controls visible.
  static const double minArtworkSizeCompact = 80;

  /// Largest the artwork may grow, per stage width.
  static const double maxArtworkSize = 372;
  static const double maxArtworkSizeSpacious = 440;
  static const double maxArtworkSizeNarrow = 300;

  /// Stage width below which the narrower artwork maximum applies.
  static const double narrowBreakpoint = 820;

  /// Viewport height below which the stage switches to its compact gaps.
  static const double compactHeightBreakpoint = 640;

  /// Vertical scroll padding of the stage column.
  static double stageVerticalPadding({required bool isCompactHeight}) =>
      isCompactHeight ? AppSpace.sm : AppSpace.md;

  /// Gap between the top bar and the artwork.
  static double gapAboveArtwork({required bool isCompactHeight}) =>
      isCompactHeight ? AppSpace.xxs : AppSpace.xs;

  /// Gap between the artwork and the title row.
  static double gapBelowArtwork({required bool isCompactHeight}) =>
      isCompactHeight ? AppSpace.xs : AppSpace.sm;

  /// Gap between the title row and the artist line.
  static double gapBelowTitle({required bool isCompactHeight}) => AppSpace.xxs;

  /// Gap between the artist line and the album line.
  static double gapBelowArtist({required bool isCompactHeight}) =>
      isCompactHeight ? AppSpace.micro : AppSpace.xxs;

  /// Gap between the album line and the transport block.
  static double gapAboveTransport({required bool isCompactHeight}) =>
      isCompactHeight ? AppSpace.sm : AppSpace.md;

  /// Gap between the timeline and the transport row.
  static double gapTimelineTransport({required bool isCompactHeight}) =>
      isCompactHeight ? AppSpace.xxs : AppSpace.sm;

  /// Width of the stage's content column at [viewportWidth].
  ///
  /// The stage centers this column, so anything sized to it — the timeline, the
  /// top bar, the control band — shares the same center and edges.
  static double columnWidth(double viewportWidth) =>
      math.min(columnMaxWidth, viewportWidth - 2 * AppSpace.xl);

  /// Edge length for the artwork so the whole column fits the viewport.
  double artworkSize({
    required BuildContext context,
    required double viewportWidth,
    required double viewportHeight,
    required double iconButtonExtent,
    required TextScaler textScaler,
  }) {
    final isCompactHeight = viewportHeight < compactHeightBreakpoint;
    final minSize = isCompactHeight ? minArtworkSizeCompact : minArtworkSize;
    final maximum = viewportWidth < narrowBreakpoint
        ? (isCompactHeight ? 200.0 : maxArtworkSizeNarrow)
        : (viewportWidth >= 1200 && viewportHeight >= 850
              ? maxArtworkSizeSpacious
              : maxArtworkSize);

    final remainder =
        viewportHeight -
        contentHeight(
          context: context,
          viewportWidth: viewportWidth,
          viewportHeight: viewportHeight,
          iconButtonExtent: iconButtonExtent,
          textScaler: textScaler,
        );

    return remainder.clamp(minSize, maximum);
  }

  /// Height of the column with the artwork excluded.
  ///
  /// Mirrors the rows the view actually builds: the fixed chrome rows, the
  /// title/artist/album text rows, and the always-stacked control band
  /// (timeline, transport, volume), so a change to the view's rows keeps the
  /// artwork sizing honest.
  double contentHeight({
    required BuildContext context,
    required double viewportWidth,
    double? viewportHeight,
    required double iconButtonExtent,
    required TextScaler textScaler,
  }) {
    final isCompactHeight =
        viewportHeight != null && viewportHeight < compactHeightBreakpoint;
    final availableWidth = columnWidth(viewportWidth);
    // The title row pads itself by one horizontal inset on each side, and the
    // title text shares the row with the balance spacer, the inter-item gap,
    // and the favorite button.
    final titleMaxWidth =
        availableWidth -
        2 * AppSpace.md -
        titleBalanceWidth -
        AppSpace.xs -
        iconButtonExtent;
    final titleHeight = _textHeight(
      isCompactHeight ? context.palette.albumTitle : context.palette.pageTitle,
      title,
      textScaler,
      titleMaxWidth,
      maxLines: 2,
    );
    // The title row is as tall as its tallest member: the favorite button, or
    // the title itself when it wraps to two lines. The spacer beside it only
    // sets a width, so it never adds height.
    final titleRowHeight = math.max(iconButtonExtent, titleHeight);
    return _fixedRowsHeight(
          iconButtonExtent,
          isCompactHeight: isCompactHeight,
        ) +
        titleRowHeight +
        _textHeight(artistStyle(context), artist, textScaler, availableWidth) +
        _textHeight(albumStyle(context), album, textScaler, availableWidth);
  }

  /// Height of the rows that never change with the text: the scroll padding,
  /// the back/close row, the gaps, the timeline row, and the transport and
  /// volume rows stacked with the gap between them.
  static double _fixedRowsHeight(
    double iconButtonExtent, {
    required bool isCompactHeight,
  }) {
    final verticalPadding =
        2 * stageVerticalPadding(isCompactHeight: isCompactHeight);

    // The control band always stacks: timeline, gap, transport, gap, volume.
    final controlBand =
        PlayerControlStyle.seekExtent +
        gapTimelineTransport(isCompactHeight: isCompactHeight) +
        (isCompactHeight
            ? PlayerControlStyle.compactControlExtent
            : PlayerControlStyle.controlExtent) +
        transportVolumeGap +
        AudioVolumeControl.extent;

    return verticalPadding +
        iconButtonExtent +
        gapAboveArtwork(isCompactHeight: isCompactHeight) +
        gapBelowArtwork(isCompactHeight: isCompactHeight) +
        gapBelowTitle(isCompactHeight: isCompactHeight) +
        gapBelowArtist(isCompactHeight: isCompactHeight) +
        gapAboveTransport(isCompactHeight: isCompactHeight) +
        controlBand;
  }

  /// Style of the artist line, mirroring the view's text row.
  static TextStyle artistStyle(BuildContext context) =>
      context.palette.sectionTitle.copyWith(
        color: context.palette.primaryText.withValues(alpha: 0.82),
        fontWeight: FontWeight.w500,
      );

  /// Style of the album line, mirroring the view's text row.
  static TextStyle albumStyle(BuildContext context) => context
      .palette
      .rowSecondary
      .copyWith(color: context.palette.primaryText.withValues(alpha: 0.6));

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
