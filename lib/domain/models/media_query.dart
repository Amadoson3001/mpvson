import 'library_models.dart';

/// Canonical sort keys for library queries. SQL ordering is derived from
/// this enum; see [sqlOrderBy].
enum MediaSortField {
  title,
  artist,
  album,
  duration,
  fileSize,
  addedAt,
  lastPlayedAt,
  trackNumber,
  playCount,
  year;

  /// Parses a persisted or UI sort id. Unknown values return null so each
  /// backend can keep its own default.
  static MediaSortField? tryParse(String? raw) {
    switch (raw) {
      case 'title':
        return MediaSortField.title;
      case 'artist':
        return MediaSortField.artist;
      case 'album':
        return MediaSortField.album;
      case 'duration':
      case 'duration_ms':
        return MediaSortField.duration;
      case 'fileSize':
        return MediaSortField.fileSize;
      case 'addedAt':
      case 'added_at':
        return MediaSortField.addedAt;
      case 'lastPlayedAt':
      case 'last_played_at':
        return MediaSortField.lastPlayedAt;
      case 'trackNumber':
        return MediaSortField.trackNumber;
      case 'playCount':
      case 'play_count':
        return MediaSortField.playCount;
      case 'year':
        return MediaSortField.year;
      default:
        return null;
    }
  }

  bool get requiresLastPlayed => this == MediaSortField.lastPlayedAt;

  /// SQL `ORDER BY` fragment, including the direction token [dir] (`ASC`/`DESC`).
  String sqlOrderBy(String dir) {
    switch (this) {
      case MediaSortField.title:
        return 'media.title COLLATE NOCASE $dir';
      case MediaSortField.artist:
        return 'media.artist COLLATE NOCASE $dir, media.track_number ASC';
      case MediaSortField.album:
        return 'media.album COLLATE NOCASE $dir, media.disc_number ASC, media.track_number ASC';
      case MediaSortField.duration:
        return 'media.duration_ms $dir';
      case MediaSortField.addedAt:
        return 'media.added_at $dir';
      case MediaSortField.lastPlayedAt:
        return 'media.last_played_at $dir';
      case MediaSortField.playCount:
        return 'media.play_count $dir';
      case MediaSortField.fileSize:
        return 'media.file_size $dir';
      case MediaSortField.trackNumber:
        return 'coalesce(media.disc_number, 1) $dir, coalesce(media.track_number, 0) $dir, lower(media.title) ASC';
      case MediaSortField.year:
        return 'media.year $dir';
    }
  }
}

/// Shared filter, search, pagination, and sort specification for library queries.
class MediaQuerySpec {
  const MediaQuerySpec({
    this.kind,
    this.searchQuery,
    this.artist,
    this.album,
    this.onlyFavorites,
    this.isAvailable,
    this.limit,
    this.offset,
    this.sortBy,
    this.ascending = true,
  });

  final MediaKind? kind;
  final String? searchQuery;
  final String? artist;
  final String? album;
  final bool? onlyFavorites;
  final bool? isAvailable;
  final int? limit;
  final int? offset;
  final MediaSortField? sortBy;
  final bool ascending;

  factory MediaQuerySpec.fromQuery({
    MediaKind? kind,
    String? searchQuery,
    String? artist,
    String? album,
    bool? onlyFavorites,
    bool? isAvailable,
    int? limit,
    int? offset,
    String? sortBy,
    bool ascending = true,
  }) {
    return MediaQuerySpec(
      kind: kind,
      searchQuery: searchQuery,
      artist: artist,
      album: album,
      onlyFavorites: onlyFavorites,
      isAvailable: isAvailable,
      limit: limit,
      offset: offset,
      sortBy: MediaSortField.tryParse(sortBy),
      ascending: ascending,
    );
  }
}
