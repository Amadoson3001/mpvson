import 'package:flutter/material.dart';

import '../../../domain/models/media_entry.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../player_controller.dart';
import 'player_control_style.dart';

/// Secondary player actions share the bottom playback strip.
class PlayerActions extends StatelessWidget {
  const PlayerActions({
    super.key,
    required this.controller,
    required this.onOpenFiles,
    required this.onOpenUrl,
    required this.onOpenRecent,
    required this.onToggleQueue,
    required this.onSettings,
    required this.onMenuVisibilityChanged,
    required this.queueOpen,
    this.onFullscreen,
    this.onPlaybackInfo,
    this.isFullscreen = false,
  });

  final PlayerController controller;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final ValueChanged<MediaEntry> onOpenRecent;
  final VoidCallback onToggleQueue;
  final VoidCallback onSettings;
  final ValueChanged<bool> onMenuVisibilityChanged;
  final bool queueOpen;
  final VoidCallback? onFullscreen;
  final VoidCallback? onPlaybackInfo;
  final bool isFullscreen;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        label:
            'Queue, ${controller.queue.length} ${controller.queue.length == 1 ? 'video' : 'videos'}',
        button: true,
        child: IconButton(
          tooltip: 'Queue (${controller.queue.length})',
          isSelected: queueOpen,
          style: PlayerControlStyle.of(context).buttonStyle.copyWith(
            animationDuration: AppMotion.duration(context, AppMotion.quick),
          ),
          onPressed: onToggleQueue,
          icon: Badge(
            isLabelVisible: controller.queue.isNotEmpty,
            label: Text('${controller.queue.length}'),
            child: Icon(
              Icons.playlist_play_rounded,
              size: PlayerControlStyle.of(context).iconSize,
            ),
          ),
        ),
      ),
      PopupMenuButton<Object>(
        key: const ValueKey('player-more'),
        tooltip: 'More options',
        padding: EdgeInsets.zero,
        style: PlayerControlStyle.of(context).buttonStyle,
        iconSize: PlayerControlStyle.of(context).iconSize,
        icon: const Icon(Icons.more_horiz_rounded),
        position: PopupMenuPosition.over,
        constraints: const BoxConstraints(minWidth: 260, maxWidth: 320),
        onOpened: () => onMenuVisibilityChanged(true),
        onCanceled: () => onMenuVisibilityChanged(false),
        onSelected: _select,
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'files',
            child: _ActionItem(
              icon: Icons.folder_open_rounded,
              label: 'Open files',
              shortcut: 'Ctrl+O',
            ),
          ),
          const PopupMenuItem(
            value: 'url',
            child: _ActionItem(
              icon: Icons.link_rounded,
              label: 'Open URL',
              shortcut: 'Ctrl+L',
            ),
          ),
          const PopupMenuDivider(),
          if (onPlaybackInfo != null)
            const PopupMenuItem(
              value: 'playback-info',
              child: _ActionItem(
                icon: Icons.query_stats_rounded,
                label: 'Playback information',
                shortcut: 'I',
              ),
            ),
          const PopupMenuItem(
            value: 'settings',
            child: _ActionItem(
              icon: Icons.settings_outlined,
              label: 'Settings',
            ),
          ),
          if (controller.recent.isNotEmpty) ...[
            const PopupMenuDivider(),
            PopupMenuItem(
              enabled: false,
              height: 32,
              child: Text(
                'Recent files',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final entry in controller.recent.take(3))
              PopupMenuItem(
                value: entry,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (entry.position > Duration.zero)
                      Text(
                        'Resume at ${_formatTime(entry.position)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
      if (onFullscreen != null)
        IconButton(
          tooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
          onPressed: onFullscreen,
          style: PlayerControlStyle.of(context).buttonStyle,
          icon: Icon(
            isFullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            size: PlayerControlStyle.of(context).iconSize,
          ),
        ),
    ],
  );

  void _select(Object value) {
    onMenuVisibilityChanged(false);
    if (value is MediaEntry) {
      onOpenRecent(value);
      return;
    }
    switch (value) {
      case 'files':
        onOpenFiles();
      case 'url':
        onOpenUrl();
      case 'settings':
        onSettings();
      case 'playback-info':
        onPlaybackInfo?.call();
    }
  }

  static String _formatTime(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return value.inHours > 0
        ? '${value.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }
}

class _ActionItem extends StatelessWidget {
  const _ActionItem({required this.icon, required this.label, this.shortcut});
  final IconData icon;
  final String label;
  final String? shortcut;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 19, color: AppTheme.secondaryText),
      const SizedBox(width: 12),
      Expanded(child: Text(label)),
      if (shortcut != null) ...[
        const SizedBox(width: 16),
        Text(shortcut!, style: Theme.of(context).textTheme.labelSmall),
      ],
    ],
  );
}
