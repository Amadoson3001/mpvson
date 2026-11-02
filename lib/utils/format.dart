/// Formats a [Duration] into a standardized timestamp:
/// - If duration is 1 hour or greater: `h:mm:ss` (e.g. `1:05:23`)
/// - Otherwise: `mm:ss` (e.g. `05:23` or `00:45`)
///
/// If [compactMinutes] is true and duration is less than 1 hour, minutes are
/// unpadded (e.g. `5:23` instead of `05:23`).
/// Negative durations preserve their negative sign (e.g. `-00:15` or `-1:02:03`).
String formatDuration(Duration d, {bool compactMinutes = false}) {
  final isNegative = d.isNegative;
  final abs = d.abs();
  final hours = abs.inHours;
  final minutes = abs.inMinutes.remainder(60);
  final seconds = abs.inSeconds.remainder(60);
  final prefix = isNegative ? '-' : '';

  final secondsStr = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final minutesStr = minutes.toString().padLeft(2, '0');
    return '$prefix$hours:$minutesStr:$secondsStr';
  }

  final minutesStr = compactMinutes
      ? minutes.toString()
      : minutes.toString().padLeft(2, '0');
  return '$prefix$minutesStr:$secondsStr';
}

/// Convenience alias for [formatDuration] matching player chrome conventions.
String formatTime(Duration d, {bool compactMinutes = false}) =>
    formatDuration(d, compactMinutes: compactMinutes);

/// Convenience wrapper for seconds (as floating point or integer).
String formatDurationSeconds(double seconds, {bool compactMinutes = false}) =>
    formatDuration(
      Duration(milliseconds: (seconds * 1000).round()),
      compactMinutes: compactMinutes,
    );

/// Convenience wrapper for milliseconds.
String formatDurationMs(int milliseconds, {bool compactMinutes = false}) =>
    formatDuration(
      Duration(milliseconds: milliseconds),
      compactMinutes: compactMinutes,
    );

/// Formats file size in bytes to human-readable binary units (B, KB, MB, GB, TB).
String formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  double size = bytes.toDouble();
  while (size >= 1024 && i < suffixes.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(1)} ${suffixes[i]}';
}
