import 'package:media_kit/media_kit.dart';

typedef PlaybackPropertyReader = Future<String> Function(String name);

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

  static Future<PlaybackStatistics> read(
    PlaybackPropertyReader readProperty, {
    Duration timeout = const Duration(seconds: 2),
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
    return PlaybackStatistics(Map.unmodifiable(Map.fromEntries(values)));
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

Future<PlaybackStatistics> readNativePlaybackStatistics(Player player) async {
  final native = player.platform;
  if (native is! NativePlayer) {
    throw UnsupportedError('Playback information requires a native engine.');
  }
  return PlaybackStatistics.read(native.getProperty);
}
