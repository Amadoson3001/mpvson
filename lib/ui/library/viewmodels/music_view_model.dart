import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../player/player_controller.dart';

/// Subtabs within the Music library view.
enum MusicSubtab {
  songs,
  albums,
  artists,
  favorites,
  recentlyAdded,
  recentlyPlayed,
}

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
  MusicViewModel({required this.repository, this.playerController}) {
    repository.addListener(_onRepositoryChanged);
  }

  final MediaLibraryRepository repository;
  final PlayerController? playerController;

  MusicSubtab _currentSubtab = MusicSubtab.songs;
  MusicSubtab get currentSubtab => _currentSubtab;
  MusicSubtab get selectedSubtab => _currentSubtab;

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

  List<String> _albums = const [];
  List<String> get albums => _albums;

  List<String> _artists = const [];
  List<String> get artists => _artists;

  List<MediaItemRecord> _favorites = const [];
  List<MediaItemRecord> get favorites => _favorites;

  List<MediaItemRecord> _recentlyAdded = const [];
  List<MediaItemRecord> get recentlyAdded => _recentlyAdded;

  List<MediaItemRecord> _recentlyPlayed = const [];
  List<MediaItemRecord> get recentlyPlayed => _recentlyPlayed;

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
    notifyListeners();
  }

  set currentSubtab(MusicSubtab subtab) => selectSubtab(subtab);
  set selectedSubtab(MusicSubtab subtab) => selectSubtab(subtab);

  void setSorting(MusicSortField field, {bool? ascending}) {
    _customSorting = true;
    _sortField = field;
    if (ascending != null) {
      _sortAscending = ascending;
    }
    notifyListeners();
  }

  void toggleSortOrder() {
    _customSorting = true;
    _sortAscending = !_sortAscending;
    notifyListeners();
  }

  void setFilterQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setSearchQuery(String query) => setFilterQuery(query);

  void filterByArtist(String? artist) {
    _selectedArtist = artist;
    notifyListeners();
  }

  void setSelectedArtist(String? artist) => filterByArtist(artist);

  void filterByAlbum(String? album) {
    _selectedAlbum = album;
    notifyListeners();
  }

  void setSelectedAlbum(String? album) => filterByAlbum(album);

  void filterByGenre(String? genre) {
    _selectedGenre = genre;
    notifyListeners();
  }

  void clearFilters() {
    _searchQuery = '';
    _selectedArtist = null;
    _selectedAlbum = null;
    _selectedGenre = null;
    notifyListeners();
  }

  /// Refreshes all music data from the repository.
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
          repository.queryMedia(kind: MediaKind.audio),
          repository.getDistinctAlbums(),
          repository.getDistinctArtists(kind: MediaKind.audio),
          repository.getPlaylists(),
        ]);

        if (_disposed) return;

        _songs = results[0] as List<MediaItemRecord>;
        _albums = results[1] as List<String>;
        _artists = results[2] as List<String>;
        _favorites = _songs.where((song) => song.isFavorite).toList();
        // Keep the repository ordering on these public collections while
        // reusing the fetched records instead of querying them again.
        _recentlyAdded = List<MediaItemRecord>.of(_songs)
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
        _recentlyPlayed =
            _songs
                .where((song) => song.lastPlayedAt != null)
                .toList(growable: false)
              ..sort(
                (a, b) =>
                    (b.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                        .compareTo(
                          a.lastPlayedAt ??
                              DateTime.fromMillisecondsSinceEpoch(0),
                        ),
              );
        _playlists = results[3] as List<PlaylistRecord>;

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
      } while (_refreshAgain && !_disposed);
    } finally {
      if (!_disposed) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Returns the current collection based on the selected subtab,
  /// with search and attribute filters and user sorting applied.
  List<MediaItemRecord> get currentCollection {
    List<MediaItemRecord> source;
    switch (_currentSubtab) {
      case MusicSubtab.songs:
        source = _songs;
        break;
      case MusicSubtab.favorites:
        source = _favorites.isNotEmpty
            ? _favorites
            : _songs.where((s) => s.isFavorite).toList();
        break;
      case MusicSubtab.recentlyAdded:
        source = _recentlyAdded.isNotEmpty
            ? _recentlyAdded
            : (List<MediaItemRecord>.of(_songs)
                ..sort((a, b) => b.addedAt.compareTo(a.addedAt)));
        break;
      case MusicSubtab.recentlyPlayed:
        source = _recentlyPlayed.isNotEmpty
            ? _recentlyPlayed
            : (_songs.where((s) => s.lastPlayedAt != null).toList()..sort(
                (a, b) =>
                    (b.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                        .compareTo(
                          a.lastPlayedAt ??
                              DateTime.fromMillisecondsSinceEpoch(0),
                        ),
              ));
        break;
      case MusicSubtab.albums:
        if (_selectedAlbum != null) {
          source = _songs
              .where(
                (s) => s.album.toLowerCase() == _selectedAlbum!.toLowerCase(),
              )
              .toList();
        } else {
          source = _songs;
        }
        break;
      case MusicSubtab.artists:
        if (_selectedArtist != null) {
          source = _songs
              .where(
                (s) => s.artist.toLowerCase() == _selectedArtist!.toLowerCase(),
              )
              .toList();
        } else {
          source = _songs;
        }
        break;
    }

    // Apply filtering
    var filtered = source;
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      filtered = filtered.where((item) {
        final filename = item.path.split(RegExp(r'[\\/]')).last.toLowerCase();
        final title = item.title.toLowerCase();
        final artist = item.artist.toLowerCase();
        final album = item.album.toLowerCase();
        return filename.contains(q) ||
            title.contains(q) ||
            artist.contains(q) ||
            album.contains(q);
      }).toList();
    }

    if (_selectedArtist != null && _currentSubtab != MusicSubtab.artists) {
      filtered = filtered
          .where(
            (s) => s.artist.toLowerCase() == _selectedArtist!.toLowerCase(),
          )
          .toList();
    }

    if (_selectedAlbum != null && _currentSubtab != MusicSubtab.albums) {
      filtered = filtered
          .where((s) => s.album.toLowerCase() == _selectedAlbum!.toLowerCase())
          .toList();
    }

    if (_selectedGenre != null) {
      filtered = filtered
          .where(
            (s) =>
                s.metadata.genre?.toLowerCase() ==
                _selectedGenre!.toLowerCase(),
          )
          .toList();
    }

    // Apply sorting
    final sorted = List<MediaItemRecord>.of(filtered)..sort(_compareMedia);
    return sorted;
  }

  List<MediaItemRecord> get currentSongs => currentCollection;
  List<MediaItemRecord> get items => currentCollection;

  int _compareMedia(MediaItemRecord a, MediaItemRecord b) {
    int result = 0;
    switch (_sortField) {
      case MusicSortField.title:
        result = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        break;
      case MusicSortField.artist:
        result = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        break;
      case MusicSortField.album:
        result = a.album.toLowerCase().compareTo(b.album.toLowerCase());
        break;
      case MusicSortField.duration:
        result = a.metadata.duration.compareTo(b.metadata.duration);
        break;
      case MusicSortField.dateAdded:
        result = a.addedAt.compareTo(b.addedAt);
        break;
      case MusicSortField.lastPlayed:
        final lpA = a.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final lpB = b.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        result = lpA.compareTo(lpB);
        break;
      case MusicSortField.trackNumber:
        final tA = a.metadata.trackNumber ?? 0;
        final tB = b.metadata.trackNumber ?? 0;
        result = tA.compareTo(tB);
        break;
      case MusicSortField.year:
        final yA = a.metadata.year ?? 0;
        final yB = b.metadata.year ?? 0;
        result = yA.compareTo(yB);
        break;
    }
    if (result == 0) {
      result = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (result == 0) {
        result = a.id.compareTo(b.id);
      }
    }
    return _sortAscending ? result : -result;
  }

  // --- Operations ---

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
      final existing = _songs.where((s) => s.id == mediaId).firstOrNull;
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
    int newIndex,
  ) async {
    await repository.reorderPlaylist(playlistId, oldIndex, newIndex);
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

  void _onRepositoryChanged() {
    if (_disposed) return;
    unawaited(
      refresh().catchError((Object error, StackTrace _) {
        debugPrint('Music library refresh failed: $error');
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    repository.removeListener(_onRepositoryChanged);
    super.dispose();
  }
}
