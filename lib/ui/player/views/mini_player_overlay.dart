import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../player_controller.dart';

/// Lightweight, hardware-composited touch & click overlay for the docked in-app mini video player.
///
/// Keeps the mini video completely clean and unobstructed (no exit, pause, or enlarge icons),
/// while providing immediate zero-delay tap-to-expand to return to the full player view and
/// a downward flick gesture to dismiss the docked mini player.
class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({
    super.key,
    required this.controller,
    required this.onExpand,
    this.onDismiss,
    this.visualOpacity = 1.0,
  });

  final PlayerController controller;
  final VoidCallback onExpand;
  final VoidCallback? onDismiss;
  final double visualOpacity;

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> {
  bool _hovered = false;
  bool _pressed = false;
  int? _activePointer;
  Offset? _downPosition;
  VelocityTracker? _velocityTracker;

  /// Minimum downward distance and velocity required to dismiss on flick,
  /// avoiding mouse micro-jitter during normal clicks.
  static const double _dismissDistance = 24;
  static const double _dismissVelocity = 700;

  void _resetPointer() {
    _activePointer = null;
    _downPosition = null;
    _velocityTracker = null;
    if (_pressed && mounted) {
      setState(() => _pressed = false);
    } else {
      _pressed = false;
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_activePointer != null || (event.buttons & kPrimaryButton) == 0) {
      return;
    }
    _activePointer = event.pointer;
    _downPosition = event.position;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    if (!_pressed && mounted) {
      setState(() => _pressed = true);
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    final downPos = _downPosition;
    final tracker = _velocityTracker;
    _resetPointer();
    if (widget.onDismiss == null || downPos == null || tracker == null) {
      return;
    }
    final delta = event.position - downPos;
    if (delta.dy >= _dismissDistance &&
        delta.dy > delta.dx.abs() &&
        tracker.getVelocity().pixelsPerSecond.dy > _dismissVelocity) {
      widget.onDismiss!();
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _resetPointer();
  }

  @override
  Widget build(BuildContext context) {
    final opacityScale = widget.visualOpacity.clamp(0.0, 1.0);
    final fillAlpha =
        (_pressed ? 0.22 : (_hovered ? 0.12 : 0.0)) * opacityScale;
    final borderAlpha =
        (_pressed ? 0.45 : (_hovered ? 0.28 : 0.0)) * opacityScale;
    final radius = BorderRadius.circular(AppLayout.dockedMiniVideoRadius);

    return Semantics(
      button: true,
      label: 'Return to video',
      excludeSemantics: true,
      onTap: widget.onExpand,
      child: MouseRegion(
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
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerUp,
            onPointerCancel: _handlePointerCancel,
            // Single-tap only (no onDoubleTap or drag recognizer competing in
            // the arena) so clicks resolve immediately on pointer up without a
            // 300ms double-tap timeout or 1px mouse-slop cancellation.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onExpand,
              child: AnimatedContainer(
                duration: _pressed
                    ? Duration.zero
                    : AppMotion.duration(context, AppMotion.press),
                decoration: BoxDecoration(
                  color: fillAlpha > 0
                      ? (_pressed
                            ? Colors.black.withValues(alpha: fillAlpha)
                            : Colors.white.withValues(alpha: fillAlpha))
                      : Colors.transparent,
                  borderRadius: radius,
                  border: borderAlpha > 0
                      ? Border.all(
                          color: Colors.white.withValues(alpha: borderAlpha),
                          width: 1,
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
