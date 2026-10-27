import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keyboard and pointer selection behavior for a media list row.
class MediaRow extends StatefulWidget {
  const MediaRow({
    super.key,
    required this.onSelect,
    required this.onPlay,
    required this.builder,
  });
  final VoidCallback onSelect;
  final VoidCallback? onPlay;
  final Widget Function(BuildContext context, FocusNode focusNode) builder;
  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  final _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    onFocusChange: (focused) {
      if (focused) widget.onSelect();
    },
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
        widget.onPlay?.call();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: widget.builder(context, _focus),
  );
}
