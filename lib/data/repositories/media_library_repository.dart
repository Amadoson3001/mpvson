import 'package:flutter/foundation.dart';
import '../../domain/models/library_models.dart';

abstract class MediaLibraryRepository extends ChangeNotifier {
  LibraryScanStatus get scanStatus;
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
    int? limit,
    int? offset,
    String? sortBy,
    bool ascending = true,
  });

  Future<MediaItemRecord?> getMediaByCanonicalSource(String canonicalSource);
  Future<MediaItemRecord?> getMediaById(String id);

  Future<void> toggleFavorite(String mediaId, bool isFavorite);
  Future<void> recordPlayback(String canonicalSource);

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
  Future<void> dispose();
}
