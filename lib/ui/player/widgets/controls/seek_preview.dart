import 'package:flutter/material.dart';

import '../../../../domain/models/media_thumbnail.dart';
import '../../../../ui/core/app_theme.dart';
import '../../../../utils/format.dart';
import '../../player_controller.dart';

class CaretPainter extends CustomPainter {
  const CaretPainter({required this.color, required this.borderColor});

  final Color color;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final fillPath = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );

    final strokePath = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0);
    canvas.drawPath(
      strokePath,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(CaretPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.borderColor != borderColor;
}

class SeekPreview extends StatelessWidget {
  const SeekPreview({
    super.key,
    required this.label,
    required this.width,
    required this.caretOffset,
    required this.previewRatio,
    required this.previewTime,
    required this.currentPosition,
    required this.controller,
    required this.previewState,
    required this.thumbnail,
    this.chapterTitle,
  });

  final String label;
  final double width;
  final double caretOffset;
  final double previewRatio;
  final Duration previewTime;
  final Duration currentPosition;
  final PlayerController controller;
  final SeekPreviewState? previewState;
  final MediaThumbnail? thumbnail;
  final String? chapterTitle;

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

    final borderColor = context.palette.border.withValues(alpha: 0.85);

    final cardContent = isAudio
        ? _buildAudioContent(context, title, diffText, isAhead)
        : _buildVideoContent(context, title, diffText, isAhead);

    final clampedCaret = (caretOffset - 5).clamp(
      8.0,
      (width - 18.0) > 8.0 ? (width - 18.0) : 8.0,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: width,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: context.palette.card,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 14,
                spreadRadius: 1,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: cardContent,
        ),
        Transform.translate(
          offset: const Offset(0, -1),
          child: Padding(
            padding: EdgeInsets.only(left: clampedCaret),
            child: CustomPaint(
              size: const Size(10, 5),
              painter: CaretPainter(
                color: context.palette.card,
                borderColor: borderColor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoContent(
    BuildContext context,
    String? title,
    String diffText,
    bool isAhead,
  ) {
    final frameHeight = ((width - 2) * 9 / 16).clamp(54.0, 96.0);
    final frame = previewState?.currentFrame;
    final isFailed = previewState?.status == SeekPreviewStatus.failed;
    final isLoading = previewState?.status == SeekPreviewStatus.loading;
    final isUpdating = previewState?.isUpdating == true;
    final showLoadingIndicator = isUpdating || (isLoading && frame == null);

    const topRadius = BorderRadius.vertical(top: Radius.circular(AppRadii.control));
    Widget imageSurface;
    if (frame != null && frame.bytes.isNotEmpty) {
      imageSurface = ClipRRect(
        borderRadius: topRadius,
        child: Image.memory(
          frame.bytes,
          cacheWidth: 320,
          cacheHeight: 180,
          filterQuality: FilterQuality.low,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const _PreviewPlaceholderFrame(),
        ),
      );
    } else if (isFailed) {
      imageSurface = const ClipRRect(
        borderRadius: topRadius,
        child: _PreviewUnavailableFrame(),
      );
    } else if (thumbnail != null && thumbnail!.bytes.isNotEmpty) {
      imageSurface = ClipRRect(
        borderRadius: topRadius,
        child: Image.memory(
          thumbnail!.bytes,
          cacheWidth: 320,
          cacheHeight: 180,
          filterQuality: FilterQuality.low,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const _PreviewPlaceholderFrame(),
        ),
      );
    } else {
      imageSurface = const ClipRRect(
        borderRadius: topRadius,
        child: _PreviewPlaceholderFrame(),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: frameHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              imageSurface,
              if (isFailed && frame != null)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.68),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.max,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.hide_image_outlined,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              'Preview unavailable',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (showLoadingIndicator)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 2.5,
                  color: Colors.black.withValues(alpha: 0.5),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: previewRatio,
                      child: Container(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.xs,
            vertical: 5,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.palette.text,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (diffText.isNotEmpty)
                    Text(
                      diffText,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: isAhead
                            ? Theme.of(context).colorScheme.primary
                            : context.palette.muted,
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
              if (chapterTitle case final title? when title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.palette.secondaryText,
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAudioContent(
    BuildContext context,
    String? title,
    String diffText,
    bool isAhead,
  ) {
    final bytes = thumbnail?.bytes;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: context.palette.surface,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: context.palette.border),
            ),
            child: (bytes != null && bytes.isNotEmpty)
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    child: Image.memory(
                      bytes,
                      cacheWidth: 64,
                      cacheHeight: 64,
                      filterQuality: FilterQuality.low,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.music_note_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  )
                : Icon(
                    Icons.music_note_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null && title.trim().isNotEmpty)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.palette.secondaryText,
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.palette.text,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (diffText.isNotEmpty)
                      Text(
                        diffText,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: isAhead
                              ? Theme.of(context).colorScheme.primary
                              : context.palette.muted,
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.w500,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
                if (chapterTitle case final chapter? when chapter.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      chapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.palette.secondaryText,
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w500,
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

class _PreviewPlaceholderFrame extends StatelessWidget {
  const _PreviewPlaceholderFrame();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [context.palette.surface, context.palette.card],
      ),
    ),
    child: Center(
      child: Icon(
        Icons.play_circle_fill_rounded,
        size: 26,
        color: context.palette.secondaryText.withValues(alpha: 0.35),
      ),
    ),
  );
}

class _PreviewUnavailableFrame extends StatelessWidget {
  const _PreviewUnavailableFrame();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [context.palette.surface, context.palette.card],
      ),
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.videocam_off_rounded,
            size: 20,
            color: context.palette.secondaryText.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 4),
          Text(
            'Preview unavailable',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: context.palette.secondaryText,
              fontSize: AppType.caption,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );
}
