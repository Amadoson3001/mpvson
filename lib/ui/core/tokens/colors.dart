import 'package:flutter/material.dart';

/// Custom "projector room" palette: warm charcoal surfaces lit by lamp amber,
/// with jade, sky, gold, and rose support tones.
abstract final class AppColors {
  // Surfaces
  static const stage = Color(0xFF060606);
  static const ground = Color(0xFF121110);
  static const layer = Color(0xFF1A1917);
  static const raised = Color(0xFF22201D);
  static const hover = Color(0xFF2B2823);
  static const line = Color(0xFF302C26);
  static const lineStrong = Color(0xFF433D33);

  // Text
  static const ink = Color(0xFFF3EFE6);
  static const inkMuted = Color(0xFFB7B1A5);
  static const inkDim = Color(0xFF8D877A);
  static const inkFaint = Color(0xFF6B665D);

  // Accent and support
  static const lamp = Color(0xFFF1A64C);
  static const jade = Color(0xFF7FC3A3);
  static const sky = Color(0xFF82B4D4);
  static const gold = Color(0xFFDDB264);
  static const rose = Color(0xFFD98B80);

  // Media overlays
  static const onStage = Color(0xFFF7F4EC);
  static const scrim = Color(0xCC000000);
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
