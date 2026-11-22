import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/app_motion.dart';

/// Shared physics-driven open/close animation for docked queue panels.
///
/// Delegates to [SpringMotionController] so wide inline slots and narrow
/// drawers preserve physical inertia across rapid open/close reversals and
/// drop stale post-frame dismissal callbacks automatically.
class QueueSlideTransition {
  QueueSlideTransition({
    required TickerProvider vsync,
    required bool initialOpen,
    required VoidCallback onDismissed,
    ValueChanged<bool>? onAnimatingChanged,
  }) : _spring = SpringMotionController(
         vsync: vsync,
         initialForward: initialOpen,
         forwardSpring: AppMotion.panelSpring,
         reverseSpring: AppMotion.panelSpring,
         tolerance: const Tolerance(distance: 0.002, velocity: 0.01),
         onDismissed: onDismissed,
         onAnimatingChanged: onAnimatingChanged,
       );

  final SpringMotionController _spring;

  AnimationController get controller => _spring.controller;
  Animation<double> get progress => _spring.progress;

  /// Re-read motion settings after [BuildContext] dependencies change.
  void applyMotion(BuildContext context) => _spring.applyMotion(context);

  void drive(bool open) => unawaited(_spring.drive(open));

  void dispose() => _spring.dispose();
}
