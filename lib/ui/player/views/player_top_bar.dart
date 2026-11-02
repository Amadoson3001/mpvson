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
  Widget build(BuildContext context) => Positioned(
    left: 16,
    top: 12,
    right: 24,
    child: MouseRegion(
      onEnter: (_) => onPointerEnter(),
      onExit: (_) => onPointerExit(),
      child: AnimatedOpacity(
        duration: AppMotion.duration(context, AppMotion.quick),
        opacity: controlsVisible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !controlsVisible,
          child: Row(
            children: [
              if (!isMiniPlayer && hasLibraryRepository) ...[
                Focus(
                  onFocusChange: onFocusChange,
                  child: TextButton.icon(
                    onPressed: onBackToHome,
                    icon: const Icon(Icons.arrow_back_rounded, size: 20),
                    label: const Text('Home'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.onStage,
                      backgroundColor: AppTheme.stage.withValues(alpha: 0.65),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
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
  );
}
