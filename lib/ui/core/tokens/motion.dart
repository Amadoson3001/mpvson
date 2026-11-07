import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'motion_stub.dart' if (dart.library.io) 'motion_io.dart';

/// Shared timing and reduced-motion behavior for the desktop interface.
abstract final class AppMotion {
  static const Duration instant = Duration.zero;
  static const Duration quick = Duration(milliseconds: 90);
  static const Duration standard = Duration(milliseconds: 150);
  static const Duration emphasized = Duration(milliseconds: 240);
  static const Duration reveal = Duration(milliseconds: 160);

  /// Slide and fade used by toasts entering and leaving a corner.
  static const Duration toast = Duration(milliseconds: 180);
  static const Duration press = Duration(milliseconds: 80);
  static const Duration hover = Duration(milliseconds: 120);
  static const Duration stage = Duration(milliseconds: 140);

  /// Sheet expansion and collapse timings for Now Playing morph transition.
  static const Duration sheetEnter = Duration(milliseconds: 240);
  static const Duration sheetExit = Duration(milliseconds: 200);

  /// Start scale for the dialog morph. The surface grows from the trigger
  /// point without any cross-fade of its content.
  static const double dialogMorphBeginScale = 0.86;

  static const Curve enter = Cubic(0.16, 1, 0.3, 1);
  static const Curve exit = Cubic(0.4, 0, 1, 1);

  /// Ultra-smooth sheet deceleration curve (fast start, cushioned arrival).
  static const Curve sheetEnterCurve = Cubic(0.12, 1.0, 0.24, 1.0);

  /// Snappy departure curve for collapsing sheets.
  static const Curve sheetExitCurve = Cubic(0.38, 0.0, 0.85, 0.25);

  /// The balanced curve used by standard transitions.
  ///
  /// `standard` is reserved for the standard duration above; a distinct name
  /// avoids a collision between a [Duration] and a [Curve] in Dart.
  static const Curve standardCurve = Curves.easeOutCubic;

  static final bool _constrainedHardware = _detectConstrainedHardware();

  static bool _detectConstrainedHardware() {
    if (kIsWeb) return false;
    return detectConstrainedHardware();
  }

  static bool reduce(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// Reduced motion or a low-core machine. Decorative scale, blur and
  /// multi-layer transitions can be skipped without changing layout.
  static bool lowPower(BuildContext context) =>
      reduce(context) || _constrainedHardware;

  static Duration duration(BuildContext context, Duration preferred) =>
      reduce(context) ? instant : preferred;

  /// Composited shared-axis transition (fade + micro vertical glide) for stage/view swaps.
  ///
  /// The curve is applied with a [CurveTween], which wraps the incoming route
  /// animation without registering listeners on it. Building a
  /// [CurvedAnimation] here instead would attach one that nothing ever
  /// detaches, leaking a listener per stage change.
  static Widget stageTransition(
    BuildContext context,
    Widget child,
    Animation<double> animation,
  ) {
    if (lowPower(context)) return child;
    final curved = CurveTween(curve: enter).animate(animation);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.015),
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
/// [beginScale] to its natural size. Reduced-motion or low-power settings
/// render the child directly, with no opacity or transform animation.
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
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.enter,
  );
  bool _hasStarted = false;
  bool _skipMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _skipMotion = AppMotion.lowPower(context);
    _controller.duration = AppMotion.duration(context, widget.duration);

    if (_skipMotion) {
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
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_skipMotion) return widget.child;

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

/// Opens a modal dialog with the app's morph presentation.
///
/// The surface grows out of [anchor] — the global-coordinates origin of the
/// widget that triggered the dialog — with a pure scale transition. The dialog
/// itself never cross-fades; only the scrim behind it fades. When [anchor] is
/// omitted the surface scales up from its own center.
Future<T?> showMorphDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Offset? anchor,
  bool barrierDismissible = true,
  Color barrierColor = Colors.black54,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel:
        Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        )?.modalBarrierDismissLabel ??
        'Close dialog',
    transitionDuration: AppMotion.emphasized,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      if (AppMotion.lowPower(context)) return child;
      return _MorphDialogTransition(
        animation: animation,
        anchor: anchor,
        child: child,
      );
    },
  );
}

class _MorphDialogTransition extends StatefulWidget {
  const _MorphDialogTransition({
    required this.animation,
    required this.anchor,
    required this.child,
  });

  final Animation<double> animation;
  final Offset? anchor;
  final Widget child;

  @override
  State<_MorphDialogTransition> createState() => _MorphDialogTransitionState();
}

class _MorphDialogTransitionState extends State<_MorphDialogTransition> {
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: widget.animation,
    curve: AppMotion.enter,
    reverseCurve: AppMotion.exit,
  );

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      child: widget.child,
      builder: (context, child) {
        final begin = AppMotion.dialogMorphBeginScale;
        return Transform.scale(
          scale: begin + (1 - begin) * _curved.value,
          // The transition fills the whole window, so a global anchor is
          // already in this transform's local space.
          origin: widget.anchor,
          alignment: widget.anchor == null ? Alignment.center : null,
          child: child,
        );
      },
    );
  }
}
