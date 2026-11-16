import 'package:flutter/material.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';

class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    super.key,
    required this.currentTitle,
    required this.controlsVisible,
    required this.hasLibraryRepository,
    required this.isMiniPlayer,
    required this.onPointerEnter,
    required this.onPointerExit,
    required this.onBackToHome,
    required this.onExitMiniPlayer,
    this.onFocusChange,
  });

  final String currentTitle;
  final bool controlsVisible;
  final bool hasLibraryRepository;
  final bool isMiniPlayer;
  final VoidCallback onPointerEnter;
  final VoidCallback onPointerExit;
  final VoidCallback onBackToHome;
  final VoidCallback onExitMiniPlayer;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => onPointerEnter(),
    onExit: (_) => onPointerExit(),
    child: AnimatedOpacity(
      opacity: controlsVisible ? 1 : 0,
      duration: AppMotion.duration(context, AppMotion.quick),
      curve: AppMotion.standardCurve,
      child: IgnorePointer(
        ignoring: !controlsVisible,
        child: ExcludeFocus(
          excluding: !controlsVisible,
          child: ExcludeSemantics(
            excluding: !controlsVisible,
            child: Row(
              children: [
                if (!isMiniPlayer && hasLibraryRepository) ...[
                  Focus(
                    onFocusChange: onFocusChange,
                    child: Tooltip(
                      message: 'Mini player',
                      child: IconButton(
                        key: const ValueKey('player-mini-button'),
                        onPressed: onBackToHome,
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 24,
                        ),
                        style: IconButton.styleFrom(
                          foregroundColor: AppTheme.onStage,
                          backgroundColor: AppTheme.stage.withValues(
                            alpha: 0.65,
                          ),
                          side: BorderSide(
                            color: AppTheme.onStage.withValues(alpha: 0.14),
                          ),
                          minimumSize: const Size(38, 38),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    currentTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppTheme.onStage,
                      shadows: const [
                        Shadow(color: AppTheme.stage, blurRadius: 5),
                      ],
                    ),
                  ),
                ),
                if (isMiniPlayer) ...[
                  const SizedBox(width: 12),
                  TextButton.icon(
                    key: const ValueKey('exit-mini-player'),
                    onPressed: onExitMiniPlayer,
                    icon: const Icon(Icons.open_in_full_rounded, size: 20),
                    label: const Text('Exit mini player'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.onStage,
                      backgroundColor: AppTheme.stage.withValues(alpha: 0.65),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
