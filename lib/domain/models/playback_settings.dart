/// Fixed playback tuning presets understood by the bundled mpv engine.
enum PlaybackQualityPreset { performance, balanced, quality }

enum ResumeBehavior { automatic, ask, startOver }

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
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.gamma = 0,
    this.audioDelaySeconds = 0,
    this.subtitleDelaySeconds = 0,
    this.subtitleFont = 'sans-serif',
    this.subtitleFontSize = 55,
    this.subtitleColor = '#FFFFFF',
    this.subtitleOutlineSize = 3,
    this.subtitleBackgroundOpacity = 0,
    this.subtitlePosition = 100,
    this.preferredAudioLanguages = '',
    this.preferredSubtitleLanguages = '',
    this.resumeBehavior = ResumeBehavior.automatic,
  });

  static const PlaybackSettings defaults = PlaybackSettings();

  final PlaybackQualityPreset qualityPreset;
  final bool preferHardwareDecoding;
  final double brightness;
  final double contrast;
  final double saturation;
  final double gamma;
  final double audioDelaySeconds;
  final double subtitleDelaySeconds;
  final String subtitleFont;
  final double subtitleFontSize;
  final String subtitleColor;
  final double subtitleOutlineSize;
  final double subtitleBackgroundOpacity;
  final double subtitlePosition;
  final String preferredAudioLanguages;
  final String preferredSubtitleLanguages;
  final ResumeBehavior resumeBehavior;

  PlaybackSettings copyWith({
    PlaybackQualityPreset? qualityPreset,
    bool? preferHardwareDecoding,
    double? brightness,
    double? contrast,
    double? saturation,
    double? gamma,
    double? audioDelaySeconds,
    double? subtitleDelaySeconds,
    String? subtitleFont,
    double? subtitleFontSize,
    String? subtitleColor,
    double? subtitleOutlineSize,
    double? subtitleBackgroundOpacity,
    double? subtitlePosition,
    String? preferredAudioLanguages,
    String? preferredSubtitleLanguages,
    ResumeBehavior? resumeBehavior,
  }) => PlaybackSettings.bounded(
    qualityPreset: qualityPreset ?? this.qualityPreset,
    preferHardwareDecoding:
        preferHardwareDecoding ?? this.preferHardwareDecoding,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    gamma: gamma ?? this.gamma,
    audioDelaySeconds: audioDelaySeconds ?? this.audioDelaySeconds,
    subtitleDelaySeconds: subtitleDelaySeconds ?? this.subtitleDelaySeconds,
    subtitleFont: subtitleFont ?? this.subtitleFont,
    subtitleFontSize: subtitleFontSize ?? this.subtitleFontSize,
    subtitleColor: subtitleColor ?? this.subtitleColor,
    subtitleOutlineSize: subtitleOutlineSize ?? this.subtitleOutlineSize,
    subtitleBackgroundOpacity:
        subtitleBackgroundOpacity ?? this.subtitleBackgroundOpacity,
    subtitlePosition: subtitlePosition ?? this.subtitlePosition,
    preferredAudioLanguages:
        preferredAudioLanguages ?? this.preferredAudioLanguages,
    preferredSubtitleLanguages:
        preferredSubtitleLanguages ?? this.preferredSubtitleLanguages,
    resumeBehavior: resumeBehavior ?? this.resumeBehavior,
  );

  /// Returns a copy with every numeric setting clamped to its supported range.
  PlaybackSettings normalized() => PlaybackSettings.bounded(
    qualityPreset: qualityPreset,
    preferHardwareDecoding: preferHardwareDecoding,
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
    gamma: gamma,
    audioDelaySeconds: audioDelaySeconds,
    subtitleDelaySeconds: subtitleDelaySeconds,
    subtitleFont: subtitleFont,
    subtitleFontSize: subtitleFontSize,
    subtitleColor: subtitleColor,
    subtitleOutlineSize: subtitleOutlineSize,
    subtitleBackgroundOpacity: subtitleBackgroundOpacity,
    subtitlePosition: subtitlePosition,
    preferredAudioLanguages: preferredAudioLanguages,
    preferredSubtitleLanguages: preferredSubtitleLanguages,
    resumeBehavior: resumeBehavior,
  );

  factory PlaybackSettings.bounded({
    PlaybackQualityPreset qualityPreset = PlaybackQualityPreset.balanced,
    bool preferHardwareDecoding = true,
    double brightness = 0,
    double contrast = 0,
    double saturation = 0,
    double gamma = 0,
    double audioDelaySeconds = 0,
    double subtitleDelaySeconds = 0,
    String subtitleFont = 'sans-serif',
    double subtitleFontSize = 55,
    String subtitleColor = '#FFFFFF',
    double subtitleOutlineSize = 3,
    double subtitleBackgroundOpacity = 0,
    double subtitlePosition = 100,
    String preferredAudioLanguages = '',
    String preferredSubtitleLanguages = '',
    ResumeBehavior resumeBehavior = ResumeBehavior.automatic,
  }) => PlaybackSettings(
    qualityPreset: qualityPreset,
    preferHardwareDecoding: preferHardwareDecoding,
    brightness: _bounded(brightness, min: -100, max: 100),
    contrast: _bounded(contrast, min: -100, max: 100),
    saturation: _bounded(saturation, min: -100, max: 100),
    gamma: _bounded(gamma, min: -100, max: 100),
    audioDelaySeconds: _bounded(audioDelaySeconds, min: -10, max: 10),
    subtitleDelaySeconds: _bounded(subtitleDelaySeconds, min: -10, max: 10),
    subtitleFont: _font(subtitleFont),
    subtitleFontSize: _bounded(subtitleFontSize, min: 12, max: 120),
    subtitleColor: _color(subtitleColor),
    subtitleOutlineSize: _bounded(subtitleOutlineSize, min: 0, max: 10),
    subtitleBackgroundOpacity: _bounded(
      subtitleBackgroundOpacity,
      min: 0,
      max: 1,
    ),
    subtitlePosition: _bounded(subtitlePosition, min: 0, max: 100),
    preferredAudioLanguages: _languages(preferredAudioLanguages),
    preferredSubtitleLanguages: _languages(preferredSubtitleLanguages),
    resumeBehavior: resumeBehavior,
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
      brightness: _readNumber(json['brightness']),
      contrast: _readNumber(json['contrast']),
      saturation: _readNumber(json['saturation']),
      gamma: _readNumber(json['gamma']),
      audioDelaySeconds: _readNumber(json['audioDelaySeconds']),
      subtitleDelaySeconds: _readNumber(json['subtitleDelaySeconds']),
      subtitleFont: json['subtitleFont'] is String
          ? json['subtitleFont'] as String
          : 'sans-serif',
      subtitleFontSize: _readNumber(json['subtitleFontSize'], fallback: 55),
      subtitleColor: json['subtitleColor'] is String
          ? json['subtitleColor'] as String
          : '#FFFFFF',
      subtitleOutlineSize: _readNumber(
        json['subtitleOutlineSize'],
        fallback: 3,
      ),
      subtitleBackgroundOpacity: _readNumber(json['subtitleBackgroundOpacity']),
      subtitlePosition: _readNumber(json['subtitlePosition'], fallback: 100),
      preferredAudioLanguages: json['preferredAudioLanguages'] is String
          ? json['preferredAudioLanguages'] as String
          : '',
      preferredSubtitleLanguages: json['preferredSubtitleLanguages'] is String
          ? json['preferredSubtitleLanguages'] as String
          : '',
      resumeBehavior: switch (json['resumeBehavior']) {
        'ask' => ResumeBehavior.ask,
        'startOver' => ResumeBehavior.startOver,
        _ => ResumeBehavior.automatic,
      },
    );
  }

  Map<String, Object?> toJson() {
    final safe = normalized();
    return <String, Object?>{
      'qualityPreset': safe.qualityPreset.name,
      'preferHardwareDecoding': safe.preferHardwareDecoding,
      'brightness': safe.brightness,
      'contrast': safe.contrast,
      'saturation': safe.saturation,
      'gamma': safe.gamma,
      'audioDelaySeconds': safe.audioDelaySeconds,
      'subtitleDelaySeconds': safe.subtitleDelaySeconds,
      'subtitleFont': safe.subtitleFont,
      'subtitleFontSize': safe.subtitleFontSize,
      'subtitleColor': safe.subtitleColor,
      'subtitleOutlineSize': safe.subtitleOutlineSize,
      'subtitleBackgroundOpacity': safe.subtitleBackgroundOpacity,
      'subtitlePosition': safe.subtitlePosition,
      'preferredAudioLanguages': safe.preferredAudioLanguages,
      'preferredSubtitleLanguages': safe.preferredSubtitleLanguages,
      'resumeBehavior': safe.resumeBehavior.name,
    };
  }

  static double _readNumber(Object? value, {double fallback = 0}) =>
      value is num ? value.toDouble() : fallback;

  static String _font(String value) {
    final font = value.trim();
    if (font.isEmpty) return 'sans-serif';
    return font.length > 80 ? font.substring(0, 80) : font;
  }

  static String _color(String value) {
    final color = value.trim().toUpperCase();
    return RegExp(r'^#[0-9A-F]{6}$').hasMatch(color) ? color : '#FFFFFF';
  }

  static String _languages(String value) {
    final tags = <String>[];
    for (final raw in value.split(',')) {
      final tag = raw.trim();
      if (!_isLanguageTag(tag)) continue;
      final normalized = tag.toLowerCase();
      if (!tags.contains(normalized)) tags.add(normalized);
    }
    return tags.join(',');
  }

  static bool _isLanguageTag(String tag) {
    final parts = tag.split('-');
    if (tag.isEmpty || parts.any((part) => part.isEmpty)) return false;
    final primary = parts.first;
    if (primary.toLowerCase() == 'x') {
      if (parts.length < 2) return false;
      return parts
          .skip(1)
          .every((part) => RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(part));
    }
    if (!RegExp(r'^[A-Za-z]{2,8}$').hasMatch(primary)) return false;
    var index = 1;

    // BCP 47 extlang subtags are three letters after a two- or three-letter
    // primary language. Accept up to the standard maximum of three.
    if (primary.length <= 3) {
      var extlangCount = 0;
      while (index < parts.length &&
          extlangCount < 3 &&
          RegExp(r'^[A-Za-z]{3}$').hasMatch(parts[index])) {
        index++;
        extlangCount++;
      }
    }
    if (index < parts.length &&
        RegExp(r'^[A-Za-z]{4}$').hasMatch(parts[index])) {
      index++;
    }
    if (index < parts.length &&
        RegExp(r'^(?:[A-Za-z]{2}|[0-9]{3})$').hasMatch(parts[index])) {
      index++;
    }
    while (index < parts.length &&
        RegExp(
          r'^(?:[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3})$',
        ).hasMatch(parts[index])) {
      index++;
    }

    final extensions = <String>{};
    while (index < parts.length &&
        RegExp(r'^[0-9A-WY-Za-wy-z]$').hasMatch(parts[index])) {
      final singleton = parts[index].toLowerCase();
      if (!extensions.add(singleton)) return false;
      index++;
      final start = index;
      while (index < parts.length &&
          RegExp(r'^[A-Za-z0-9]{2,8}$').hasMatch(parts[index])) {
        index++;
      }
      if (index == start) return false;
    }
    if (index < parts.length && parts[index].toLowerCase() == 'x') {
      index++;
      final start = index;
      while (index < parts.length &&
          RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(parts[index])) {
        index++;
      }
      if (index == start) return false;
    }
    return index == parts.length;
  }

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
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.gamma == gamma &&
      other.audioDelaySeconds == audioDelaySeconds &&
      other.subtitleDelaySeconds == subtitleDelaySeconds &&
      other.subtitleFont == subtitleFont &&
      other.subtitleFontSize == subtitleFontSize &&
      other.subtitleColor == subtitleColor &&
      other.subtitleOutlineSize == subtitleOutlineSize &&
      other.subtitleBackgroundOpacity == subtitleBackgroundOpacity &&
      other.subtitlePosition == subtitlePosition &&
      other.preferredAudioLanguages == preferredAudioLanguages &&
      other.preferredSubtitleLanguages == preferredSubtitleLanguages &&
      other.resumeBehavior == resumeBehavior;

  @override
  int get hashCode => Object.hash(
    qualityPreset,
    preferHardwareDecoding,
    brightness,
    contrast,
    saturation,
    gamma,
    audioDelaySeconds,
    subtitleDelaySeconds,
    subtitleFont,
    subtitleFontSize,
    subtitleColor,
    subtitleOutlineSize,
    subtitleBackgroundOpacity,
    subtitlePosition,
    preferredAudioLanguages,
    preferredSubtitleLanguages,
    resumeBehavior,
  );
}
