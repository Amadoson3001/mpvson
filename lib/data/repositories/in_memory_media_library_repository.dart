import 'dart:async';
import '../../domain/models/library_models.dart';
import '../../domain/models/media_catalog.dart';
import 'media_library_repository.dart';

extension _FirstWhereOrNullExt<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T element) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}

/// In-memory implementation of [MediaLibraryRepository] suitable for testing,
/// previews, and offline operation.
class InMemoryMediaLibraryRepository extends MediaLibraryRepository {
  InMemoryMediaLibraryRepository({
    List<LibraryFolderRecord>? initialFolders,
    List<MediaItemRecord>? initialItems,
    List<PlaylistRecord>? initialPlaylists,
    Map<String, List<PlaylistEntryRecord>>? initialPlaylistEntries,
    LibraryScanStatus? initialScanStatus,
  }) : _folders = List<LibraryFolderRecord>.from(initialFolders ?? const []),
       _items = List<MediaItemRecord>.from(initialItems ?? const []),
       _playlists = List<PlaylistRecord>.from(initialPlaylists ?? const []),
       _playlistEntries = Map<String, List<PlaylistEntryRecord>>.from(
         initialPlaylistEntries ?? const {},
       ),
       _scanStatus = initialScanStatus ?? const LibraryScanStatus();

  final List<LibraryFolderRecord> _folders;
  final List<MediaItemRecord> _items;
  final List<PlaylistRecord> _playlists;
  final Map<String, List<PlaylistEntryRecord>> _playlistEntries;
  LibraryScanStatus _scanStatus;
  bool _isReady = true;
  String? _initializationError;

  @override
  LibraryScanStatus get scanStatus => _scanStatus;

  @override
  List<LibraryFolderRecord> get folders => List.unmodifiable(_folders);

  List<MediaItemRecord> get items => List.unmodifiable(_items);

  @override
  bool get isReady => _isReady;

  @override
  String? get initializationError => _initializationError;

  void setScanStatus(LibraryScanStatus status) {
    _scanStatus = status;
    publishScanStatus(status);
  }

  void setItems(List<MediaItemRecord> items) {
    _items
      ..clear()
      ..addAll(items);
    notifyListeners();
  }

  @override
  Future<void> initialize() async {
    _isReady = true;
    _initializationError = null;
    notifyListeners();
  }

  @override
  Future<void> addFolder(String path) async {
    final existing = _folders.firstWhereOrNull((f) => f.path == path);
    if (existing == null) {
      _folders.add(LibraryFolderRecord(path: path, addedAt: DateTime.now()));
      notifyListeners();
    }
  }

  @override
  Future<void> removeFolder(String path) async {
    _folders.removeWhere((f) => f.path == path);
    _items.removeWhere((item) => item.path.startsWith(path));
    notifyListeners();
  }

  @override
  Future<List<LibraryFolderRecord>> getFolders() async => folders;

  @override
  Future<void> upsertDiscoveredFiles(List<String> paths) async {
    for (final path in paths) {
      final existing = _items.firstWhereOrNull((i) => i.path == path);
      if (existing == null) {
        final kind = MediaCatalog.kindFromExtension(path);
        _items.add(
          MediaItemRecord(
            id: 'item_${_items.length + 1}_${DateTime.now().microsecondsSinceEpoch}',
            canonicalSource: path,
            path: path,
            kind: kind,
            addedAt: DateTime.now(),
          ),
        );
      }
    }
    notifyListeners();
  }

  @override
  Future<void> updateMediaMetadata(
    String canonicalSource, {
    required MediaKind kind,
    required MediaMetadata metadata,
    required int fileSize,
    required DateTime modifiedAt,
  }) async {
    final index = _items.indexWhere(
      (i) => i.canonicalSource == canonicalSource,
    );
    if (index >= 0) {
      _items[index] = _items[index].copyWith(
        kind: kind,
        metadata: metadata,
        fileSize: fileSize,
        modifiedAt: modifiedAt,
      );
      notifyListeners();
    }
  }

  @override
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
  }) async {
    var result = List<MediaItemRecord>.from(_items);

    if (kind != null) {
      result = result.where((item) => item.kind == kind).toList();
    }

    if (onlyFavorites == true) {
      result = result.where((item) => item.isFavorite).toList();
    }
    if (onlyPlayed) {
      result = result.where((item) => item.lastPlayedAt != null).toList();
    }

    if (artist != null && artist.isNotEmpty) {
      result = result
          .where((item) => item.artist.toLowerCase() == artist.toLowerCase())
          .toList();
    }

    if (album != null && album.isNotEmpty) {
      result = result
          .where((item) => item.album.toLowerCase() == album.toLowerCase())
          .toList();
    }

    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      final q = searchQuery.trim().toLowerCase();
      result = result.where((item) {
        final title = item.title.toLowerCase();
        final art = item.artist.toLowerCase();
        final alb = item.album.toLowerCase();
        final path = item.path.toLowerCase();
        return title.contains(q) ||
            art.contains(q) ||
            alb.contains(q) ||
            path.contains(q);
      }).toList();
    }

    if (sortBy != null) {
      result.sort((a, b) {
        int comparison;
        switch (sortBy) {
          case 'title':
            comparison = a.title.toLowerCase().compareTo(b.title.toLowerCase());
            break;
          case 'artist':
            comparison = a.artist.toLowerCase().compareTo(
              b.artist.toLowerCase(),
            );
            break;
          case 'album':
            comparison = a.album.toLowerCase().compareTo(b.album.toLowerCase());
            break;
          case 'duration':
            comparison = a.metadata.duration.compareTo(b.metadata.duration);
            break;
          case 'fileSize':
            comparison = a.fileSize.compareTo(b.fileSize);
            break;
          case 'addedAt':
            comparison = a.addedAt.compareTo(b.addedAt);
            break;
          case 'lastPlayedAt':
            final aTime =
                a.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bTime =
                b.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            comparison = aTime.compareTo(bTime);
            break;
          case 'trackNumber':
            final discCompare = (a.metadata.discNumber ?? 1).compareTo(
              b.metadata.discNumber ?? 1,
            );
            if (discCompare != 0) {
              comparison = discCompare;
            } else {
              comparison = (a.metadata.trackNumber ?? 0).compareTo(
                b.metadata.trackNumber ?? 0,
              );
            }
            break;
          default:
            comparison = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        }
        if (comparison == 0) {
          return a.canonicalSource.compareTo(b.canonicalSource);
        }
        return ascending ? comparison : -comparison;
      });
    }

    if (offset != null && offset > 0) {
      if (offset >= result.length) {
        return const [];
      }
      result = result.sublist(offset);
    }

    if (limit != null && limit > 0 && result.length > limit) {
      result = result.sublist(0, limit);
    }

    return result;
  }

  @override
  Future<MediaItemRecord?> getMediaByCanonicalSource(
    String canonicalSource,
  ) async {
    return _items.firstWhereOrNull((i) => i.canonicalSource == canonicalSource);
  }

  @override
  Future<MediaItemRecord?> getMediaById(String id) async {
    return _items.firstWhereOrNull((i) => i.id == id);
  }

  @override
  Future<void> toggleFavorite(String mediaId, bool isFavorite) async {
    final index = _items.indexWhere((i) => i.id == mediaId);
    if (index >= 0) {
      _items[index] = _items[index].copyWith(isFavorite: isFavorite);
      notifyListeners();
    }
  }

  @override
  Future<void> recordPlayback(String canonicalSource) async {
    final index = _items.indexWhere(
      (i) => i.canonicalSource == canonicalSource,
    );
    if (index >= 0) {
      _items[index] = _items[index].copyWith(
        lastPlayedAt: DateTime.now(),
        playCount: _items[index].playCount + 1,
      );
      notifyListeners();
    }
  }

  @override
  Future<List<PlaylistRecord>> getPlaylists() async {
    return List.unmodifiable(_playlists);
  }

  @override
  Future<void> clearPlaybackHistory() async {
    for (var i = 0; i < _items.length; i++) {
      _items[i] = _items[i].copyWith(clearLastPlayedAt: true, playCount: 0);
    }
    notifyListeners();
  }

  @override
  Future<PlaylistRecord> createPlaylist(String title) async {
    final now = DateTime.now();
    final playlist = PlaylistRecord(
      id: 'pl_${_playlists.length + 1}_${now.microsecondsSinceEpoch}',
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
    final list = _playlistEntries.putIfAbsent(
      playlistId,
      () => <PlaylistEntryRecord>[],
    );
    final now = DateTime.now();
    for (final mediaId in mediaIds) {
      final media = _items.firstWhereOrNull((i) => i.id == mediaId);
      final entry = PlaylistEntryRecord(
        id: 'entry_${list.length + 1}_${now.microsecondsSinceEpoch}',
        playlistId: playlistId,
        mediaId: mediaId,
        position: list.length,
        addedAt: now,
        mediaItem: media,
      );
      list.add(entry);
    }
    final plIndex = _playlists.indexWhere((p) => p.id == playlistId);
    if (plIndex >= 0) {
      _playlists[plIndex] = _playlists[plIndex].copyWith(
        entryCount: list.length,
        updatedAt: now,
      );
    }
    notifyListeners();
  }

  @override
  Future<void> removeFromPlaylist(
    String playlistId,
    String playlistEntryId,
  ) async {
    final list = _playlistEntries[playlistId];
    if (list != null) {
      list.removeWhere((e) => e.id == playlistEntryId);
      for (var i = 0; i < list.length; i++) {
        list[i] = list[i].copyWith(position: i);
      }
      final plIndex = _playlists.indexWhere((p) => p.id == playlistId);
      if (plIndex >= 0) {
        _playlists[plIndex] = _playlists[plIndex].copyWith(
          entryCount: list.length,
          updatedAt: DateTime.now(),
        );
      }
      notifyListeners();
    }
  }

  @override
  Future<void> reorderPlaylist(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {
    final list = _playlistEntries[playlistId];
    if (list != null &&
        oldIndex >= 0 &&
        oldIndex < list.length &&
        newIndex >= 0 &&
        newIndex <= list.length) {
      if (newIndex > oldIndex) newIndex--;
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
      for (var i = 0; i < list.length; i++) {
        list[i] = list[i].copyWith(position: i);
      }
      notifyListeners();
    }
  }

  @override
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(
    String playlistId,
  ) async {
    final list = _playlistEntries[playlistId] ?? const <PlaylistEntryRecord>[];
    return List.unmodifiable(list);
  }

  @override
  Future<List<String>> getDistinctArtists({MediaKind? kind}) async {
    final items = kind != null ? _items.where((i) => i.kind == kind) : _items;
    final artists = items.map((i) => i.artist).toSet().toList()..sort();
    return artists;
  }

  @override
  Future<List<String>> getDistinctAlbums({String? artist}) async {
    final items = artist != null
        ? _items.where((i) => i.artist.toLowerCase() == artist.toLowerCase())
        : _items;
    final albums = items.map((i) => i.album).toSet().toList()..sort();
    return albums;
  }

  @override
  Future<void> markFolderAvailability(
    String folderPath,
    bool isAvailable,
  ) async {
    final fIndex = _folders.indexWhere((f) => f.path == folderPath);
    if (fIndex >= 0) {
      _folders[fIndex] = _folders[fIndex].copyWith(isAvailable: isAvailable);
    }
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].path.startsWith(folderPath)) {
        _items[i] = _items[i].copyWith(isAvailable: isAvailable);
      }
    }
    notifyListeners();
  }

  @override
  Future<void> rescanFolder(String folderPath) async {
    setScanStatus(
      LibraryScanStatus(
        phase: ScanPhase.discovering,
        currentFolder: folderPath,
        discoveredCount: _items.length,
        enrichedCount: _items.length,
        totalToEnrich: _items.length,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    setScanStatus(
      LibraryScanStatus(
        phase: ScanPhase.enriching,
        currentFolder: folderPath,
        discoveredCount: _items.length,
        enrichedCount: _items.length,
        totalToEnrich: _items.length,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    setScanStatus(const LibraryScanStatus(phase: ScanPhase.idle));
  }

  @override
  Future<void> rescanAll() async {
    setScanStatus(
      LibraryScanStatus(
        phase: ScanPhase.discovering,
        currentFolder: _folders.isNotEmpty ? _folders.first.path : null,
        discoveredCount: _items.length,
        enrichedCount: _items.length,
        totalToEnrich: _items.length,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    setScanStatus(const LibraryScanStatus(phase: ScanPhase.idle));
  }

  @override
  Future<void> cancelScan() async {
    setScanStatus(const LibraryScanStatus(phase: ScanPhase.idle));
  }

  /// Factory helper that returns sample data for testing or demo.
  factory InMemoryMediaLibraryRepository.sample() {
    final now = DateTime.now();
    final items = <MediaItemRecord>[
      MediaItemRecord(
        id: 'track_1',
        canonicalSource: 'C:/Music/Album1/01-Track1.mp3',
        path: 'C:/Music/Album1/01-Track1.mp3',
        kind: MediaKind.audio,
        fileSize: 8400000,
        addedAt: now.subtract(const Duration(days: 2)),
        lastPlayedAt: now.subtract(const Duration(hours: 1)),
        isFavorite: true,
        metadata: const MediaMetadata(
          title: 'Midnight Echoes',
          artist: 'Aura Nova',
          album: 'Neon Horizon',
          discNumber: 1,
          trackNumber: 1,
          duration: Duration(minutes: 3, seconds: 45),
        ),
      ),
      MediaItemRecord(
        id: 'track_2',
        canonicalSource: 'C:/Music/Album1/02-Track2.mp3',
        path: 'C:/Music/Album1/02-Track2.mp3',
        kind: MediaKind.audio,
        fileSize: 9200000,
        addedAt: now.subtract(const Duration(days: 2)),
        metadata: const MediaMetadata(
          title: 'Solar Wind',
          artist: 'Aura Nova',
          album: 'Neon Horizon',
          discNumber: 1,
          trackNumber: 2,
          duration: Duration(minutes: 4, seconds: 12),
        ),
      ),
      MediaItemRecord(
        id: 'track_3',
        canonicalSource: 'C:/Music/Album2/01-Intro.flac',
        path: 'C:/Music/Album2/01-Intro.flac',
        kind: MediaKind.audio,
        fileSize: 24500000,
        addedAt: now.subtract(const Duration(days: 10)),
        lastPlayedAt: now.subtract(const Duration(days: 1)),
        isFavorite: false,
        metadata: const MediaMetadata(
          title: 'Prelude to Dawn',
          artist: 'Canyon Strings',
          album: 'Acoustic Journey',
          discNumber: 1,
          trackNumber: 1,
          duration: Duration(minutes: 2, seconds: 15),
        ),
      ),
      MediaItemRecord(
        id: 'video_1',
        canonicalSource: 'C:/Videos/Nature/Cinematic_Mountains.mp4',
        path: 'C:/Videos/Nature/Cinematic_Mountains.mp4',
        kind: MediaKind.video,
        fileSize: 124500000,
        addedAt: now.subtract(const Duration(days: 5)),
        metadata: const MediaMetadata(
          title: 'Cinematic Mountains 4K',
          duration: Duration(minutes: 12, seconds: 30),
        ),
      ),
      MediaItemRecord(
        id: 'video_2',
        canonicalSource: 'D:/External/Archive/Documentary.mkv',
        path: 'D:/External/Archive/Documentary.mkv',
        kind: MediaKind.video,
        fileSize: 840000000,
        isAvailable: false,
        addedAt: now.subtract(const Duration(days: 30)),
        metadata: const MediaMetadata(
          title: 'Deep Ocean Life',
          duration: Duration(minutes: 45, seconds: 0),
        ),
      ),
    ];

    final folders = <LibraryFolderRecord>[
      LibraryFolderRecord(
        path: 'C:/Music',
        addedAt: now.subtract(const Duration(days: 10)),
        lastScannedAt: now.subtract(const Duration(minutes: 30)),
        isAvailable: true,
        fileCount: 3,
      ),
      LibraryFolderRecord(
        path: 'D:/External/Archive',
        addedAt: now.subtract(const Duration(days: 30)),
        lastScannedAt: now.subtract(const Duration(days: 5)),
        isAvailable: false,
        fileCount: 1,
      ),
    ];

    final playlist = PlaylistRecord(
      id: 'pl_favorites',
      title: 'Night Drive',
      createdAt: now.subtract(const Duration(days: 3)),
      updatedAt: now.subtract(const Duration(hours: 4)),
      entryCount: 2,
    );

    final entries = <String, List<PlaylistEntryRecord>>{
      playlist.id: [
        PlaylistEntryRecord(
          id: 'pe_1',
          playlistId: playlist.id,
          mediaId: items[0].id,
          position: 0,
          addedAt: now.subtract(const Duration(days: 3)),
          mediaItem: items[0],
        ),
        PlaylistEntryRecord(
          id: 'pe_2',
          playlistId: playlist.id,
          mediaId: items[1].id,
          position: 1,
          addedAt: now.subtract(const Duration(days: 3)),
          mediaItem: items[1],
        ),
      ],
    };

    return InMemoryMediaLibraryRepository(
      initialFolders: folders,
      initialItems: items,
      initialPlaylists: [playlist],
      initialPlaylistEntries: entries,
    );
  }
}
