import 'package:flutter/foundation.dart';
import 'package:mpvson/data/repositories/media_library_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';

class FakeMediaLibraryRepository extends ChangeNotifier
    implements MediaLibraryRepository {
  FakeMediaLibraryRepository({
    List<LibraryFolderRecord>? folders,
    LibraryScanStatus? scanStatus,
    List<MediaItemRecord>? mediaItems,
    List<PlaylistRecord>? playlists,
  })  : _folders = folders != null
            ? List<LibraryFolderRecord>.of(folders)
            : <LibraryFolderRecord>[],
        _scanStatus = scanStatus ?? const LibraryScanStatus(),
        _mediaItems = mediaItems != null
            ? List<MediaItemRecord>.of(mediaItems)
            : <MediaItemRecord>[],
        _playlists = playlists != null
            ? List<PlaylistRecord>.of(playlists)
            : <PlaylistRecord>[];

  final List<LibraryFolderRecord> _folders;
  LibraryScanStatus _scanStatus;
  final List<MediaItemRecord> _mediaItems;
  final List<PlaylistRecord> _playlists;
  final Map<String, List<PlaylistEntryRecord>> _playlistEntries = {};

  final List<String> addFolderCalls = [];
  final List<String> removeFolderCalls = [];
  final List<String> rescanFolderCalls = [];
  int rescanAllCalls = 0;
  int cancelScanCalls = 0;
  final List<Map<String, dynamic>> queryMediaCalls = [];
  final List<Map<String, dynamic>> toggleFavoriteCalls = [];

  bool _isReady = true;
  String? _initializationError;

  @override
  bool get isReady => _isReady;

  set isReady(bool value) {
    _isReady = value;
    notifyListeners();
  }

  @override
  String? get initializationError => _initializationError;

  set initializationError(String? value) {
    _initializationError = value;
    notifyListeners();
  }

  @override
  List<LibraryFolderRecord> get folders => List.unmodifiable(_folders);

  @override
  LibraryScanStatus get scanStatus => _scanStatus;

  set scanStatus(LibraryScanStatus status) {
    _scanStatus = status;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> addFolder(String path) async {
    addFolderCalls.add(path);
    _folders.add(
      LibraryFolderRecord(
        path: path,
        addedAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> removeFolder(String path) async {
    removeFolderCalls.add(path);
    _folders.removeWhere((f) => f.path == path);
    notifyListeners();
  }

  @override
  Future<List<LibraryFolderRecord>> getFolders() async => folders;

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
  }) async {
    queryMediaCalls.add({
      'kind': kind,
      'searchQuery': searchQuery,
      'artist': artist,
      'album': album,
      'onlyFavorites': onlyFavorites,
      'limit': limit,
      'offset': offset,
      'sortBy': sortBy,
      'ascending': ascending,
    });

    var result = List<MediaItemRecord>.of(_mediaItems);

    if (kind != null) {
      result = result.where((m) => m.kind == kind).toList();
    }
    if (searchQuery != null && searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      result = result.where((m) {
        final filename = m.path.split(RegExp(r'[\\/]')).last.toLowerCase();
        final title = m.title.toLowerCase();
        final art = m.artist.toLowerCase();
        final alb = m.album.toLowerCase();
        return filename.contains(q) ||
            title.contains(q) ||
            art.contains(q) ||
            alb.contains(q);
      }).toList();
    }
    if (artist != null) {
      result = result
          .where((m) => m.artist.toLowerCase() == artist.toLowerCase())
          .toList();
    }
    if (album != null) {
      result = result
          .where((m) => m.album.toLowerCase() == album.toLowerCase())
          .toList();
    }
    if (onlyFavorites == true) {
      result = result.where((m) => m.isFavorite).toList();
    }

    if (sortBy != null) {
      result.sort((a, b) {
        int cmp = 0;
        switch (sortBy) {
          case 'title':
            cmp = a.title.compareTo(b.title);
            break;
          case 'addedAt':
            cmp = a.addedAt.compareTo(b.addedAt);
            break;
          case 'lastPlayedAt':
            final lpA = a.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final lpB = b.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            cmp = lpA.compareTo(lpB);
            break;
        }
        return ascending ? cmp : -cmp;
      });
    }

    if (offset != null && offset > 0) {
      result = result.skip(offset).toList();
    }
    if (limit != null && limit > 0) {
      result = result.take(limit).toList();
    }

    return result;
  }

  @override
  Future<MediaItemRecord?> getMediaByCanonicalSource(String canonicalSource) async {
    return _mediaItems
        .where((m) => m.canonicalSource == canonicalSource)
        .firstOrNull;
  }

  @override
  Future<MediaItemRecord?> getMediaById(String id) async {
    return _mediaItems.where((m) => m.id == id).firstOrNull;
  }

  @override
  Future<void> toggleFavorite(String mediaId, bool isFavorite) async {
    toggleFavoriteCalls.add({'id': mediaId, 'isFavorite': isFavorite});
    final index = _mediaItems.indexWhere((m) => m.id == mediaId);
    if (index >= 0) {
      _mediaItems[index] = _mediaItems[index].copyWith(isFavorite: isFavorite);
      notifyListeners();
    }
  }

  @override
  Future<void> recordPlayback(String canonicalSource) async {}

  @override
  Future<List<PlaylistRecord>> getPlaylists() async =>
      List.unmodifiable(_playlists);

  @override
  Future<PlaylistRecord> createPlaylist(String title) async {
    final now = DateTime.now();
    final playlist = PlaylistRecord(
      id: 'pl-${_playlists.length + 1}',
      title: title,
      createdAt: now,
      updatedAt: now,
      entryCount: 0,
    );
    _playlists.add(playlist);
    _playlistEntries[playlist.id] = <PlaylistEntryRecord>[];
    notifyListeners();
    return playlist;
  }

  @override
  Future<void> deletePlaylist(String playlistId) async {
    _playlists.removeWhere((p) => p.id == playlistId);
    _playlistEntries.remove(playlistId);
    notifyListeners();
  }

  @override
  Future<void> renamePlaylist(String playlistId, String newTitle) async {
    final index = _playlists.indexWhere((p) => p.id == playlistId);
    if (index >= 0) {
      _playlists[index] = _playlists[index].copyWith(
        title: newTitle,
        updatedAt: DateTime.now(),
      );
      notifyListeners();
    }
  }

  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {
    final entries = _playlistEntries.putIfAbsent(playlistId, () => []);
    for (final mediaId in mediaIds) {
      final media = await getMediaById(mediaId);
      final entry = PlaylistEntryRecord(
        id: 'entry-${entries.length + 1}',
        playlistId: playlistId,
        mediaId: mediaId,
        position: entries.length,
        addedAt: DateTime.now(),
        mediaItem: media,
      );
      entries.add(entry);
    }
    final pIdx = _playlists.indexWhere((p) => p.id == playlistId);
    if (pIdx >= 0) {
      _playlists[pIdx] = _playlists[pIdx].copyWith(
        entryCount: entries.length,
        updatedAt: DateTime.now(),
      );
    }
    notifyListeners();
  }

  @override
  Future<void> removeFromPlaylist(String playlistId, String playlistEntryId) async {
    final entries = _playlistEntries[playlistId];
    if (entries != null) {
      entries.removeWhere((e) => e.id == playlistEntryId);
      for (var i = 0; i < entries.length; i++) {
        entries[i] = entries[i].copyWith(position: i);
      }
      final pIdx = _playlists.indexWhere((p) => p.id == playlistId);
      if (pIdx >= 0) {
        _playlists[pIdx] = _playlists[pIdx].copyWith(
          entryCount: entries.length,
          updatedAt: DateTime.now(),
        );
      }
      notifyListeners();
    }
  }

  @override
  Future<void> reorderPlaylist(String playlistId, int oldIndex, int newIndex) async {
    final entries = _playlistEntries[playlistId];
    if (entries != null &&
        oldIndex >= 0 &&
        oldIndex < entries.length &&
        newIndex >= 0 &&
        newIndex <= entries.length) {
      if (newIndex > oldIndex) newIndex--;
      final item = entries.removeAt(oldIndex);
      entries.insert(newIndex, item);
      for (var i = 0; i < entries.length; i++) {
        entries[i] = entries[i].copyWith(position: i);
      }
      notifyListeners();
    }
  }

  @override
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(String playlistId) async {
    return List.unmodifiable(_playlistEntries[playlistId] ?? const []);
  }

  @override
  Future<List<String>> getDistinctArtists({MediaKind? kind}) async {
    return _mediaItems
        .where((m) => kind == null || m.kind == kind)
        .map((m) => m.artist)
        .toSet()
        .toList();
  }

  @override
  Future<List<String>> getDistinctAlbums({String? artist}) async {
    return _mediaItems
        .where((m) => artist == null || m.artist.toLowerCase() == artist.toLowerCase())
        .map((m) => m.album)
        .toSet()
        .toList();
  }

  @override
  Future<void> markFolderAvailability(String folderPath, bool isAvailable) async {}

  @override
  Future<void> rescanFolder(String folderPath) async {
    rescanFolderCalls.add(folderPath);
    _scanStatus = _scanStatus.copyWith(
      phase: ScanPhase.discovering,
      currentFolder: folderPath,
    );
    notifyListeners();
  }

  @override
  Future<void> rescanAll() async {
    rescanAllCalls++;
    _scanStatus = _scanStatus.copyWith(
      phase: ScanPhase.discovering,
      currentFolder: 'all',
    );
    notifyListeners();
  }

  @override
  Future<void> cancelScan() async {
    cancelScanCalls++;
    _scanStatus = _scanStatus.copyWith(phase: ScanPhase.idle);
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    super.dispose();
  }
}
