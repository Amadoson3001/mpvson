import 'package:flutter/material.dart';
import '../app_theme.dart';

/// A standardized popup menu item featuring an icon, spacing, and an expanded label,
/// matching the design pattern across media library views and player actions.
class AppPopupMenuItem<T> extends PopupMenuItem<T> {
  AppPopupMenuItem({
    super.key,
    super.value,
    super.onTap,
    super.enabled = true,
    super.height = kMinInteractiveDimension,
    super.padding,
    super.mouseCursor,
    required IconData icon,
    Color? iconColor,
    double iconSize = 18.0,
    double spacing = 10.0,
    required String text,
    TextStyle? textStyle,
    String? shortcut,
    Widget? trailing,
  }) : super(
         child: AppPopupMenuItemContent(
           icon: icon,
           iconColor: iconColor,
           iconSize: iconSize,
           spacing: spacing,
           text: text,
           textStyle: textStyle,
           shortcut: shortcut,
           trailing: trailing,
         ),
       );
}

/// Standalone row content for popup menu items.
class AppPopupMenuItemContent extends StatelessWidget {
  const AppPopupMenuItemContent({
    super.key,
    required this.icon,
    this.iconColor,
    this.iconSize = 18.0,
    this.spacing = 10.0,
    required this.text,
    this.textStyle,
    this.shortcut,
    this.trailing,
  });

  final IconData icon;
  final Color? iconColor;
  final double iconSize;
  final double spacing;
  final String text;
  final TextStyle? textStyle;
  final String? shortcut;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final effectiveIconColor = iconColor ?? context.palette.secondaryText;
    final effectiveTextStyle = textStyle ?? context.palette.rowPrimary;

    return Row(
      children: [
        Icon(icon, size: iconSize, color: effectiveIconColor),
        SizedBox(width: spacing),
        Expanded(
          child: Text(
            text,
            style: effectiveTextStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (shortcut != null) ...[
          const SizedBox(width: AppSpace.sm),
          Text(
            shortcut!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.palette.secondaryText,
            ),
          ),
        ],
        ?trailing,
      ],
    );
  }
}
