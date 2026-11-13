import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../domain/models/media_thumbnail.dart';
import '../../../../ui/core/app_motion.dart';
import '../../../../ui/core/app_theme.dart';
import '../../../../utils/format.dart';
import '../../player_controller.dart';
import 'seek_preview_metrics.dart';

export 'seek_preview_metrics.dart';

class SeekPreview extends StatelessWidget {
  const SeekPreview({
    super.key,
    required this.label,
    required this.width,
    required this.caretOffset,
    required this.previewTime,
    required this.currentPosition,
    required this.controller,
    required this.previewState,
    required this.thumbnail,
    this.chapterTitle,
    this.compact = false,
  });

  static const double videoWidth = SeekPreviewMetrics.videoWidth;
  static const double audioWidth = SeekPreviewMetrics.audioWidth;

  static Widget switchLayout(Widget? current, List<Widget> previous) => Stack(
    alignment: Alignment.bottomCenter,
    clipBehavior: Clip.none,
    children: [...previous, ?current],
  );

  static Widget switchTransition(
    BuildContext context,
    Widget child,
    Animation<double> animation,
  ) {
    if (AppMotion.reduce(context)) return child;
    final curved = animation.drive(CurveTween(curve: AppMotion.enter));
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
        alignment: Alignment.bottomCenter,
        child: child,
      ),
    );
  }

  final String label;
  final double width;
  final double caretOffset;
  final Duration previewTime;
  final Duration currentPosition;
  final PlayerController controller;
  final SeekPreviewState? previewState;
  final MediaThumbnail? thumbnail;
  final String? chapterTitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isAudio = controller.isAudio;
    final diff = previewTime - currentPosition;
    final isAhead = diff > Duration.zero;
    final absDiff = diff.abs();
    final diffText = absDiff >= const Duration(seconds: 1)
        ? '${isAhead ? '+' : '-'}${formatTime(absDiff)}'
        : '';
    final entry = controller.current;
    final title = entry?.title ?? controller.currentMetadata.title;
    final cardColor = isAudio ? context.palette.card : const Color(0xFF101014);
    final borderColor = Colors.white.withValues(alpha: isAudio ? 0.10 : 0.14);
    final caretLeft = (caretOffset - SeekPreviewMetrics.caretWidth / 2).clamp(
      8.0,
      (width - SeekPreviewMetrics.caretWidth - 8.0).clamp(8.0, width),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: width,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(
              compact ? AppRadii.control : AppRadii.artwork,
            ),
            border: Border.all(color: borderColor),
            boxShadow: AppMotion.lowPower(context)
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: compact ? 0.42 : 0.55,
                      ),
                      blurRadius: compact ? 12 : 22,
                      spreadRadius: 0,
                      offset: Offset(0, compact ? 4 : 8),
                    ),
                  ],
          ),
          child: isAudio
              ? _AudioPreview(
                  title: title,
                  label: label,
                  diffText: diffText,
                  isAhead: isAhead,
                  thumbnail: thumbnail,
                  chapterTitle: chapterTitle,
                )
              : _VideoPreview(
                  width: width,
                  compact: compact,
                  label: label,
                  diffText: diffText,
                  isAhead: isAhead,
                  previewState: previewState,
                  thumbnail: thumbnail,
                  chapterTitle: chapterTitle,
                ),
        ),
        Transform.translate(
          offset: const Offset(0, -1),
          child: Padding(
            padding: EdgeInsets.only(left: caretLeft),
            child: CustomPaint(
              size: const Size(
                SeekPreviewMetrics.caretWidth,
                SeekPreviewMetrics.caretHeight,
              ),
              painter: CaretPainter(color: cardColor, borderColor: borderColor),
            ),
          ),
        ),
      ],
    );
  }
}

class _VideoPreview extends StatelessWidget {
  const _VideoPreview({
    required this.width,
    required this.compact,
    required this.label,
    required this.diffText,
    required this.isAhead,
    required this.previewState,
    required this.thumbnail,
    required this.chapterTitle,
  });

  final double width;
  final bool compact;
  final String label;
  final String diffText;
  final bool isAhead;
  final SeekPreviewState? previewState;
  final MediaThumbnail? thumbnail;
  final String? chapterTitle;

  @override
  Widget build(BuildContext context) {
    final frame = previewState?.currentFrame;
    final isFailed = previewState?.status == SeekPreviewStatus.failed;
    final isLoading = previewState?.status == SeekPreviewStatus.loading;
    final showSpinner =
        previewState?.isUpdating == true || (isLoading && frame == null);
    final frameHeight = compact
        ? width * 9 / 16
        : (width * 9 / 16).clamp(88.0, 144.0);
    final inset = compact ? 6.0 : 10.0;
    final accent = Theme.of(context).colorScheme.primary;

    Widget image;
    if (frame != null && frame.bytes.isNotEmpty) {
      image = _PreviewBitmap(bytes: frame.bytes);
    } else if (isFailed) {
      image = const _PreviewUnavailableFrame();
    } else if (thumbnail != null && thumbnail!.bytes.isNotEmpty) {
      image = _PreviewBitmap(bytes: thumbnail!.bytes);
    } else {
      image = const _PreviewPlaceholderFrame();
    }

    return SizedBox(
      height: frameHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0xCC000000)],
                stops: [0.42, 1],
              ),
            ),
          ),
          if (showSpinner)
            Positioned(
              top: compact ? 5 : 8,
              right: compact ? 5 : 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: accent,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: inset,
            right: inset,
            bottom: compact ? 6 : 9,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (chapterTitle case final chapter? when chapter.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      chapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.86),
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 8 : 10,
                      vertical: compact ? 3 : 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontSize: compact
                                    ? AppType.caption
                                    : AppType.small,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                        if (diffText.isNotEmpty) ...[
                          const SizedBox(width: 7),
                          Text(
                            diffText,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: isAhead
                                      ? accent
                                      : Colors.white.withValues(alpha: 0.72),
                                  fontSize: AppType.caption,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioPreview extends StatelessWidget {
  const _AudioPreview({
    required this.title,
    required this.label,
    required this.diffText,
    required this.isAhead,
    required this.thumbnail,
    required this.chapterTitle,
  });

  final String? title;
  final String label;
  final String diffText;
  final bool isAhead;
  final MediaThumbnail? thumbnail;
  final String? chapterTitle;

  @override
  Widget build(BuildContext context) {
    final bytes = thumbnail?.bytes;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.palette.surface,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            clipBehavior: Clip.antiAlias,
            child: (bytes != null && bytes.isNotEmpty)
                ? _PreviewBitmap(bytes: bytes, square: true)
                : Icon(Icons.music_note_rounded, size: 20, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null && title!.trim().isNotEmpty)
                  Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.palette.secondaryText,
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                Row(
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.palette.text,
                        fontSize: AppType.small,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (diffText.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        diffText,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isAhead ? accent : context.palette.muted,
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
                if (chapterTitle case final chapter? when chapter.isNotEmpty)
                  Text(
                    chapter,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.palette.secondaryText,
                      fontSize: AppType.caption,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBitmap extends StatelessWidget {
  const _PreviewBitmap({required this.bytes, this.square = false});

  final Uint8List bytes;
  final bool square;

  @override
  Widget build(BuildContext context) => Image.memory(
    bytes,
    cacheWidth: square ? 80 : 480,
    filterQuality: FilterQuality.medium,
    fit: BoxFit.cover,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => const _PreviewPlaceholderFrame(),
  );
}

class _PreviewPlaceholderFrame extends StatelessWidget {
  const _PreviewPlaceholderFrame();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF16161C),
    child: Center(
      child: Icon(Icons.movie_outlined, size: 28, color: Color(0x66FFFFFF)),
    ),
  );
}

class _PreviewUnavailableFrame extends StatelessWidget {
  const _PreviewUnavailableFrame();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF16161C),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.videocam_off_rounded,
            size: 22,
            color: Color(0x99FFFFFF),
          ),
          const SizedBox(height: 6),
          Text(
            'Preview unavailable',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: AppType.caption,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );
}
