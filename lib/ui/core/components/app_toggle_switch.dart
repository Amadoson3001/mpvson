import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_motion.dart';

/// A sleek, tactile animated toggle switch with smooth physics and accessibility.
class AppToggleSwitch extends StatefulWidget {
  const AppToggleSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  State<AppToggleSwitch> createState() => _AppToggleSwitchState();
}

class _AppToggleSwitchState extends State<AppToggleSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _animation;
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  static const double _trackWidth = 42.0;
  static const double _trackHeight = 24.0;
  static const double _thumbSize = 18.0;
  static const double _thumbPadding = 3.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      value: widget.value ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 220),
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
  }

  @override
  void didUpdateWidget(AppToggleSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      if (AppMotion.reduce(context)) {
        _controller.value = widget.value ? 1.0 : 0.0;
      } else {
        if (widget.value) {
          _controller.forward();
        } else {
          _controller.reverse();
        }
      }
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (!widget.enabled || widget.onChanged == null) return;
    widget.onChanged!(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    final inactiveTrack = isDark
        ? const Color(0xFF2C2E35)
        : const Color(0xFFE2E4E9);
    final inactiveBorder = isDark
        ? const Color(0xFF3F424C)
        : const Color(0xFFCDD0D8);
    final activeBorder = primary;

    final maxOffset = _trackWidth - _thumbSize - (_thumbPadding * 2);

    return Semantics(
      toggled: widget.value,
      enabled: widget.enabled,
      button: true,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _handleTap();
              return null;
            },
          ),
        },
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          onTapDown: widget.enabled
              ? (_) => setState(() => _pressed = true)
              : null,
          onTapUp: widget.enabled
              ? (_) => setState(() => _pressed = false)
              : null,
          onTapCancel: widget.enabled
              ? () => setState(() => _pressed = false)
              : null,
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, _) {
              final t = _animation.value;
              final inactiveThumb = isDark
                  ? const Color(0xFF9CA3AF)
                  : const Color(0xFF6B7280);
              final activeThumb = Colors.white;

              final trackColor = Color.lerp(inactiveTrack, primary, t)!;
              final borderColor = Color.lerp(inactiveBorder, activeBorder, t)!;
              final thumbColor = Color.lerp(inactiveThumb, activeThumb, t)!;

              // Subtly elongate knob while moving or pressed for tactile feedback
              final stretch =
                  (_pressed ||
                      (_controller.isAnimating && !AppMotion.reduce(context)))
                  ? 3.0
                  : 0.0;
              final baseThumbSize = 15.0 + (3.0 * t);
              final currentThumbWidth = baseThumbSize + stretch;
              final currentThumbHeight = baseThumbSize;
              final thumbLeft = _thumbPadding + (t * (maxOffset - stretch));
              final thumbTop = (_trackHeight - currentThumbHeight) / 2;

              return Container(
                width: _trackWidth,
                height: _trackHeight,
                decoration: BoxDecoration(
                  color: widget.enabled
                      ? trackColor
                      : trackColor.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(_trackHeight / 2),
                  border: Border.all(
                    color: _hovered && widget.enabled
                        ? theme.colorScheme.outline
                        : borderColor,
                    width: 1.2,
                  ),
                  boxShadow: _focused && widget.enabled
                      ? [
                          BoxShadow(
                            color: primary.withValues(alpha: 0.4),
                            spreadRadius: 2,
                            blurRadius: 3,
                          ),
                        ]
                      : null,
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: thumbLeft.clamp(
                        _thumbPadding,
                        _trackWidth - currentThumbWidth - _thumbPadding,
                      ),
                      top: thumbTop,
                      child: Container(
                        width: currentThumbWidth,
                        height: currentThumbHeight,
                        decoration: BoxDecoration(
                          color: thumbColor,
                          borderRadius: BorderRadius.circular(
                            currentThumbHeight / 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 3.5,
                              offset: const Offset(0, 1.2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
