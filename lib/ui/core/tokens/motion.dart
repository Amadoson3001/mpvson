import 'package:flutter/material.dart';

/// Shared timing and reduced-motion behavior for the desktop interface.
abstract final class AppMotion {
  static const Duration instant = Duration.zero;
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 120);
  static const Duration emphasized = Duration(milliseconds: 380);
  static const Duration reveal = Duration(milliseconds: 120);

  /// Slide and fade used by toasts entering and leaving a corner.
  static const Duration toast = Duration(milliseconds: 220);
  static const Duration press = Duration(milliseconds: 90);
  static const Duration hover = Duration(milliseconds: 140);
  static const Duration stage = Duration(milliseconds: 160);

  /// Sheet expansion and collapse timings for Now Playing morph transition.
  static const Duration sheetEnter = Duration(milliseconds: 320);
  static const Duration sheetExit = Duration(milliseconds: 260);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;

  /// Ultra-smooth sheet deceleration curve (fast start, cushioned arrival).
  static const Curve sheetEnterCurve = Cubic(0.12, 1.0, 0.24, 1.0);

  /// Snappy departure curve for collapsing sheets.
  static const Curve sheetExitCurve = Cubic(0.38, 0.0, 0.85, 0.25);

  /// The balanced curve used by standard transitions.
  ///
  /// `standard` is reserved for the standard duration above; a distinct name
  /// avoids a collision between a [Duration] and a [Curve] in Dart.
  static const Curve standardCurve = Curves.easeInOutCubic;

  static bool reduce(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  static Duration duration(BuildContext context, Duration preferred) =>
      reduce(context) ? instant : preferred;

  /// Composited shared-axis transition (fade + micro vertical glide) for stage/view swaps.
  static Widget stageTransition(
    BuildContext context,
    Widget child,
    Animation<double> animation,
  ) {
    if (reduce(context)) return child;
    final curved = CurvedAnimation(parent: animation, curve: enter);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// A single, restrained aperture reveal for a newly presented screen surface.
///
/// The child is revealed once over [duration], fading in while scaling from
/// [beginScale] to its natural size. Reduced-motion settings render the child
/// directly, with no opacity or transform animation.
class AppMotionReveal extends StatefulWidget {
  const AppMotionReveal({
    super.key,
    required this.child,
    this.duration = AppMotion.reveal,
    this.beginScale = 0.985,
  });

  final Widget child;
  final Duration duration;
  final double beginScale;

  @override
  State<AppMotionReveal> createState() => _AppMotionRevealState();
}

class _AppMotionRevealState extends State<AppMotionReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _curved = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.enter,
  );
  bool _hasStarted = false;
  bool _reducedMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = AppMotion.reduce(context);
    _controller.duration = AppMotion.duration(context, widget.duration);

    if (_reducedMotion) {
      _controller.stop();
      _controller.value = 1;
      _hasStarted = true;
    } else if (!_hasStarted) {
      _hasStarted = true;
      _controller.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant AppMotionReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = AppMotion.duration(context, widget.duration);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reducedMotion) return widget.child;

    return AnimatedBuilder(
      animation: _curved,
      child: widget.child,
      builder: (context, child) {
        final progress = _curved.value;
        final scale = widget.beginScale + (1 - widget.beginScale) * progress;

        return FadeTransition(
          opacity: _curved,
          // Keep controls usable during the brief opening fade.
          alwaysIncludeSemantics: true,
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}
