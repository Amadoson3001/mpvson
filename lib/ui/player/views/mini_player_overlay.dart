import 'package:flutter/material.dart';

import '../player_controller.dart';

/// Lightweight, hardware-composited touch & click overlay for the docked in-app mini video player.
///
/// Keeps the mini video completely clean and unobstructed (no exit, pause, or enlarge icons),
/// while providing click/tap-to-expand to smoothly return to the full player view.
class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({
    super.key,
    required this.controller,
    required this.onExpand,
    this.onDismiss,
  });

  final PlayerController controller;
  final VoidCallback onExpand;
  final VoidCallback? onDismiss;

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered && mounted) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered && mounted) setState(() => _hovered = false);
      },
      child: Tooltip(
        message: 'Return to video',
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onExpand,
          onDoubleTap: widget.onExpand,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            color: _hovered
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}
