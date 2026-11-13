import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Builder widget that encapsulates [MouseRegion] hover detection and provides
/// a clean `builder: (context, isHovered)` interface, eliminating boilerplate
/// `setState(_isHovered = ...)` across UI controls.
class HoverBuilder extends StatefulWidget {
  const HoverBuilder({
    super.key,
    required this.builder,
    this.cursor = MouseCursor.defer,
    this.hitTestBehavior = HitTestBehavior.opaque,
    this.onEnter,
    this.onExit,
  });

  final Widget Function(BuildContext context, bool isHovered) builder;
  final MouseCursor cursor;
  final HitTestBehavior hitTestBehavior;
  final VoidCallback? onEnter;
  final VoidCallback? onExit;

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _isHovered = false;

  void _handleEnter(PointerEnterEvent event) {
    if (!_isHovered) {
      setState(() {
        _isHovered = true;
      });
      widget.onEnter?.call();
    }
  }

  void _handleExit(PointerExitEvent event) {
    if (_isHovered) {
      setState(() {
        _isHovered = false;
      });
      widget.onExit?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      hitTestBehavior: widget.hitTestBehavior,
      onEnter: _handleEnter,
      onExit: _handleExit,
      child: widget.builder(context, _isHovered),
    );
  }
}

/// Hover tracker that exposes a [ValueListenable] so descendants can rebuild
/// a subtree without reconstructing the whole row.
class HoverListenable extends StatefulWidget {
  const HoverListenable({
    super.key,
    required this.builder,
    this.cursor = MouseCursor.defer,
    this.hitTestBehavior = HitTestBehavior.opaque,
  });

  final Widget Function(BuildContext context, ValueListenable<bool> isHovered)
  builder;
  final MouseCursor cursor;
  final HitTestBehavior hitTestBehavior;

  @override
  State<HoverListenable> createState() => _HoverListenableState();
}

class _HoverListenableState extends State<HoverListenable> {
  final ValueNotifier<bool> _hovered = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      hitTestBehavior: widget.hitTestBehavior,
      onEnter: (_) {
        if (!_hovered.value) _hovered.value = true;
      },
      onExit: (_) {
        if (_hovered.value) _hovered.value = false;
      },
      child: widget.builder(context, _hovered),
    );
  }
}
