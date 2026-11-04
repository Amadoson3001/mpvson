import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/gpu_adapter.dart';
import 'diagnostic_log.dart';

/// Read-only GPU diagnostics and the Windows per-app GPU preference.
class GpuInfoService {
  GpuInfoService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('mpvson/gpu');

  final MethodChannel _channel;
  Future<GpuDefaultAdapter?>? _defaultAdapter;

  Future<GpuSnapshot?> snapshot() async {
    final raw = await _invoke<Map<Object?, Object?>>('snapshot');
    if (raw == null) return null;
    return GpuSnapshot.fromJson(raw);
  }

  /// Predicts the adapter both ANGLE devices will use at launch.
  ///
  /// The native probe creates and releases a throwaway D3D11 device, so the
  /// result is cached for the lifetime of this service.
  Future<GpuDefaultAdapter?> resolveDefault({bool refresh = false}) {
    if (!refresh) {
      final cached = _defaultAdapter;
      if (cached != null) return cached;
    }
    final future = _readDefault();
    _defaultAdapter = future;
    return future;
  }

  Future<GpuDefaultAdapter?> _readDefault() async {
    final raw = await _invoke<Object?>('resolveDefault');
    if (raw == null) return null;
    return GpuDefaultAdapter.tryParse(raw);
  }

  Future<int?> readPreference() async {
    final value = await _invoke<int>('readPreference');
    if (value == null || value < 0 || value > 2) return null;
    return value;
  }

  Future<bool> setPreference(int level) async {
    if (level < 0 || level > 2) return false;
    final result = await _invoke<bool>('setPreference', level);
    return result ?? false;
  }

  Future<bool> clearPreference() async {
    final result = await _invoke<bool>('clearPreference');
    return result ?? false;
  }

  /// Writes the full diagnostic snapshot beside `diagnostics.log`.
  Future<File?> writeSnapshot({Directory? directory}) async {
    final gpuSnapshot = await snapshot();
    final defaultAdapter = await resolveDefault();
    final preference = await readPreference();
    final payload = <String, Object?>{
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'defaultAdapter': defaultAdapter?.toJson(),
      'preference': preference,
      'snapshot': gpuSnapshot?.toJson(),
    };

    try {
      final target = directory ?? await _defaultDirectory();
      await target.create(recursive: true);
      final file = File(p.join(target.path, 'gpu_snapshot.json'));
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
      return file;
    } on Object {
      return null;
    }
  }

  Future<void> recordSnapshot(
    DiagnosticSink sink, {
    Directory? directory,
  }) async {
    final file = await writeSnapshot(directory: directory);
    if (file == null) {
      sink.record('gpu.snapshot', message: 'GPU diagnostics were unavailable.');
      return;
    }
    sink.record('gpu.snapshot', message: 'Wrote ${file.path}');
  }

  Future<Directory> _defaultDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'mpvson'));
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
