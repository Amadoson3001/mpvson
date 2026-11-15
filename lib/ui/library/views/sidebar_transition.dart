import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../core/app_motion.dart';

/// Physics-driven expand/collapse transition for the desktop library sidebar.
///
/// Drives a single continuous `0.0` (collapsed) -> `1.0` (expanded) progress
/// value with a critically damped [SpringSimulation] so width, icons, labels,
/// and the collapse toggle move in lockstep and mid-flight reversals preserve
/// momentum without snapping or jumping.
class SidebarTransition {
  SidebarTransition({
    required TickerProvider vsync,
    required bool initialExpanded,
  }) : _expanded = initialExpanded {
    controller = AnimationController(
      vsync: vsync,
      value: initialExpanded ? 1.0 : 0.0,
    );
  }

  static const Tolerance _springTolerance = Tolerance(
    distance: 0.001,
    velocity: 0.005,
  );

  late final AnimationController controller;

  bool _expanded;
  bool _reduced = false;
  SpringDescription _spring = AppMotion.sidebarSpring;
  int _generation = 0;
  bool _disposed = false;

  Animation<double> get progress => controller;

  bool get targetExpanded => _expanded;

  /// Re-reads reduced-motion and animation-speed preferences from [context].
  void applyMotion(BuildContext context) {
    _reduced = AppMotion.reduce(context);
    _spring = AppMotion.scaledSpring(context, AppMotion.sidebarSpring);
    if (!_reduced) return;

    final target = _expanded ? 1.0 : 0.0;
    if (controller.value == target && !controller.isAnimating) return;
    _generation++;
    controller
      ..stop()
      ..value = target;
  }

  /// Snaps immediately to [expanded] without starting an animation.
  void snap(bool expanded) {
    _expanded = expanded;
    _generation++;
    final target = expanded ? 1.0 : 0.0;
    controller
      ..stop()
      ..value = target;
  }

  /// Animates continuously toward [expanded], preserving current velocity when
  /// reversing mid-flight.
  void drive(bool expanded) {
    final target = expanded ? 1.0 : 0.0;
    if (_expanded == expanded &&
        (controller.isAnimating ||
            (controller.value - target).abs() < 0.0001)) {
      return;
    }
    _expanded = expanded;
    final generation = ++_generation;

    if (_reduced) {
      controller
        ..stop()
        ..value = target;
      return;
    }

    final simulation = SpringSimulation(
      _spring,
      controller.value,
      target,
      controller.velocity,
      tolerance: _springTolerance,
    );
    controller.animateWith(simulation).then((_) {
      if (_disposed || generation != _generation) return;
      if (!controller.isAnimating && controller.value != target) {
        controller.value = target;
      }
    });
  }

  void dispose() {
    _disposed = true;
    _generation++;
    controller.dispose();
  }
}
