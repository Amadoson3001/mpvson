import 'package:flutter/material.dart';

/// Custom "projector room" palette: warm charcoal surfaces lit by lamp amber,
/// with jade, sky, gold, and rose support tones.
abstract final class AppColors {
  // Surfaces
  static const stage = Color(0xFF060606);
  static const ground = Color(0xFF09090B);
  static const layer = Color(0xFF121215);
  static const raised = Color(0xFF18181B);
  static const hover = Color(0xFF222226);
  static const line = Color(0xFF27272A);
  static const lineStrong = Color(0xFF3F3F46);

  // Text
  static const ink = Color(0xFFF4F4F5);
  static const inkMuted = Color(0xFFA1A1AA);
  static const inkDim = Color(0xFF71717A);
  static const inkFaint = Color(0xFF52525B);

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

/// Rich palette extracted from the current media's artwork.
///
/// Provides coordinated dominant, vibrant, and muted tones for ambient glows,
/// backdrop lighting, and secondary highlights with guaranteed lerping.
@immutable
class MediaAccentPalette extends ThemeExtension<MediaAccentPalette> {
  const MediaAccentPalette({
    this.dominant = AppColors.lamp,
    this.vibrant = AppColors.gold,
    this.muted = AppColors.layer,
  });

  final Color dominant;
  final Color vibrant;
  final Color muted;

  @override
  MediaAccentPalette copyWith({
    Color? dominant,
    Color? vibrant,
    Color? muted,
  }) => MediaAccentPalette(
    dominant: dominant ?? this.dominant,
    vibrant: vibrant ?? this.vibrant,
    muted: muted ?? this.muted,
  );

  @override
  MediaAccentPalette lerp(covariant MediaAccentPalette? other, double t) {
    if (other == null) return this;
    return MediaAccentPalette(
      dominant: Color.lerp(dominant, other.dominant, t) ?? dominant,
      vibrant: Color.lerp(vibrant, other.vibrant, t) ?? vibrant,
      muted: Color.lerp(muted, other.muted, t) ?? muted,
    );
  }
}

/// Curated dynamic accent presets for personalizing the interface.
@immutable
class AppAccentPreset {
  const AppAccentPreset({
    required this.id,
    required this.label,
    required this.description,
    required this.color,
    Color? lightColor,
    this.icon = Icons.circle,
  }) : lightColor = lightColor ?? color;

  final String id;
  final String label;
  final String description;
  final Color color;
  final Color lightColor;
  final IconData icon;

  static const lamp = AppAccentPreset(
    id: 'lamp',
    label: 'Amber Lamp',
    description: 'Warm projector-room glow',
    color: Color(0xFFF1A64C),
    lightColor: Color(0xFFD97706),
    icon: Icons.lightbulb_outline_rounded,
  );

  static const jade = AppAccentPreset(
    id: 'jade',
    label: 'Jade Aurora',
    description: 'Serene cinema emerald & mint',
    color: Color(0xFF2DD4BF),
    lightColor: Color(0xFF0D9488),
    icon: Icons.eco_outlined,
  );

  static const sky = AppAccentPreset(
    id: 'sky',
    label: 'Electric Sky',
    description: 'Crisp modern cobalt & sapphire',
    color: Color(0xFF38BDF8),
    lightColor: Color(0xFF0284C7),
    icon: Icons.water_drop_outlined,
  );

  static const rose = AppAccentPreset(
    id: 'rose',
    label: 'Crimson Rose',
    description: 'Classic theater velvet coral & ruby',
    color: Color(0xFFF43F5E),
    lightColor: Color(0xFFE11D48),
    icon: Icons.local_fire_department_outlined,
  );

  static const amethyst = AppAccentPreset(
    id: 'amethyst',
    label: 'Amethyst Neon',
    description: 'Futuristic synthwave violet',
    color: Color(0xFFA855F7),
    lightColor: Color(0xFF7E22CE),
    icon: Icons.auto_awesome_outlined,
  );

  static const gold = AppAccentPreset(
    id: 'gold',
    label: 'Solar Gold',
    description: 'Brilliant cinematic amber-gold',
    color: Color(0xFFF59E0B),
    lightColor: Color(0xFFB45309),
    icon: Icons.wb_sunny_outlined,
  );

  static const List<AppAccentPreset> all = [
    lamp,
    jade,
    sky,
    rose,
    amethyst,
    gold,
  ];

  static AppAccentPreset fromId(String? id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return lamp;
  }
}
