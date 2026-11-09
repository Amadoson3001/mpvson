import 'package:flutter/foundation.dart';

/// Visual style presentation for the bottom player controls.
enum PlayerControlBarStyle {
  floatingPill,
  cinematicGradient,
  frostedDocked,
  minimal;

  String get label => switch (this) {
    PlayerControlBarStyle.floatingPill => 'Floating Pill',
    PlayerControlBarStyle.cinematicGradient => 'Cinematic Gradient',
    PlayerControlBarStyle.frostedDocked => 'Frosted Dock',
    PlayerControlBarStyle.minimal => 'Minimalist',
  };

  String get description => switch (this) {
    PlayerControlBarStyle.floatingPill =>
      'Floating rounded dock with frosted glass blur and ambient elevation.',
    PlayerControlBarStyle.cinematicGradient =>
      'Smooth dark cinema vignette that blends seamlessly into the video.',
    PlayerControlBarStyle.frostedDocked =>
      'Full-width docked bar at the bottom with frosted glass blur.',
    PlayerControlBarStyle.minimal =>
      'Streamlined compact bar with minimal screen footprint.',
  };

  static PlayerControlBarStyle fromName(String? name) {
    if (name == null) return PlayerControlBarStyle.floatingPill;
    for (final style in PlayerControlBarStyle.values) {
      if (style.name == name) return style;
    }
    return PlayerControlBarStyle.floatingPill;
  }
}

/// Thickness configuration for the timeline seekbar.
enum SeekBarThickness {
  slim,
  standard,
  bold;

  String get label => switch (this) {
    SeekBarThickness.slim => 'Slim (2.5px)',
    SeekBarThickness.standard => 'Standard (3.5px)',
    SeekBarThickness.bold => 'Bold (5.0px)',
  };

  double get restingHeight => switch (this) {
    SeekBarThickness.slim => 2.5,
    SeekBarThickness.standard => 3.5,
    SeekBarThickness.bold => 5.0,
  };

  double get hoverHeight => switch (this) {
    SeekBarThickness.slim => 4.5,
    SeekBarThickness.standard => 6.0,
    SeekBarThickness.bold => 8.0,
  };

  double get restingThumbRadius => switch (this) {
    SeekBarThickness.slim => 4.0,
    SeekBarThickness.standard => 5.5,
    SeekBarThickness.bold => 6.5,
  };

  double get hoverThumbRadius => switch (this) {
    SeekBarThickness.slim => 6.5,
    SeekBarThickness.standard => 8.0,
    SeekBarThickness.bold => 9.5,
  };

  static SeekBarThickness fromName(String? name) {
    if (name == null) return SeekBarThickness.standard;
    for (final thickness in SeekBarThickness.values) {
      if (thickness.name == name) return thickness;
    }
    return SeekBarThickness.standard;
  }
}

/// User preferences for the player controls strip, seekbar, and layout.
@immutable
class PlayerControlsPreferences {
  const PlayerControlsPreferences({
    this.barStyle = PlayerControlBarStyle.floatingPill,
    this.backgroundOpacity = 0.88,
    this.enableBlur = true,
    this.showStopButton = true,
    this.showShuffleRepeat = true,
    this.showSpeedButton = true,
    this.showVolumeSlider = true,
    this.showQueueButton = true,
    this.showRemainingTime = false,
    this.seekBarThickness = SeekBarThickness.standard,
    this.autoHideDelaySeconds = 2.8,
  });

  final PlayerControlBarStyle barStyle;
  final double backgroundOpacity;
  final bool enableBlur;
  final bool showStopButton;
  final bool showShuffleRepeat;
  final bool showSpeedButton;
  final bool showVolumeSlider;
  final bool showQueueButton;
  final bool showRemainingTime;
  final SeekBarThickness seekBarThickness;
  final double autoHideDelaySeconds;

  PlayerControlsPreferences copyWith({
    PlayerControlBarStyle? barStyle,
    double? backgroundOpacity,
    bool? enableBlur,
    bool? showStopButton,
    bool? showShuffleRepeat,
    bool? showSpeedButton,
    bool? showVolumeSlider,
    bool? showQueueButton,
    bool? showRemainingTime,
    SeekBarThickness? seekBarThickness,
    double? autoHideDelaySeconds,
  }) => PlayerControlsPreferences(
    barStyle: barStyle ?? this.barStyle,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    enableBlur: enableBlur ?? this.enableBlur,
    showStopButton: showStopButton ?? this.showStopButton,
    showShuffleRepeat: showShuffleRepeat ?? this.showShuffleRepeat,
    showSpeedButton: showSpeedButton ?? this.showSpeedButton,
    showVolumeSlider: showVolumeSlider ?? this.showVolumeSlider,
    showQueueButton: showQueueButton ?? this.showQueueButton,
    showRemainingTime: showRemainingTime ?? this.showRemainingTime,
    seekBarThickness: seekBarThickness ?? this.seekBarThickness,
    autoHideDelaySeconds: autoHideDelaySeconds ?? this.autoHideDelaySeconds,
  );

  factory PlayerControlsPreferences.fromJson(Map<String, Object?>? json) {
    if (json == null) return const PlayerControlsPreferences();
    return PlayerControlsPreferences(
      barStyle: PlayerControlBarStyle.fromName(json['barStyle'] as String?),
      backgroundOpacity:
          (json['backgroundOpacity'] as num?)?.toDouble().clamp(0.2, 1.0) ??
          0.88,
      enableBlur: json['enableBlur'] as bool? ?? true,
      showStopButton: json['showStopButton'] as bool? ?? true,
      showShuffleRepeat: json['showShuffleRepeat'] as bool? ?? true,
      showSpeedButton: json['showSpeedButton'] as bool? ?? true,
      showVolumeSlider: json['showVolumeSlider'] as bool? ?? true,
      showQueueButton: json['showQueueButton'] as bool? ?? true,
      showRemainingTime: json['showRemainingTime'] as bool? ?? false,
      seekBarThickness: SeekBarThickness.fromName(
        json['seekBarThickness'] as String?,
      ),
      autoHideDelaySeconds:
          (json['autoHideDelaySeconds'] as num?)?.toDouble().clamp(0.0, 10.0) ??
          2.8,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'barStyle': barStyle.name,
    'backgroundOpacity': backgroundOpacity,
    'enableBlur': enableBlur,
    'showStopButton': showStopButton,
    'showShuffleRepeat': showShuffleRepeat,
    'showSpeedButton': showSpeedButton,
    'showVolumeSlider': showVolumeSlider,
    'showQueueButton': showQueueButton,
    'showRemainingTime': showRemainingTime,
    'seekBarThickness': seekBarThickness.name,
    'autoHideDelaySeconds': autoHideDelaySeconds,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayerControlsPreferences &&
          runtimeType == other.runtimeType &&
          barStyle == other.barStyle &&
          backgroundOpacity == other.backgroundOpacity &&
          enableBlur == other.enableBlur &&
          showStopButton == other.showStopButton &&
          showShuffleRepeat == other.showShuffleRepeat &&
          showSpeedButton == other.showSpeedButton &&
          showVolumeSlider == other.showVolumeSlider &&
          showQueueButton == other.showQueueButton &&
          showRemainingTime == other.showRemainingTime &&
          seekBarThickness == other.seekBarThickness &&
          autoHideDelaySeconds == other.autoHideDelaySeconds;

  @override
  int get hashCode => Object.hash(
    barStyle,
    backgroundOpacity,
    enableBlur,
    showStopButton,
    showShuffleRepeat,
    showSpeedButton,
    showVolumeSlider,
    showQueueButton,
    showRemainingTime,
    seekBarThickness,
    autoHideDelaySeconds,
  );
}
