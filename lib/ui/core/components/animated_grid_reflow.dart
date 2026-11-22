import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import '../app_motion.dart';
import 'stable_width_box.dart';

/// Exposes a shell pane's live width-transition state (sidebar / docked queue)
/// to descendant grids without rebuilding the intermediate widget subtree on
/// every animation tick.
class ShellWidthMotionScope extends InheritedWidget {
  const ShellWidthMotionScope({
    super.key,
    required this.listenable,
    required this.pendingWidthDelta,
    required this.columnBasisWidth,
    required super.child,
  });

  /// Fires on every frame while a neighbouring pane (sidebar or docked queue)
  /// is animating its width.
  final Listenable listenable;

  /// Returns `settledContentWidth - currentContentWidth` (`0.0` at rest).
  final double Function() pendingWidthDelta;

  /// Window-anchored width used to determine grid column counts so toggling
  /// the sidebar lets cards smoothly breathe in place without reshuffling rows.
  final double columnBasisWidth;

  static ShellWidthMotionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellWidthMotionScope>();

  @override
  bool updateShouldNotify(ShellWidthMotionScope oldWidget) =>
      listenable != oldWidget.listenable ||
      (columnBasisWidth - oldWidget.columnBasisWidth).abs() >= 0.5;
}

/// Fixed-column grid geometry used to compute exact cell rects for FLIP reflow.
@immutable
class GridReflowMetrics {
  const GridReflowMetrics({
    required this.columns,
    required this.itemWidth,
    required this.itemHeight,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
    this.horizontalPadding = 0.0,
  });

  final int columns;
  final double itemWidth;
  final double itemHeight;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final double horizontalPadding;

  Rect rectFor(int index) {
    final safeColumns = columns < 1 ? 1 : columns;
    final col = index % safeColumns;
    final row = index ~/ safeColumns;
    return Rect.fromLTWH(
      horizontalPadding + col * (itemWidth + crossAxisSpacing),
      row * (itemHeight + mainAxisSpacing),
      itemWidth,
      itemHeight,
    );
  }
}

typedef _RectResolver = Rect Function(int index);

/// Combines a settled-width layout box with GPU-composited FLIP reflow driven
/// in 100% lockstep with [ShellWidthMotionScope] (sidebar / docked queue).
///
/// While a neighbouring pane animates:
/// - The inner grid is laid out **once** on frame 0 at its settled target width
///   (zero per-frame card relayouts and zero per-frame Skia re-rasterizations).
/// - Every card immediately starts gliding and scaling on frame 0 from its
///   exact previous rect into its new slot in lockstep with the sidebar spring
///   (zero mid-flight column-count delay and zero trailing second spring).
/// - Outside of shell-pane motion (e.g. OS window resize), column-count changes
///   still animate smoothly via [GridReflowScope]'s own spring.
class StableGridReflowBox extends StatefulWidget {
  const StableGridReflowBox({
    super.key,
    required this.metricsBuilder,
    required this.builder,
    this.scrollController,
  });

  /// Computes grid metrics from the settled [layoutWidth] (for card sizing)
  /// and window-anchored [columnBasisWidth] (for stable column count).
  final GridReflowMetrics Function(double layoutWidth, double columnBasisWidth)
  metricsBuilder;
  final Widget Function(
    BuildContext context,
    GridReflowMetrics metrics,
    bool isReflowing,
  )
  builder;
  final ScrollController? scrollController;

  @override
  State<StableGridReflowBox> createState() => _StableGridReflowBoxState();
}

class _StableGridReflowBoxState extends State<StableGridReflowBox> {
  ShellWidthMotionScope? _scope;
  late final _GridReflowController _reflowController = _GridReflowController(
    initialMetrics: const GridReflowMetrics(
      columns: 1,
      itemWidth: 1,
      itemHeight: 1,
      crossAxisSpacing: 0,
      mainAxisSpacing: 0,
    ),
  );

  bool _initialized = false;
  bool _skipMotion = false;
  double _lastTargetWidth = 0.0;
  double _initialDelta = 0.0;
  GridReflowMetrics? _lastMetrics;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _skipMotion = AppMotion.lowPower(context);
    final nextScope = ShellWidthMotionScope.maybeOf(context);
    if (!identical(_scope, nextScope)) {
      _scope?.listenable.removeListener(_onShellMotionTick);
      _scope = nextScope;
      _scope?.listenable.addListener(_onShellMotionTick);
    }
    if (_skipMotion && _reflowController.isReflowing) {
      _initialDelta = 0.0;
      _reflowController.settle();
    }
  }

  @override
  void dispose() {
    _scope?.listenable.removeListener(_onShellMotionTick);
    _reflowController.dispose();
    super.dispose();
  }

  void _onShellMotionTick() {
    if (!mounted) return;
    final delta = _skipMotion ? 0.0 : (_scope?.pendingWidthDelta() ?? 0.0);
    if (delta.abs() < 0.05) {
      if (_initialDelta != 0.0 || _reflowController.isReflowing) {
        _initialDelta = 0.0;
        _reflowController.settle();
      }
      return;
    }

    if (_initialDelta.abs() > 0.05) {
      final p = (1.0 - (delta / _initialDelta)).clamp(0.0, 1.0);
      _reflowController.setProgress(p);
    }
  }

  double _currentScrollOffset() {
    final sc = widget.scrollController;
    if (sc == null || !sc.hasClients) return 0.0;
    return sc.position.pixels;
  }

  Widget _buildInnerGrid(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final targetWidth = constraints.maxWidth;
        final delta = _skipMotion ? 0.0 : (_scope?.pendingWidthDelta() ?? 0.0);
        final columnBasis = _scope?.columnBasisWidth ?? targetWidth;
        final metrics = widget.metricsBuilder(targetWidth, columnBasis);

        if (!_initialized) {
          _initialized = true;
          _lastTargetWidth = targetWidth;
          _lastMetrics = metrics;
          _reflowController.updateLiveMetrics(metrics);
        } else {
          final targetChanged = (targetWidth - _lastTargetWidth).abs() >= 0.5;
          if (targetChanged && delta.abs() >= 0.5 && !_skipMotion) {
            final fromMetrics = _lastMetrics ?? metrics;
            final offsetBefore = _currentScrollOffset();
            _initialDelta = delta;
            _reflowController.beginReflow(
              fromMetrics: fromMetrics,
              toMetrics: metrics,
            );
            if (widget.scrollController != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || !_reflowController.isReflowing) return;
                final scrollDelta = offsetBefore - _currentScrollOffset();
                if (scrollDelta.abs() > 0.5) {
                  _reflowController.setScrollDelta(scrollDelta);
                }
              });
            }
          } else if (delta.abs() < 0.05) {
            _initialDelta = 0.0;
            _reflowController
              ..updateLiveMetrics(metrics)
              ..settle();
          } else {
            _reflowController.updateLiveMetrics(metrics);
          }

          _lastTargetWidth = targetWidth;
          _lastMetrics = metrics;
        }

        // Rebuild GridView only when reflowing flips false <-> true so
        // clipBehavior switches to Clip.none while cards glide across the
        // target width boundary (outer ClipRect still clips cleanly at live
        // slot bounds), with zero GridView rebuilds on intermediate ticks.
        return ValueListenableBuilder<bool>(
          valueListenable: _reflowController.reflowingListenable,
          builder: (context, isShellReflowing, _) {
            return _GridReflowInherited(
              controller: _reflowController,
              child: GridReflowScope(
                metrics: metrics,
                scrollController: widget.scrollController,
                bypassWhenParentReflowing: isShellReflowing,
                child: widget.builder(context, metrics, isShellReflowing),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final inner = _buildInnerGrid(context);
    final scope = _scope;
    if (scope == null) {
      return ClipRect(child: inner);
    }
    return ClipRect(
      child: AnimatedBuilder(
        animation: scope.listenable,
        child: inner,
        builder: (context, child) => StableWidthBox(
          widthDelta: _skipMotion ? 0.0 : scope.pendingWidthDelta(),
          child: child,
        ),
      ),
    );
  }
}

/// Gives fixed-column grids a featherlight, single-layer settle when the OS
/// window resizes across a column-count breakpoint (e.g. maximize/restore
/// switching 4 ↔ 5 columns), without heavy per-card diagonal flight.
class GridReflowScope extends StatefulWidget {
  const GridReflowScope({
    super.key,
    required this.metrics,
    required this.child,
    this.scrollController,
    this.bypassWhenParentReflowing = false,
  });

  final GridReflowMetrics metrics;
  final ScrollController? scrollController;
  final bool bypassWhenParentReflowing;
  final Widget child;

  static _GridReflowController? _maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_GridReflowInherited>()
      ?.controller;

  @override
  State<GridReflowScope> createState() => _GridReflowScopeState();
}

class _GridReflowController extends ChangeNotifier {
  _GridReflowController({required GridReflowMetrics initialMetrics})
    : _currentMetrics = initialMetrics;

  GridReflowMetrics _currentMetrics;
  GridReflowMetrics get currentMetrics => _currentMetrics;

  _RectResolver? _fromResolver;
  int _resolverDepth = 0;
  double _progress = 1.0;
  double _scrollDelta = 0.0;

  final ValueNotifier<bool> reflowingListenable = ValueNotifier<bool>(false);

  bool get isReflowing => _fromResolver != null && _progress < 0.999;
  double get progress => _progress;
  double get scrollDelta => _scrollDelta;

  void _syncReflowingFlag() {
    final active = isReflowing;
    if (reflowingListenable.value != active) {
      reflowingListenable.value = active;
    }
  }

  @override
  void dispose() {
    reflowingListenable.dispose();
    super.dispose();
  }

  Rect fromRectFor(int index) =>
      _fromResolver?.call(index) ?? _currentMetrics.rectFor(index);

  void updateLiveMetrics(GridReflowMetrics metrics) {
    _currentMetrics = metrics;
  }

  void beginReflow({
    required GridReflowMetrics fromMetrics,
    required GridReflowMetrics toMetrics,
  }) {
    if (isReflowing && _resolverDepth < 3) {
      final prevResolver = _fromResolver!;
      final prevProgress = _progress.clamp(0.0, 1.0);
      final prevScrollDelta = _scrollDelta;
      _fromResolver = (index) {
        final start = prevResolver(index);
        final end = fromMetrics.rectFor(index);
        return Rect.fromLTWH(
          lerpDouble(start.left, end.left, prevProgress)!,
          lerpDouble(start.top - prevScrollDelta, end.top, prevProgress)!,
          lerpDouble(start.width, end.width, prevProgress)!,
          lerpDouble(start.height, end.height, prevProgress)!,
        );
      };
      _resolverDepth++;
    } else {
      _fromResolver = fromMetrics.rectFor;
      _resolverDepth = 1;
    }
    _currentMetrics = toMetrics;
    _progress = 0.0;
    _scrollDelta = 0.0;
    _syncReflowingFlag();
    notifyListeners();
  }

  void setScrollDelta(double delta) {
    if (_scrollDelta == delta) return;
    _scrollDelta = delta;
    if (isReflowing) notifyListeners();
  }

  void setProgress(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (_progress == clamped) return;
    _progress = clamped;
    _syncReflowingFlag();
    notifyListeners();
  }

  void settle() {
    if (_fromResolver == null && _progress == 1.0) return;
    _fromResolver = null;
    _resolverDepth = 0;
    _progress = 1.0;
    _scrollDelta = 0.0;
    _syncReflowingFlag();
    notifyListeners();
  }
}

class _GridReflowScopeState extends State<GridReflowScope>
    with SingleTickerProviderStateMixin {
  static const Duration _settleDuration = Duration(milliseconds: 130);

  late final AnimationController _settleController = AnimationController(
    vsync: this,
    duration: _settleDuration,
    value: 1.0,
  );
  late final CurvedAnimation _settleCurve = CurvedAnimation(
    parent: _settleController,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 0.88,
    end: 1.0,
  ).animate(_settleCurve);
  late final Animation<double> _scale = Tween<double>(
    begin: 0.99,
    end: 1.0,
  ).animate(_settleCurve);

  bool _skipMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _skipMotion = AppMotion.lowPower(context);
    _settleController.duration = AppMotion.scaled(context, _settleDuration);
    if (_skipMotion && _settleController.isAnimating) {
      _settleController
        ..stop()
        ..value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant GridReflowScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bypassWhenParentReflowing || _skipMotion) {
      if (_settleController.value != 1.0 || _settleController.isAnimating) {
        _settleController
          ..stop()
          ..value = 1.0;
      }
      return;
    }

    if (widget.metrics.columns != oldWidget.metrics.columns) {
      _settleController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _settleCurve.dispose();
    _settleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bypassWhenParentReflowing || _skipMotion) {
      return widget.child;
    }
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(
        scale: _scale,
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}

/// Sliver equivalent of [GridReflowScope]: gives a [SliverGrid] inside a
/// [CustomScrollView] a featherlight, single-layer fade settle when [columns]
/// changes (e.g. window maximize/restore 4 ↔ 5) without pulsing headers above it.
class SliverGridSettle extends StatefulWidget {
  const SliverGridSettle({
    super.key,
    required this.columns,
    required this.sliver,
  });

  final int columns;
  final Widget sliver;

  @override
  State<SliverGridSettle> createState() => _SliverGridSettleState();
}

class _SliverGridSettleState extends State<SliverGridSettle>
    with SingleTickerProviderStateMixin {
  static const Duration _settleDuration = Duration(milliseconds: 140);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _settleDuration,
    value: 1.0,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 0.85,
    end: 1.0,
  ).animate(_curve);

  bool _skipMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _skipMotion = AppMotion.lowPower(context);
    _controller.duration = AppMotion.scaled(context, _settleDuration);
    if (_skipMotion && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant SliverGridSettle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_skipMotion) {
      if (_controller.value != 1.0 || _controller.isAnimating) {
        _controller
          ..stop()
          ..value = 1.0;
      }
      return;
    }
    if (widget.columns != oldWidget.columns) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_skipMotion) return widget.sliver;
    return SliverFadeTransition(opacity: _opacity, sliver: widget.sliver);
  }
}

class _GridReflowInherited extends InheritedWidget {
  const _GridReflowInherited({required this.controller, required super.child});

  final _GridReflowController controller;

  @override
  bool updateShouldNotify(_GridReflowInherited oldWidget) =>
      controller != oldWidget.controller;
}

/// Wraps an individual grid item inside a [GridReflowScope] or
/// [StableGridReflowBox] so it glides smoothly across width/column changes
/// using GPU transforms only.
class GridReflowItem extends StatelessWidget {
  const GridReflowItem({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = GridReflowScope._maybeOf(context);
    if (controller == null) return child;

    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        if (!controller.isReflowing) return child!;

        final p = controller.progress.clamp(0.0, 1.0);
        final fromRect = controller.fromRectFor(index);
        final toRect = controller.currentMetrics.rectFor(index);
        if (toRect.width <= 0.0 || toRect.height <= 0.0) return child!;

        final inv = 1.0 - p;
        final dx = (fromRect.left - toRect.left) * inv;
        final dy = (fromRect.top - toRect.top - controller.scrollDelta) * inv;
        final sx = lerpDouble(fromRect.width / toRect.width, 1.0, p)!;
        final sy = lerpDouble(fromRect.height / toRect.height, 1.0, p)!;

        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(
            scaleX: sx,
            scaleY: sy,
            alignment: Alignment.topLeft,
            child: child,
          ),
        );
      },
    );
  }
}
