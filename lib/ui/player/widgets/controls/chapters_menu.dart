import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../domain/models/playback_chapter.dart';
import '../../../../ui/core/app_theme.dart';
import '../../../../utils/format.dart';
import '../../player_controller.dart';
import '../player_control_style.dart';

/// Quick chapter jump selector displayed when the active media exposes chapters.
class ChaptersMenu extends StatelessWidget {
  const ChaptersMenu({
    super.key,
    required this.controller,
    required this.onMenuVisibilityChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onMenuVisibilityChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PlaybackChapter>>(
      valueListenable: controller.chaptersListenable,
      builder: (context, chapters, _) {
        if (chapters.isEmpty) return const SizedBox.shrink();
        final sizing = PlayerControlStyle.of(context);
        final accent = Theme.of(context).colorScheme.primary;
        final activeIndex = _activeChapterIndex(
          chapters,
          controller.displayPosition,
        );

        return Semantics(
          label: 'Chapters, ${chapters.length}',
          button: true,
          child: PopupMenuButton<Duration>(
            key: const ValueKey('chapters-menu-button'),
            tooltip: 'Chapters',
            padding: EdgeInsets.zero,
            position: PopupMenuPosition.over,
            style: sizing.buttonStyle,
            iconSize: sizing.iconSize,
            icon: const Icon(Icons.format_list_bulleted_rounded),
            constraints: const BoxConstraints(minWidth: 260, maxWidth: 340),
            onOpened: () => onMenuVisibilityChanged?.call(true),
            onCanceled: () => onMenuVisibilityChanged?.call(false),
            onSelected: (start) {
              onMenuVisibilityChanged?.call(false);
              unawaited(controller.seek(start));
            },
            itemBuilder: (context) => [
              PopupMenuItem<Duration>(
                enabled: false,
                height: 28,
                child: Text(
                  'Chapters (${chapters.length})',
                  style: context.palette.metadata.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.palette.mutedText,
                  ),
                ),
              ),
              for (var i = 0; i < chapters.length; i++)
                PopupMenuItem<Duration>(
                  value: chapters[i].start,
                  child: Row(
                    children: [
                      SizedBox(
                        width: chapters[i].start.inHours > 0 ? 58 : 44,
                        child: Text(
                          formatTime(chapters[i].start, compactMinutes: true),
                          style: context.palette.metadata.copyWith(
                            color: i == activeIndex
                                ? accent
                                : context.palette.mutedText,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          chapters[i].title.trim().isNotEmpty
                              ? chapters[i].title.trim()
                              : 'Chapter ${i + 1}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: i == activeIndex
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (i == activeIndex) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.check_rounded, size: 17, color: accent),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static int _activeChapterIndex(
    List<PlaybackChapter> chapters,
    Duration position,
  ) {
    var active = -1;
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].start > position) break;
      active = i;
    }
    return active;
  }
}
