import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keyboard and pointer selection behavior for a media list row.
///
/// Provides an instant [handleTap] callback for `InkWell.onTap` instead of
/// registering a competing `onDoubleTap` recognizer, avoiding Flutter's 300ms
/// `kDoubleTapTimeout` delay on every single click while still triggering
/// [onPlay] on rapid consecutive clicks.
class MediaRow extends StatefulWidget {
  const MediaRow({
    super.key,
    required this.onSelect,
    required this.onPlay,
    required this.builder,
  });

  final VoidCallback onSelect;
  final VoidCallback? onPlay;
  final Widget Function(
    BuildContext context,
    FocusNode focusNode,
    VoidCallback handleTap,
  )
  builder;

  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  final _focus = FocusNode();
  Timer? _doubleTapTimer;
  bool _awaitingDoubleTap = false;

  @override
  void dispose() {
    _doubleTapTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (!_focus.hasFocus) {
      _focus.requestFocus();
    }
    widget.onSelect();
    final onPlay = widget.onPlay;
    if (onPlay == null) return;
    if (_awaitingDoubleTap) {
      _doubleTapTimer?.cancel();
      _doubleTapTimer = null;
      _awaitingDoubleTap = false;
      onPlay();
    } else {
      _awaitingDoubleTap = true;
      _doubleTapTimer?.cancel();
      _doubleTapTimer = Timer(const Duration(milliseconds: 450), () {
        _awaitingDoubleTap = false;
        _doubleTapTimer = null;
      });
    }
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
    child: widget.builder(context, _focus, _handleTap),
  );
}
