import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/components/seek_bar.dart';
import '../../library/widgets/audio_volume_control.dart';
import '../../player/widgets/player_control_style.dart';
import '../../player/widgets/player_controls.dart';

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

  /// Space kept between the transport row and the volume control.
  static const double minControlGap = 16;

  /// Width of the stage's content column at [viewportWidth].
  ///
  /// The stage centers this column, so anything sized to it — the timeline, the
  /// top bar, the control band — shares the same center and edges.
  static double columnWidth(double viewportWidth) =>
      math.min(columnMaxWidth, viewportWidth - 2 * AppSpace.xl);

  /// Whether the volume control can sit beside the transport on one row.
  ///
  /// The transport is centered in the column while the volume rides the
  /// trailing edge, so the row only has room when the space left over after the
  /// transport is at least the volume plus the timeline's inset. Narrower
  /// stages drop the volume to its own row rather than crowding the transport.
  static bool controlsShareRow({
    required double viewportWidth,
    required bool isCompactHeight,
  }) {
    final width = columnWidth(viewportWidth);
    final gap =
        (width - TransportButtons.preferredWidth(compact: isCompactHeight)) /
            2 -
        volumeControlWidth(compact: isCompactHeight) -
        SeekBar.sideInset -
        TransportButtons.playButtonCenterOffset(compact: isCompactHeight);
    return gap >= minControlGap;
  }

  /// Width of the volume control in each presentation.
  static double volumeControlWidth({required bool compact}) =>
      AudioVolumeControl.preferredWidth(compact: compact, showPercent: true);

  /// Edge length for the artwork so the whole column fits the viewport.
  double artworkSize({
    required BuildContext context,
    required double viewportWidth,
    required double viewportHeight,
    required double iconButtonExtent,
    required TextScaler textScaler,
  }) {
    final isCompactHeight = viewportHeight < 640;
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
  double contentHeight({
    required BuildContext context,
    required double viewportWidth,
    double? viewportHeight,
    required double iconButtonExtent,
    required TextScaler textScaler,
  }) {
    final isCompactHeight = viewportHeight != null && viewportHeight < 640;
    final columnWidth =
        math.min(columnMaxWidth, viewportWidth) - 2 * AppSpace.xl;
    final titleHeight = _textHeight(
      isCompactHeight ? context.palette.albumTitle : context.palette.pageTitle,
      title,
      textScaler,
      columnWidth - titleBalanceWidth - iconButtonExtent,
      maxLines: 2,
    );
    // The title row is as tall as its tallest member: the favorite button, or
    // the title itself when it wraps to two lines. The spacer beside it only
    // sets a width, so it never adds height.
    final titleRowHeight = math.max(iconButtonExtent, titleHeight);
    return _fixedRowsHeight(
          iconButtonExtent,
          viewportWidth: viewportWidth,
          isCompactHeight: isCompactHeight,
        ) +
        titleRowHeight +
        _textHeight(artistStyle(context), artist, textScaler, columnWidth) +
        _textHeight(albumStyle(context), album, textScaler, columnWidth);
  }

  /// Height of the rows that never change with the text: the scroll padding,
  /// the back/close row, the gaps, the timeline row and the transport row.
  static double _fixedRowsHeight(
    double iconButtonExtent, {
    double? viewportWidth,
    bool isCompactHeight = false,
  }) {
    final verticalPadding = isCompactHeight ? 2 * AppSpace.sm : 2 * AppSpace.lg;
    final gapAboveArtwork = isCompactHeight ? 8.0 : 12.0;
    final gapBelowArtwork = isCompactHeight ? 14.0 : 28.0;
    final gapBelowTitle = isCompactHeight ? 4.0 : 8.0;
    final gapBelowArtist = isCompactHeight ? 2.0 : 4.0;
    final gapAboveTransport = isCompactHeight ? 16.0 : AppSpace.xl;
    final gapTimelineTransport = isCompactHeight ? 4.0 : AppSpace.sm;

    // The control band is as tall as its tallest member: the transport row, or
    // the volume control, whose mute button stays the same size in both
    // presentations.
    final controlRow = math.max(
      isCompactHeight
          ? PlayerControlStyle.compactControlExtent
          : PlayerControlStyle.controlExtent,
      AudioVolumeControl.extent,
    );

    // Narrow stages stack the volume under the transport, which adds a second
    // control row to the column.
    final stackedVolume =
        viewportWidth != null &&
        !controlsShareRow(
          viewportWidth: viewportWidth,
          isCompactHeight: isCompactHeight,
        );

    return verticalPadding +
        iconButtonExtent +
        gapAboveArtwork +
        gapBelowArtwork +
        gapBelowTitle +
        gapBelowArtist +
        gapAboveTransport +
        gapTimelineTransport +
        PlayerControlStyle.seekExtent +
        controlRow +
        (stackedVolume ? AudioVolumeControl.extent + AppSpace.sm : 0);
  }

  static TextStyle artistStyle(BuildContext context) =>
      context.palette.sectionTitle.copyWith(
        color: context.palette.secondaryText,
        fontWeight: FontWeight.w500,
      );

  /// Style of the album line, mirroring the view's text row.
  static TextStyle albumStyle(BuildContext context) =>
      context.palette.rowSecondary.copyWith(color: context.palette.mutedText);

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
