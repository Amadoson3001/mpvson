import 'package:flutter/foundation.dart';

import 'stream_rendition.dart';

export 'stream_rendition.dart';

/// Represents the resolved direct media stream and metadata produced by a stream resolver.
@immutable
class ResolvedStream {
  /// The original page or media URL that was resolved.
  final String originalUrl;

  /// The direct media or manifest stream URL to play.
  final String streamUrl;

  /// Optional synchronized external audio URL for split audio/video formats.
  final String? audioUrl;

  /// Resolved title of the stream.
  final String? title;

  /// Origin-scoped HTTP headers required to stream the media.
  final Map<String, String>? httpHeaders;

  /// Available stream renditions / qualities.
  final List<StreamRendition> renditions;

  /// Whether the resolved media URL contains temporary CDN tokens that will expire.
  final bool isExpiring;

  /// Expected expiration timestamp of the stream URL, if known.
  final DateTime? expiresAt;

  /// The identifier of the selected format or rendition.
  final String? formatId;

  /// The extractor used to resolve this stream (e.g. "youtube", "vimeo", "generic").
  final String? extractor;

  /// Total duration of the stream if known.
  final Duration? duration;

  const ResolvedStream({
    required this.originalUrl,
    required this.streamUrl,
    this.audioUrl,
    this.title,
    this.httpHeaders,
    this.renditions = const [],
    this.isExpiring = false,
    this.expiresAt,
    this.formatId,
    this.extractor,
    this.duration,
  });

  /// Whether this stream requires a separate audio input.
  bool get hasSeparateAudio => audioUrl != null && audioUrl != streamUrl;

  /// Whether the resolved URL is already expired.
  bool isExpired({DateTime? now}) {
    if (expiresAt == null) return false;
    return (now ?? DateTime.now()).isAfter(expiresAt!);
  }

  /// Whether the resolved URL is near expiry within the specified [threshold].
  bool isNearExpiry({
    DateTime? now,
    Duration threshold = const Duration(minutes: 5),
  }) {
    if (expiresAt == null) return false;
    return (now ?? DateTime.now()).add(threshold).isAfter(expiresAt!);
  }

  /// The rendition matching [formatId], if available.
  StreamRendition? get selectedRendition {
    if (formatId == null) return null;
    return renditions.where((r) => r.id == formatId).firstOrNull;
  }

  ResolvedStream copyWith({
    String? originalUrl,
    String? streamUrl,
    String? audioUrl,
    bool clearAudioUrl = false,
    String? title,
    Map<String, String>? httpHeaders,
    List<StreamRendition>? renditions,
    bool? isExpiring,
    DateTime? expiresAt,
    bool clearExpiresAt = false,
    String? formatId,
    String? extractor,
    Duration? duration,
  }) {
    return ResolvedStream(
      originalUrl: originalUrl ?? this.originalUrl,
      streamUrl: streamUrl ?? this.streamUrl,
      audioUrl: clearAudioUrl ? null : (audioUrl ?? this.audioUrl),
      title: title ?? this.title,
      httpHeaders: httpHeaders ?? this.httpHeaders,
      renditions: renditions ?? this.renditions,
      isExpiring: isExpiring ?? this.isExpiring,
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      formatId: formatId ?? this.formatId,
      extractor: extractor ?? this.extractor,
      duration: duration ?? this.duration,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ResolvedStream &&
        other.originalUrl == originalUrl &&
        other.streamUrl == streamUrl &&
        other.audioUrl == audioUrl &&
        other.title == title &&
        mapEquals(other.httpHeaders, httpHeaders) &&
        listEquals(other.renditions, renditions) &&
        other.isExpiring == isExpiring &&
        other.expiresAt == expiresAt &&
        other.formatId == formatId &&
        other.extractor == extractor &&
        other.duration == duration;
  }

  @override
  int get hashCode => Object.hash(
    originalUrl,
    streamUrl,
    audioUrl,
    title,
    _hashHeaders(httpHeaders),
    Object.hashAll(renditions),
    isExpiring,
    expiresAt,
    formatId,
    extractor,
    duration,
  );

  @override
  String toString() {
    return 'ResolvedStream('
        'originalUrl: $originalUrl, '
        'streamUrl: $streamUrl, '
        'audioUrl: ${audioUrl != null ? "<paired>" : "none"}, '
        'formatId: $formatId, '
        'isExpiring: $isExpiring, '
        'renditions: ${renditions.length}'
        ')';
  }
}

int _hashHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return 0;
  var hash = 0;
  for (final entry in headers.entries) {
    hash ^= Object.hash(entry.key, entry.value);
  }
  return hash;
}
