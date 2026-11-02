import 'dart:async';

import '../../../../data/repositories/media_library_repository.dart';
import '../../../../data/services/desktop_integration_service.dart';
import '../../../../domain/models/library_models.dart';

class EmptyDesktopIntegrationService extends DesktopIntegrationService {
  @override
  SystemPlaybackStatus get playbackStatus => SystemPlaybackStatus.closed;
  @override
  MediaMetadata get currentMetadata => MediaMetadata.empty;
  @override
  bool get isAwakeInhibited => false;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> updatePlaybackState({
    required SystemPlaybackStatus status,
    required Duration position,
    required Duration duration,
    required double playbackRate,
  }) async {}
  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {}
  @override
  Future<void> updateCapabilities({
    bool canPlay = true,
    bool canPause = true,
    bool canSeek = true,
    bool canGoNext = true,
    bool canGoPrevious = true,
  }) async {}
  @override
  Future<void> setKeepAwake(
    bool enable, {
    required bool isVideoPlaying,
  }) async {}
  @override
  Future<void> openDefaultAppsSettings() async {}
}

class EmptyMediaLibraryRepository extends MediaLibraryRepository {
  @override
  LibraryScanStatus get scanStatus => const LibraryScanStatus();
  @override
  List<LibraryFolderRecord> get folders => const [];
  @override
  bool get isReady => true;
  @override
  String? get initializationError => null;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> addFolder(String path) async {}
  @override
  Future<void> removeFolder(String path) async {}
  @override
  Future<List<LibraryFolderRecord>> getFolders() async => const [];
  @override
  Future<void> upsertDiscoveredFiles(List<String> paths) async {}
  @override
  Future<void> updateMediaMetadata(
    String canonicalSource, {
    required MediaKind kind,
    required MediaMetadata metadata,
    required int fileSize,
    required DateTime modifiedAt,
  }) async {}
  @override
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
  }) async => const [];
  @override
  Future<MediaItemRecord?> getMediaByCanonicalSource(
    String canonicalSource,
  ) async => null;
  @override
  Future<MediaItemRecord?> getMediaById(String id) async => null;
  @override
  Future<void> toggleFavorite(String mediaId, bool isFavorite) async {}
  @override
  Future<void> recordPlayback(String canonicalSource) async {}
  @override
  Future<List<PlaylistRecord>> getPlaylists() async => const [];
  @override
  Future<PlaylistRecord> createPlaylist(String title) async => PlaylistRecord(
    id: '1',
    title: title,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
  @override
  Future<void> deletePlaylist(String playlistId) async {}
  @override
  Future<void> renamePlaylist(String playlistId, String newTitle) async {}
  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {}
  @override
  Future<void> removeFromPlaylist(
    String playlistId,
    String playlistEntryId,
  ) async {}
  @override
  Future<void> reorderPlaylist(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {}
  @override
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(
    String playlistId,
  ) async => const [];
  @override
  Future<List<String>> getDistinctArtists({MediaKind? kind}) async => const [];
  @override
  Future<List<String>> getDistinctAlbums({String? artist}) async => const [];
  @override
  Future<void> markFolderAvailability(
    String folderPath,
    bool isAvailable,
  ) async {}
  @override
  Future<void> rescanFolder(String folderPath) async {}
  @override
  Future<void> rescanAll() async {}
  @override
  Future<void> cancelScan() async {}
  @override
  Future<void> dispose() async {
    super.dispose();
  }
}
