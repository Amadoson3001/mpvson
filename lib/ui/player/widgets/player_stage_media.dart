import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../player_controller.dart';
import 'empty_library.dart';
import 'media_ready.dart';

/// Empty, ready, audio, and video surfaces for [PlayerStage].
///
/// Built once per stage rebuild so mini-player animation ticks can reuse the
/// video child instead of reconstructing it.
({String state, Widget surface}) buildPlayerStageMedia({
  required BuildContext context,
  required PlayerController controller,
  required Widget Function(BuildContext context, PlayerController controller)
  videoBuilder,
  required VoidCallback onOpenFiles,
  required VoidCallback onOpenUrl,
  required ValueChanged<MediaEntry> onOpenRecent,
  required bool draggingFiles,
  required VoidCallback? onOpenLibrary,
}) {
  final current = controller.current;
  final audioEntry =
      controller.isAudio ||
      (current != null && MediaCatalog.kindFromExtension(current.path).isAudio);

  if (current == null) {
    return (
      state: 'empty',
      surface: Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: EmptyLibrary(
          recent: controller.recent,
          onOpenFiles: onOpenFiles,
          onOpenUrl: onOpenUrl,
          onOpenRecent: onOpenRecent,
          onRemoveRecent: (MediaEntry entry) {
            final restored = controller.removeRecent(entry);
            if (restored != null && context.mounted) {
              AppToast.show(
                context,
                'Removed from recently played',
                actionLabel: 'Undo',
                onAction: () =>
                    controller.restoreRecent(restored.$1, restored.$2),
              );
            }
          },
          isDragging: draggingFiles,
          onOpenLibrary: onOpenLibrary,
        ),
      ),
    );
  }
  if (!controller.hasMedia) {
    return (
      state: 'ready',
      surface: Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            controller.displayPositionListenable,
            controller.durationListenable,
            controller.bufferingListenable,
          ]),
          builder: (context, _) => MediaReady(
            entry: controller.current ?? current,
            position: controller.displayPosition,
            duration: controller.duration,
            isOpening: controller.isBuffering,
            onPlay: () => unawaited(controller.togglePlayPause()),
          ),
        ),
      ),
    );
  }
  if (audioEntry) {
    return (state: 'audio', surface: const ColoredBox(color: AppTheme.stage));
  }
  return (state: 'video', surface: videoBuilder(context, controller));
}
