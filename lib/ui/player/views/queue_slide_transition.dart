import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/app_motion.dart';

/// Shared open/close animation for docked queue panels.
///
/// Owns the [AnimationController], [CurvedAnimation], [AppMotion]-scaled
/// durations, and the post-frame deferred-dismiss callback. Call [drive] when
/// the panel should open or close; stale dismiss callbacks are dropped via an
/// internal generation counter whenever [drive](`true`) runs.
class QueueSlideTransition {
  QueueSlideTransition({
    required TickerProvider vsync,
    required bool initialOpen,
    required this._onDismissed,
  }) : _open = initialOpen {
    controller = AnimationController(
      vsync: vsync,
      duration: AppMotion.panelEnter,
      reverseDuration: AppMotion.panelExit,
      value: initialOpen ? 1.0 : 0.0,
    )..addStatusListener(_handleStatus);
    progress = CurvedAnimation(
      parent: controller,
      curve: AppMotion.panelEnterCurve,
      reverseCurve: AppMotion.exit,
    );
  }

  final VoidCallback _onDismissed;

  late final AnimationController controller;
  late final CurvedAnimation progress;

  int _dismissGeneration = 0;
  bool _open;

  /// Re-read motion settings after [BuildContext] dependencies change.
  void applyMotion(BuildContext context) {
    final reduced = AppMotion.reduce(context);
    controller.duration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.panelEnter);
    controller.reverseDuration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.panelExit);
    if (!reduced) return;
    // An animation already in flight keeps the duration it started with, so a
    // preference change made mid-transition would otherwise run out the old
    // timing. Snap to the requested state instead.
    final target = _open ? 1.0 : 0.0;
    if (controller.value == target && !controller.isAnimating) return;
    controller
      ..stop()
      ..value = target;
  }

  void drive(bool open) {
    _open = open;
    if (open) {
      _dismissGeneration++;
      controller.forward();
    } else {
      controller.reverse();
    }
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    // A zero-length reverse can finish inside the build phase; unmount at the
    // end of the frame instead.
    final generation = _dismissGeneration;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (generation != _dismissGeneration) return;
      _onDismissed();
    });
  }

  void dispose() {
    controller.removeStatusListener(_handleStatus);
    progress.dispose();
    controller.dispose();
  }
}
