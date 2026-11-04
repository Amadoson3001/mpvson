import 'package:flutter/foundation.dart';

enum GpuPreferenceMode {
  systemDefault,
  powerSaving,
  highPerformance,
  automatic,
}

extension GpuPreferenceModeLabel on GpuPreferenceMode {
  String get label => switch (this) {
    GpuPreferenceMode.systemDefault => 'System default',
    GpuPreferenceMode.powerSaving => 'Power saving',
    GpuPreferenceMode.highPerformance => 'High performance',
    GpuPreferenceMode.automatic => 'Automatic (AC / battery)',
  };

  /// Windows `UserGpuPreferences` level. Automatic must be resolved first.
  int? get registryLevel => switch (this) {
    GpuPreferenceMode.systemDefault => 0,
    GpuPreferenceMode.powerSaving => 1,
    GpuPreferenceMode.highPerformance => 2,
    GpuPreferenceMode.automatic => null,
  };
}

enum VideoMemoryMode { zeroCopy, ramStaged }

extension VideoMemoryModeLabel on VideoMemoryMode {
  String get label => switch (this) {
    VideoMemoryMode.zeroCopy => 'Zero-copy',
    VideoMemoryMode.ramStaged => 'System memory staging',
  };
}

/// Persisted graphics and memory tuning.
///
/// [preferredGpu] only selects a process-wide launch preference; it never
/// pins a device. `automatic` resolves from AC/battery state once at launch.
@immutable
class GraphicsSettings {
  const GraphicsSettings({
    this.preferredGpu = GpuPreferenceMode.systemDefault,
    this.videoMemoryMode = VideoMemoryMode.zeroCopy,
    this.trimOnMinimize = true,
    this.limitDemuxerCache = true,
  });

  static const GraphicsSettings defaults = GraphicsSettings();

  final GpuPreferenceMode preferredGpu;
  final VideoMemoryMode videoMemoryMode;
  final bool trimOnMinimize;
  final bool limitDemuxerCache;

  /// Resolves launch behavior without ever returning [GpuPreferenceMode.automatic].
  GpuPreferenceMode resolvePreferredGpu({bool? onAcPower}) {
    if (preferredGpu != GpuPreferenceMode.automatic) return preferredGpu;
    if (onAcPower == null) return GpuPreferenceMode.systemDefault;
    return onAcPower
        ? GpuPreferenceMode.highPerformance
        : GpuPreferenceMode.powerSaving;
  }

  GraphicsSettings copyWith({
    GpuPreferenceMode? preferredGpu,
    VideoMemoryMode? videoMemoryMode,
    bool? trimOnMinimize,
    bool? limitDemuxerCache,
  }) => GraphicsSettings(
    preferredGpu: preferredGpu ?? this.preferredGpu,
    videoMemoryMode: videoMemoryMode ?? this.videoMemoryMode,
    trimOnMinimize: trimOnMinimize ?? this.trimOnMinimize,
    limitDemuxerCache: limitDemuxerCache ?? this.limitDemuxerCache,
  );

  /// Unknown or corrupt values fall back to safe defaults, never a pinned GPU.
  factory GraphicsSettings.fromJson(Object? value) {
    if (value is! Map) return defaults;
    final json = Map<Object?, Object?>.from(value);
    return GraphicsSettings(
      preferredGpu: _parseGpuPreference(json['preferredGpu']),
      videoMemoryMode: _parseVideoMemoryMode(json['videoMemoryMode']),
      trimOnMinimize: json['trimOnMinimize'] != false,
      limitDemuxerCache: json['limitDemuxerCache'] != false,
    );
  }

  GraphicsSettings normalized() => GraphicsSettings(
    preferredGpu: preferredGpu,
    videoMemoryMode: videoMemoryMode,
    trimOnMinimize: trimOnMinimize,
    limitDemuxerCache: limitDemuxerCache,
  );

  Map<String, Object?> toJson() {
    final safe = normalized();
    return <String, Object?>{
      'preferredGpu': safe.preferredGpu.name,
      'videoMemoryMode': safe.videoMemoryMode.name,
      'trimOnMinimize': safe.trimOnMinimize,
      'limitDemuxerCache': safe.limitDemuxerCache,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphicsSettings &&
          runtimeType == other.runtimeType &&
          preferredGpu == other.preferredGpu &&
          videoMemoryMode == other.videoMemoryMode &&
          trimOnMinimize == other.trimOnMinimize &&
          limitDemuxerCache == other.limitDemuxerCache;

  @override
  int get hashCode => Object.hash(
    preferredGpu,
    videoMemoryMode,
    trimOnMinimize,
    limitDemuxerCache,
  );

  @override
  String toString() =>
      'GraphicsSettings(preferredGpu: ${preferredGpu.name}, '
      'videoMemoryMode: ${videoMemoryMode.name}, '
      'trimOnMinimize: $trimOnMinimize, '
      'limitDemuxerCache: $limitDemuxerCache)';
}

/// Resolves mpv's `hwdec` for the selected memory mode.
String resolveHwdec({
  required bool preferHardwareDecoding,
  required VideoMemoryMode mode,
  required bool isWindows,
}) {
  if (!preferHardwareDecoding) return 'no';
  if (mode == VideoMemoryMode.ramStaged) {
    return isWindows ? 'd3d11va-copy' : 'auto-copy';
  }
  return isWindows ? 'auto-safe' : 'auto';
}

const int _megabyte = 1024 * 1024;

/// Bounded demuxer caps. Disabling the limit restores mpv's 150/75 MiB defaults.
///
/// `lowSpec` covers the performance preset and RAM preservation.
({int forwardBytes, int backBytes}) demuxerCacheLimits({
  required bool limit,
  required bool lowSpec,
}) {
  if (!limit) {
    return (forwardBytes: 150 * _megabyte, backBytes: 75 * _megabyte);
  }
  return lowSpec
      ? (forwardBytes: 48 * _megabyte, backBytes: 16 * _megabyte)
      : (forwardBytes: 128 * _megabyte, backBytes: 48 * _megabyte);
}

GpuPreferenceMode _parseGpuPreference(Object? value) => switch (value) {
  'powerSaving' => GpuPreferenceMode.powerSaving,
  'highPerformance' => GpuPreferenceMode.highPerformance,
  'automatic' => GpuPreferenceMode.automatic,
  'systemDefault' => GpuPreferenceMode.systemDefault,
  _ => GpuPreferenceMode.systemDefault,
};

VideoMemoryMode _parseVideoMemoryMode(Object? value) => switch (value) {
  'ramStaged' => VideoMemoryMode.ramStaged,
  'zeroCopy' => VideoMemoryMode.zeroCopy,
  _ => VideoMemoryMode.zeroCopy,
};
