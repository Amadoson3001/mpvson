import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Standard icon button used throughout player controls and panels,
/// combining an accessible [Tooltip], consistent padding, and hover feedback.
class PlayerIconButton extends StatelessWidget {
  const PlayerIconButton({
    super.key,
    required this.icon,
    this.tooltip,
    required this.onPressed,
    this.size = 20.0,
    this.color,
    this.hoverColor,
    this.padding = const EdgeInsets.all(8.0),
    this.constraints,
  });

  final Widget icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;
  final Color? hoverColor;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final effectiveColor = color ?? palette.text;
    final effectiveHover = hoverColor ?? palette.hover.withValues(alpha: 0.4);

    final button = IconButton(
      icon: icon,
      iconSize: size,
      color: effectiveColor,
      hoverColor: effectiveHover,
      padding: padding,
      constraints: constraints,
      splashRadius: size + 8,
      onPressed: onPressed,
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      return Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 500),
        child: button,
      );
    }

    return button;
  }
}
