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
          onFolderAvailabilityChanged: (path, available) async {
            final db = _database;
            if (_isDisposed || db == null || db.isClosed) return;
            await db.markFolderAvailability(path, available);
            await _refreshFolders();
          },
          onFolderScanCompleted:
              (path, {required fileCount, required lastScannedAt}) async {
                final db = _database;
                if (_isDisposed || db == null || db.isClosed) return;
                await db.updateFolderScanStats(
                  path,
                  fileCount: fileCount,
                  lastScannedAt: lastScannedAt,
                );
                await _refreshFolders();
              },
        );
      }

      _folders = await _database!.getAllFolders();
      if (_isDisposed) return;
      for (final folder in _folders) {
        _scanner?.registerFolder(folder.path);
      }

      if (_scanner != null) {
        _scanSubscription = _scanner!.scanStatusStream.listen((status) {
          if (_isDisposed) return;
          _scanStatus = status;
          notifyListeners();
          if (status.phase == ScanPhase.idle) unawaited(_refreshFolders());
        });
      }

      _isReady = true;
      _initializationError = null;
      notifyListeners();
      // Changes made while the app was closed cannot be observed by watchers.
      if (_scanner != null && _folders.isNotEmpty) {
        unawaited(_scanner!.scanAll().catchError((Object _) {}));
      }
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

  Future<void> _refreshFolders() async {
    final database = _database;
    if (_isDisposed || database == null || database.isClosed) return;
    try {
      final folders = await database.getAllFolders();
      if (_isDisposed) return;
      _folders = folders;
      notifyListeners();
    } catch (_) {
      if (!_isDisposed && !database.isClosed) rethrow;
    }
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
    await _refreshFolders();
  }

  @override
  Future<void> removeFolder(String path) async {
    _checkReady();
    final norm = p.normalize(p.absolute(path));
    _scanner?.unregisterFolder(norm);
    await _database!.deleteFolder(norm);
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
  }

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
    _checkReady();
    return _database!.queryMedia(
      kind: kind,
      searchQuery: searchQuery,
      artist: artist,
      album: album,
      isFavorite: onlyFavorites == true ? true : null,
      limit: limit,
      offset: offset,
      sortBy: sortBy,
      ascending: ascending,
    );
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
  Future<String?> resolveArtwork(String path) async =>
      _probeService?.resolveArtwork(path);

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
    await _refreshFolders();
  }

  @override
  Future<void> rescanAll() async {
    _checkReady();
    await _scanner?.scanAll();
    await _refreshFolders();
  }

  @override
  Future<void> cancelScan() async {
    _scanner?.cancelScan();
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

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

    if (_ownsScanner) {
      await _scanner?.dispose();
    }
    _scanner = null;

    if (_ownsDatabase) {
      await _database?.close();
    }
    _database = null;

    super.dispose();
  }
}
