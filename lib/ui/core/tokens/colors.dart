import 'package:flutter/material.dart';

/// Neutral surfaces and the fallback projector-lamp accent.
abstract final class AppColors {
  static const stage = Color(0xFF000000);
  static const ground = Color(0xFF17181A);
  static const layer = Color(0xFF222326);
  static const raised = Color(0xFF292A2E);
  static const line = Color(0xFF33353A);
  static const ink = Color(0xFFECEBE8);
  static const inkDim = Color(0xFF9A9A9F);
  static const lamp = Color(0xFFE9A23B);
}

/// The current media's accent; defaults to the projector-lamp color.
@immutable
class MediaAccent extends ThemeExtension<MediaAccent> {
  const MediaAccent({this.color = AppColors.lamp});
  final Color color;

  @override
  MediaAccent copyWith({Color? color}) =>
      MediaAccent(color: color ?? this.color);

  @override
  MediaAccent lerp(covariant MediaAccent? other, double t) =>
      MediaAccent(color: Color.lerp(color, other?.color ?? color, t)!);
}
