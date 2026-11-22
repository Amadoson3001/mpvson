import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Holds its child at a stable target width while a neighboring pane animates.
///
/// During a neighbour's width animation, the child is laid out once at its
/// final (settled) width (`slotWidth + widthDelta`), start-aligned, and clipped
/// to the box's actual bounds so it slides smoothly instead of re-flowing on
/// every frame.
class StableWidthBox extends SingleChildRenderObjectWidget {
  const StableWidthBox({super.key, required this.widthDelta, super.child});

  /// Difference between the settled width and the current slot width.
  final double widthDelta;

  @override
  RenderStableWidthBox createRenderObject(BuildContext context) =>
      RenderStableWidthBox(
        widthDelta: widthDelta,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderStableWidthBox renderObject,
  ) {
    renderObject
      ..widthDelta = widthDelta
      ..textDirection = Directionality.of(context);
  }
}

/// Render object backing [StableWidthBox].
///
/// During a neighbour's width animation, the child is laid out once at its
/// final (settled) width, start-aligned, and clipped, so it slides instead of
/// re-flowing.
class RenderStableWidthBox extends RenderShiftedBox {
  RenderStableWidthBox({
    RenderBox? child,
    required this._widthDelta,
    required this._textDirection,
  }) : super(child);

  double _widthDelta;
  double get widthDelta => _widthDelta;
  set widthDelta(double value) {
    if (_widthDelta == value) return;
    _widthDelta = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  double? _lastChildWidth;
  bool _overflows = false;
  final LayerHandle<ClipRectLayer> _clipHandle = LayerHandle<ClipRectLayer>();

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
      return constraints.biggest;
    }
    final child = this.child;
    if (child == null) return constraints.smallest;
    return child.getDryLayout(constraints);
  }

  @override
  void performLayout() {
    final child = this.child;
    if (!constraints.hasBoundedWidth ||
        !constraints.hasBoundedHeight ||
        child == null) {
      _overflows = false;
      _lastChildWidth = null;
      if (child != null) {
        child.layout(constraints, parentUsesSize: true);
        size = child.size;
        (child.parentData! as BoxParentData).offset = Offset.zero;
      } else {
        size = constraints.smallest;
      }
      return;
    }

    size = constraints.biggest;
    var w = math.max(0.0, size.width + _widthDelta);
    if (_lastChildWidth != null && (w - _lastChildWidth!).abs() < 0.01) {
      w = _lastChildWidth!;
    }
    _lastChildWidth = w;

    child.layout(BoxConstraints.tightFor(width: w, height: size.height));

    final childOffset = switch (_textDirection) {
      TextDirection.ltr => Offset.zero,
      TextDirection.rtl => Offset(size.width - w, 0),
    };
    (child.parentData! as BoxParentData).offset = childOffset;
    _overflows = w > size.width + 0.01 || childOffset.dx < 0;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_overflows) {
      _clipHandle.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        super.paint,
        oldLayer: _clipHandle.layer,
      );
    } else {
      _clipHandle.layer = null;
      super.paint(context, offset);
    }
  }

  @override
  void dispose() {
    _clipHandle.layer = null;
    super.dispose();
  }
}
