// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:path/path.dart' as p;

import '../../domain/models/library_models.dart';
import '../services/media_probe_service.dart';
import '../services/media_scanner_service.dart';
import 'database/library_database.dart';
import 'media_library_repository.dart';

typedef DatabaseOpener = Future<LibraryDatabase> Function();

/// Concrete implementation of [MediaLibraryRepository].
///
/// Delegates storage, queries, and playlist management to [LibraryDatabase] (in an isolate),
/// and delegates directory traversal, debounced file watching, and metadata enrichment
/// to [MediaScannerService].
class MediaLibraryRepositoryImpl extends MediaLibraryRepository {
  MediaLibraryRepositoryImpl({
    LibraryDatabase? database,
    MediaScannerService? scannerService,
    MediaProbeService? probeService,
    DatabaseOpener? databaseOpener,
    String? databasePath,
    bool inMemory = false,
  }) : _database = database,
       _scanner = scannerService,
       _probeService = probeService,
       _databaseOpener =
           databaseOpener ??
           (() => LibraryDatabase.open(path: databasePath, inMemory: inMemory)),
       _ownsDatabase = database == null,
       _ownsScanner = scannerService == null;

  LibraryDatabase? _database;
  MediaScannerService? _scanner;
  final MediaProbeService? _probeService;
  final DatabaseOpener _databaseOpener;
  final bool _ownsDatabase;
  final bool _ownsScanner;

  StreamSubscription<LibraryScanStatus>? _scanSubscription;
  StreamSubscription<void>? _libraryChangesSubscription;
  Timer? _libraryChangeTimer;
  bool _libraryChangePending = false;
  Future<void>? _libraryRefresh;
  bool _refreshAgain = false;
  List<LibraryFolderRecord> _folders = <LibraryFolderRecord>[];
  LibraryScanStatus _scanStatus = const LibraryScanStatus();
  bool _isReady = false;
  String? _initializationError;
  bool _isDisposed = false;
  Future<void>? _initializationFuture;

  @override
  LibraryScanStatus get scanStatus => _scanner?.scanStatus ?? _scanStatus;

  @override
  List<LibraryFolderRecord> get folders => List.unmodifiable(_folders);

  @override
  bool get isReady => _isReady;

  @override
  String? get initializationError => _initializationError;

  /// Exposes the live scan status stream directly from the scanner.
  Stream<LibraryScanStatus> get scanStatusStream =>
      _scanner?.scanStatusStream ?? const Stream<LibraryScanStatus>.empty();

  @override
  Future<void> initialize() {
    if (_isDisposed || _isReady) return Future<void>.value();
    return _initializationFuture ??= _initialize().whenComplete(() {
      _initializationFuture = null;
    });
  }

  Future<void> _initialize() async {
    try {
      _database ??= await _databaseOpener();
      if (_isDisposed) return;

      if (_scanner == null && _probeService != null) {
        _scanner = MediaScannerService(
          probeService: _probeService,
          database: _database!,
        );
      }

      _folders = await _database!.getAllFolders();
      if (_isDisposed) return;
      for (final folder in _folders) {
        _scanner?.registerFolder(folder.path);
      }

      if (_scanner != null) {
        _scanSubscription = _scanner!.scanStatusStream.listen((status) {
          _scanStatus = status;
          publishScanStatus(status);
          if (!status.isScanning && _libraryChangePending) {
            _libraryChangeTimer?.cancel();
            _libraryChangeTimer = null;
            unawaited(_refreshLibraryContents());
          }
        });
        _libraryChangesSubscription = _scanner!.libraryChanges.listen((_) {
          _scheduleLibraryChange();
        });
      }

      _isReady = true;
      _initializationError = null;
      notifyListeners();
    } catch (e) {
      if (!_isDisposed) {
        _initializationError = e.toString();
        _isReady = false;
        notifyListeners();
      }
      rethrow;
    }
  }

  void _checkReady() {
    if (!_isReady || _database == null) {
      throw StateError(
        'MediaLibraryRepository is not initialized. Call initialize() first.',
      );
    }
  }

  void _scheduleLibraryChange() {
    if (_isDisposed) return;
    _libraryChangePending = true;
    _libraryChangeTimer ??= Timer(const Duration(milliseconds: 500), () {
      _libraryChangeTimer = null;
      unawaited(_refreshLibraryContents());
    });
  }

  /// Batches scan and watcher writes into a bounded number of query refreshes.
  /// The final scan state flushes pending changes without a debounce delay.
  Future<void> _refreshLibraryContents() {
    if (_isDisposed) return Future<void>.value();
    final active = _libraryRefresh;
    if (active != null) {
      _refreshAgain = true;
      return active;
    }
    final future = _drainLibraryRefreshes();
    final tracked = future.whenComplete(() {
      _libraryRefresh = null;
      if (_refreshAgain && !_isDisposed) {
        unawaited(_refreshLibraryContents());
      }
    });
    _libraryRefresh = tracked;
    return tracked;
  }

  Future<void> _drainLibraryRefreshes() async {
    do {
      _refreshAgain = false;
      _libraryChangePending = false;
      try {
        final folders = await _database!.getAllFolders();
        if (_isDisposed) return;
        _folders = folders;
        notifyListeners();
      } on Object {
        // The database may be closing after a cancelled scan.
        if (!_isDisposed) notifyListeners();
      }
    } while (_refreshAgain && !_isDisposed);
  }

  Future<void> _flushLibraryChanges() async {
    _libraryChangeTimer?.cancel();
    _libraryChangeTimer = null;
    if (_libraryChangePending) await _refreshLibraryContents();
    await _libraryRefresh;
  }

  @override
  Future<void> addFolder(String path) async {
    _checkReady();
    final norm = p.normalize(p.absolute(path));
    final existing = await _database!.getFolder(norm);
    if (existing == null) {
      final record = LibraryFolderRecord(
        path: norm,
        addedAt: DateTime.now(),
        isAvailable: true,
      );
      await _database!.insertFolder(record);
    } else if (!existing.isAvailable) {
      await _database!.markFolderAvailability(norm, true);
    }

    _scanner?.registerFolder(norm);
    _folders = await _database!.getAllFolders();
    notifyListeners();

    await _scanner?.scanFolder(norm);
    await _flushLibraryChanges();
  }

  @override
  Future<void> removeFolder(String path) async {
    _checkReady();
    final norm = p.normalize(p.absolute(path));
    await _database!.deleteFolder(norm);
    _scanner?.unregisterFolder(norm);
    _folders = await _database!.getAllFolders();
    notifyListeners();
  }

  @override
  Future<List<LibraryFolderRecord>> getFolders() async {
    _checkReady();
    _folders = await _database!.getAllFolders();
    return List.unmodifiable(_folders);
  }

  @override
  Future<void> upsertDiscoveredFiles(List<String> paths) async {
    _checkReady();
    await _database!.batchUpsertDiscoveredFiles(paths);
    _scheduleLibraryChange();
  }

  @override
  Future<void> updateMediaMetadata(
    String canonicalSource, {
    required MediaKind kind,
    required MediaMetadata metadata,
    required int fileSize,
    required DateTime modifiedAt,
  }) async {
    _checkReady();
    await _database!.updateMediaMetadata(
      canonicalSource,
      kind: kind,
      metadata: metadata,
      fileSize: fileSize,
      modifiedAt: modifiedAt,
    );
    _scheduleLibraryChange();
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
    _checkReady();
    return _database!.queryMedia(
      kind: kind,
      searchQuery: searchQuery,
      artist: artist,
      album: album,
      isFavorite: onlyFavorites == true ? true : null,
      onlyPlayed: onlyPlayed,
      limit: limit,
      offset: offset,
      sortBy: sortBy,
      ascending: ascending,
    );
  }

  @override
  Future<List<LibraryAlbumSummary>> queryAlbums({
    String? searchQuery,
    String? album,
    int? limit,
    int? offset,
  }) async {
    _checkReady();
    final rows = await _database!.queryAlbums(
      searchQuery: searchQuery,
      album: album,
      limit: limit,
      offset: offset,
    );
    return rows
        .map(
          (row) => LibraryAlbumSummary(
            album: row['album'] as String,
            artist: row['artist'] as String,
            trackCount: row['track_count'] as int,
            totalDuration: Duration(
              milliseconds: row['total_duration_ms'] as int,
            ),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<LibraryArtistSummary>> queryArtists({
    String? searchQuery,
    String? artist,
    int? limit,
    int? offset,
  }) async {
    _checkReady();
    final rows = await _database!.queryArtists(
      searchQuery: searchQuery,
      artist: artist,
      limit: limit,
      offset: offset,
    );
    return rows
        .map(
          (row) => LibraryArtistSummary(
            artist: row['artist'] as String,
            songCount: row['song_count'] as int,
            albumCount: row['album_count'] as int,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<MediaItemRecord?> getMediaByCanonicalSource(
    String canonicalSource,
  ) async {
    _checkReady();
    return _database!.getMediaByCanonicalSource(canonicalSource);
  }

  @override
  Future<MediaItemRecord?> getMediaById(String id) async {
    _checkReady();
    return _database!.getMediaById(id);
  }

  @override
  Future<void> toggleFavorite(String mediaId, bool isFavorite) async {
    _checkReady();
    await _database!.setFavorite(mediaId, isFavorite);
    notifyListeners();
  }

  @override
  Future<void> recordPlayback(String canonicalSource) async {
    _checkReady();
    await _database!.recordPlayHistoryByCanonicalSource(canonicalSource);
    notifyListeners();
  }

  @override
  Future<void> clearPlaybackHistory() async {
    _checkReady();
    await _database!.clearPlaybackHistory();
    if (!_isDisposed) notifyListeners();
  }

  @override
  Future<List<PlaylistRecord>> getPlaylists() async {
    _checkReady();
    return _database!.getAllPlaylists();
  }

  @override
  Future<PlaylistRecord> createPlaylist(String title) async {
    _checkReady();
    final pl = await _database!.createPlaylist(title);
    notifyListeners();
    return pl;
  }

  @override
  Future<void> deletePlaylist(String playlistId) async {
    _checkReady();
    await _database!.deletePlaylist(playlistId);
    notifyListeners();
  }

  @override
  Future<void> renamePlaylist(String playlistId, String newTitle) async {
    _checkReady();
    await _database!.renamePlaylist(playlistId, newTitle);
    notifyListeners();
  }

  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {
    _checkReady();
    await _database!.addEntriesToPlaylist(playlistId, mediaIds);
    notifyListeners();
  }

  @override
  Future<void> removeFromPlaylist(
    String playlistId,
    String playlistEntryId,
  ) async {
    _checkReady();
    await _database!.removePlaylistEntry(playlistEntryId);
    notifyListeners();
  }

  @override
  Future<void> reorderPlaylist(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {
    _checkReady();
    await _database!.reorderPlaylistEntries(playlistId, oldIndex, newIndex);
    notifyListeners();
  }

  @override
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(
    String playlistId,
  ) async {
    _checkReady();
    return _database!.getPlaylistEntries(playlistId);
  }

  @override
  Future<List<String>> getDistinctArtists({MediaKind? kind}) async {
    _checkReady();
    return _database!.getDistinctArtists(kind: kind);
  }

  @override
  Future<List<String>> getDistinctAlbums({String? artist}) async {
    _checkReady();
    return _database!.getDistinctAlbums(artist: artist);
  }

  @override
  Future<void> markFolderAvailability(
    String folderPath,
    bool isAvailable,
  ) async {
    _checkReady();
    final norm = p.normalize(p.absolute(folderPath));
    await _database!.markFolderAvailability(norm, isAvailable);
    _folders = await _database!.getAllFolders();
    notifyListeners();
  }

  @override
  Future<void> rescanFolder(String folderPath) async {
    _checkReady();
    final norm = p.normalize(p.absolute(folderPath));
    await _scanner?.scanFolder(norm);
    await _flushLibraryChanges();
  }

  @override
  Future<void> rescanAll() async {
    _checkReady();
    await _scanner?.scanAll();
    await _flushLibraryChanges();
  }

  @override
  Future<void> cancelScan() async {
    _scanner?.cancelScan();
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _libraryChangeTimer?.cancel();
    _libraryChangeTimer = null;

    final initialization = _initializationFuture;
    if (initialization != null) {
      try {
        await initialization;
      } on Object {
        // Continue releasing any resources created before initialization failed.
      }
    }

    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _libraryChangesSubscription?.cancel();
    _libraryChangesSubscription = null;
    await _libraryRefresh;

    if (_ownsScanner) {
      await _scanner?.dispose();
    }
    _scanner = null;

    if (_ownsDatabase) {
      await _database?.close();
    }
    _database = null;

    await super.dispose();
  }
}
