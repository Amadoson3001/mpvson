import 'dart:math' as math;

import 'package:flutter/foundation.dart';

enum GpuAdapterKind { discrete, integrated, software, unknown }

extension GpuAdapterKindLabel on GpuAdapterKind {
  String get label => switch (this) {
    GpuAdapterKind.discrete => 'Discrete',
    GpuAdapterKind.integrated => 'Integrated',
    GpuAdapterKind.software => 'Software',
    GpuAdapterKind.unknown => 'Unknown',
  };
}

/// Video memory reported by DXGI for one adapter memory segment.
@immutable
class GpuMemoryInfo {
  const GpuMemoryInfo({
    this.usage = 0,
    this.budget = 0,
    this.reservation = 0,
    this.availableForReservation = 0,
  });

  final int usage;
  final int budget;
  final int reservation;
  final int availableForReservation;

  static GpuMemoryInfo? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = Map<Object?, Object?>.from(value);
    return GpuMemoryInfo(
      usage: _readBytes(json['usage']),
      budget: _readBytes(json['budget']),
      reservation: _readBytes(json['reservation']),
      availableForReservation: _readBytes(json['availableForReservation']),
    );
  }

  GpuMemoryInfo normalized() => GpuMemoryInfo(
    usage: math.max(0, usage),
    budget: math.max(0, budget),
    reservation: math.max(0, reservation),
    availableForReservation: math.max(0, availableForReservation),
  );

  Map<String, Object?> toJson() {
    final safe = normalized();
    return <String, Object?>{
      'usage': safe.usage,
      'budget': safe.budget,
      'reservation': safe.reservation,
      'availableForReservation': safe.availableForReservation,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GpuMemoryInfo &&
          runtimeType == other.runtimeType &&
          usage == other.usage &&
          budget == other.budget &&
          reservation == other.reservation &&
          availableForReservation == other.availableForReservation;

  @override
  int get hashCode =>
      Object.hash(usage, budget, reservation, availableForReservation);

  @override
  String toString() =>
      'GpuMemoryInfo(usage: $usage, budget: $budget, reservation: $reservation, '
      'availableForReservation: $availableForReservation)';
}

/// A physical or software adapter as reported by DXGI.
@immutable
class GpuAdapter {
  const GpuAdapter({
    required this.name,
    required this.vendorId,
    required this.deviceId,
    this.luid,
    this.dedicatedVideoMemory = 0,
    this.dedicatedSystemMemory = 0,
    this.sharedSystemMemory = 0,
    this.flags = 0,
    this.kind = GpuAdapterKind.unknown,
    this.displayAttached = false,
    this.outputCount = 0,
    this.localMemory,
    this.nonLocalMemory,
  });

  final String name;
  final int vendorId;
  final int deviceId;

  /// Locally unique adapter identifier used to match DXGI and D3D11 probes.
  final int? luid;

  final int dedicatedVideoMemory;
  final int dedicatedSystemMemory;
  final int sharedSystemMemory;
  final int flags;
  final GpuAdapterKind kind;
  final bool displayAttached;
  final int outputCount;

  /// Dedicated segment (`DXGI_MEMORY_SEGMENT_GROUP_LOCAL`).
  final GpuMemoryInfo? localMemory;

  /// Shared system-memory segment (`DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL`).
  final GpuMemoryInfo? nonLocalMemory;

  bool get isSoftware => kind == GpuAdapterKind.software;

  static GpuAdapter? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = Map<Object?, Object?>.from(value);
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final rawMemory = json['memory'];
    final memory = rawMemory is Map
        ? Map<Object?, Object?>.from(rawMemory)
        : null;
    return GpuAdapter(
      name: name,
      vendorId: _readInt(json['vendorId']),
      deviceId: _readInt(json['deviceId']),
      luid: _readNullableInt(json['luid']),
      dedicatedVideoMemory: _readBytes(json['dedicatedVideoMemory']),
      dedicatedSystemMemory: _readBytes(json['dedicatedSystemMemory']),
      sharedSystemMemory: _readBytes(json['sharedSystemMemory']),
      flags: _readInt(json['flags']),
      kind: _parseKind(json['kind']),
      displayAttached: json['displayAttached'] == true,
      outputCount: _readBytes(json['outputCount']),
      localMemory: GpuMemoryInfo.tryParse(memory?['local']),
      nonLocalMemory: GpuMemoryInfo.tryParse(memory?['nonLocal']),
    );
  }

  GpuAdapter normalized() {
    final memory = localMemory?.normalized();
    final nonLocal = nonLocalMemory?.normalized();
    return GpuAdapter(
      name: name.trim(),
      vendorId: math.max(0, vendorId),
      deviceId: math.max(0, deviceId),
      luid: luid,
      dedicatedVideoMemory: math.max(0, dedicatedVideoMemory),
      dedicatedSystemMemory: math.max(0, dedicatedSystemMemory),
      sharedSystemMemory: math.max(0, sharedSystemMemory),
      flags: math.max(0, flags),
      kind: kind,
      displayAttached: displayAttached,
      outputCount: math.max(0, outputCount),
      localMemory: memory,
      nonLocalMemory: nonLocal,
    );
  }

  Map<String, Object?> toJson() {
    final safe = normalized();
    return <String, Object?>{
      'name': safe.name,
      'vendorId': safe.vendorId,
      'deviceId': safe.deviceId,
      if (safe.luid != null) 'luid': safe.luid,
      'dedicatedVideoMemory': safe.dedicatedVideoMemory,
      'dedicatedSystemMemory': safe.dedicatedSystemMemory,
      'sharedSystemMemory': safe.sharedSystemMemory,
      'flags': safe.flags,
      'kind': safe.kind.name,
      'displayAttached': safe.displayAttached,
      'outputCount': safe.outputCount,
      if (safe.localMemory != null || safe.nonLocalMemory != null)
        'memory': <String, Object?>{
          if (safe.localMemory != null) 'local': safe.localMemory!.toJson(),
          if (safe.nonLocalMemory != null)
            'nonLocal': safe.nonLocalMemory!.toJson(),
        },
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GpuAdapter &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          vendorId == other.vendorId &&
          deviceId == other.deviceId &&
          luid == other.luid &&
          dedicatedVideoMemory == other.dedicatedVideoMemory &&
          dedicatedSystemMemory == other.dedicatedSystemMemory &&
          sharedSystemMemory == other.sharedSystemMemory &&
          flags == other.flags &&
          kind == other.kind &&
          displayAttached == other.displayAttached &&
          outputCount == other.outputCount &&
          localMemory == other.localMemory &&
          nonLocalMemory == other.nonLocalMemory;

  @override
  int get hashCode => Object.hash(
    name,
    vendorId,
    deviceId,
    luid,
    dedicatedVideoMemory,
    dedicatedSystemMemory,
    sharedSystemMemory,
    flags,
    kind,
    displayAttached,
    outputCount,
    localMemory,
    nonLocalMemory,
  );

  @override
  String toString() =>
      'GpuAdapter($name, kind: ${kind.name}, luid: $luid, '
      'displayAttached: $displayAttached)';
}

/// Result of the throwaway `D3D11CreateDevice(NULL, HARDWARE)` probe.
@immutable
class GpuDefaultAdapter {
  const GpuDefaultAdapter({
    required this.luid,
    required this.name,
    this.vendorId = 0,
    this.deviceId = 0,
  });

  final int luid;
  final String name;
  final int vendorId;
  final int deviceId;

  static GpuDefaultAdapter? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = Map<Object?, Object?>.from(value);
    final luid = _readNullableInt(json['luid']);
    final name = json['name'];
    if (luid == null || name is! String) return null;
    return GpuDefaultAdapter(
      luid: luid,
      name: name,
      vendorId: _readInt(json['vendorId']),
      deviceId: _readInt(json['deviceId']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'luid': luid,
    'name': name,
    'vendorId': vendorId,
    'deviceId': deviceId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GpuDefaultAdapter &&
          runtimeType == other.runtimeType &&
          luid == other.luid &&
          name == other.name &&
          vendorId == other.vendorId &&
          deviceId == other.deviceId;

  @override
  int get hashCode => Object.hash(luid, name, vendorId, deviceId);

  @override
  String toString() => 'GpuDefaultAdapter($name, luid: $luid)';
}

/// A point-in-time view of the adapters and the per-app preference.
@immutable
class GpuSnapshot {
  const GpuSnapshot({
    this.adapters = const <GpuAdapter>[],
    this.displayAdapterLuid,
    this.preference,
    this.totalPhysicalMemory,
  });

  final List<GpuAdapter> adapters;

  /// Adapter that currently drives an attached display, when known.
  final int? displayAdapterLuid;

  /// Windows per-app preference: 0 = system default, 1 = power saving,
  /// 2 = high performance. Null means no explicit preference.
  final int? preference;

  /// Installed physical system memory in bytes, when reported by the platform.
  final int? totalPhysicalMemory;

  GpuAdapter? get displayAdapter => adapterForLuid(displayAdapterLuid);

  GpuAdapter? adapterForLuid(int? luid) {
    if (luid == null) return null;
    for (final adapter in adapters) {
      if (adapter.luid == luid) return adapter;
    }
    return null;
  }

  static GpuSnapshot fromJson(Object? value) {
    if (value is! Map) return const GpuSnapshot();
    final json = Map<Object?, Object?>.from(value);
    final rawAdapters = json['adapters'];
    final adapters = <GpuAdapter>[];
    if (rawAdapters is List) {
      for (final raw in rawAdapters) {
        final adapter = GpuAdapter.tryParse(raw);
        if (adapter != null) adapters.add(adapter.normalized());
      }
    }
    final rawPreference = _readNullableInt(json['preference']);
    final rawTotalMemory = _readNullableInt(json['totalPhysicalMemory']);
    return GpuSnapshot(
      adapters: List<GpuAdapter>.unmodifiable(adapters),
      displayAdapterLuid: _readNullableInt(json['displayAdapterLuid']),
      preference:
          rawPreference != null && rawPreference >= 0 && rawPreference <= 2
          ? rawPreference
          : null,
      totalPhysicalMemory: rawTotalMemory != null && rawTotalMemory > 0
          ? rawTotalMemory
          : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'adapters': <Object?>[for (final adapter in adapters) adapter.toJson()],
    if (displayAdapterLuid != null) 'displayAdapterLuid': displayAdapterLuid,
    if (preference != null) 'preference': preference,
    if (totalPhysicalMemory != null) 'totalPhysicalMemory': totalPhysicalMemory,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GpuSnapshot &&
          runtimeType == other.runtimeType &&
          listEquals(adapters, other.adapters) &&
          displayAdapterLuid == other.displayAdapterLuid &&
          preference == other.preference &&
          totalPhysicalMemory == other.totalPhysicalMemory;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(adapters),
    displayAdapterLuid,
    preference,
    totalPhysicalMemory,
  );

  @override
  String toString() =>
      'GpuSnapshot(adapters: $adapters, displayAdapterLuid: '
      '$displayAdapterLuid, preference: $preference, '
      'totalPhysicalMemory: $totalPhysicalMemory)';
}

GpuAdapterKind _parseKind(Object? value) => switch (value) {
  'discrete' => GpuAdapterKind.discrete,
  'integrated' => GpuAdapterKind.integrated,
  'software' => GpuAdapterKind.software,
  _ => GpuAdapterKind.unknown,
};

int _readInt(Object? value) {
  if (value is num) return value.toInt();
  return 0;
}

int? _readNullableInt(Object? value) {
  if (value is num) return value.toInt();
  return null;
}

int _readBytes(Object? value) {
  final number = _readInt(value);
  return number < 0 ? 0 : number;
}
