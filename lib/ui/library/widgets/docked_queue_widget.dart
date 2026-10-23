import 'package:flutter/material.dart';
import '../../player/player_controller.dart';
import '../theme/library_theme.dart';

/// Reusable docked queue panel for desktop layouts and drawers.
class DockedQueueWidget extends StatelessWidget {
  const DockedQueueWidget({super.key, required this.controller, this.onClose});

  final PlayerController controller;
  final VoidCallback? onClose;

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final queue = controller.queue;
        final currentIndex = controller.currentIndex;

        return Container(
          color: LibraryTheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                color: LibraryTheme.surface,
                child: Row(
                  children: [
                    const Icon(
                      Icons.queue_music_rounded,
                      size: 18,
                      color: LibraryTheme.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Queue (${queue.length})',
                        style: LibraryTheme.sectionTitle.copyWith(fontSize: 15),
                      ),
                    ),
                    if (onClose != null)
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        tooltip: 'Close queue',
                        visualDensity: VisualDensity.compact,
                        color: LibraryTheme.mutedText,
                        onPressed: onClose,
                      ),
                  ],
                ),
              ),
              const Divider(height: 1, color: LibraryTheme.border),
              // Queue Entries
              Expanded(
                child: queue.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Queue is empty',
                            style: LibraryTheme.metadata,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: queue.length,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          color: LibraryTheme.raisedSurface,
                        ),
                        itemBuilder: (context, index) {
                          final item = queue[index];
                          final isCurrent = index == currentIndex;

                          return InkWell(
                            onTap: () => controller.playIndex(index),
                            hoverColor: LibraryTheme.hover,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              color: isCurrent
                                  ? LibraryTheme.accent.withValues(alpha: 0.1)
                                  : Colors.transparent,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 24,
                                    child: isCurrent && controller.isPlaying
                                        ? const Icon(
                                            Icons.volume_up_rounded,
                                            size: 14,
                                            color: LibraryTheme.accent,
                                          )
                                        : Text(
                                            '${index + 1}',
                                            style: LibraryTheme.metadata
                                                .copyWith(
                                                  color: isCurrent
                                                      ? LibraryTheme.accent
                                                      : LibraryTheme.mutedText,
                                                ),
                                          ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          item.title,
                                          style: LibraryTheme.rowPrimary
                                              .copyWith(
                                                fontSize: 13,
                                                color: isCurrent
                                                    ? LibraryTheme.accent
                                                    : LibraryTheme.primaryText,
                                                fontWeight: isCurrent
                                                    ? FontWeight.w600
                                                    : FontWeight.normal,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (item.duration > Duration.zero) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            _formatDuration(item.duration),
                                            style: LibraryTheme.metadata
                                                .copyWith(fontSize: 11),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 14,
                                    ),
                                    tooltip: 'Remove',
                                    visualDensity: VisualDensity.compact,
                                    color: LibraryTheme.mutedText,
                                    hoverColor: LibraryTheme.hover,
                                    onPressed: () => controller.removeAt(index),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
