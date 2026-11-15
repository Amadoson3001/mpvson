import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
