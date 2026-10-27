import 'package:flutter/material.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';

class PlaybackFeedback extends StatelessWidget {
  const PlaybackFeedback({
    super.key,
    required this.icon,
    required this.label,
    this.progress,
  });

  final IconData icon;
  final String label;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final railProgress = progress?.clamp(0.0, 1.0).toDouble();
    final textTheme = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;

    return Semantics(
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            duration: AppMotion.duration(context, AppMotion.standard),
            curve: AppMotion.enter,
            tween: Tween<double>(begin: 0, end: 1),
            builder: (context, progress, child) {
              if (AppMotion.reduce(context)) return child!;
              final eased = progress.clamp(0.0, 1.0).toDouble();
              return Opacity(
                opacity: eased,
                child: Transform.translate(
                  offset: Offset(0, (1 - eased) * 5),
                  child: Transform.scale(
                    scale: 0.96 + (0.04 * eased),
                    child: child,
                  ),
                ),
              );
            },
            child: RepaintBoundary(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppTheme.surface.withValues(alpha: 0.96),
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(AppRadii.artwork),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 9,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 20, color: accent),
                            const SizedBox(width: 9),
                            Flexible(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodyMedium?.copyWith(
                                  color: AppTheme.text,
                                  fontSize: AppType.small,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (railProgress != null) ...[
                          const SizedBox(height: 7),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(
                              AppRadii.square,
                            ),
                            child: LinearProgressIndicator(
                              value: railProgress,
                              minHeight: 2,
                              backgroundColor: AppTheme.border,
                              color: accent,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
