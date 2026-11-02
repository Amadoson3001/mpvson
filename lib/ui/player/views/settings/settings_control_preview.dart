import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';

class ControlBarPreview extends StatelessWidget {
  const ControlBarPreview({
    super.key,
    required this.compact,
    required this.compactViewport,
  });

  final bool compact;
  final bool compactViewport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final buttonSize = compact ? 28.0 : 36.0;
    final iconSize = compact ? 15.0 : 18.0;
    final barHeight = compact ? 42.0 : 52.0;

    return Container(
      key: const ValueKey('control-density-preview'),
      height: 120.0,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        border: Border.all(color: theme.colorScheme.outlineVariant, width: 1),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            theme.colorScheme.surfaceContainerLowest,
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: barHeight,
            child: Center(
              child: Icon(
                Icons.movie_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.35,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: barHeight,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
                    width: 1,
                  ),
                ),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 12 : 16,
                vertical: compact ? 3 : 6,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LinearProgressIndicator(
                    value: 0.42,
                    minHeight: compact ? 3 : 4,
                    backgroundColor: theme.colorScheme.outlineVariant,
                    color: accent,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.skip_previous_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: buttonSize,
                              height: buttonSize,
                              decoration: BoxDecoration(
                                color: accent,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: iconSize + 2,
                                color: theme.colorScheme.onPrimary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.skip_next_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Icon(
                              Icons.volume_up_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: compact ? 44 : 60,
                              child: LinearProgressIndicator(
                                value: 0.72,
                                minHeight: 3,
                                backgroundColor:
                                    theme.colorScheme.outlineVariant,
                                color: theme.colorScheme.onSurfaceVariant,
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              Icons.queue_music_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.fullscreen_rounded,
                              size: iconSize,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
