import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'media_catalog.dart';

/// A single source in the player's queue or listening history.
///
/// Queue entries carry a unique [id], even when two entries refer to the same
/// file. History entries use [canonicalSource] as their id so repeated plays
/// of the same source update one row instead of creating duplicates.
///
/// [title], [position], and [duration] are session/queue fields. Probed
/// library properties (artist, album, artwork, codec) live on
/// [MediaMetadata], owned by [MediaItemRecord.metadata].
class MediaEntry {
  const MediaEntry({
    required this.id,
    required this.path,
    required this.title,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    required this.lastPlayed,
  });

  final String id;
  final String path;
  final String title;
  final Duration position;
  final Duration duration;
  final DateTime lastPlayed;

  /// Longest media duration accepted from stored data (30 days). Values beyond
  /// this are corrupt rather than long, and are clamped instead of overflowing.
  static const int maximumStoredMilliseconds = 30 * 24 * 60 * 60 * 1000;

  /// Longest stored text field accepted from stored data.
  static const int maximumStoredTextLength = 4096;

  factory MediaEntry.fromPath(
    String source, {
    required String id,
    DateTime? lastPlayed,
  }) {
    final normalizedSource = normalizeSourcePath(source);
    return MediaEntry(
      id: id,
      path: normalizedSource,
      title: titleFromPath(normalizedSource),
      lastPlayed: lastPlayed ?? DateTime.now(),
    );
  }

  factory MediaEntry.fromJson(Map<String, Object?> json) {
    final source = _asText(json['path']);
    final rawLastPlayed = json['lastPlayed'];
    final parsedTime = rawLastPlayed is String
        ? DateTime.tryParse(rawLastPlayed)
        : null;
    final title = _asText(json['title']);
    return MediaEntry(
      id: _asText(json['id'], fallback: canonicalSource(source)),
      path: source,
      title: title.trim().isNotEmpty ? title : titleFromPath(source),
      position: Duration(milliseconds: _asInt(json['positionMs'])),
      duration: Duration(milliseconds: _asInt(json['durationMs'])),
      lastPlayed: parsedTime ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'path': path,
    'title': title,
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    'lastPlayed': lastPlayed.toIso8601String(),
  };

  MediaEntry copyWith({
    String? id,
    String? path,
    String? title,
    Duration? position,
    Duration? duration,
    DateTime? lastPlayed,
  }) {
    return MediaEntry(
      id: id ?? this.id,
      path: path ?? this.path,
      title: title ?? this.title,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      lastPlayed: lastPlayed ?? this.lastPlayed,
    );
  }

  /// Whether [source] represents a network HTTP or HTTPS address.
  static bool isNetworkUrl(String source) {
    final trimmed = source.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  /// Converts local file paths and file URIs to normalized absolute filesystem
  /// paths, while preserving http and https URLs untouched.
  static String normalizeSourcePath(String source) {
    final trimmed = source.trim();
    if (isNetworkUrl(trimmed)) {
      return trimmed;
    }

    var filePath = stripLongPathPrefix(trimmed);
    final uri = Uri.tryParse(filePath);
    if (uri != null && uri.scheme.toLowerCase() == 'file') {
      try {
        filePath = uri.toFilePath(windows: Platform.isWindows);
      } on UnsupportedError {
        filePath = uri.path;
        if (Platform.isWindows &&
            filePath.startsWith('/') &&
            filePath.length > 2 &&
            filePath[2] == ':') {
          filePath = filePath.substring(1);
        }
      }
      filePath = stripLongPathPrefix(filePath);
    }

    if (Platform.isWindows &&
        filePath.startsWith('/') &&
        filePath.length > 2 &&
        RegExp(r'^[a-zA-Z]:').hasMatch(filePath.substring(1))) {
      filePath = filePath.substring(1);
    }

    return p.normalize(p.absolute(filePath));
  }

  /// Returns a stable key for a source, independent of its queue occurrence.
  static String canonicalSource(String source) {
    final trimmed = source.trim();
    if (isNetworkUrl(trimmed)) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null) {
        // The fragment never reaches the engine, so it must not make two
        // identities differ. `removeFragment` also avoids an empty `#` marker.
        return uri.removeFragment().toString();
      }
      return trimmed;
    }

    final normalized = normalizeSourcePath(trimmed);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  /// Removes the Windows long-path prefix (`\\?\`) that libmpv reports for a
  /// loaded source, so engine identity compares equal to the user's path.
  static String stripLongPathPrefix(String source) {
    const longPrefix = r'\\?\';
    const uncPrefix = r'\\?\UNC\';
    if (source.startsWith(uncPrefix)) {
      return '\\\\${source.substring(uncPrefix.length)}';
    }
    if (source.startsWith(longPrefix) &&
        source.length > longPrefix.length &&
        !source.substring(longPrefix.length).startsWith('UNC')) {
      return source.substring(longPrefix.length);
    }
    return source;
  }

  /// Formats [source] for user display, preserving the filesystem's actual
  /// on-disk casing if the directory or file exists on disk.
  ///
  /// On case-insensitive filesystems (such as Windows), paths may be stored
  /// lowercased or normalized. This retrieves the canonical casing from the
  /// filesystem using [Directory.resolveSymbolicLinksSync] or
  /// [File.resolveSymbolicLinksSync], falling back to [source] if unavailable
  /// or on any error.
  static final LinkedHashMap<String, String> _displayPathCache =
      LinkedHashMap<String, String>();
  static const int _maxDisplayPathCache = 256;

  static String formatDisplayPath(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty || isNetworkUrl(trimmed)) {
      return source;
    }
    final cached = _displayPathCache.remove(trimmed);
    if (cached != null) {
      _displayPathCache[trimmed] = cached;
      return cached;
    }
    try {
      final dir = Directory(trimmed);
      if (dir.existsSync()) {
        final resolved = p.normalize(
          stripLongPathPrefix(dir.resolveSymbolicLinksSync()),
        );
        _recordDisplayPath(trimmed, resolved);
        return resolved;
      }
      final file = File(trimmed);
      if (file.existsSync()) {
        final resolved = p.normalize(
          stripLongPathPrefix(file.resolveSymbolicLinksSync()),
        );
        _recordDisplayPath(trimmed, resolved);
        return resolved;
      }
    } catch (_) {
      // Fallback on any error (e.g. drive disconnected, permission denied).
    }
    // Cache misses too so list rebuilds do not keep hitting existsSync.
    _recordDisplayPath(trimmed, source);
    return source;
  }

  static void _recordDisplayPath(String source, String resolved) {
    _displayPathCache[source] = resolved;
    while (_displayPathCache.length > _maxDisplayPathCache) {
      _displayPathCache.remove(_displayPathCache.keys.first);
    }
  }

  /// Alias for [formatDisplayPath] retrieving the filesystem's canonical case.
  static String canonicalCase(String source) => formatDisplayPath(source);

  static String titleFromPath(String source) {
    if (isNetworkUrl(source)) {
      final uri = Uri.tryParse(source);
      if (uri != null) {
        try {
          final lastSegment = uri.pathSegments.isEmpty
              ? ''
              : uri.pathSegments.last;
          if (lastSegment.isNotEmpty) {
            return MediaCatalog.displayName(Uri.decodeComponent(lastSegment));
          }
          return uri.host.isEmpty ? source : uri.host;
        } on Object {
          // A percent escape can be syntactically valid yet not decode as UTF-8.
          // The title is display-only, so keep the raw final segment instead of
          // failing the whole row.
          final segments = uri.path
              .split('/')
              .where((segment) => segment.isNotEmpty);
          final rawSegment = segments.isEmpty ? '' : segments.last;
          if (rawSegment.isNotEmpty) {
            return MediaCatalog.displayName(rawSegment);
          }
          return uri.host.isEmpty ? source : uri.host;
        }
      }
      return source;
    }

    final normalized = normalizeSourcePath(source);
    final name = p.basename(normalized);
    return name.isEmpty ? normalized : MediaCatalog.displayName(name);
  }

  static int _asInt(Object? value) {
    if (value is int) {
      if (value <= 0) return 0;
      return value > maximumStoredMilliseconds
          ? maximumStoredMilliseconds
          : value;
    }
    if (value is num) {
      if (!value.isFinite || value <= 0) return 0;
      // Clamp before rounding: converting a huge double is not guaranteed to
      // saturate and could wrap into a negative duration.
      if (value >= maximumStoredMilliseconds) {
        return maximumStoredMilliseconds;
      }
      return value.round();
    }
    return 0;
  }

  static String _asText(Object? value, {String fallback = ''}) {
    if (value is! String) return fallback;
    if (value.length <= maximumStoredTextLength) return value;
    return value.substring(0, maximumStoredTextLength);
  }
}
