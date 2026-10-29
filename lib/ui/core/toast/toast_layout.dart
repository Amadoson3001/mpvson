import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app_theme.dart';
import 'app_toast.dart';

/// Distance kept between a toast and whatever it avoids.
const double _toastGap = AppSpace.md;

/// How close a rectangle must sit to a screen edge to claim it.
const double _edgeTolerance = 2;

/// Smallest rectangle a toast needs to stay readable.
const double _minToastHeight = 52;
const double _minToastWidth = 220;

/// Toasts never grow wider than this, however much room is free.
const double _maxToastWidth = 384;

/// Where a toast settles and how much room it leaves for the rest of the UI.
@immutable
class ToastGeometry {
  const ToastGeometry({
    required this.insets,
    required this.alignment,
    required this.maxWidth,
  });

  /// Space to leave free on every screen edge.
  final EdgeInsets insets;

  /// Corner the toast settles in.
  final Alignment alignment;

  /// Width available for the card in that corner.
  final double maxWidth;
}

/// Tracks the rectangles already claimed by persistent chrome.
///
/// Toasts read this registry to settle in genuinely free space: the queue
/// panel, the player controls, and the mini player all report the area they
/// occupy, and a toast moves aside as they slide in and out.
class ToastLayoutState extends ChangeNotifier {
  final Map<Object, Rect> _regions = <Object, Rect>{};
  bool _flushScheduled = false;
  bool _disposed = false;

  /// The occupied rectangles, in no particular order.
  List<Rect> get rects {
    if (_regions.isEmpty) return const <Rect>[];
    return _regions.values.toList(growable: false);
  }

  void report(Object key, Rect rect) {
    if (_disposed) return;
    if (rect.width <= 0 || rect.height <= 0) {
      // The region collapsed, for example when the mini player is gone.
      release(key);
      return;
    }
    final previous = _regions[key];
    if (previous != null && _isSameRect(previous, rect)) return;
    _regions[key] = rect;
    _scheduleFlush();
  }

  void release(Object key) {
    if (_disposed) return;
    if (_regions.remove(key) == null) return;
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushScheduled || _disposed) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  bool _isSameRect(Rect a, Rect b) {
    final centerDelta = math.sqrt(
      math.pow(a.center.dx - b.center.dx, 2) +
          math.pow(a.center.dy - b.center.dy, 2),
    );
    final sizeDelta = math.sqrt(
      math.pow(a.width - b.width, 2) + math.pow(a.height - b.height, 2),
    );
    return centerDelta < 0.5 && sizeDelta < 0.5;
  }

  @override
  void dispose() {
    _disposed = true;
    _regions.clear();
    super.dispose();
  }
}

/// Resolves the corner a toast should settle in and the room it may take.
///
/// Chrome that touches a screen edge reserves that edge, but only where it
/// actually reaches: a full-width control bar pushes a bottom toast upward,
/// while a panel docked to the right pushes it sideways. The horizontal claims
/// are resolved first so the toast's own column is known, then only chrome
/// overlapping that column counts against the vertical edges. When a corner
/// runs out of room the toast moves to the opposite edge instead of covering
/// anything.
ToastGeometry resolveToastGeometry({
  required Size screen,
  required EdgeInsets safe,
  required List<Rect> regions,
}) {
  final claimed = regions.where((rect) => !rect.isEmpty).toList();

  // Chrome that spans an edge claims the perpendicular edge instead: a
  // full-width control bar pushes a toast upward rather than sideways.
  var rightClaim = safe.right;
  var leftClaim = safe.left;
  for (final rect in claimed) {
    final touchesRight = screen.width - rect.right <= _edgeTolerance;
    final touchesLeft = rect.left <= _edgeTolerance;
    if (touchesRight && !touchesLeft) {
      rightClaim = math.max(rightClaim, screen.width - rect.left);
    }
    if (touchesLeft && !touchesRight) {
      leftClaim = math.max(leftClaim, rect.right);
    }
  }

  final roomAtRight = screen.width - rightClaim - _toastGap;
  final roomAtLeft = screen.width - leftClaim - _toastGap;
  final settleRight =
      roomAtRight >= _minToastWidth || roomAtRight >= roomAtLeft;

  final horizontalClaim = settleRight ? rightClaim : leftClaim;
  final oppositeClaim = settleRight ? leftClaim : rightClaim;
  final maxWidth =
      (screen.width -
              safe.left -
              safe.right -
              horizontalClaim -
              oppositeClaim -
              _toastGap * 2)
          .clamp(_minToastWidth, _maxToastWidth);

  // The column the toast will occupy, used to measure vertical crowding.
  final columnLeft = settleRight
      ? screen.width - safe.right - horizontalClaim - _toastGap - maxWidth
      : safe.left + horizontalClaim + _toastGap;
  final columnRight = columnLeft + maxWidth;

  // Vertical edges: only chrome overlapping the toast's own column counts.
  var bottomClaim = safe.bottom;
  var topClaim = safe.top;
  for (final rect in claimed) {
    if (rect.right <= columnLeft || rect.left >= columnRight) continue;
    final touchesBottom = screen.height - rect.bottom <= _edgeTolerance;
    final touchesTop = rect.top <= _edgeTolerance;
    if (touchesBottom && !touchesTop) {
      bottomClaim = math.max(bottomClaim, screen.height - rect.top);
    }
    if (touchesTop && !touchesBottom) {
      topClaim = math.max(topClaim, rect.bottom);
    }
  }

  final roomAtBottom = screen.height - bottomClaim - _toastGap;
  final roomAtTop = screen.height - topClaim - _toastGap;
  final settleBottom =
      roomAtBottom >= _minToastHeight || roomAtBottom >= roomAtTop;

  // Never let one claim consume the whole axis.
  final verticalClaim = (settleBottom ? bottomClaim : topClaim).clamp(
    0.0,
    math.max(
      0.0,
      screen.height - safe.top - safe.bottom - _minToastHeight - _toastGap,
    ),
  );

  return ToastGeometry(
    insets: EdgeInsets.only(
      left: settleRight ? 0 : horizontalClaim + _toastGap,
      right: settleRight ? horizontalClaim + _toastGap : 0,
      top: settleBottom ? 0 : verticalClaim + _toastGap,
      bottom: settleBottom ? verticalClaim + _toastGap : 0,
    ),
    alignment: Alignment(settleRight ? 1 : -1, settleBottom ? 1 : -1),
    maxWidth: maxWidth,
  );
}

/// Wraps persistent chrome so the toast layer treats that space as occupied.
///
/// The region measures its own painted rectangle on every layout, so toasts
/// move aside while the queue panel slides in, the player controls retract, or
/// the mini player appears and disappears.
class ToastRegion extends StatefulWidget {
  const ToastRegion({super.key, required this.child});

  final Widget child;

  @override
  State<ToastRegion> createState() => _ToastRegionState();
}

class _ToastRegionState extends State<ToastRegion> {
  ToastLayoutState? _layout;
  final Object _key = Object();
  bool _measureScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _layout = AppToastScope.maybeOf(context)?.layout;
  }

  @override
  void dispose() {
    _layout?.release(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Ancestors can hide the region without laying it out again, so re-measure
    // once the frame that follows a rebuild is on screen.
    _scheduleMeasure();
    return _ToastRegionSurface(onPainted: _measure, child: widget.child);
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (mounted) _measure();
    });
  }

  void _measure() {
    final layout = _layout;
    if (layout == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || _isHidden(box)) {
      layout.release(_key);
      return;
    }
    final origin = box.localToGlobal(Offset.zero);
    layout.report(_key, origin & box.size);
  }

  /// Chrome that is off stage or ignores pointers reserves no space: it cannot
  /// be seen or used, so a toast may sit where it is.
  bool _isHidden(RenderBox box) {
    RenderObject? node = box.parent;
    while (node != null) {
      if (node is RenderOffstage && node.offstage) return true;
      if (node is RenderIgnorePointer && node.ignoring) return true;
      node = node.parent;
    }
    return false;
  }
}

class _ToastRegionSurface extends SingleChildRenderObjectWidget {
  const _ToastRegionSurface({required this.onPainted, super.child});

  final VoidCallback onPainted;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ToastRegionBox(onPainted: onPainted);

  @override
  void updateRenderObject(BuildContext context, _ToastRegionBox renderObject) =>
      renderObject.onPainted = onPainted;
}

class _ToastRegionBox extends RenderProxyBox {
  _ToastRegionBox({required this.onPainted});

  VoidCallback onPainted;
  bool _awaitingPaint = false;

  @override
  void performLayout() {
    super.performLayout();
    _awaitingPaint = true;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!_awaitingPaint) return;
    _awaitingPaint = false;
    onPainted();
  }
}
