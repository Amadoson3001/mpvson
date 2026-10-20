import 'package:flutter/material.dart';

/// Sizing shared by the bottom controls, without shrinking dialogs or menus.
class PlayerControlStyle extends InheritedWidget {
  const PlayerControlStyle({
    super.key,
    required this.compact,
    required super.child,
  });

  final bool compact;

  static PlayerControlStyle of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerControlStyle>() ??
      const PlayerControlStyle(compact: false, child: SizedBox.shrink());

  double get buttonExtent => compact ? 32 : 44;
  double get iconSize => compact ? 17 : 20;
  double get seekHitHeight => compact ? 24 : 32;

  ButtonStyle get buttonStyle => IconButton.styleFrom(
    minimumSize: Size.square(buttonExtent),
    maximumSize: Size.square(buttonExtent),
    padding: EdgeInsets.zero,
    iconSize: iconSize,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.standard,
  );

  @override
  bool updateShouldNotify(PlayerControlStyle oldWidget) =>
      compact != oldWidget.compact;
}
