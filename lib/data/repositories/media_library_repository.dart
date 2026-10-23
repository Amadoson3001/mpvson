import 'package:flutter/foundation.dart';
import '../../domain/models/library_models.dart';

abstract class MediaLibraryRepository extends ChangeNotifier {
  ValueNotifier<LibraryScanStatus>? _scanStatusNotifier;

  LibraryScanStatus get scanStatus;

  /// Progress changes independently of the library contents. Browsing views
  /// listen to this repository only when their query results may have changed.
  ValueListenable<LibraryScanStatus> get scanStatusListenable =>
      _scanStatusNotifier ??= ValueNotifier<LibraryScanStatus>(scanStatus);

  @protected
  void publishScanStatus(LibraryScanStatus status) {
    _scanStatusNotifier?.value = status;
  }

  List<LibraryFolderRecord> get folders;
  bool get isReady;
  String? get initializationError;

  Future<void> initialize();
  Future<void> addFolder(String path);
  Future<void> removeFolder(String path);
  Future<List<LibraryFolderRecord>> getFolders();

  Future<void> upsertDiscoveredFiles(List<String> paths);
  Future<void> updateMediaMetadata(
    String canonicalSource, {
    required MediaKind kind,
    required MediaMetadata metadata,
    required int fileSize,
    required DateTime modifiedAt,
  });

  Future<List<MediaItemRecord>> queryMedia({
    MediaKind? kind,
    String? searchQuery,
    String? artist,
    String? album,
    bool? onlyFavorites,
    bool onlyPlayed = false,
    int? limit,
    int? offset,
    String? sortBy,
    bool ascending = true,
  });

  /// In-memory fallback. Persistent repositories aggregate and page in SQL.
  Future<List<LibraryAlbumSummary>> queryAlbums({
    String? searchQuery,
    String? album,
    int? limit,
    int? offset,
  }) async {
    final items = await queryMedia(
      kind: MediaKind.audio,
      searchQuery: searchQuery,
      album: album,
      sortBy: 'title',
    );
    final groups = <String, List<MediaItemRecord>>{};
    for (final item in items) {
      groups.putIfAbsent(item.album, () => []).add(item);
    }
    final names = groups.keys.toList()..sort(_compareNames);
    return names
        .skip(offset ?? 0)
        .take(limit ?? names.length)
        .map((name) {
          final tracks = groups[name]!;
          return LibraryAlbumSummary(
            album: name,
            artist: tracks.first.artist,
            trackCount: tracks.length,
            totalDuration: tracks.fold<Duration>(
              Duration.zero,
              (total, track) => total + track.metadata.duration,
            ),
          );
        })
        .toList(growable: false);
  }

  Future<List<LibraryArtistSummary>> queryArtists({
    String? searchQuery,
    String? artist,
    int? limit,
    int? offset,
  }) async {
    final items = await queryMedia(
      kind: MediaKind.audio,
      searchQuery: searchQuery,
      artist: artist,
    );
    final groups = <String, List<MediaItemRecord>>{};
    for (final item in items) {
      groups.putIfAbsent(item.artist, () => []).add(item);
    }
    final names = groups.keys.toList()..sort(_compareNames);
    return names
        .skip(offset ?? 0)
        .take(limit ?? names.length)
        .map((name) {
          final tracks = groups[name]!;
          return LibraryArtistSummary(
            artist: name,
            songCount: tracks.length,
            albumCount: tracks.map((track) => track.album).toSet().length,
          );
        })
        .toList(growable: false);
  }

  static int _compareNames(String a, String b) {
    final comparison = a.toLowerCase().compareTo(b.toLowerCase());
    return comparison != 0 ? comparison : a.compareTo(b);
  }

  Future<MediaItemRecord?> getMediaByCanonicalSource(String canonicalSource);
  Future<MediaItemRecord?> getMediaById(String id);

  Future<void> toggleFavorite(String mediaId, bool isFavorite);
  Future<void> recordPlayback(String canonicalSource);
  Future<void> clearPlaybackHistory();

  Future<List<PlaylistRecord>> getPlaylists();
  Future<PlaylistRecord> createPlaylist(String title);
  Future<void> deletePlaylist(String playlistId);
  Future<void> renamePlaylist(String playlistId, String newTitle);
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds);
  Future<void> removeFromPlaylist(String playlistId, String playlistEntryId);
  Future<void> reorderPlaylist(String playlistId, int oldIndex, int newIndex);
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(String playlistId);

  Future<List<String>> getDistinctArtists({MediaKind? kind});
  Future<List<String>> getDistinctAlbums({String? artist});

  Future<void> markFolderAvailability(String folderPath, bool isAvailable);
  Future<void> rescanFolder(String folderPath);
  Future<void> rescanAll();
  Future<void> cancelScan();

  @override
  Future<void> dispose() async {
    _scanStatusNotifier?.dispose();
    super.dispose();
  }
}
