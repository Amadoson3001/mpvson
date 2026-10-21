import 'package:meta/meta.dart';

/// Technical audio properties for an audio track or stream.
@immutable
class AudioTechnicalInfo {
  const AudioTechnicalInfo({
    this.codec,
    this.sampleRate,
    this.channels,
    this.bitrate,
    this.bitsPerSample,
  });

  final String? codec;
  final int? sampleRate;
  final int? channels;
  final int? bitrate;
  final int? bitsPerSample;

  factory AudioTechnicalInfo.fromJson(Map<String, Object?> json) {
    return AudioTechnicalInfo(
      codec: json['codec'] as String?,
      sampleRate: (json['sampleRate'] as num?)?.toInt(),
      channels: (json['channels'] as num?)?.toInt(),
      bitrate: (json['bitrate'] as num?)?.toInt(),
      bitsPerSample: (json['bitsPerSample'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'codec': codec,
    'sampleRate': sampleRate,
    'channels': channels,
    'bitrate': bitrate,
    'bitsPerSample': bitsPerSample,
  };

  AudioTechnicalInfo copyWith({
    String? codec,
    int? sampleRate,
    int? channels,
    int? bitrate,
    int? bitsPerSample,
  }) {
    return AudioTechnicalInfo(
      codec: codec ?? this.codec,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      bitrate: bitrate ?? this.bitrate,
      bitsPerSample: bitsPerSample ?? this.bitsPerSample,
    );
  }
}

/// Metadata describing a media file or stream.
@immutable
class MediaMetadata {
  const MediaMetadata({
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.genre,
    this.year,
    this.trackNumber,
    this.discNumber,
    this.duration = Duration.zero,
    this.artworkUri,
    this.audioInfo,
  });

  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;
  final String? genre;
  final int? year;
  final int? trackNumber;
  final int? discNumber;
  final Duration duration;
  final String? artworkUri;
  final AudioTechnicalInfo? audioInfo;

  static const MediaMetadata empty = MediaMetadata();

  /// Normalized effective artist for grouping and display.
  String get effectiveArtist {
    final a = artist?.trim();
    if (a != null && a.isNotEmpty) return a;
    final aa = albumArtist?.trim();
    if (aa != null && aa.isNotEmpty) return aa;
    return 'Unknown Artist';
  }

  /// Normalized effective album artist for album grouping.
  String get effectiveAlbumArtist {
    final aa = albumArtist?.trim();
    if (aa != null && aa.isNotEmpty) return aa;
    final a = artist?.trim();
    if (a != null && a.isNotEmpty) return a;
    return 'Unknown Artist';
  }

  /// Normalized effective album title.
  String get effectiveAlbum {
    final a = album?.trim();
    if (a != null && a.isNotEmpty) return a;
    return 'Unknown Album';
  }

  factory MediaMetadata.fromJson(Map<String, Object?> json) {
    return MediaMetadata(
      title: json['title'] as String?,
      artist: json['artist'] as String?,
      albumArtist: json['albumArtist'] as String?,
      album: json['album'] as String?,
      genre: json['genre'] as String?,
      year: (json['year'] as num?)?.toInt(),
      trackNumber: (json['trackNumber'] as num?)?.toInt(),
      discNumber: (json['discNumber'] as num?)?.toInt(),
      duration: Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
      artworkUri: json['artworkUri'] as String?,
      audioInfo: json['audioInfo'] != null
          ? AudioTechnicalInfo.fromJson(
              (json['audioInfo'] as Map).cast<String, Object?>(),
            )
          : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'artist': artist,
    'albumArtist': albumArtist,
    'album': album,
    'genre': genre,
    'year': year,
    'trackNumber': trackNumber,
    'discNumber': discNumber,
    'durationMs': duration.inMilliseconds,
    'artworkUri': artworkUri,
    'audioInfo': audioInfo?.toJson(),
  };

  MediaMetadata copyWith({
    String? title,
    String? artist,
    String? albumArtist,
    String? album,
    String? genre,
    int? year,
    int? trackNumber,
    int? discNumber,
    Duration? duration,
    String? artworkUri,
    AudioTechnicalInfo? audioInfo,
  }) {
    return MediaMetadata(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      albumArtist: albumArtist ?? this.albumArtist,
      album: album ?? this.album,
      genre: genre ?? this.genre,
      year: year ?? this.year,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
      duration: duration ?? this.duration,
      artworkUri: artworkUri ?? this.artworkUri,
      audioInfo: audioInfo ?? this.audioInfo,
    );
  }
}
