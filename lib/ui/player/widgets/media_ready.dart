import 'package:flutter/material.dart';

import '../../../domain/models/media_entry.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import 'screen_play_mark.dart';

/// A stopped/restored queue item before the native playback engine has opened it.
class MediaReady extends StatelessWidget {
  const MediaReady({
    super.key,
    required this.entry,
    required this.position,
    required this.duration,
    required this.isOpening,
    required this.onPlay,
  });

  final MediaEntry entry;
  final Duration position;
  final Duration duration;
  final bool isOpening;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final hasResumePosition = position > Duration.zero;
    final durationMs = duration.inMilliseconds;
    final progress = durationMs > 0
        ? (position.inMilliseconds / durationMs).clamp(0.0, 1.0)
        : 0.0;

    return ColoredBox(
      color: context.palette.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 600;
          final content = _ReadyContent(
            entry: entry,
            position: position,
            duration: duration,
            hasResumePosition: hasResumePosition,
            progress: progress.toDouble(),
            isOpening: isOpening,
            onPlay: onPlay,
          );

          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: AppMotionReveal(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 22 : 38,
                        vertical: compact ? 28 : 40,
                      ),
                      child: compact
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const ScreenPlayMark(width: 94, height: 72),
                                const SizedBox(height: 20),
                                content,
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(child: content),
                                const SizedBox(width: 28),
                                const ScreenPlayMark(width: 154, height: 118),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ReadyContent extends StatelessWidget {
  const _ReadyContent({
    required this.entry,
    required this.position,
    required this.duration,
    required this.hasResumePosition,
    required this.progress,
    required this.isOpening,
    required this.onPlay,
  });

  final MediaEntry entry;
  final Duration position;
  final Duration duration;
  final bool hasResumePosition;
  final double progress;
  final bool isOpening;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isOpening
              ? 'Opening video'
              : hasResumePosition
              ? 'Ready to resume'
              : 'Ready to play',
          style: textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          entry.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.headlineMedium?.copyWith(
            fontSize: AppType.display,
            height: 1.12,
            letterSpacing: -0.65,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          entry.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall,
        ),
        if (hasResumePosition) ...[
          const SizedBox(height: 13),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.play_arrow_rounded, size: 17),
              const SizedBox(width: 5),
              Text(
                'Continue at ${_formatTime(position)}',
                style: textTheme.bodyMedium?.copyWith(
                  color: context.palette.secondaryText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (duration > Duration.zero) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.square),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                backgroundColor: context.palette.border,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ],
        const SizedBox(height: 21),
        Tooltip(
          message: hasResumePosition ? 'Resume this video' : 'Play this video',
          child: FilledButton.icon(
            key: const ValueKey('resume-current'),
            onPressed: isOpening ? null : onPlay,
            icon: isOpening
                ? SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: context.palette.accentForeground,
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(
              isOpening
                  ? 'Opening…'
                  : hasResumePosition
                  ? 'Resume video'
                  : 'Play video',
            ),
          ),
        ),
      ],
    );
  }

  static String _formatTime(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
