import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../player/player_controller.dart';

/// Top-level tabs for the library navigation.
enum LibraryTab { videos, music, playlists, nowPlaying }

/// ViewModel managing top-level library navigation, global search with debouncing,
/// folder management, scan status, and player interaction.
class LibraryViewModel extends ChangeNotifier {
  LibraryViewModel({
    required this.repository,
    this.playerController,
    this.searchDebounceDuration = const Duration(milliseconds: 300),
  }) {
    _scanStatus = repository.scanStatus;
    _folders = repository.folders;
    repository.addListener(_onRepositoryChanged);
    playerController?.addListener(_onPlayerChanged);
  }

  final MediaLibraryRepository repository;
  final PlayerController? playerController;
  final Duration searchDebounceDuration;

  LibraryTab _currentTab = LibraryTab.music;
  LibraryTab get currentTab => _currentTab;
  LibraryTab get selectedTab => _currentTab;

  LibraryScanStatus _scanStatus = const LibraryScanStatus();
  LibraryScanStatus get scanStatus => _scanStatus;
  bool get isScanning => _scanStatus.isScanning;

  List<LibraryFolderRecord> _folders = const [];
  List<LibraryFolderRecord> get folders => _folders;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  bool _isSearching = false;
  bool get isSearching => _isSearching;

  String? _searchError;
  String? get searchError => _searchError;

  List<MediaItemRecord> _searchResults = const [];
  List<MediaItemRecord> get searchResults => _searchResults;

  List<PlaylistRecord> _playlists = const [];
  List<PlaylistRecord> get playlists => _playlists;

  Timer? _debounceTimer;
  int _searchGeneration = 0;
  bool _disposed = false;

  // Now Playing exposures from PlayerController
  MediaEntry? get nowPlaying => playerController?.current;
  bool get isPlaying => playerController?.isPlaying ?? false;
  Duration get position => playerController?.position ?? Duration.zero;
  Duration get duration => playerController?.duration ?? Duration.zero;
  List<MediaEntry> get queue => playerController?.queue ?? const [];

  void setTab(LibraryTab tab) {
    if (_currentTab == tab) return;
    _currentTab = tab;
    notifyListeners();
  }

  void selectTab(LibraryTab tab) => setTab(tab);

  set currentTab(LibraryTab tab) => setTab(tab);
  set selectedTab(LibraryTab tab) => setTab(tab);

  /// Updates the search query and schedules a debounced execution.
  void setSearchQuery(String query) {
    _searchQuery = query;
    final generation = ++_searchGeneration;
    _debounceTimer?.cancel();

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _searchResults = const [];
      _isSearching = false;
      _searchError = null;
      notifyListeners();
      return;
    }

    _isSearching = true;
    _searchError = null;
    notifyListeners();

    if (searchDebounceDuration == Duration.zero) {
      unawaited(_executeSearch(trimmed, generation));
    } else {
      _debounceTimer = Timer(searchDebounceDuration, () {
        unawaited(_executeSearch(trimmed, generation));
      });
    }
  }

  /// Executes a search immediately without debouncing.
  Future<void> search(String query) async {
    final generation = ++_searchGeneration;
    _debounceTimer?.cancel();
    _searchQuery = query;
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _searchResults = const [];
      _isSearching = false;
      _searchError = null;
      notifyListeners();
      return;
    }
    await _executeSearch(trimmed, generation);
  }

  /// Clears the active search query and results.
  void clearSearch() {
    _searchGeneration++;
    _debounceTimer?.cancel();
    _searchQuery = '';
    _searchResults = const [];
    _isSearching = false;
    _searchError = null;
    notifyListeners();
  }

  Future<void> _executeSearch(String query, int generation) async {
    if (_disposed || generation != _searchGeneration) return;
    _isSearching = true;
    _searchError = null;
    notifyListeners();

    try {
      final results = await repository.queryMedia(searchQuery: query);
      if (_disposed) return;
      if (!_disposed && generation == _searchGeneration) {
        _searchResults = results;
        _isSearching = false;
        notifyListeners();
      }
    } catch (error) {
      if (_disposed) return;
      if (!_disposed && generation == _searchGeneration) {
        _searchError = error.toString();
        _isSearching = false;
        notifyListeners();
      }
    }
  }

  /// Matches a media item locally against titles, artists, albums, and filenames.
  static bool matchesSearch(MediaItemRecord item, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;

    final filename = item.path.split(RegExp(r'[\\/]')).last.toLowerCase();
    final title = item.title.toLowerCase();
    final artist = item.artist.toLowerCase();
    final album = item.album.toLowerCase();
    final metaArtist = (item.metadata.artist ?? '').toLowerCase();
    final metaAlbumArtist = (item.metadata.albumArtist ?? '').toLowerCase();
    final metaAlbum = (item.metadata.album ?? '').toLowerCase();
    final metaTitle = (item.metadata.title ?? '').toLowerCase();

    return filename.contains(q) ||
        title.contains(q) ||
        metaTitle.contains(q) ||
        artist.contains(q) ||
        metaArtist.contains(q) ||
        metaAlbumArtist.contains(q) ||
        album.contains(q) ||
        metaAlbum.contains(q);
  }

  // --- Folder Management ---

  Future<void> loadFolders() async {
    final folders = await repository.getFolders();
    if (_disposed) return;
    _folders = folders;
    _scanStatus = repository.scanStatus;
    notifyListeners();
  }

  Future<void> addFolder(String path) async {
    await repository.addFolder(path);
    await loadFolders();
  }

  Future<void> removeFolder(String path) async {
    await repository.removeFolder(path);
    await loadFolders();
  }

  Future<void> rescanFolder(String path) async {
    await repository.rescanFolder(path);
    if (_disposed) return;
    _scanStatus = repository.scanStatus;
    notifyListeners();
  }

  Future<void> rescanAll() async {
    await repository.rescanAll();
    if (_disposed) return;
    _scanStatus = repository.scanStatus;
    notifyListeners();
  }

  Future<void> cancelScan() async {
    await repository.cancelScan();
    if (_disposed) return;
    _scanStatus = repository.scanStatus;
    notifyListeners();
  }

  // --- Playlists Management ---

  Future<void> loadPlaylists() async {
    final playlists = await repository.getPlaylists();
    if (_disposed) return;
    _playlists = playlists;
    notifyListeners();
  }

  // --- Player Interaction ---

  Future<void> playMedia(MediaItemRecord item) async {
    await playerController?.openPaths([item.path], append: false);
  }

  Future<void> playPaths(
    List<String> paths, {
    bool append = false,
    int initialIndex = 0,
  }) async {
    await playerController?.openPaths(
      paths,
      append: append,
      initialIndex: initialIndex,
    );
  }

  void _onRepositoryChanged() {
    if (_disposed) return;
    _scanStatus = repository.scanStatus;
    _folders = repository.folders;
    notifyListeners();
  }

  void _onPlayerChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchGeneration++;
    _debounceTimer?.cancel();
    repository.removeListener(_onRepositoryChanged);
    playerController?.removeListener(_onPlayerChanged);
    super.dispose();
  }
}
