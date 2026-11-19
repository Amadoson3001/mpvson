import 'package:flutter/foundation.dart';

/// Supported streaming container or manifest formats.
enum StreamFormat { progressive, hls, dash, direct }

/// A single stream rendition or representation (e.g., 1080p, 720p, or synthetic Auto).
@immutable
class StreamRendition {
  /// Unique identifier (e.g. representation ID, edition index, format ID, or variant URI).
  final String id;

  /// User-facing quality label (e.g. "1080p", "720p", "360p", "Auto").
  final String label;

  /// Video horizontal resolution in pixels, if known.
  final int? width;

  /// Video vertical resolution in pixels, if known.
  final int? height;

  /// Total or video bitrate in bits per second, if known.
  final int? bitrate;

  /// Frame rate in frames per second, if known.
  final double? frameRate;

  /// Codec string (e.g. "avc1.640028,mp4a.40.2" or "vp09.00.51.08"), if known.
  final String? codec;

  /// Video-specific codec string (e.g. "avc1.640028"), if known.
  final String? videoCodec;

  /// Audio-specific codec string (e.g. "mp4a.40.2"), if known.
  final String? audioCodec;

  /// Child playlist URL, representation URI, or media stream URL.
  final String? url;

  /// Synchronized external audio stream URL for split video/audio streams.
  final String? audioUrl;

  /// Format description or note from extractor (e.g. "1080p", "tiny").
  final String? formatNote;

  /// Container or file extension format (e.g. "mp4", "webm", "m4a").
  final String? container;

  /// Origin-scoped HTTP headers required to stream this rendition.
  final Map<String, String>? httpHeaders;

  /// File size in bytes, if known.
  final int? fileSize;

  /// Whether this is the synthetic "Auto" quality option.
  final bool isAuto;

  /// Whether this rendition carries muxed audio and video together.
  final bool isMuxed;

  const StreamRendition({
    required this.id,
    String? label,
    this.width,
    this.height,
    this.bitrate,
    double? frameRate,
    double? fps,
    this.codec,
    this.videoCodec,
    this.audioCodec,
    this.audioUrl,
    this.url,
    this.formatNote,
    this.container,
    this.httpHeaders,
    this.fileSize,
    this.isAuto = false,
    this.isMuxed = true,
  }) : label =
           label ??
           (formatNote ?? ((height != null && height > 0) ? '${height}p' : id)),
       frameRate = frameRate ?? fps;

  /// The synthetic Auto quality option.
  static const StreamRendition auto = StreamRendition(
    id: 'auto',
    label: 'Auto',
    isAuto: true,
    isMuxed: true,
  );

  /// Format identifier alias matching extractor terminology.
  String get formatId => id;

  /// Frame rate alias in fps.
  double? get fps => frameRate;

  /// Whether this rendition has video content.
  bool get hasVideo =>
      (height != null && height! > 0) ||
      (width != null && width! > 0) ||
      (videoCodec != null && videoCodec != 'none');

  /// Whether this rendition has audio content (either muxed, paired, or dedicated).
  bool get hasAudio =>
      isMuxed ||
      audioUrl != null ||
      (audioCodec != null && audioCodec != 'none') ||
      (codec != null && !codec!.contains('none'));

  /// Human-readable resolution or dimensions string (e.g. "1080p", "720p").
  String get resolution {
    if (height != null && height! > 0) {
      return '${height}p';
    }
    if (width != null && width! > 0) {
      return '${width}w';
    }
    return formatNote ?? label;
  }

  /// Formatted quality label suitable for UI menus (e.g. "1080p (60fps)" or "720p").
  String get qualityLabel {
    if (isAuto) return label;
    final res = resolution;
    if (frameRate != null && frameRate! > 30) {
      return '$res (${frameRate!.round()}fps)';
    }
    return res.isNotEmpty ? res : label;
  }

  StreamRendition copyWith({
    String? id,
    String? formatId,
    String? label,
    int? width,
    int? height,
    int? bitrate,
    double? frameRate,
    double? fps,
    String? codec,
    String? videoCodec,
    String? audioCodec,
    String? url,
    String? audioUrl,
    bool clearAudioUrl = false,
    String? formatNote,
    String? container,
    Map<String, String>? httpHeaders,
    int? fileSize,
    bool? isAuto,
    bool? isMuxed,
  }) {
    final effectiveHeight = height ?? this.height;
    final defaultLabel = (label != null)
        ? label
        : (height != null && height != this.height)
        ? '${height}p'
        : this.label;

    return StreamRendition(
      id: formatId ?? id ?? this.id,
      label: defaultLabel,
      width: width ?? this.width,
      height: effectiveHeight,
      bitrate: bitrate ?? this.bitrate,
      frameRate: fps ?? frameRate ?? this.frameRate,
      codec: codec ?? this.codec,
      videoCodec: videoCodec ?? this.videoCodec,
      audioCodec: audioCodec ?? this.audioCodec,
      url: url ?? this.url,
      audioUrl: clearAudioUrl ? null : (audioUrl ?? this.audioUrl),
      formatNote: formatNote ?? this.formatNote,
      container: container ?? this.container,
      httpHeaders: httpHeaders ?? this.httpHeaders,
      fileSize: fileSize ?? this.fileSize,
      isAuto: isAuto ?? this.isAuto,
      isMuxed: isMuxed ?? this.isMuxed,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StreamRendition &&
        other.id == id &&
        other.label == label &&
        other.width == width &&
        other.height == height &&
        other.bitrate == bitrate &&
        other.frameRate == frameRate &&
        other.codec == codec &&
        other.videoCodec == videoCodec &&
        other.audioCodec == audioCodec &&
        other.url == url &&
        other.audioUrl == audioUrl &&
        other.formatNote == formatNote &&
        other.container == container &&
        mapEquals(other.httpHeaders, httpHeaders) &&
        other.fileSize == fileSize &&
        other.isAuto == isAuto &&
        other.isMuxed == isMuxed;
  }

  @override
  int get hashCode => Object.hash(
    id,
    label,
    width,
    height,
    bitrate,
    frameRate,
    codec,
    videoCodec,
    audioCodec,
    url,
    audioUrl,
    formatNote,
    container,
    _hashHeaders(httpHeaders),
    fileSize,
    isAuto,
    isMuxed,
  );

  @override
  String toString() {
    return 'StreamRendition('
        'id: $id, '
        'label: $label, '
        'width: $width, '
        'height: $height, '
        'bitrate: $bitrate, '
        'frameRate: $frameRate, '
        'codec: $codec, '
        'url: $url, '
        'audioUrl: ${audioUrl != null ? "<paired>" : "none"}, '
        'isAuto: $isAuto, '
        'isMuxed: $isMuxed'
        ')';
  }
}

/// Metadata and discovered renditions for an adaptive or direct stream.
@immutable
class StreamManifestInfo {
  /// The canonical original or master URL requested.
  final String masterUrl;

  /// The detected stream format.
  final StreamFormat format;

  /// Whether the stream is an ongoing live or dynamic broadcast.
  final bool isLive;

  /// Discovered video / media rendition candidates.
  final List<StreamRendition> variants;

  /// Discovered distinct audio rendition groups or tracks.
  final List<String> audioGroups;

  /// Discovered distinct subtitle or closed-caption rendition groups.
  final List<String> subtitleGroups;

  /// Whether the stream provides separate non-muxed audio tracks.
  final bool hasSeparateAudio;

  /// Whether unsupported DRM / ContentProtection was detected on this manifest.
  final bool hasUnsupportedDrm;

  const StreamManifestInfo({
    required this.masterUrl,
    required this.format,
    this.isLive = false,
    this.variants = const [],
    this.audioGroups = const [],
    this.subtitleGroups = const [],
    this.hasSeparateAudio = false,
    this.hasUnsupportedDrm = false,
  });

  /// Creates a fallback [StreamManifestInfo] for direct single-rendition playback.
  factory StreamManifestInfo.directFallback(String url) {
    return StreamManifestInfo(
      masterUrl: url,
      format: StreamFormat.direct,
      isLive: false,
      variants: [
        StreamRendition(
          id: 'direct',
          label: 'Default',
          url: url,
          isMuxed: true,
        ),
      ],
      audioGroups: const [],
      subtitleGroups: const [],
      hasSeparateAudio: false,
      hasUnsupportedDrm: false,
    );
  }

  StreamManifestInfo copyWith({
    String? masterUrl,
    StreamFormat? format,
    bool? isLive,
    List<StreamRendition>? variants,
    List<String>? audioGroups,
    List<String>? subtitleGroups,
    bool? hasSeparateAudio,
    bool? hasUnsupportedDrm,
  }) {
    return StreamManifestInfo(
      masterUrl: masterUrl ?? this.masterUrl,
      format: format ?? this.format,
      isLive: isLive ?? this.isLive,
      variants: variants ?? this.variants,
      audioGroups: audioGroups ?? this.audioGroups,
      subtitleGroups: subtitleGroups ?? this.subtitleGroups,
      hasSeparateAudio: hasSeparateAudio ?? this.hasSeparateAudio,
      hasUnsupportedDrm: hasUnsupportedDrm ?? this.hasUnsupportedDrm,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StreamManifestInfo &&
        other.masterUrl == masterUrl &&
        other.format == format &&
        other.isLive == isLive &&
        listEquals(other.variants, variants) &&
        listEquals(other.audioGroups, audioGroups) &&
        listEquals(other.subtitleGroups, subtitleGroups) &&
        other.hasSeparateAudio == hasSeparateAudio &&
        other.hasUnsupportedDrm == hasUnsupportedDrm;
  }

  @override
  int get hashCode => Object.hash(
    masterUrl,
    format,
    isLive,
    Object.hashAll(variants),
    Object.hashAll(audioGroups),
    Object.hashAll(subtitleGroups),
    hasSeparateAudio,
    hasUnsupportedDrm,
  );

  @override
  String toString() {
    return 'StreamManifestInfo('
        'masterUrl: $masterUrl, '
        'format: $format, '
        'isLive: $isLive, '
        'variants: ${variants.length}, '
        'audioGroups: $audioGroups, '
        'subtitleGroups: $subtitleGroups, '
        'hasSeparateAudio: $hasSeparateAudio, '
        'hasUnsupportedDrm: $hasUnsupportedDrm'
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
