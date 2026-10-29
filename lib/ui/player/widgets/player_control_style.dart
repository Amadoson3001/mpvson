import 'package:flutter/material.dart';

/// Sizing shared by the bottom controls, without shrinking dialogs or menus.
class PlayerControlStyle extends InheritedWidget {
  const PlayerControlStyle({
    super.key,
    required this.compact,
    required super.child,
  });

  /// Extents of the controls in the full-size presentation.
  ///
  /// Static so layout that sits outside the controls — the Now Playing stage
  /// sizes its artwork around them — measures the same numbers instead of
  /// repeating them and drifting apart.
  static const double controlExtent = 44;
  static const double compactControlExtent = 32;
  static const double seekExtent = 32;
  static const double compactSeekExtent = 24;

  final bool compact;

  static PlayerControlStyle of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerControlStyle>() ??
      const PlayerControlStyle(compact: false, child: SizedBox.shrink());

  double get buttonExtent => compact ? compactControlExtent : controlExtent;
  double get iconSize => compact ? 17 : 20;
  double get seekHitHeight => compact ? compactSeekExtent : seekExtent;

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
