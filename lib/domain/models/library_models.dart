import 'package:meta/meta.dart';
import 'media_kind.dart';
import 'media_metadata.dart';

export 'media_kind.dart';
export 'media_metadata.dart';

enum ScanPhase {
  idle,
  discovering,
  enriching,
  reconciling,
  error,
}

@immutable
class LibraryScanStatus {
  const LibraryScanStatus({
    this.phase = ScanPhase.idle,
    this.currentFolder,
    this.discoveredCount = 0,
    this.enrichedCount = 0,
    this.totalToEnrich = 0,
    this.errorMessage,
  });

  final ScanPhase phase;
  final String? currentFolder;
  final int discoveredCount;
  final int enrichedCount;
  final int totalToEnrich;
  final String? errorMessage;

  bool get isScanning =>
      phase == ScanPhase.discovering ||
      phase == ScanPhase.enriching ||
      phase == ScanPhase.reconciling;

  LibraryScanStatus copyWith({
    ScanPhase? phase,
    String? currentFolder,
    int? discoveredCount,
    int? enrichedCount,
    int? totalToEnrich,
    String? errorMessage,
  }) {
    return LibraryScanStatus(
      phase: phase ?? this.phase,
      currentFolder: currentFolder ?? this.currentFolder,
      discoveredCount: discoveredCount ?? this.discoveredCount,
      enrichedCount: enrichedCount ?? this.enrichedCount,
      totalToEnrich: totalToEnrich ?? this.totalToEnrich,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

@immutable
class LibraryFolderRecord {
  const LibraryFolderRecord({
    required this.path,
    required this.addedAt,
    this.lastScannedAt,
    this.isAvailable = true,
    this.fileCount = 0,
  });

  final String path;
  final DateTime addedAt;
  final DateTime? lastScannedAt;
  final bool isAvailable;
  final int fileCount;

  LibraryFolderRecord copyWith({
    String? path,
    DateTime? addedAt,
    DateTime? lastScannedAt,
    bool? isAvailable,
    int? fileCount,
  }) {
    return LibraryFolderRecord(
      path: path ?? this.path,
      addedAt: addedAt ?? this.addedAt,
      lastScannedAt: lastScannedAt ?? this.lastScannedAt,
      isAvailable: isAvailable ?? this.isAvailable,
      fileCount: fileCount ?? this.fileCount,
    );
  }
}

@immutable
class MediaItemRecord {
  const MediaItemRecord({
    required this.id,
    required this.canonicalSource,
    required this.path,
    this.kind = MediaKind.unknown,
    this.metadata = MediaMetadata.empty,
    this.fileSize = 0,
    this.modifiedAt,
    this.isAvailable = true,
    this.isFavorite = false,
    required this.addedAt,
    this.lastPlayedAt,
    this.playCount = 0,
  });

  final String id;
  final String canonicalSource;
  final String path;
  final MediaKind kind;
  final MediaMetadata metadata;
  final int fileSize;
  final DateTime? modifiedAt;
  final bool isAvailable;
  final bool isFavorite;
  final DateTime addedAt;
  final DateTime? lastPlayedAt;
  final int playCount;

  String get title {
    final t = metadata.title?.trim();
    if (t != null && t.isNotEmpty) return t;
    return path.split(RegExp(r'[\\/]')).last;
  }

  String get artist => metadata.effectiveArtist;
  String get album => metadata.effectiveAlbum;

  MediaItemRecord copyWith({
    String? id,
    String? canonicalSource,
    String? path,
    MediaKind? kind,
    MediaMetadata? metadata,
    int? fileSize,
    DateTime? modifiedAt,
    bool? isAvailable,
    bool? isFavorite,
    DateTime? addedAt,
    DateTime? lastPlayedAt,
    int? playCount,
  }) {
    return MediaItemRecord(
      id: id ?? this.id,
      canonicalSource: canonicalSource ?? this.canonicalSource,
      path: path ?? this.path,
      kind: kind ?? this.kind,
      metadata: metadata ?? this.metadata,
      fileSize: fileSize ?? this.fileSize,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      isAvailable: isAvailable ?? this.isAvailable,
      isFavorite: isFavorite ?? this.isFavorite,
      addedAt: addedAt ?? this.addedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      playCount: playCount ?? this.playCount,
    );
  }
}

@immutable
class PlaylistRecord {
  const PlaylistRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.entryCount = 0,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int entryCount;

  PlaylistRecord copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? entryCount,
  }) {
    return PlaylistRecord(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      entryCount: entryCount ?? this.entryCount,
    );
  }
}

@immutable
class PlaylistEntryRecord {
  const PlaylistEntryRecord({
    required this.id,
    required this.playlistId,
    required this.mediaId,
    required this.position,
    required this.addedAt,
    this.mediaItem,
  });

  final String id;
  final String playlistId;
  final String mediaId;
  final int position;
  final DateTime addedAt;
  final MediaItemRecord? mediaItem;

  PlaylistEntryRecord copyWith({
    String? id,
    String? playlistId,
    String? mediaId,
    int? position,
    DateTime? addedAt,
    MediaItemRecord? mediaItem,
  }) {
    return PlaylistEntryRecord(
      id: id ?? this.id,
      playlistId: playlistId ?? this.playlistId,
      mediaId: mediaId ?? this.mediaId,
      position: position ?? this.position,
      addedAt: addedAt ?? this.addedAt,
      mediaItem: mediaItem ?? this.mediaItem,
    );
  }
}
