import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

class PlayerDragDrop extends StatefulWidget {
  const PlayerDragDrop({
    super.key,
    required this.child,
    required this.enabled,
    required this.onFilesDropped,
    this.onDragStateChanged,
  });

  final Widget child;
  final bool enabled;
  final ValueChanged<List<String>> onFilesDropped;
  final ValueChanged<bool>? onDragStateChanged;

  @override
  State<PlayerDragDrop> createState() => _PlayerDragDropState();
}

class _PlayerDragDropState extends State<PlayerDragDrop> {
  void _setDragging(bool dragging) {
    widget.onDragStateChanged?.call(dragging);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return DropTarget(
      onDragEntered: (_) => _setDragging(true),
      onDragExited: (_) => _setDragging(false),
      onDragDone: (details) {
        _setDragging(false);
        final paths = details.files
            .map((file) => file.path)
            .where((path) => path.isNotEmpty)
            .toList();
        if (paths.isNotEmpty) {
          widget.onFilesDropped(paths);
        }
      },
      child: widget.child,
    );
  }
}

class PlayerDragOverlay extends StatelessWidget {
  const PlayerDragOverlay({super.key, required this.hasMedia});

  final bool hasMedia;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: context.palette.background.withValues(alpha: 0.6),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary,
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          hasMedia
              ? 'Drop videos to add them to the queue'
              : 'Drop a video to start playback',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    ),
  );
}
