import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'gpu_adapter.dart';
import 'playback_settings.dart';

/// Performance classification derived from CPU, GPU, and system memory.
///
/// - [low]: legacy CPUs, low system RAM, or software/minimal GPUs. Disables
///   heavy blurs, multi-pass shaders, shadows, and large memory caches so the UI
///   and video stay snappy.
/// - [balanced]: modern integrated GPUs or mid-range desktops. Uses clean
///   motion and balanced video scaling without unnecessary GPU bloat.
/// - [high]: discrete GPUs or high-core-count modern APUs with ample RAM.
///   Unlocks larger decoded-image caches and smooth compositing polish.
enum HardwareTier { low, balanced, high }

/// Detected host hardware capabilities used to tune caches, shaders, and motion.
@immutable
class HardwareProfile {
  const HardwareProfile({
    required this.tier,
    required this.cpuCount,
    this.totalPhysicalMemoryBytes,
    this.activeGpu,
    this.hasDiscreteGpu = false,
    this.isSoftwareGpu = false,
  });

  static const int _gib = 1024 * 1024 * 1024;
  static const int _mib = 1024 * 1024;

  /// Conservative baseline used synchronously before async GPU probing settles.
  factory HardwareProfile.initial({required int cpuCount}) {
    final safeCpu = math.max(1, cpuCount);
    final tier = safeCpu <= 4 ? HardwareTier.low : HardwareTier.balanced;
    return HardwareProfile(tier: tier, cpuCount: safeCpu);
  }

  /// Classifies host capabilities from CPU count and optional DXGI diagnostics.
  factory HardwareProfile.detect({
    required int cpuCount,
    GpuSnapshot? gpuSnapshot,
    GpuDefaultAdapter? defaultAdapter,
  }) {
    final safeCpu = math.max(1, cpuCount);
    final adapters = gpuSnapshot?.adapters ?? const <GpuAdapter>[];
    final active =
        gpuSnapshot?.adapterForLuid(defaultAdapter?.luid) ??
        gpuSnapshot?.displayAdapter ??
        (adapters.isNotEmpty ? adapters.first : null);
    final discreteGpu = _pickBestDiscrete(adapters);
    final hasDiscrete = discreteGpu != null;
    final primary = active ?? discreteGpu;

    final isSoftware =
        (primary != null && primary.isSoftware) ||
        (defaultAdapter != null && _looksSoftwareName(defaultAdapter.name));

    final ramBytes = gpuSnapshot?.totalPhysicalMemory;
    final dedicatedVram = (primary?.dedicatedVideoMemory ?? 0) > 0
        ? primary!.dedicatedVideoMemory
        : (discreteGpu?.dedicatedVideoMemory ?? 0);
    final localBudget = primary?.localMemory?.budget ?? 0;
    final effectiveVram = math.max(dedicatedVram, localBudget);

    final HardwareTier tier;
    if (isSoftware ||
        safeCpu <= 2 ||
        (ramBytes != null && ramBytes > 0 && ramBytes <= 4 * _gib) ||
        (safeCpu <= 4 &&
            !hasDiscrete &&
            (ramBytes == null || ramBytes <= 8 * _gib))) {
      tier = HardwareTier.low;
    } else if ((hasDiscrete &&
            effectiveVram >= 1536 * _mib &&
            safeCpu >= 4 &&
            (ramBytes == null || ramBytes >= 8 * _gib)) ||
        (safeCpu >= 8 &&
            !isSoftware &&
            (ramBytes == null || ramBytes >= 12 * _gib))) {
      tier = HardwareTier.high;
    } else {
      tier = HardwareTier.balanced;
    }

    return HardwareProfile(
      tier: tier,
      cpuCount: safeCpu,
      totalPhysicalMemoryBytes: ramBytes,
      activeGpu: primary,
      hasDiscreteGpu: hasDiscrete,
      isSoftwareGpu: isSoftware,
    );
  }

  final HardwareTier tier;
  final int cpuCount;
  final int? totalPhysicalMemoryBytes;
  final GpuAdapter? activeGpu;
  final bool hasDiscreteGpu;
  final bool isSoftwareGpu;

  bool get isConstrained => tier == HardwareTier.low;

  /// Recommended playback quality preset when no user preference has been saved.
  PlaybackQualityPreset get recommendedQualityPreset => switch (tier) {
    HardwareTier.low => PlaybackQualityPreset.performance,
    HardwareTier.balanced => PlaybackQualityPreset.balanced,
    HardwareTier.high => PlaybackQualityPreset.balanced,
  };

  /// Decoded image cache byte ceiling tuned to host RAM and GPU tier.
  int get recommendedImageCacheBytes => switch (tier) {
    HardwareTier.low => 8 * _mib,
    HardwareTier.balanced => 32 * _mib,
    HardwareTier.high => 64 * _mib,
  };

  /// Decoded image cache entry ceiling tuned to host RAM and GPU tier.
  int get recommendedImageCacheCount => switch (tier) {
    HardwareTier.low => 100,
    HardwareTier.balanced => 200,
    HardwareTier.high => 350,
  };

  /// Bounded probe worker count scaled to physical CPU concurrency.
  int get recommendedMaxConcurrentProbes => switch (tier) {
    HardwareTier.low => math.min(2, cpuCount),
    HardwareTier.balanced => math.min(4, cpuCount),
    HardwareTier.high => cpuCount >= 8 ? 6 : 4,
  };

  static GpuAdapter? _pickBestDiscrete(List<GpuAdapter> adapters) {
    GpuAdapter? best;
    for (final adapter in adapters) {
      if (adapter.kind != GpuAdapterKind.discrete) continue;
      if (best == null ||
          adapter.dedicatedVideoMemory > best.dedicatedVideoMemory) {
        best = adapter;
      }
    }
    return best;
  }

  static bool _looksSoftwareName(String name) {
    final lower = name.toLowerCase();
    return lower.contains('basic render') ||
        lower.contains('llvmpipe') ||
        lower.contains('swiftshader') ||
        lower.contains('software');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HardwareProfile &&
          runtimeType == other.runtimeType &&
          tier == other.tier &&
          cpuCount == other.cpuCount &&
          totalPhysicalMemoryBytes == other.totalPhysicalMemoryBytes &&
          activeGpu == other.activeGpu &&
          hasDiscreteGpu == other.hasDiscreteGpu &&
          isSoftwareGpu == other.isSoftwareGpu;

  @override
  int get hashCode => Object.hash(
    tier,
    cpuCount,
    totalPhysicalMemoryBytes,
    activeGpu,
    hasDiscreteGpu,
    isSoftwareGpu,
  );
}
