import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'motion.dart';

/// Shared physics-driven `0.0 <-> 1.0` transition coordinator.
///
/// Uses critically damped [SpringSimulation]s so panels, drawers, sheets, and
/// docked surfaces preserve velocity across rapid mid-flight reversals without
/// jumping, overshooting, or leaving stale dismissal callbacks behind.
class SpringMotionController {
  SpringMotionController({
    required TickerProvider vsync,
    required bool initialForward,
    required this.forwardSpring,
    SpringDescription? reverseSpring,
    this.tolerance = const Tolerance(distance: 0.002, velocity: 0.01),
    this.onDismissed,
    this.onCompleted,
    this.onAnimatingChanged,
  }) : reverseSpring = reverseSpring ?? forwardSpring,
       _targetForward = initialForward,
       _scaledForward = forwardSpring,
       _scaledReverse = reverseSpring ?? forwardSpring {
    controller = AnimationController(
      vsync: vsync,
      value: initialForward ? 1.0 : 0.0,
    );
  }

  /// Spring used when driving toward `1.0`.
  final SpringDescription forwardSpring;

  /// Spring used when driving toward `0.0`. Defaults to [forwardSpring].
  final SpringDescription reverseSpring;

  /// Resting tolerance for the underlying [SpringSimulation].
  final Tolerance tolerance;

  /// Invoked post-frame when a reverse transition settles at `0.0`.
  final VoidCallback? onDismissed;

  /// Invoked when a forward transition settles at `1.0`.
  final VoidCallback? onCompleted;

  /// Invoked only when the active animation state flips between idle and running.
  final ValueChanged<bool>? onAnimatingChanged;

  late final AnimationController controller;

  bool _targetForward;
  bool _reduced = false;
  SpringDescription _scaledForward;
  SpringDescription _scaledReverse;
  int _generation = 0;
  int _dismissGeneration = 0;
  bool _disposed = false;
  bool _isAnimatingNotified = false;
  Completer<void>? _activeCompleter;

  Animation<double> get progress => controller;

  double get value => controller.value;

  bool get isAnimating => controller.isAnimating;

  bool get targetForward => _targetForward;

  /// Re-reads reduced-motion and animation-speed preferences from [context].
  void applyMotion(BuildContext context) {
    if (_disposed) return;
    _reduced = AppMotion.reduce(context);
    _scaledForward = AppMotion.scaledSpring(context, forwardSpring);
    _scaledReverse = AppMotion.scaledSpring(context, reverseSpring);
    if (!_reduced) return;

    final target = _targetForward ? 1.0 : 0.0;
    final alreadyAtTarget =
        (controller.value - target).abs() < 0.0001 && !controller.isAnimating;
    if (alreadyAtTarget) {
      if (controller.value != target) controller.value = target;
      _setAnimating(false);
      return;
    }

    _generation++;
    final completer = _activeCompleter;
    _activeCompleter = null;
    controller
      ..stop()
      ..value = target;
    _setAnimating(false);
    if (_targetForward) {
      onCompleted?.call();
    } else {
      _scheduleDismissed();
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Snaps immediately to [forward] without starting an animation or triggering
  /// completion/dismiss callbacks.
  void snap(bool forward) {
    if (_disposed) return;
    _targetForward = forward;
    _generation++;
    if (forward) _dismissGeneration++;
    final completer = _activeCompleter;
    _activeCompleter = null;
    controller
      ..stop()
      ..value = forward ? 1.0 : 0.0;
    _setAnimating(false);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Drives continuously toward [forward], preserving momentum if reversing
  /// mid-flight.
  Future<void> drive(bool forward) {
    if (_disposed) return Future<void>.value();

    final target = forward ? 1.0 : 0.0;
    if (_targetForward == forward) {
      if (controller.isAnimating && _activeCompleter != null) {
        return _activeCompleter!.future;
      }
      if (!controller.isAnimating &&
          (controller.value - target).abs() < 0.0001) {
        if (controller.value != target) controller.value = target;
        return Future<void>.value();
      }
    }

    _targetForward = forward;
    final generation = ++_generation;
    if (forward) _dismissGeneration++;

    final previousCompleter = _activeCompleter;
    if (previousCompleter != null && !previousCompleter.isCompleted) {
      previousCompleter.complete();
    }

    if (_reduced) {
      _activeCompleter = null;
      controller
        ..stop()
        ..value = target;
      _setAnimating(false);
      if (forward) {
        onCompleted?.call();
      } else {
        _scheduleDismissed();
      }
      return Future<void>.value();
    }

    final completer = Completer<void>();
    _activeCompleter = completer;

    final spring = forward ? _scaledForward : _scaledReverse;
    final simulation = SpringSimulation(
      spring,
      controller.value,
      target,
      controller.velocity,
      tolerance: tolerance,
    );
    _setAnimating(true);
    controller.animateWith(simulation).then((_) {
      if (_disposed || generation != _generation) return;
      if (identical(_activeCompleter, completer)) {
        _activeCompleter = null;
      }
      if (!controller.isAnimating && controller.value != target) {
        controller.value = target;
      }
      _setAnimating(false);
      if (forward) {
        onCompleted?.call();
      } else {
        _scheduleDismissed();
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  void _setAnimating(bool animating) {
    if (_isAnimatingNotified == animating) return;
    _isAnimatingNotified = animating;
    onAnimatingChanged?.call(animating);
  }

  void _scheduleDismissed() {
    final callback = onDismissed;
    if (callback == null) return;
    final dismissGen = _dismissGeneration;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_disposed || dismissGen != _dismissGeneration || _targetForward) {
        return;
      }
      callback();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _dismissGeneration++;
    _setAnimating(false);
    final completer = _activeCompleter;
    _activeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    controller.dispose();
  }
}
