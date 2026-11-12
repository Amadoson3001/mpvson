/// Fixed playback tuning presets understood by the bundled mpv engine.
enum PlaybackQualityPreset { performance, balanced, quality }

extension PlaybackQualityPresetLabel on PlaybackQualityPreset {
  String get label => switch (this) {
    PlaybackQualityPreset.performance => 'Performance',
    PlaybackQualityPreset.balanced => 'Balanced',
    PlaybackQualityPreset.quality => 'Quality',
  };
}

/// Persisted, validated playback preferences.
///
/// Color adjustment follows mpv's documented -100 to 100 range. Timing offsets
/// are kept within ten seconds so corrupt session data cannot apply extreme
/// delays when playback starts.
class PlaybackSettings {
  const PlaybackSettings({
    this.qualityPreset = PlaybackQualityPreset.balanced,
    this.preferHardwareDecoding = true,
    this.ramPreservation = false,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.gamma = 0,
    this.audioDelaySeconds = 0,
    this.subtitleDelaySeconds = 0,
  });

  static const PlaybackSettings defaults = PlaybackSettings();

  final PlaybackQualityPreset qualityPreset;
  final bool preferHardwareDecoding;
  final bool ramPreservation;
  final double brightness;
  final double contrast;
  final double saturation;
  final double gamma;
  final double audioDelaySeconds;
  final double subtitleDelaySeconds;

  /// Whether a low-spec profile is active or RAM preservation is enabled.
  bool get isLowSpecOrRamPreserved =>
      qualityPreset == PlaybackQualityPreset.performance || ramPreservation;

  /// mpv renderer properties for this quality preset.
  ///
  /// Performance is the old-hardware profile. Balanced and Quality keep a
  /// modern-looking picture; they do not inherit the cheap FBO/scaler cuts.
  Map<String, String> get rendererProperties {
    return switch (qualityPreset) {
      PlaybackQualityPreset.performance => const <String, String>{
        'scale': 'bilinear',
        'cscale': 'bilinear',
        'dscale': 'bilinear',
        'deband': 'no',
        'gpu-dumb-mode': 'yes',
        'dither': 'no',
        'correct-downscaling': 'no',
        'linear-downscaling': 'no',
        'sigmoid-upscaling': 'no',
        'hdr-compute-peak': 'no',
        'fbo-format': 'rgba8',
      },
      PlaybackQualityPreset.balanced => const <String, String>{
        'scale': 'lanczos',
        'cscale': 'bilinear',
        'dscale': 'mitchell',
        'deband': 'no',
        'gpu-dumb-mode': 'no',
        'dither': 'auto',
        'correct-downscaling': 'yes',
        'linear-downscaling': 'no',
        'sigmoid-upscaling': 'no',
        'hdr-compute-peak': 'no',
      },
      PlaybackQualityPreset.quality => const <String, String>{
        'scale': 'lanczos',
        'cscale': 'lanczos',
        'dscale': 'mitchell',
        'deband': 'yes',
        'gpu-dumb-mode': 'no',
        'dither': 'yes',
        'correct-downscaling': 'yes',
        'linear-downscaling': 'yes',
        'sigmoid-upscaling': 'yes',
        'hdr-compute-peak': 'yes',
      },
    };
  }

  PlaybackSettings copyWith({
    PlaybackQualityPreset? qualityPreset,
    bool? preferHardwareDecoding,
    bool? ramPreservation,
    double? brightness,
    double? contrast,
    double? saturation,
    double? gamma,
    double? audioDelaySeconds,
    double? subtitleDelaySeconds,
  }) => PlaybackSettings.bounded(
    qualityPreset: qualityPreset ?? this.qualityPreset,
    preferHardwareDecoding:
        preferHardwareDecoding ?? this.preferHardwareDecoding,
    ramPreservation: ramPreservation ?? this.ramPreservation,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    gamma: gamma ?? this.gamma,
    audioDelaySeconds: audioDelaySeconds ?? this.audioDelaySeconds,
    subtitleDelaySeconds: subtitleDelaySeconds ?? this.subtitleDelaySeconds,
  );

  /// Returns a copy with every numeric setting clamped to its supported range.
  PlaybackSettings normalized() => PlaybackSettings.bounded(
    qualityPreset: qualityPreset,
    preferHardwareDecoding: preferHardwareDecoding,
    ramPreservation: ramPreservation,
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
    gamma: gamma,
    audioDelaySeconds: audioDelaySeconds,
    subtitleDelaySeconds: subtitleDelaySeconds,
  );

  factory PlaybackSettings.bounded({
    PlaybackQualityPreset qualityPreset = PlaybackQualityPreset.balanced,
    bool preferHardwareDecoding = true,
    bool ramPreservation = false,
    double brightness = 0,
    double contrast = 0,
    double saturation = 0,
    double gamma = 0,
    double audioDelaySeconds = 0,
    double subtitleDelaySeconds = 0,
  }) => PlaybackSettings(
    qualityPreset: qualityPreset,
    preferHardwareDecoding: preferHardwareDecoding,
    ramPreservation: ramPreservation,
    brightness: _bounded(brightness, min: -100, max: 100),
    contrast: _bounded(contrast, min: -100, max: 100),
    saturation: _bounded(saturation, min: -100, max: 100),
    gamma: _bounded(gamma, min: -100, max: 100),
    audioDelaySeconds: _bounded(audioDelaySeconds, min: -10, max: 10),
    subtitleDelaySeconds: _bounded(subtitleDelaySeconds, min: -10, max: 10),
  );

  factory PlaybackSettings.fromJson(Object? value) {
    if (value is! Map) return defaults;
    final json = Map<Object?, Object?>.from(value);
    final preset = switch (json['qualityPreset']) {
      'performance' => PlaybackQualityPreset.performance,
      'quality' => PlaybackQualityPreset.quality,
      _ => PlaybackQualityPreset.balanced,
    };
    return PlaybackSettings.bounded(
      qualityPreset: preset,
      preferHardwareDecoding: json['preferHardwareDecoding'] != false,
      ramPreservation: json['ramPreservation'] == true,
      brightness: _readNumber(json['brightness']),
      contrast: _readNumber(json['contrast']),
      saturation: _readNumber(json['saturation']),
      gamma: _readNumber(json['gamma']),
      audioDelaySeconds: _readNumber(json['audioDelaySeconds']),
      subtitleDelaySeconds: _readNumber(json['subtitleDelaySeconds']),
    );
  }

  Map<String, Object?> toJson() {
    final safe = normalized();
    return <String, Object?>{
      'qualityPreset': safe.qualityPreset.name,
      'preferHardwareDecoding': safe.preferHardwareDecoding,
      'ramPreservation': safe.ramPreservation,
      'brightness': safe.brightness,
      'contrast': safe.contrast,
      'saturation': safe.saturation,
      'gamma': safe.gamma,
      'audioDelaySeconds': safe.audioDelaySeconds,
      'subtitleDelaySeconds': safe.subtitleDelaySeconds,
    };
  }

  static double _readNumber(Object? value) =>
      value is num ? value.toDouble() : 0;

  static double _bounded(
    double value, {
    required double min,
    required double max,
  }) {
    if (!value.isFinite) return 0;
    return value.clamp(min, max).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackSettings &&
      other.qualityPreset == qualityPreset &&
      other.preferHardwareDecoding == preferHardwareDecoding &&
      other.ramPreservation == ramPreservation &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.gamma == gamma &&
      other.audioDelaySeconds == audioDelaySeconds &&
      other.subtitleDelaySeconds == subtitleDelaySeconds;

  @override
  int get hashCode => Object.hash(
    qualityPreset,
    preferHardwareDecoding,
    ramPreservation,
    brightness,
    contrast,
    saturation,
    gamma,
    audioDelaySeconds,
    subtitleDelaySeconds,
  );
}
