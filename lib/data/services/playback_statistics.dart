import 'package:media_kit/media_kit.dart';

import '../../domain/models/gpu_adapter.dart';
import 'gpu_info_service.dart';

typedef PlaybackPropertyReader = Future<String> Function(String name);
typedef PlaybackGpuRowReader = Future<Map<String, String>> Function();

/// An on-demand sample. No observers or background polling run during playback.
class PlaybackStatistics {
  const PlaybackStatistics(this.values);

  final Map<String, String> values;

  static const properties = <String, String>{
    'mpv-version': 'Playback engine',
    'video-format': 'Video codec',
    'hwdec-current': 'Active decoder',
    'dwidth': 'Display width',
    'dheight': 'Display height',
    'container-fps': 'Source frame rate',
    'frame-drop-count': 'Frames dropped by output',
    'decoder-frame-drop-count': 'Frames dropped by decoder',
    'avsync': 'Audio/video difference',
    'demuxer-cache-duration': 'Buffered media',
  };

  static const gpuProperties = <String>[
    'Active GPU',
    'GPU type',
    'Dedicated memory (used / budget)',
    'Shared memory (used / budget)',
  ];

  static Future<PlaybackStatistics> read(
    PlaybackPropertyReader readProperty, {
    Duration timeout = const Duration(seconds: 2),
    PlaybackGpuRowReader? readGpuRows,
  }) async {
    final values = await Future.wait(
      properties.entries.map((entry) async {
        String? value;
        try {
          final raw = (await readProperty(entry.key).timeout(timeout)).trim();
          if (raw.isNotEmpty) value = _format(entry.key, raw);
        } on Object {
          // Audio-only sources and older engines omit some video properties.
        }
        return MapEntry(entry.value, value ?? 'Unavailable');
      }),
    );
    final merged = Map<String, String>.fromEntries(values);
    if (readGpuRows != null) {
      try {
        merged.addAll(await readGpuRows());
      } on Object {
        // GPU diagnostics are optional; playback information still stands.
      }
      for (final label in gpuProperties) {
        merged.putIfAbsent(label, () => 'Unavailable');
      }
    }
    return PlaybackStatistics(Map.unmodifiable(merged));
  }

  static Future<Map<String, String>> gpuRows(GpuInfoService gpuInfo) async {
    final snapshotFuture = gpuInfo.snapshot();
    final defaultFuture = gpuInfo.resolveDefault();
    final snapshot = await snapshotFuture;
    final defaultAdapter = await defaultFuture;
    if (defaultAdapter == null) {
      return const <String, String>{
        'Active GPU': 'Unavailable',
        'GPU type': 'Unavailable',
        'Dedicated memory (used / budget)': 'Unavailable',
        'Shared memory (used / budget)': 'Unavailable',
      };
    }

    final adapter = snapshot?.adapterForLuid(defaultAdapter.luid);
    final local = adapter?.localMemory;
    final nonLocal = adapter?.nonLocalMemory;
    return <String, String>{
      'Active GPU': defaultAdapter.name,
      'GPU type': (adapter?.kind ?? GpuAdapterKind.unknown).label,
      'Dedicated memory (used / budget)': local == null
          ? 'Unavailable'
          : '${_formatBytes(local.usage)} / ${_formatBytes(local.budget)}',
      'Shared memory (used / budget)': nonLocal == null
          ? 'Unavailable'
          : '${_formatBytes(nonLocal.usage)} / ${_formatBytes(nonLocal.budget)}',
    };
  }

  static String _format(String property, String raw) {
    if (property == 'hwdec-current') {
      return raw == 'no' ? 'Software' : raw;
    }
    if (property == 'avsync' ||
        property == 'demuxer-cache-duration' ||
        property == 'container-fps') {
      final number = double.tryParse(raw);
      if (number == null || !number.isFinite) return 'Unavailable';
      if (property == 'avsync') {
        return '${(number * 1000).toStringAsFixed(1)} ms';
      }
      if (property == 'container-fps') {
        return '${number.toStringAsFixed(3)} fps';
      }
      return '${number.toStringAsFixed(1)} s';
    }
    return raw;
  }
}

Future<PlaybackStatistics> readNativePlaybackStatistics(
  Player player, {
  GpuInfoService? gpuInfo,
}) async {
  final native = player.platform;
  if (native is! NativePlayer) {
    throw UnsupportedError('Playback information requires a native engine.');
  }
  return PlaybackStatistics.read(
    native.getProperty,
    readGpuRows: gpuInfo == null
        ? null
        : () => PlaybackStatistics.gpuRows(gpuInfo),
  );
}

String _formatBytes(int bytes) {
  const gigabyte = 1024 * 1024 * 1024;
  const megabyte = 1024 * 1024;
  if (bytes >= gigabyte) return '${(bytes / gigabyte).toStringAsFixed(1)} GB';
  if (bytes >= megabyte) return '${(bytes / megabyte).toStringAsFixed(0)} MB';
  if (bytes > 0) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '0 MB';
}
