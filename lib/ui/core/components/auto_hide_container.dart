import 'dart:async';

import 'package:flutter/material.dart';

import '../app_motion.dart';

/// Wraps [child] with an [AnimatedOpacity] and an activity timer that
/// automatically hides the child after a period of user inactivity.
class AutoHideContainer extends StatefulWidget {
  const AutoHideContainer({
    super.key,
    required this.child,
    this.visible = true,
    this.autoHide = true,
    this.hideDelay = const Duration(seconds: 3),
    this.fadeDuration = const Duration(milliseconds: 250),
    this.onVisibilityChanged,
  });

  final Widget child;
  final bool visible;
  final bool autoHide;
  final Duration hideDelay;
  final Duration fadeDuration;
  final ValueChanged<bool>? onVisibilityChanged;

  @override
  State<AutoHideContainer> createState() => _AutoHideContainerState();
}

class _AutoHideContainerState extends State<AutoHideContainer> {
  Timer? _inactivityTimer;
  bool _isVisible = true;

  @override
  void initState() {
    super.initState();
    _isVisible = widget.visible;
    if (_isVisible && widget.autoHide) {
      _startTimer();
    }
  }

  @override
  void didUpdateWidget(AutoHideContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      _setVisible(widget.visible);
    }
    if (widget.autoHide && !oldWidget.autoHide && _isVisible) {
      _startTimer();
    } else if (!widget.autoHide && oldWidget.autoHide) {
      _cancelTimer();
    }
  }

  @override
  void dispose() {
    _cancelTimer();
    super.dispose();
  }

  void _setVisible(bool visible) {
    if (_isVisible == visible) return;
    setState(() {
      _isVisible = visible;
    });
    widget.onVisibilityChanged?.call(visible);
    if (visible && widget.autoHide) {
      _startTimer();
    } else {
      _cancelTimer();
    }
  }

  void _startTimer() {
    _cancelTimer();
    _inactivityTimer = Timer(widget.hideDelay, () {
      if (mounted) {
        _setVisible(false);
      }
    });
  }

  void _cancelTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
  }

  void notifyUserActivity() {
    if (!_isVisible) {
      _setVisible(true);
    } else if (widget.autoHide) {
      _startTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child = AnimatedOpacity(
      opacity: _isVisible ? 1.0 : 0.0,
      duration: widget.fadeDuration,
      curve: AppMotion.standardCurve,
      child: IgnorePointer(ignoring: !_isVisible, child: widget.child),
    );
    if (widget.autoHide) {
      child = MouseRegion(onHover: (_) => notifyUserActivity(), child: child);
    }
    return child;
  }
}
