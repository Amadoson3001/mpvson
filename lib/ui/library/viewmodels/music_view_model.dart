import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../player/player_controller.dart';
import '../paged_media_loader.dart';

/// Subtabs within the Music library view.
enum MusicSubtab {
  songs,
  albums,
  artists,
  favorites,
  recentlyAdded,
  recentlyPlayed,
}

typedef MusicSubTab = MusicSubtab;

/// Fields available for sorting media collections.
enum MusicSortField {
  title,
  artist,
  album,
  duration,
  dateAdded,
  lastPlayed,
  trackNumber,
  year,
}

/// ViewModel for browsing and interacting with the music collection, albums,
/// artists, favorites, recent tracks, and playlists.
class MusicViewModel extends ChangeNotifier {
  MusicViewModel({required this.repository, this.playerController});

  final MediaLibraryRepository repository;
  final PlayerController? playerController;

  MusicSubtab _currentSubtab = MusicSubtab.songs;
  MusicSubtab get currentSubtab => _currentSubtab;
  MusicSubtab get selectedSubtab => _currentSubtab;
  MusicSubtab get subTab => _currentSubtab;
  MusicSubtab get subtab => _currentSubtab;

  MusicSortField _sortField = MusicSortField.title;
  MusicSortField get sortField => _sortField;

  bool _sortAscending = true;
  bool get sortAscending => _sortAscending;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;
  String get filterQuery => _searchQuery;

  String? _selectedArtist;
  String? get selectedArtist => _selectedArtist;

  String? _selectedAlbum;
  String? get selectedAlbum => _selectedAlbum;

  String? _selectedGenre;
  String? get selectedGenre => _selectedGenre;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  List<MediaItemRecord> _songs = const [];
  List<MediaItemRecord> get songs => _songs;

  int _songsOffset = 0;
  bool _hasMoreSongs = true;
  bool get hasMoreSongs => _hasMoreSongs;

  bool _loadingMoreSongs = false;
  bool get isLoadingMoreSongs => _loadingMoreSongs;

  int _songPageEpoch = 0;

  List<String> _albums = const [];
  List<String> get albums => _albums;

  List<String> _artists = const [];
  List<String> get artists => _artists;

  List<MediaItemRecord> get favorites =>
      _currentSubtab == MusicSubtab.favorites ? _songs : const [];

  List<MediaItemRecord> get recentlyAdded =>
      _currentSubtab == MusicSubtab.recentlyAdded ? _songs : const [];

  List<MediaItemRecord> get recentlyPlayed =>
      _currentSubtab == MusicSubtab.recentlyPlayed ? _songs : const [];

  List<PlaylistRecord> _playlists = const [];
  List<PlaylistRecord> get playlists => _playlists;

  PlaylistRecord? _selectedPlaylist;
  PlaylistRecord? get selectedPlaylist => _selectedPlaylist;

  List<PlaylistEntryRecord> _playlistEntries = const [];
  List<PlaylistEntryRecord> get playlistEntries => _playlistEntries;

  bool _disposed = false;
  bool _customSorting = false;
  Future<void>? _refreshFuture;
  bool _refreshAgain = false;

  static bool _isSongListSubtab(MusicSubtab subtab) =>
      subtab == MusicSubtab.songs ||
      subtab == MusicSubtab.favorites ||
      subtab == MusicSubtab.recentlyAdded ||
      subtab == MusicSubtab.recentlyPlayed;

  void _resetSongPages() {
    _songs = const [];
    _songsOffset = 0;
    _hasMoreSongs = true;
    _songPageEpoch++;
  }

  String _sortByForField(MusicSortField field) {
    return switch (field) {
      MusicSortField.title => 'title',
      MusicSortField.artist => 'artist',
      MusicSortField.album => 'album',
      MusicSortField.duration => 'duration',
      MusicSortField.dateAdded => 'addedAt',
      MusicSortField.lastPlayed => 'lastPlayedAt',
      MusicSortField.trackNumber => 'trackNumber',
      MusicSortField.year => 'year',
    };
  }

  /// Query parameters for [fetchMediaPage] (same filters as the music library view).
  ({
    MediaKind kind,
    String? searchQuery,
    String? artist,
    String? album,
    bool? onlyFavorites,
    String sortBy,
    bool ascending,
  })
  _songPageQueryForCurrentSubtab() {
    final trimmed = _searchQuery.trim();
    final search = trimmed.isEmpty ? null : trimmed;
    switch (_currentSubtab) {
      case MusicSubtab.songs:
        return (
          kind: MediaKind.audio,
          searchQuery: search,
          artist: _selectedArtist,
          album: _selectedAlbum,
          onlyFavorites: null,
          sortBy: _sortByForField(_sortField),
          ascending: _sortAscending,
        );
      case MusicSubtab.favorites:
        return (
          kind: MediaKind.audio,
          searchQuery: search,
          artist: _selectedArtist,
          album: _selectedAlbum,
          onlyFavorites: true,
          sortBy: _sortByForField(_sortField),
          ascending: _sortAscending,
        );
      case MusicSubtab.recentlyAdded:
        return (
          kind: MediaKind.audio,
          searchQuery: search,
          artist: _selectedArtist,
          album: _selectedAlbum,
          onlyFavorites: null,
          sortBy: _sortByForField(_sortField),
          ascending: _sortAscending,
        );
      case MusicSubtab.recentlyPlayed:
        return (
          kind: MediaKind.audio,
          searchQuery: search,
          artist: _selectedArtist,
          album: _selectedAlbum,
          onlyFavorites: null,
          sortBy: _sortByForField(_sortField),
          ascending: _sortAscending,
        );
      case MusicSubtab.albums:
      case MusicSubtab.artists:
        return (
          kind: MediaKind.audio,
          searchQuery: search,
          artist: null,
          album: null,
          onlyFavorites: null,
          sortBy: 'title',
          ascending: true,
        );
    }
  }

  Future<void> ensureFirstSongsPage() async {
    if (_disposed || !_isSongListSubtab(_currentSubtab)) return;
    if (_songs.isNotEmpty || _loadingMoreSongs) return;
    await loadMoreSongs();
  }

  Future<void> loadMoreSongs() async {
    if (_disposed || !_isSongListSubtab(_currentSubtab)) return;
    if (!_hasMoreSongs || _loadingMoreSongs) return;

    final epoch = _songPageEpoch;
    _loadingMoreSongs = true;
    notifyListeners();

    try {
      final query = _songPageQueryForCurrentSubtab();
      final batch = await fetchMediaPage(
        repository,
        offset: _songsOffset,
        kind: query.kind,
        searchQuery: query.searchQuery,
        artist: query.artist,
        album: query.album,
        onlyFavorites: query.onlyFavorites,
        sortBy: query.sortBy,
        ascending: query.ascending,
      );

      if (_disposed || epoch != _songPageEpoch) return;

      var items = batch.items;
      if (_currentSubtab == MusicSubtab.recentlyPlayed) {
        items = items.where((item) => item.lastPlayedAt != null).toList();
      }

      _songs = [..._songs, ...items];
      _songsOffset += batch.items.length;
      _hasMoreSongs = batch.hasMore;
    } finally {
      if (!_disposed) {
        _loadingMoreSongs = false;
        notifyListeners();
      }
    }
  }

  void _invalidateSongPagesAndScheduleLoad() {
    _resetSongPages();
    notifyListeners();
    unawaited(ensureFirstSongsPage());
  }

  void selectSubtab(MusicSubtab subtab) {
    if (_currentSubtab == subtab) return;
    _currentSubtab = subtab;
    if (!_customSorting) {
      if (subtab == MusicSubtab.recentlyAdded) {
        _sortField = MusicSortField.dateAdded;
        _sortAscending = false;
      } else if (subtab == MusicSubtab.recentlyPlayed) {
        _sortField = MusicSortField.lastPlayed;
        _sortAscending = false;
      } else {
        _sortField = MusicSortField.title;
        _sortAscending = true;
      }
    }
    if (_isSongListSubtab(subtab)) {
      _invalidateSongPagesAndScheduleLoad();
    } else {
      _resetSongPages();
      notifyListeners();
    }
  }

  set currentSubtab(MusicSubtab subtab) => selectSubtab(subtab);
  set selectedSubtab(MusicSubtab subtab) => selectSubtab(subtab);
  set subTab(MusicSubtab subtab) => selectSubtab(subtab);
  set subtab(MusicSubtab subtab) => selectSubtab(subtab);

  void setSorting(MusicSortField field, {bool? ascending}) {
    _customSorting = true;
    _sortField = field;
    if (ascending != null) {
      _sortAscending = ascending;
    }
    if (_isSongListSubtab(_currentSubtab)) {
      _invalidateSongPagesAndScheduleLoad();
    } else {
      notifyListeners();
    }
  }

  void toggleSortOrder() {
    _customSorting = true;
    _sortAscending = !_sortAscending;
    if (_isSongListSubtab(_currentSubtab)) {
      _invalidateSongPagesAndScheduleLoad();
    } else {
      notifyListeners();
    }
  }

  void setFilterQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    if (_isSongListSubtab(_currentSubtab)) {
      _invalidateSongPagesAndScheduleLoad();
    } else {
      notifyListeners();
    }
  }

  void setSearchQuery(String query) => setFilterQuery(query);

  void filterByArtist(String? artist) {
    if (_selectedArtist == artist) return;
    _selectedArtist = artist;
    if (_isSongListSubtab(_currentSubtab)) {
      _invalidateSongPagesAndScheduleLoad();
    } else {
      notifyListeners();
    }
  }

  void setSelectedArtist(String? artist) => filterByArtist(artist);

  void filterByAlbum(String? album) {
    if (_selectedAlbum == album) return;
    _selectedAlbum = album;
    if (_isSongListSubtab(_currentSubtab)) {
      _invalidateSongPagesAndScheduleLoad();
    } else {
      notifyListeners();
    }
  }

  void setSelectedAlbum(String? album) => filterByAlbum(album);

  void filterByGenre(String? genre) {
    if (_selectedGenre == genre) return;
    _selectedGenre = genre;
    notifyListeners();
  }

  void clearFilters() {
    _searchQuery = '';
    _selectedArtist = null;
    _selectedAlbum = null;
    _selectedGenre = null;
    if (_isSongListSubtab(_currentSubtab)) {
      _invalidateSongPagesAndScheduleLoad();
    } else {
      notifyListeners();
    }
  }

  /// Distinct albums/artists and playlists only (MusicView owns paged song loads).
  Future<void> refreshLibraryMetadata() async {
    if (_disposed) return;
    try {
      final results = await Future.wait([
        repository.getDistinctAlbums(),
        repository.getDistinctArtists(kind: MediaKind.audio),
        repository.getPlaylists(),
      ]);
      if (_disposed) return;
      _albums = results[0] as List<String>;
      _artists = results[1] as List<String>;
      _playlists = results[2] as List<PlaylistRecord>;
      notifyListeners();
    } catch (error, stackTrace) {
      debugPrint('Music library metadata refresh failed: $error\n$stackTrace');
    }
  }

  /// Refreshes library metadata (albums, artists, playlists) without loading
  /// the full audio collection; song lists are paged on demand.
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    final activeRefresh = _refreshFuture;
    if (activeRefresh != null) {
      _refreshAgain = true;
      return activeRefresh;
    }
    final refresh = _drainRefreshRequests();
    final tracked = refresh.whenComplete(() {
      _refreshFuture = null;
      if (_refreshAgain && !_disposed) {
        unawaited(this.refresh());
      }
    });
    _refreshFuture = tracked;
    return tracked;
  }

  Future<void> _drainRefreshRequests() async {
    _isLoading = true;
    notifyListeners();

    try {
      do {
        _refreshAgain = false;
        final results = await Future.wait([
          repository.getDistinctAlbums(),
          repository.getDistinctArtists(kind: MediaKind.audio),
          repository.getPlaylists(),
        ]);

        if (_disposed) return;

        _albums = results[0] as List<String>;
        _artists = results[1] as List<String>;
        _playlists = results[2] as List<PlaylistRecord>;

        _resetSongPages();

        if (_selectedPlaylist != null) {
          final currentId = _selectedPlaylist!.id;
          final updated = _playlists
              .where((p) => p.id == currentId)
              .firstOrNull;
          _selectedPlaylist = updated;
          if (updated != null) {
            _playlistEntries = await repository.getPlaylistEntries(currentId);
          } else {
            _playlistEntries = const [];
          }
        } else {
          _playlistEntries = const [];
        }

        if (_isSongListSubtab(_currentSubtab)) {
          await ensureFirstSongsPage();
        }
      } while (_refreshAgain && !_disposed);
    } finally {
      if (!_disposed) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Returns the current collection based on the selected subtab.
  /// Song-list subtabs expose loaded pages; albums/artists use distinct lists in the view.
  List<MediaItemRecord> get currentCollection {
    switch (_currentSubtab) {
      case MusicSubtab.albums:
      case MusicSubtab.artists:
        return const [];
      case MusicSubtab.songs:
      case MusicSubtab.favorites:
      case MusicSubtab.recentlyAdded:
      case MusicSubtab.recentlyPlayed:
        break;
    }

    var filtered = _songs;

    if (_selectedGenre != null) {
      filtered = filtered
          .where(
            (s) =>
                s.metadata.genre?.toLowerCase() ==
                _selectedGenre!.toLowerCase(),
          )
          .toList();
    }

    return filtered;
  }

  List<MediaItemRecord> get currentSongs => currentCollection;
  List<MediaItemRecord> get items => currentCollection;

  // --- Operations ---

  Future<MediaItemRecord?> _resolveMediaRecord(String mediaId) async {
    final loaded = _songs.where((s) => s.id == mediaId).firstOrNull;
    if (loaded != null) return loaded;
    final byId = await repository.getMediaById(mediaId);
    if (byId != null) return byId;
    return repository.getMediaByCanonicalSource(mediaId);
  }

  /// Plays the current collection starting at the specified index.
  Future<void> playSongAtIndex(int index) async {
    final collection = currentCollection;
    if (index < 0 || index >= collection.length) return;
    final paths = collection.map((e) => e.path).toList();
    await playerController?.openPaths(
      paths,
      append: false,
      initialIndex: index,
    );
  }

  Future<void> playAtIndex(int index) => playSongAtIndex(index);

  /// Plays a specific song by finding its index in the current collection.
  Future<void> playSong(MediaItemRecord song) async {
    final index = currentCollection.indexWhere((item) => item.id == song.id);
    if (index >= 0) {
      await playSongAtIndex(index);
    } else {
      await playerController?.openPaths([song.path], append: false);
    }
  }

  /// Orders tracks by disc number, track number, then filename.
  static int compareAlbumTracks(MediaItemRecord a, MediaItemRecord b) {
    final discA = a.metadata.discNumber ?? 1;
    final discB = b.metadata.discNumber ?? 1;
    if (discA != discB) return discA.compareTo(discB);

    final trackA = a.metadata.trackNumber ?? 0;
    final trackB = b.metadata.trackNumber ?? 0;
    if (trackA != trackB) return trackA.compareTo(trackB);

    final fileA = a.path.split(RegExp(r'[\\/]')).last.toLowerCase();
    final fileB = b.path.split(RegExp(r'[\\/]')).last.toLowerCase();
    return fileA.compareTo(fileB);
  }

  /// Plays an album with tracks ordered by disc number, track number, then filename.
  /// Accepts either an album title (String) or a list of MediaItemRecord.
  Future<void> playAlbum(dynamic album, {int startIndex = 0}) async {
    List<MediaItemRecord> tracks;
    if (album is String) {
      tracks = await repository.queryMedia(kind: MediaKind.audio, album: album);
    } else if (album is List<MediaItemRecord>) {
      tracks = List<MediaItemRecord>.of(album);
    } else {
      return;
    }

    final sortedTracks = List<MediaItemRecord>.of(tracks)
      ..sort(compareAlbumTracks);
    final paths = sortedTracks.map((t) => t.path).toList();
    if (paths.isEmpty) return;

    await playerController?.openPaths(
      paths,
      append: false,
      initialIndex: startIndex,
    );
  }

  Future<void> playAlbumTracks(
    List<MediaItemRecord> tracks, {
    int startIndex = 0,
  }) => playAlbum(tracks, startIndex: startIndex);

  List<String> _extractPaths(dynamic media) {
    if (media is MediaItemRecord) return [media.path];
    if (media is String) return [media];
    if (media is List<MediaItemRecord>) {
      return media.map((e) => e.path).toList();
    }
    if (media is List<String>) return media;
    if (media is Iterable<MediaItemRecord>) {
      return media.map((e) => e.path).toList();
    }
    if (media is Iterable<String>) return media.toList();
    return const [];
  }

  /// Inserts item(s) to play immediately after the current song.
  Future<void> playNext(dynamic media) async {
    final paths = _extractPaths(media);
    if (paths.isEmpty) return;
    if (media is String && paths.length == 1) {
      final inPage = _songs.any(
        (s) => s.id == media || s.path == media || s.canonicalSource == media,
      );
      if (!inPage) {
        final resolved = await _resolveMediaRecord(media);
        if (resolved != null) {
          await playerController?.openPaths(
            [resolved.path],
            append: true,
            playNext: true,
          );
          return;
        }
      }
    }
    await playerController?.openPaths(paths, append: true, playNext: true);
  }

  /// Appends item(s) to the end of the playback queue.
  Future<void> addToQueue(dynamic media) async {
    final paths = _extractPaths(media);
    if (paths.isEmpty) return;
    await playerController?.openPaths(paths, append: true);
  }

  /// Toggles favorite status for a given media item or id.
  Future<void> toggleFavorite(dynamic media, [bool? targetStatus]) async {
    String mediaId;
    bool newStatus;
    if (media is MediaItemRecord) {
      mediaId = media.id;
      newStatus = targetStatus ?? !media.isFavorite;
    } else if (media is String) {
      mediaId = media;
      final existing = await _resolveMediaRecord(mediaId);
      newStatus =
          targetStatus ?? (existing != null ? !existing.isFavorite : true);
    } else {
      return;
    }

    await repository.toggleFavorite(mediaId, newStatus);
    await refresh();
  }

  // --- Playlists Management ---

  Future<void> loadPlaylists() async {
    _playlists = await repository.getPlaylists();
    notifyListeners();
  }

  Future<void> selectPlaylist(PlaylistRecord? playlist) async {
    _selectedPlaylist = playlist;
    if (playlist != null) {
      _playlistEntries = await repository.getPlaylistEntries(playlist.id);
    } else {
      _playlistEntries = const [];
    }
    notifyListeners();
  }

  Future<PlaylistRecord> createPlaylist(String title) async {
    final created = await repository.createPlaylist(title);
    await loadPlaylists();
    return created;
  }

  Future<void> renamePlaylist(String playlistId, String newTitle) async {
    await repository.renamePlaylist(playlistId, newTitle);
    if (_selectedPlaylist?.id == playlistId) {
      _selectedPlaylist = _selectedPlaylist!.copyWith(title: newTitle);
    }
    await loadPlaylists();
  }

  Future<void> deletePlaylist(String playlistId) async {
    await repository.deletePlaylist(playlistId);
    if (_selectedPlaylist?.id == playlistId) {
      _selectedPlaylist = null;
      _playlistEntries = const [];
    }
    await loadPlaylists();
  }

  Future<void> addSongsToPlaylist(
    String playlistId,
    List<String> mediaIds,
  ) async {
    await repository.addToPlaylist(playlistId, mediaIds);
    if (_selectedPlaylist?.id == playlistId) {
      _playlistEntries = await repository.getPlaylistEntries(playlistId);
    }
    await loadPlaylists();
  }

  Future<void> addSongToPlaylist(String playlistId, String mediaId) =>
      addSongsToPlaylist(playlistId, [mediaId]);

  Future<void> removeSongFromPlaylist(
    String playlistId,
    String playlistEntryId,
  ) async {
    await repository.removeFromPlaylist(playlistId, playlistEntryId);
    if (_selectedPlaylist?.id == playlistId) {
      _playlistEntries = await repository.getPlaylistEntries(playlistId);
    }
    await loadPlaylists();
  }

  Future<void> reorderPlaylist(
    String playlistId,
    int oldIndex,
    int newIndex, {
    String? entryId,
  }) async {
    await repository.reorderPlaylist(
      playlistId,
      oldIndex,
      newIndex,
      entryId: entryId,
    );
    if (_selectedPlaylist?.id == playlistId) {
      _playlistEntries = await repository.getPlaylistEntries(playlistId);
    }
    notifyListeners();
  }

  Future<void> playPlaylist(String playlistId, {int startIndex = 0}) async {
    final entries = await repository.getPlaylistEntries(playlistId);
    final paths = entries
        .map((e) => e.mediaItem?.path)
        .whereType<String>()
        .toList();
    if (paths.isEmpty) return;
    await playerController?.openPaths(
      paths,
      append: false,
      initialIndex: startIndex,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
