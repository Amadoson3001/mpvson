// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';

/// Data payload for batch metadata updates.
@immutable
class MediaEnrichmentData {
  const MediaEnrichmentData({
    required this.canonicalSource,
    required this.kind,
    required this.metadata,
    required this.fileSize,
    required this.modifiedAt,
  });

  final String canonicalSource;
  final MediaKind kind;
  final MediaMetadata metadata;
  final int fileSize;
  final DateTime modifiedAt;

  Map<String, Object?> toMap() => <String, Object?>{
    'canonicalSource': canonicalSource,
    'kind': kind.name,
    'title': metadata.title,
    'artist': metadata.artist,
    'albumArtist': metadata.albumArtist,
    'album': metadata.album,
    'genre': metadata.genre,
    'year': metadata.year,
    'trackNumber': metadata.trackNumber,
    'discNumber': metadata.discNumber,
    'durationMs': metadata.duration.inMilliseconds,
    'artworkUri': metadata.artworkUri,
    'audioCodec': metadata.audioInfo?.codec,
    'sampleRate': metadata.audioInfo?.sampleRate,
    'channels': metadata.audioInfo?.channels,
    'bitrate': metadata.audioInfo?.bitrate,
    'bitsPerSample': metadata.audioInfo?.bitsPerSample,
    'fileSize': fileSize,
    'modifiedAt': modifiedAt.millisecondsSinceEpoch,
  };

  factory MediaEnrichmentData.fromMap(Map<String, Object?> map) {
    final audioCodec = map['audioCodec'] as String?;
    final sampleRate = map['sampleRate'] as int?;
    final channels = map['channels'] as int?;
    final bitrate = map['bitrate'] as int?;
    final bitsPerSample = map['bitsPerSample'] as int?;
    final hasAudioInfo =
        audioCodec != null ||
        sampleRate != null ||
        channels != null ||
        bitrate != null ||
        bitsPerSample != null;

    final kindStr = map['kind'] as String?;
    final kind = MediaKind.values.firstWhere(
      (k) => k.name == kindStr,
      orElse: () => MediaKind.unknown,
    );

    return MediaEnrichmentData(
      canonicalSource: map['canonicalSource'] as String,
      kind: kind,
      metadata: MediaMetadata(
        title: map['title'] as String?,
        artist: map['artist'] as String?,
        albumArtist: map['albumArtist'] as String?,
        album: map['album'] as String?,
        genre: map['genre'] as String?,
        year: map['year'] as int?,
        trackNumber: map['trackNumber'] as int?,
        discNumber: map['discNumber'] as int?,
        duration: Duration(milliseconds: (map['durationMs'] as int?) ?? 0),
        artworkUri: map['artworkUri'] as String?,
        audioInfo: hasAudioInfo
            ? AudioTechnicalInfo(
                codec: audioCodec,
                sampleRate: sampleRate,
                channels: channels,
                bitrate: bitrate,
                bitsPerSample: bitsPerSample,
              )
            : null,
      ),
      fileSize: (map['fileSize'] as int?) ?? 0,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['modifiedAt'] as int?) ?? 0,
      ),
    );
  }
}

/// A robust SQLite media library database executed entirely in a dedicated isolate.
///
/// Ensures database operations never block the main Flutter UI isolate.
class LibraryDatabase {
  LibraryDatabase._({
    required Isolate isolate,
    required SendPort commandPort,
    required ReceivePort responsePort,
    required ReceivePort exitPort,
  }) : _isolate = isolate,
       _commandPort = commandPort,
       _responsePort = responsePort,
       _exitPort = exitPort {
    _responseSubscription = _responsePort.listen(
      _handleResponse,
      onError: (Object error, StackTrace stackTrace) {
        _failAllPending(error, stackTrace);
      },
      onDone: () {
        _failAllPending(StateError('Database isolate connection closed.'));
      },
    );
    _exitSubscription = _exitPort.listen((_) {
      _failAllPending(StateError('Database isolate exited unexpectedly.'));
    });
  }

  final Isolate _isolate;
  final SendPort _commandPort;
  final ReceivePort _responsePort;
  final ReceivePort _exitPort;
  StreamSubscription<dynamic>? _responseSubscription;
  StreamSubscription<dynamic>? _exitSubscription;

  int _nextRequestId = 1;
  final Map<int, Completer<dynamic>> _pendingRequests =
      <int, Completer<dynamic>>{};
  bool _isClosed = false;

  /// Whether the database isolate connection is closed.
  bool get isClosed => _isClosed;

  /// Opens or initializes the SQLite database at [path], or in-memory when
  /// [inMemory] is true or [path] is ':memory:'.
  static Future<LibraryDatabase> open({
    String? path,
    bool inMemory = false,
  }) async {
    final initPort = ReceivePort();
    final exitPort = ReceivePort();
    final responsePort = ReceivePort();

    final isolate = await Isolate.spawn<_DbInitParams>(
      _databaseIsolateEntryPoint,
      _DbInitParams(
        initPort: initPort.sendPort,
        path: path,
        inMemory: inMemory,
      ),
      onExit: exitPort.sendPort,
    );

    final dynamic initResult = await initPort.first;
    initPort.close();

    if (initResult is _DbInitError) {
      exitPort.close();
      responsePort.close();
      isolate.kill(priority: Isolate.immediate);
      throw Exception(
        'Failed to initialize LibraryDatabase: ${initResult.message}',
      );
    }

    if (initResult is! SendPort) {
      exitPort.close();
      responsePort.close();
      isolate.kill(priority: Isolate.immediate);
      throw StateError(
        'Unexpected init response from database isolate: $initResult',
      );
    }

    return LibraryDatabase._(
      isolate: isolate,
      commandPort: initResult,
      responsePort: responsePort,
      exitPort: exitPort,
    );
  }

  void _handleResponse(dynamic message) {
    if (message is _DbResponse) {
      final completer = _pendingRequests.remove(message.id);
      if (completer != null) {
        if (message.isSuccess) {
          completer.complete(message.result);
        } else {
          completer.completeError(
            Exception(message.error),
            message.stackTrace != null
                ? StackTrace.fromString(message.stackTrace!)
                : null,
          );
        }
      }
    }
  }

  void _failAllPending(Object error, [StackTrace? stackTrace]) {
    final pending = List<Completer<dynamic>>.from(_pendingRequests.values);
    _pendingRequests.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }
  }

  Future<T> _send<T>(String action, [Object? params]) {
    if (_isClosed) {
      throw StateError('LibraryDatabase is closed.');
    }
    final requestId = _nextRequestId++;
    final completer = Completer<T>();
    _pendingRequests[requestId] = completer;

    _commandPort.send(
      _DbRequest(
        id: requestId,
        action: action,
        params: params,
        replyPort: _responsePort.sendPort,
      ),
    );

    return completer.future;
  }

  /// Returns the PRAGMA journal_mode value (e.g. 'wal' or 'memory').
  Future<String> getJournalMode() async {
    final res = await _send<dynamic>('getJournalMode');
    return res as String;
  }

  /// Executes raw SQL without returning rows.
  Future<void> executeRaw(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    await _send<dynamic>('executeRaw', <String, Object?>{
      'sql': sql,
      'params': parameters,
    });
  }

  /// Selects raw rows from SQL.
  Future<List<Map<String, Object?>>> selectRaw(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    final rows = await _send<dynamic>('selectRaw', <String, Object?>{
      'sql': sql,
      'params': parameters,
    });
    return (rows as List)
        .map((e) => (e as Map).cast<String, Object?>())
        .toList();
  }

  // ---------------------------------------------------------------------------
  // FOLDERS
  // ---------------------------------------------------------------------------

  /// Inserts a new folder record.
  Future<void> insertFolder(LibraryFolderRecord folder) async {
    await _send<dynamic>('insertFolder', _folderToMap(folder));
  }

  /// Updates an existing folder record.
  Future<void> updateFolder(LibraryFolderRecord folder) async {
    await _send<dynamic>('updateFolder', _folderToMap(folder));
  }

  /// Deletes a folder record by path.
  Future<void> deleteFolder(String path) async {
    await _send<dynamic>('deleteFolder', path);
  }

  /// Retrieves a folder record by path.
  Future<LibraryFolderRecord?> getFolder(String path) async {
    final res = await _send<dynamic>('getFolder', path);
    if (res == null) return null;
    return _folderFromMap((res as Map).cast<String, Object?>());
  }

  /// Retrieves all folder records.
  Future<List<LibraryFolderRecord>> getAllFolders() async {
    final res = await _send<dynamic>('getAllFolders');
    return (res as List)
        .map((e) => _folderFromMap((e as Map).cast<String, Object?>()))
        .toList();
  }

  /// Updates the availability of a folder and all media items located inside it.
  Future<void> markFolderAvailability(
    String folderPath,
    bool isAvailable,
  ) async {
    await _send<dynamic>('markFolderAvailability', <String, Object?>{
      'folderPath': folderPath,
      'isAvailable': isAvailable,
    });
  }

  /// Updates a folder's fileCount and lastScannedAt stats.
  Future<void> updateFolderScanStats(
    String path, {
    int? fileCount,
    DateTime? lastScannedAt,
  }) async {
    await _send<dynamic>('updateFolderScanStats', <String, Object?>{
      'path': path,
      'fileCount': fileCount,
      'lastScannedAt': lastScannedAt?.millisecondsSinceEpoch,
    });
  }

  // ---------------------------------------------------------------------------
  // MEDIA CRUD
  // ---------------------------------------------------------------------------

  /// Inserts a media item.
  Future<void> insertMedia(MediaItemRecord media) async {
    await _send<dynamic>('insertMedia', _mediaToMap(media));
  }

  /// Updates a media item.
  Future<void> updateMedia(MediaItemRecord media) async {
    await _send<dynamic>('updateMedia', _mediaToMap(media));
  }

  /// Deletes a media item by ID.
  Future<void> deleteMedia(String id) async {
    await _send<dynamic>('deleteMedia', id);
  }

  /// Deletes a media item by canonical source URI.
  Future<void> deleteMediaByCanonicalSource(String canonicalSource) async {
    await _send<dynamic>('deleteMediaByCanonicalSource', canonicalSource);
  }

  /// Gets a media item by ID.
  Future<MediaItemRecord?> getMediaById(String id) async {
    final res = await _send<dynamic>('getMediaById', id);
    if (res == null) return null;
    return _mediaFromMap((res as Map).cast<String, Object?>());
  }

  /// Gets a media item by canonical source URI.
  Future<MediaItemRecord?> getMediaByCanonicalSource(
    String canonicalSource,
  ) async {
    final res = await _send<dynamic>(
      'getMediaByCanonicalSource',
      canonicalSource,
    );
    if (res == null) return null;
    return _mediaFromMap((res as Map).cast<String, Object?>());
  }

  /// Gets a media item by file path.
  Future<MediaItemRecord?> getMediaByPath(String path) async {
    final res = await _send<dynamic>('getMediaByPath', path);
    if (res == null) return null;
    return _mediaFromMap((res as Map).cast<String, Object?>());
  }

  // ---------------------------------------------------------------------------
  // FAVORITES & PLAY HISTORY
  // ---------------------------------------------------------------------------

  /// Toggles favorite status for a media item.
  Future<void> setFavorite(String mediaId, bool isFavorite) async {
    await _send<dynamic>('setFavorite', <String, Object?>{
      'mediaId': mediaId,
      'isFavorite': isFavorite,
    });
  }

  /// Records playback history for a media item by ID.
  Future<void> recordPlayHistory(String mediaId, {DateTime? playedAt}) async {
    await _send<dynamic>('recordPlayHistory', <String, Object?>{
      'mediaId': mediaId,
      'playedAt': (playedAt ?? DateTime.now()).millisecondsSinceEpoch,
    });
  }

  /// Records playback history for a media item by canonical source URI.
  Future<void> recordPlayHistoryByCanonicalSource(
    String canonicalSource, {
    DateTime? playedAt,
  }) async {
    await _send<dynamic>(
      'recordPlayHistoryByCanonicalSource',
      <String, Object?>{
        'canonicalSource': canonicalSource,
        'playedAt': (playedAt ?? DateTime.now()).millisecondsSinceEpoch,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // BATCH OPERATIONS
  // ---------------------------------------------------------------------------

  /// Batch upsert discovered file paths.
  ///
  /// Existing items retain enriched metadata while updating availability,
  /// path, file size, and modified time.
  Future<void> batchUpsertDiscoveredFiles(List<String> paths) async {
    await _send<dynamic>('batchUpsertDiscoveredFiles', paths);
  }

  /// Batch upsert full MediaItemRecord entries.
  Future<void> batchUpsertMedia(List<MediaItemRecord> mediaList) async {
    await _send<dynamic>(
      'batchUpsertMedia',
      mediaList.map(_mediaToMap).toList(),
    );
  }

  /// Batch updates metadata enrichment for media items.
  Future<void> batchUpdateMetadata(List<MediaEnrichmentData> updates) async {
    await _send<dynamic>(
      'batchUpdateMetadata',
      updates.map((u) => u.toMap()).toList(),
    );
  }

  /// Updates metadata for a single media item.
  Future<void> updateMediaMetadata(
    String canonicalSource, {
    required MediaKind kind,
    required MediaMetadata metadata,
    required int fileSize,
    required DateTime modifiedAt,
  }) async {
    await batchUpdateMetadata(<MediaEnrichmentData>[
      MediaEnrichmentData(
        canonicalSource: canonicalSource,
        kind: kind,
        metadata: metadata,
        fileSize: fileSize,
        modifiedAt: modifiedAt,
      ),
    ]);
  }

  // ---------------------------------------------------------------------------
  // QUERY MEDIA & AGGREGATES
  // ---------------------------------------------------------------------------

  /// Queries media with optional filtering, FTS5 search query, pagination,
  /// and sorting.
  Future<List<MediaItemRecord>> queryMedia({
    MediaKind? kind,
    String? artist,
    String? album,
    bool? isFavorite,
    bool? isAvailable,
    String? searchQuery,
    int? limit,
    int? offset,
    String? sortBy,
    bool ascending = true,
  }) async {
    final payload = <String, Object?>{'ascending': ascending};
    if (kind != null) payload['kind'] = kind.name;
    if (artist != null) payload['artist'] = artist;
    if (album != null) payload['album'] = album;
    if (isFavorite != null) payload['isFavorite'] = isFavorite;
    if (isAvailable != null) payload['isAvailable'] = isAvailable;
    if (searchQuery != null) payload['searchQuery'] = searchQuery;
    if (limit != null) payload['limit'] = limit;
    if (offset != null) payload['offset'] = offset;
    if (sortBy != null) payload['sortBy'] = sortBy;

    final res = await _send<dynamic>('queryMedia', payload);

    return (res as List)
        .map((e) => _mediaFromMap((e as Map).cast<String, Object?>()))
        .toList();
  }

  /// Retrieves distinct artist names from the media library.
  Future<List<String>> getDistinctArtists({MediaKind? kind}) async {
    final payload = <String, Object?>{};
    if (kind != null) payload['kind'] = kind.name;
    final res = await _send<dynamic>('getDistinctArtists', payload);
    return (res as List).cast<String>();
  }

  /// Retrieves distinct album names from the media library.
  Future<List<String>> getDistinctAlbums({String? artist}) async {
    final payload = <String, Object?>{};
    if (artist != null) payload['artist'] = artist;
    final res = await _send<dynamic>('getDistinctAlbums', payload);
    return (res as List).cast<String>();
  }

  // ---------------------------------------------------------------------------
  // PLAYLISTS
  // ---------------------------------------------------------------------------

  /// Creates a playlist with [title].
  Future<PlaylistRecord> createPlaylist(String title, {String? id}) async {
    final payload = <String, Object?>{'title': title};
    if (id != null) payload['id'] = id;
    final res = await _send<dynamic>('createPlaylist', payload);
    return _playlistFromMap((res as Map).cast<String, Object?>());
  }

  /// Gets a playlist by ID.
  Future<PlaylistRecord?> getPlaylist(String id) async {
    final res = await _send<dynamic>('getPlaylist', id);
    if (res == null) return null;
    return _playlistFromMap((res as Map).cast<String, Object?>());
  }

  /// Gets all playlists.
  Future<List<PlaylistRecord>> getAllPlaylists() async {
    final res = await _send<dynamic>('getAllPlaylists');
    return (res as List)
        .map((e) => _playlistFromMap((e as Map).cast<String, Object?>()))
        .toList();
  }

  /// Updates playlist title and metadata.
  Future<void> updatePlaylist(PlaylistRecord playlist) async {
    await _send<dynamic>('updatePlaylist', _playlistToMap(playlist));
  }

  /// Renames a playlist.
  Future<void> renamePlaylist(String id, String newTitle) async {
    await _send<dynamic>('renamePlaylist', <String, Object?>{
      'id': id,
      'title': newTitle,
    });
  }

  /// Deletes a playlist and its entries.
  Future<void> deletePlaylist(String id) async {
    await _send<dynamic>('deletePlaylist', id);
  }

  /// Adds media items to a playlist at the end of the current order.
  Future<void> addEntriesToPlaylist(
    String playlistId,
    List<String> mediaIds,
  ) async {
    await _send<dynamic>('addEntriesToPlaylist', <String, Object?>{
      'playlistId': playlistId,
      'mediaIds': mediaIds,
    });
  }

  /// Removes a single playlist entry by entry ID.
  Future<void> removePlaylistEntry(String entryId) async {
    await _send<dynamic>('removePlaylistEntry', entryId);
  }

  /// Reorders playlist entries so that entry at [oldIndex] moves to [newIndex].
  Future<void> reorderPlaylistEntries(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {
    await _send<dynamic>('reorderPlaylistEntries', <String, Object?>{
      'playlistId': playlistId,
      'oldIndex': oldIndex,
      'newIndex': newIndex,
    });
  }

  /// Gets all entries of a playlist, including joined MediaItemRecord data.
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(
    String playlistId,
  ) async {
    final res = await _send<dynamic>('getPlaylistEntries', playlistId);
    return (res as List)
        .map((e) => _playlistEntryFromMap((e as Map).cast<String, Object?>()))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // DISPOSE & SHUTDOWN
  // ---------------------------------------------------------------------------

  /// Shuts down the database isolate and releases resources.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    try {
      await _send<dynamic>('close');
    } catch (_) {
      // Isolate may have already exited.
    } finally {
      await _responseSubscription?.cancel();
      await _exitSubscription?.cancel();
      _responsePort.close();
      _exitPort.close();
      _isolate.kill(priority: Isolate.immediate);
      _failAllPending(StateError('Database has been closed.'));
    }
  }

  /// Alias for [close].
  Future<void> dispose() => close();
}

// =============================================================================
// ISOLATE ENTRYPOINT & WORKER
// =============================================================================

class _DbInitParams {
  const _DbInitParams({
    required this.initPort,
    this.path,
    this.inMemory = false,
  });

  final SendPort initPort;
  final String? path;
  final bool inMemory;
}

class _DbInitError {
  const _DbInitError(this.message);
  final String message;
}

class _DbRequest {
  const _DbRequest({
    required this.id,
    required this.action,
    required this.params,
    required this.replyPort,
  });

  final int id;
  final String action;
  final Object? params;
  final SendPort replyPort;
}

class _DbResponse {
  const _DbResponse({
    required this.id,
    this.result,
    this.error,
    this.stackTrace,
  });

  final int id;
  final Object? result;
  final String? error;
  final String? stackTrace;

  bool get isSuccess => error == null;
}

void _databaseIsolateEntryPoint(_DbInitParams params) {
  Database? db;
  final commandPort = ReceivePort();

  try {
    final path = params.path;
    final inMemory = params.inMemory || path == null || path == ':memory:';

    if (inMemory) {
      db = sqlite3.openInMemory();
    } else {
      final file = File(path);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      db = sqlite3.open(path);
    }

    // Enable WAL mode & performance pragmas
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('PRAGMA synchronous = NORMAL;');

    _initializeSchema(db);

    // Notify parent isolate that worker is ready
    params.initPort.send(commandPort.sendPort);
  } catch (e, st) {
    params.initPort.send(_DbInitError('$e\n$st'));
    commandPort.close();
    db?.close();
    return;
  }

  final database = db;

  commandPort.listen((dynamic message) {
    if (message is! _DbRequest) return;

    if (message.action == 'close') {
      try {
        database.close();
      } catch (_) {}
      message.replyPort.send(_DbResponse(id: message.id, result: true));
      commandPort.close();
      return;
    }

    try {
      final result = _dispatchAction(database, message.action, message.params);
      message.replyPort.send(_DbResponse(id: message.id, result: result));
    } catch (e, st) {
      message.replyPort.send(
        _DbResponse(
          id: message.id,
          error: e.toString(),
          stackTrace: st.toString(),
        ),
      );
    }
  });
}

void _initializeSchema(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS folders (
      path TEXT PRIMARY KEY,
      added_at INTEGER NOT NULL,
      last_scanned_at INTEGER,
      is_available INTEGER NOT NULL DEFAULT 1,
      file_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS media (
      id TEXT PRIMARY KEY,
      canonical_source TEXT UNIQUE NOT NULL,
      path TEXT NOT NULL,
      kind TEXT NOT NULL,
      title TEXT,
      artist TEXT,
      album_artist TEXT,
      album TEXT,
      genre TEXT,
      year INTEGER,
      track_number INTEGER,
      disc_number INTEGER,
      duration_ms INTEGER,
      artwork_uri TEXT,
      audio_codec TEXT,
      sample_rate INTEGER,
      channels INTEGER,
      bitrate INTEGER,
      bits_per_sample INTEGER,
      file_size INTEGER NOT NULL DEFAULT 0,
      modified_at INTEGER,
      is_available INTEGER NOT NULL DEFAULT 1,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      added_at INTEGER NOT NULL,
      last_played_at INTEGER,
      play_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_media_path ON media(path);
    CREATE INDEX IF NOT EXISTS idx_media_kind ON media(kind);
    CREATE INDEX IF NOT EXISTS idx_media_artist ON media(artist);
    CREATE INDEX IF NOT EXISTS idx_media_album ON media(album);
    CREATE INDEX IF NOT EXISTS idx_media_is_favorite ON media(is_favorite);
    CREATE INDEX IF NOT EXISTS idx_media_is_available ON media(is_available);
    CREATE INDEX IF NOT EXISTS idx_media_added_at ON media(added_at);
    CREATE INDEX IF NOT EXISTS idx_media_title ON media(title COLLATE NOCASE);
    CREATE INDEX IF NOT EXISTS idx_media_last_played ON media(last_played_at);

    CREATE TABLE IF NOT EXISTS playlists (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS playlist_entries (
      id TEXT PRIMARY KEY,
      playlist_id TEXT NOT NULL,
      media_id TEXT NOT NULL,
      position INTEGER NOT NULL,
      added_at INTEGER NOT NULL,
      FOREIGN KEY (playlist_id) REFERENCES playlists (id) ON DELETE CASCADE,
      FOREIGN KEY (media_id) REFERENCES media (id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_playlist_entries_playlist ON playlist_entries (playlist_id, position);

    CREATE VIRTUAL TABLE IF NOT EXISTS media_fts USING fts5(
      title,
      artist,
      album,
      filename,
      content=media,
      content_rowid=rowid
    );

    CREATE TRIGGER IF NOT EXISTS media_ai AFTER INSERT ON media BEGIN
      INSERT INTO media_fts(rowid, title, artist, album, filename)
      VALUES (new.rowid, new.title, new.artist, new.album, new.path);
    END;

    CREATE TRIGGER IF NOT EXISTS media_ad AFTER DELETE ON media BEGIN
      INSERT INTO media_fts(media_fts, rowid, title, artist, album, filename)
      VALUES('delete', old.rowid, old.title, old.artist, old.album, old.path);
    END;

    CREATE TRIGGER IF NOT EXISTS media_au AFTER UPDATE ON media BEGIN
      INSERT INTO media_fts(media_fts, rowid, title, artist, album, filename)
      VALUES('delete', old.rowid, old.title, old.artist, old.album, old.path);
      INSERT INTO media_fts(rowid, title, artist, album, filename)
      VALUES (new.rowid, new.title, new.artist, new.album, new.path);
    END;
  ''');
}

Object? _dispatchAction(Database db, String action, Object? params) {
  switch (action) {
    case 'getJournalMode':
      final row = db.select('PRAGMA journal_mode;');
      return row.first.values.first as String;

    case 'executeRaw':
      final map = (params as Map).cast<String, Object?>();
      final sql = map['sql'] as String;
      final pList = (map['params'] as List?) ?? const [];
      db.execute(sql, pList);
      return null;

    case 'selectRaw':
      final map = (params as Map).cast<String, Object?>();
      final sql = map['sql'] as String;
      final pList = (map['params'] as List?) ?? const [];
      final result = db.select(sql, pList);
      return result.map((r) => Map<String, Object?>.from(r)).toList();

    // ---------------- Folders ----------------
    case 'insertFolder':
      final f = (params as Map).cast<String, Object?>();
      db.execute(
        '''
        INSERT INTO folders (path, added_at, last_scanned_at, is_available, file_count)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          last_scanned_at = excluded.last_scanned_at,
          is_available = excluded.is_available,
          file_count = excluded.file_count
        ''',
        [
          f['path'],
          f['added_at'],
          f['last_scanned_at'],
          (f['is_available'] as bool? ?? true) ? 1 : 0,
          f['file_count'] ?? 0,
        ],
      );
      return null;

    case 'updateFolder':
      final f = (params as Map).cast<String, Object?>();
      db.execute(
        '''
        UPDATE folders SET
          added_at = ?,
          last_scanned_at = ?,
          is_available = ?,
          file_count = ?
        WHERE path = ?
        ''',
        [
          f['added_at'],
          f['last_scanned_at'],
          (f['is_available'] as bool? ?? true) ? 1 : 0,
          f['file_count'] ?? 0,
          f['path'],
        ],
      );
      return null;

    case 'deleteFolder':
      final path = params as String;
      db.execute('DELETE FROM folders WHERE path = ?', [path]);
      return null;

    case 'getFolder':
      final path = params as String;
      final rows = db.select('SELECT * FROM folders WHERE path = ?', [path]);
      if (rows.isEmpty) return null;
      return Map<String, Object?>.from(rows.first);

    case 'getAllFolders':
      final rows = db.select('SELECT * FROM folders ORDER BY path ASC');
      return rows.map((r) => Map<String, Object?>.from(r)).toList();

    case 'markFolderAvailability':
      final map = (params as Map).cast<String, Object?>();
      final folderPath = map['folderPath'] as String;
      final isAvailable = map['isAvailable'] as bool;
      final availInt = isAvailable ? 1 : 0;

      final normSlash = folderPath.replaceAll(r'\', '/');
      final normBackslash = folderPath.replaceAll('/', r'\');

      db.execute('UPDATE folders SET is_available = ? WHERE path = ?', [
        availInt,
        folderPath,
      ]);

      db.execute(
        '''
        UPDATE media SET is_available = ?
        WHERE path = ? OR path = ?
           OR path LIKE ? OR path LIKE ?
           OR path LIKE ? OR path LIKE ?
        ''',
        [
          availInt,
          folderPath,
          normSlash,
          '$folderPath/%',
          '$folderPath\\%',
          '$normSlash/%',
          '$normBackslash\\%',
        ],
      );
      return null;

    case 'updateFolderScanStats':
      final map = (params as Map).cast<String, Object?>();
      final path = map['path'] as String;
      final fileCount = map['fileCount'] as int?;
      final lastScannedAt = map['lastScannedAt'] as int?;

      db.execute(
        '''
        UPDATE folders SET
          file_count = COALESCE(?, file_count),
          last_scanned_at = COALESCE(?, last_scanned_at)
        WHERE path = ?
        ''',
        [fileCount, lastScannedAt, path],
      );
      return null;

    // ---------------- Media CRUD ----------------
    case 'insertMedia':
      final m = (params as Map).cast<String, Object?>();
      _insertOrUpdateMediaRow(db, m);
      return null;

    case 'updateMedia':
      final m = (params as Map).cast<String, Object?>();
      _insertOrUpdateMediaRow(db, m);
      return null;

    case 'deleteMedia':
      final id = params as String;
      db.execute('DELETE FROM media WHERE id = ?', [id]);
      return null;

    case 'deleteMediaByCanonicalSource':
      final canonicalSource = params as String;
      final canon = MediaEntry.canonicalSource(canonicalSource);
      db.execute(
        'DELETE FROM media WHERE canonical_source = ? OR canonical_source = ?',
        [canonicalSource, canon],
      );
      return null;

    case 'getMediaById':
      final id = params as String;
      final rows = db.select('SELECT * FROM media WHERE id = ?', [id]);
      if (rows.isEmpty) return null;
      return Map<String, Object?>.from(rows.first);

    case 'getMediaByCanonicalSource':
      final canonicalSource = params as String;
      final canon = MediaEntry.canonicalSource(canonicalSource);
      final rows = db.select(
        'SELECT * FROM media WHERE canonical_source = ? OR canonical_source = ?',
        [canonicalSource, canon],
      );
      if (rows.isEmpty) return null;
      return Map<String, Object?>.from(rows.first);

    case 'getMediaByPath':
      final path = params as String;
      final norm = MediaEntry.normalizeSourcePath(path);
      final rows = db.select('SELECT * FROM media WHERE path = ? OR path = ?', [
        path,
        norm,
      ]);
      if (rows.isEmpty) return null;
      return Map<String, Object?>.from(rows.first);

    case 'setFavorite':
      final map = (params as Map).cast<String, Object?>();
      final mediaId = map['mediaId'] as String;
      final isFav = (map['isFavorite'] as bool) ? 1 : 0;
      db.execute('UPDATE media SET is_favorite = ? WHERE id = ?', [
        isFav,
        mediaId,
      ]);
      return null;

    case 'recordPlayHistory':
      final map = (params as Map).cast<String, Object?>();
      final mediaId = map['mediaId'] as String;
      final playedAt = map['playedAt'] as int;
      db.execute(
        '''
        UPDATE media SET
          last_played_at = ?,
          play_count = play_count + 1
        WHERE id = ?
        ''',
        [playedAt, mediaId],
      );
      return null;

    case 'recordPlayHistoryByCanonicalSource':
      final map = (params as Map).cast<String, Object?>();
      final canonicalSource = map['canonicalSource'] as String;
      final canon = MediaEntry.canonicalSource(canonicalSource);
      final playedAt = map['playedAt'] as int;
      db.execute(
        '''
        UPDATE media SET
          last_played_at = ?,
          play_count = play_count + 1
        WHERE canonical_source = ? OR canonical_source = ?
        ''',
        [playedAt, canonicalSource, canon],
      );
      return null;

    // ---------------- Batch Operations ----------------
    case 'batchUpsertDiscoveredFiles':
      final paths = (params as List).cast<String>();
      _batchUpsertPaths(db, paths);
      return null;

    case 'batchUpsertMedia':
      final list = (params as List).cast<Map<dynamic, dynamic>>();
      db.execute('BEGIN TRANSACTION;');
      try {
        final stmt = db.prepare('''
          INSERT INTO media (
            id, canonical_source, path, kind, title, artist, album_artist, album,
            genre, year, track_number, disc_number, duration_ms, artwork_uri,
            audio_codec, sample_rate, channels, bitrate, bits_per_sample,
            file_size, modified_at, is_available, is_favorite, added_at,
            last_played_at, play_count
          ) VALUES (
            ?, ?, ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?
          )
          ON CONFLICT(canonical_source) DO UPDATE SET
            path = excluded.path,
            kind = excluded.kind,
            title = excluded.title,
            artist = excluded.artist,
            album_artist = excluded.album_artist,
            album = excluded.album,
            genre = excluded.genre,
            year = excluded.year,
            track_number = excluded.track_number,
            disc_number = excluded.disc_number,
            duration_ms = excluded.duration_ms,
            artwork_uri = excluded.artwork_uri,
            audio_codec = excluded.audio_codec,
            sample_rate = excluded.sample_rate,
            channels = excluded.channels,
            bitrate = excluded.bitrate,
            bits_per_sample = excluded.bits_per_sample,
            file_size = excluded.file_size,
            modified_at = excluded.modified_at,
            is_available = excluded.is_available,
            is_favorite = excluded.is_favorite,
            last_played_at = excluded.last_played_at,
            play_count = excluded.play_count
        ''');
        try {
          for (final item in list) {
            _executeInsertMediaRowStmt(stmt, item.cast<String, Object?>());
          }
        } finally {
          stmt.close();
        }
        db.execute('COMMIT;');
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
      return null;

    case 'batchUpdateMetadata':
      final updates = (params as List).cast<Map<dynamic, dynamic>>();
      _batchUpdateMetadata(db, updates);
      return null;

    // ---------------- Query Media ----------------
    case 'queryMedia':
      final map = (params as Map).cast<String, Object?>();
      return _queryMediaRows(db, map);

    case 'getDistinctArtists':
      final map = (params as Map).cast<String, Object?>();
      final kind = map['kind'] as String?;
      final sql = StringBuffer('''
        SELECT DISTINCT artist FROM media
        WHERE artist IS NOT NULL AND TRIM(artist) != ''
        ''');
      final args = <Object?>[];
      if (kind != null) {
        sql.write(' AND kind = ?');
        args.add(kind);
      }
      sql.write(' ORDER BY LOWER(artist) COLLATE NOCASE ASC');
      final rows = db.select(sql.toString(), args);
      return rows.map((r) => r['artist'] as String).toList();

    case 'getDistinctAlbums':
      final map = (params as Map).cast<String, Object?>();
      final artist = map['artist'] as String?;
      final sql = StringBuffer('''
        SELECT DISTINCT album FROM media
        WHERE album IS NOT NULL AND TRIM(album) != ''
        ''');
      final args = <Object?>[];
      if (artist != null) {
        sql.write(' AND artist = ?');
        args.add(artist);
      }
      sql.write(' ORDER BY LOWER(album) COLLATE NOCASE ASC');
      final rows = db.select(sql.toString(), args);
      return rows.map((r) => r['album'] as String).toList();

    // ---------------- Playlists ----------------
    case 'createPlaylist':
      final map = (params as Map).cast<String, Object?>();
      final title = map['title'] as String;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = (map['id'] as String?) ?? _generateId(title);

      db.execute(
        '''
        INSERT INTO playlists (id, title, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        ''',
        [id, title, now, now],
      );
      return <String, Object?>{
        'id': id,
        'title': title,
        'created_at': now,
        'updated_at': now,
        'entry_count': 0,
      };

    case 'getPlaylist':
      final id = params as String;
      final rows = db.select(
        '''
        SELECT p.*, (SELECT COUNT(*) FROM playlist_entries WHERE playlist_id = p.id) AS entry_count
        FROM playlists p
        WHERE p.id = ?
        ''',
        [id],
      );
      if (rows.isEmpty) return null;
      return Map<String, Object?>.from(rows.first);

    case 'getAllPlaylists':
      final rows = db.select('''
        SELECT p.*, (SELECT COUNT(*) FROM playlist_entries WHERE playlist_id = p.id) AS entry_count
        FROM playlists p
        ORDER BY LOWER(p.title) COLLATE NOCASE ASC
        ''');
      return rows.map((r) => Map<String, Object?>.from(r)).toList();

    case 'updatePlaylist':
      final pMap = (params as Map).cast<String, Object?>();
      db.execute(
        '''
        UPDATE playlists SET
          title = ?,
          updated_at = ?
        WHERE id = ?
        ''',
        [pMap['title'], pMap['updated_at'], pMap['id']],
      );
      return null;

    case 'renamePlaylist':
      final map = (params as Map).cast<String, Object?>();
      final id = map['id'] as String;
      final title = map['title'] as String;
      final now = DateTime.now().millisecondsSinceEpoch;
      db.execute(
        '''
        UPDATE playlists SET title = ?, updated_at = ? WHERE id = ?
        ''',
        [title, now, id],
      );
      return null;

    case 'deletePlaylist':
      final id = params as String;
      db.execute('DELETE FROM playlists WHERE id = ?', [id]);
      return null;

    case 'addEntriesToPlaylist':
      final map = (params as Map).cast<String, Object?>();
      final playlistId = map['playlistId'] as String;
      final mediaIds = (map['mediaIds'] as List).cast<String>();

      db.execute('BEGIN TRANSACTION;');
      try {
        final posRow = db.select(
          'SELECT COALESCE(MAX(position), -1) AS max_pos FROM playlist_entries WHERE playlist_id = ?',
          [playlistId],
        );
        int nextPos = ((posRow.first['max_pos'] as int?) ?? -1) + 1;
        final now = DateTime.now().millisecondsSinceEpoch;

        final stmt = db.prepare('''
          INSERT INTO playlist_entries (id, playlist_id, media_id, position, added_at)
          VALUES (?, ?, ?, ?, ?)
        ''');

        for (final mediaId in mediaIds) {
          final entryId = _generateId('$playlistId-$mediaId-$nextPos');
          stmt.execute([entryId, playlistId, mediaId, nextPos++, now]);
        }
        stmt.close();

        db.execute('UPDATE playlists SET updated_at = ? WHERE id = ?', [
          now,
          playlistId,
        ]);
        db.execute('COMMIT;');
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
      return null;

    case 'removePlaylistEntry':
      final entryId = params as String;
      db.execute('BEGIN TRANSACTION;');
      try {
        final row = db.select(
          'SELECT playlist_id, position FROM playlist_entries WHERE id = ?',
          [entryId],
        );
        if (row.isNotEmpty) {
          final playlistId = row.first['playlist_id'] as String;
          final position = row.first['position'] as int;

          db.execute('DELETE FROM playlist_entries WHERE id = ?', [entryId]);
          db.execute(
            '''
            UPDATE playlist_entries
            SET position = position - 1
            WHERE playlist_id = ? AND position > ?
            ''',
            [playlistId, position],
          );
          db.execute('UPDATE playlists SET updated_at = ? WHERE id = ?', [
            DateTime.now().millisecondsSinceEpoch,
            playlistId,
          ]);
        }
        db.execute('COMMIT;');
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
      return null;

    case 'reorderPlaylistEntries':
      final map = (params as Map).cast<String, Object?>();
      final playlistId = map['playlistId'] as String;
      final oldIndex = map['oldIndex'] as int;
      final newIndex = map['newIndex'] as int;

      if (oldIndex == newIndex) return null;

      db.execute('BEGIN TRANSACTION;');
      try {
        final entries = db.select(
          'SELECT id FROM playlist_entries WHERE playlist_id = ? ORDER BY position ASC',
          [playlistId],
        );

        if (oldIndex >= 0 &&
            oldIndex < entries.length &&
            newIndex >= 0 &&
            newIndex < entries.length) {
          final idList = entries.map((r) => r['id'] as String).toList();
          final movedId = idList.removeAt(oldIndex);
          idList.insert(newIndex, movedId);

          final stmt = db.prepare(
            'UPDATE playlist_entries SET position = ? WHERE id = ?',
          );
          for (var i = 0; i < idList.length; i++) {
            stmt.execute([i, idList[i]]);
          }
          stmt.close();

          db.execute('UPDATE playlists SET updated_at = ? WHERE id = ?', [
            DateTime.now().millisecondsSinceEpoch,
            playlistId,
          ]);
        }
        db.execute('COMMIT;');
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
      return null;

    case 'getPlaylistEntries':
      final playlistId = params as String;
      final rows = db.select(
        '''
        SELECT
          pe.id AS entry_id,
          pe.playlist_id,
          pe.media_id,
          pe.position,
          pe.added_at AS entry_added_at,
          m.id AS media_row_id,
          m.canonical_source,
          m.path,
          m.kind,
          m.title,
          m.artist,
          m.album_artist,
          m.album,
          m.genre,
          m.year,
          m.track_number,
          m.disc_number,
          m.duration_ms,
          m.artwork_uri,
          m.audio_codec,
          m.sample_rate,
          m.channels,
          m.bitrate,
          m.bits_per_sample,
          m.file_size,
          m.modified_at,
          m.is_available,
          m.is_favorite,
          m.added_at AS media_added_at,
          m.last_played_at,
          m.play_count
        FROM playlist_entries pe
        LEFT JOIN media m ON pe.media_id = m.id
        WHERE pe.playlist_id = ?
        ORDER BY pe.position ASC
        ''',
        [playlistId],
      );

      final resultList = <Map<String, Object?>>[];
      for (final r in rows) {
        final rowMap = Map<String, Object?>.from(r);
        final entryMap = <String, Object?>{
          'id': rowMap['entry_id'],
          'playlist_id': rowMap['playlist_id'],
          'media_id': rowMap['media_id'],
          'position': rowMap['position'],
          'added_at': rowMap['entry_added_at'],
        };

        if (rowMap['media_row_id'] != null) {
          entryMap['mediaItem'] = <String, Object?>{
            'id': rowMap['media_row_id'],
            'canonical_source': rowMap['canonical_source'],
            'path': rowMap['path'],
            'kind': rowMap['kind'],
            'title': rowMap['title'],
            'artist': rowMap['artist'],
            'album_artist': rowMap['album_artist'],
            'album': rowMap['album'],
            'genre': rowMap['genre'],
            'year': rowMap['year'],
            'track_number': rowMap['track_number'],
            'disc_number': rowMap['disc_number'],
            'duration_ms': rowMap['duration_ms'],
            'artwork_uri': rowMap['artwork_uri'],
            'audio_codec': rowMap['audio_codec'],
            'sample_rate': rowMap['sample_rate'],
            'channels': rowMap['channels'],
            'bitrate': rowMap['bitrate'],
            'bits_per_sample': rowMap['bits_per_sample'],
            'file_size': rowMap['file_size'],
            'modified_at': rowMap['modified_at'],
            'is_available': rowMap['is_available'],
            'is_favorite': rowMap['is_favorite'],
            'added_at': rowMap['media_added_at'],
            'last_played_at': rowMap['last_played_at'],
            'play_count': rowMap['play_count'],
          };
        }
        resultList.add(entryMap);
      }
      return resultList;

    default:
      throw UnsupportedError('Unknown database isolate action: $action');
  }
}

void _executeInsertMediaRowStmt(
  PreparedStatement stmt,
  Map<String, Object?> m,
) {
  stmt.execute([
    m['id'],
    m['canonical_source'],
    m['path'],
    m['kind'] ?? 'unknown',
    m['title'],
    m['artist'],
    m['album_artist'],
    m['album'],
    m['genre'],
    m['year'],
    m['track_number'],
    m['disc_number'],
    m['duration_ms'],
    m['artwork_uri'],
    m['audio_codec'],
    m['sample_rate'],
    m['channels'],
    m['bitrate'],
    m['bits_per_sample'],
    m['file_size'] ?? 0,
    m['modified_at'],
    (m['is_available'] as bool? ?? true) ? 1 : 0,
    (m['is_favorite'] as bool? ?? false) ? 1 : 0,
    m['added_at'] ?? DateTime.now().millisecondsSinceEpoch,
    m['last_played_at'],
    m['play_count'] ?? 0,
  ]);
}

void _insertOrUpdateMediaRow(Database db, Map<String, Object?> m) {
  db.execute(
    '''
    INSERT INTO media (
      id, canonical_source, path, kind, title, artist, album_artist, album,
      genre, year, track_number, disc_number, duration_ms, artwork_uri,
      audio_codec, sample_rate, channels, bitrate, bits_per_sample,
      file_size, modified_at, is_available, is_favorite, added_at,
      last_played_at, play_count
    ) VALUES (
      ?, ?, ?, ?, ?, ?, ?, ?,
      ?, ?, ?, ?, ?, ?,
      ?, ?, ?, ?, ?,
      ?, ?, ?, ?, ?,
      ?, ?
    )
    ON CONFLICT(canonical_source) DO UPDATE SET
      path = excluded.path,
      kind = excluded.kind,
      title = excluded.title,
      artist = excluded.artist,
      album_artist = excluded.album_artist,
      album = excluded.album,
      genre = excluded.genre,
      year = excluded.year,
      track_number = excluded.track_number,
      disc_number = excluded.disc_number,
      duration_ms = excluded.duration_ms,
      artwork_uri = excluded.artwork_uri,
      audio_codec = excluded.audio_codec,
      sample_rate = excluded.sample_rate,
      channels = excluded.channels,
      bitrate = excluded.bitrate,
      bits_per_sample = excluded.bits_per_sample,
      file_size = excluded.file_size,
      modified_at = excluded.modified_at,
      is_available = excluded.is_available,
      is_favorite = excluded.is_favorite,
      last_played_at = excluded.last_played_at,
      play_count = excluded.play_count
    ''',
    [
      m['id'],
      m['canonical_source'],
      m['path'],
      m['kind'] ?? 'unknown',
      m['title'],
      m['artist'],
      m['album_artist'],
      m['album'],
      m['genre'],
      m['year'],
      m['track_number'],
      m['disc_number'],
      m['duration_ms'],
      m['artwork_uri'],
      m['audio_codec'],
      m['sample_rate'],
      m['channels'],
      m['bitrate'],
      m['bits_per_sample'],
      m['file_size'] ?? 0,
      m['modified_at'],
      (m['is_available'] as bool? ?? true) ? 1 : 0,
      (m['is_favorite'] as bool? ?? false) ? 1 : 0,
      m['added_at'] ?? DateTime.now().millisecondsSinceEpoch,
      m['last_played_at'],
      m['play_count'] ?? 0,
    ],
  );
}

void _batchUpsertPaths(Database db, List<String> paths) {
  if (paths.isEmpty) return;

  db.execute('BEGIN TRANSACTION;');
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stmt = db.prepare('''
      INSERT INTO media (
        id, canonical_source, path, kind, title,
        file_size, modified_at, is_available, is_favorite, added_at, play_count
      ) VALUES (
        ?, ?, ?, ?, ?,
        0, NULL, 1, 0, ?, 0
      )
      ON CONFLICT(canonical_source) DO UPDATE SET
        path = excluded.path,
        is_available = 1
    ''');
    try {
      for (final rawPath in paths) {
        final normalized = MediaEntry.normalizeSourcePath(rawPath);
        final canonical = MediaEntry.canonicalSource(rawPath);
        final id = _generateId(canonical);
        final kind = _detectKindFromExtension(normalized).name;
        final fileName = MediaEntry.titleFromPath(normalized);

        stmt.execute([id, canonical, normalized, kind, fileName, now]);
      }
    } finally {
      stmt.close();
    }
    db.execute('COMMIT;');
  } catch (_) {
    db.execute('ROLLBACK;');
    rethrow;
  }
}

void _batchUpdateMetadata(Database db, List<Map<dynamic, dynamic>> updates) {
  if (updates.isEmpty) return;

  db.execute('BEGIN TRANSACTION;');
  try {
    final stmt = db.prepare('''
      UPDATE media SET
        kind = ?,
        title = ?,
        artist = ?,
        album_artist = ?,
        album = ?,
        genre = ?,
        year = ?,
        track_number = ?,
        disc_number = ?,
        duration_ms = ?,
        artwork_uri = ?,
        audio_codec = ?,
        sample_rate = ?,
        channels = ?,
        bitrate = ?,
        bits_per_sample = ?,
        file_size = ?,
        modified_at = ?
      WHERE canonical_source = ? OR canonical_source = ?
    ''');
    try {
      for (final rawItem in updates) {
        final u = rawItem.cast<String, Object?>();
        final rawSource = u['canonicalSource'] as String;
        final canon = MediaEntry.canonicalSource(rawSource);
        stmt.execute([
          u['kind'],
          u['title'],
          u['artist'],
          u['albumArtist'],
          u['album'],
          u['genre'],
          u['year'],
          u['trackNumber'],
          u['discNumber'],
          u['durationMs'],
          u['artworkUri'],
          u['audioCodec'],
          u['sampleRate'],
          u['channels'],
          u['bitrate'],
          u['bitsPerSample'],
          u['fileSize'],
          u['modifiedAt'],
          rawSource,
          canon,
        ]);
      }
    } finally {
      stmt.close();
    }
    db.execute('COMMIT;');
  } catch (_) {
    db.execute('ROLLBACK;');
    rethrow;
  }
}

List<Map<String, Object?>> _queryMediaRows(
  Database db,
  Map<String, Object?> map,
) {
  final kind = map['kind'] as String?;
  final artist = map['artist'] as String?;
  final album = map['album'] as String?;
  final isFavorite = map['isFavorite'] as bool?;
  final isAvailable = map['isAvailable'] as bool?;
  final rawSearchQuery = map['searchQuery'] as String?;
  final limit = map['limit'] as int?;
  final offset = map['offset'] as int?;
  final sortBy = map['sortBy'] as String?;
  final ascending = map['ascending'] as bool? ?? true;

  final ftsMatch = rawSearchQuery != null
      ? _buildFts5MatchExpression(rawSearchQuery)
      : null;
  final useFts = ftsMatch != null && ftsMatch.isNotEmpty;

  final sql = StringBuffer();
  final args = <Object?>[];

  if (useFts) {
    sql.write('''
      SELECT media.*
      FROM media
      JOIN media_fts ON media.rowid = media_fts.rowid
      WHERE media_fts MATCH ?
    ''');
    args.add(ftsMatch);
  } else {
    sql.write('''
      SELECT media.*
      FROM media
      WHERE 1=1
    ''');
  }

  if (kind != null) {
    sql.write(' AND media.kind = ?');
    args.add(kind);
  }
  if (artist != null) {
    sql.write(' AND media.artist = ?');
    args.add(artist);
  }
  if (album != null) {
    sql.write(' AND media.album = ?');
    args.add(album);
  }
  if (isFavorite != null) {
    sql.write(' AND media.is_favorite = ?');
    args.add(isFavorite ? 1 : 0);
  }
  if (isAvailable != null) {
    sql.write(' AND media.is_available = ?');
    args.add(isAvailable ? 1 : 0);
  }

  final dir = ascending ? 'ASC' : 'DESC';
  switch (sortBy) {
    case 'title':
      sql.write(' ORDER BY LOWER(media.title) COLLATE NOCASE $dir');
      break;
    case 'artist':
      sql.write(
        ' ORDER BY LOWER(media.artist) COLLATE NOCASE $dir, media.track_number ASC',
      );
      break;
    case 'album':
      sql.write(
        ' ORDER BY LOWER(media.album) COLLATE NOCASE $dir, media.disc_number ASC, media.track_number ASC',
      );
      break;
    case 'duration':
    case 'duration_ms':
      sql.write(' ORDER BY media.duration_ms $dir');
      break;
    case 'added_at':
      sql.write(' ORDER BY media.added_at $dir');
      break;
    case 'last_played_at':
      sql.write(' ORDER BY media.last_played_at $dir');
      break;
    case 'play_count':
      sql.write(' ORDER BY media.play_count $dir');
      break;
    case 'rank':
      if (useFts) {
        sql.write(' ORDER BY media_fts.rank $dir');
      } else {
        sql.write(' ORDER BY media.added_at $dir');
      }
      break;
    default:
      if (useFts) {
        sql.write(' ORDER BY media_fts.rank ASC');
      } else {
        sql.write(' ORDER BY media.added_at DESC');
      }
  }

  if (limit != null) {
    sql.write(' LIMIT ?');
    args.add(limit);
    if (offset != null) {
      sql.write(' OFFSET ?');
      args.add(offset);
    }
  }

  final rows = db.select(sql.toString(), args);
  return rows.map((r) => Map<String, Object?>.from(r)).toList();
}

String? _buildFts5MatchExpression(String query) {
  final clean = query.replaceAll(RegExp(r'["*():^{}+_~^#@!\[\]]'), ' ').trim();
  if (clean.isEmpty) return null;

  final words = clean
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => '"${w.replaceAll('"', '""')}*"')
      .toList();

  if (words.isEmpty) return null;
  return words.join(' ');
}

MediaKind _detectKindFromExtension(String path) {
  final ext = p.extension(path).toLowerCase();
  switch (ext) {
    case '.mp3':
    case '.flac':
    case '.m4a':
    case '.aac':
    case '.wav':
    case '.ogg':
    case '.opus':
    case '.wma':
    case '.aiff':
    case '.alac':
      return MediaKind.audio;
    case '.mp4':
    case '.mkv':
    case '.avi':
    case '.mov':
    case '.webm':
    case '.wmv':
    case '.flv':
    case '.m4v':
    case '.ts':
      return MediaKind.video;
    default:
      return MediaKind.unknown;
  }
}

int _idSeedCounter = 0;
String _generateId(String seed) {
  final count = _idSeedCounter++;
  final time = DateTime.now().microsecondsSinceEpoch;
  return crypto.sha256
      .convert(utf8.encode('$seed-$time-$count'))
      .toString()
      .substring(0, 32);
}

// =============================================================================
// RECORD SERIALIZATION HELPERS
// =============================================================================

Map<String, Object?> _folderToMap(LibraryFolderRecord folder) {
  return <String, Object?>{
    'path': folder.path,
    'added_at': folder.addedAt.millisecondsSinceEpoch,
    'last_scanned_at': folder.lastScannedAt?.millisecondsSinceEpoch,
    'is_available': folder.isAvailable,
    'file_count': folder.fileCount,
  };
}

LibraryFolderRecord _folderFromMap(Map<String, Object?> map) {
  return LibraryFolderRecord(
    path: map['path'] as String,
    addedAt: DateTime.fromMillisecondsSinceEpoch(map['added_at'] as int),
    lastScannedAt: map['last_scanned_at'] != null
        ? DateTime.fromMillisecondsSinceEpoch(map['last_scanned_at'] as int)
        : null,
    isAvailable: (map['is_available'] as int? ?? 1) == 1,
    fileCount: (map['file_count'] as int?) ?? 0,
  );
}

Map<String, Object?> _mediaToMap(MediaItemRecord media) {
  return <String, Object?>{
    'id': media.id,
    'canonical_source': media.canonicalSource,
    'path': media.path,
    'kind': media.kind.name,
    'title': media.metadata.title,
    'artist': media.metadata.artist,
    'album_artist': media.metadata.albumArtist,
    'album': media.metadata.album,
    'genre': media.metadata.genre,
    'year': media.metadata.year,
    'track_number': media.metadata.trackNumber,
    'disc_number': media.metadata.discNumber,
    'duration_ms': media.metadata.duration.inMilliseconds,
    'artwork_uri': media.metadata.artworkUri,
    'audio_codec': media.metadata.audioInfo?.codec,
    'sample_rate': media.metadata.audioInfo?.sampleRate,
    'channels': media.metadata.audioInfo?.channels,
    'bitrate': media.metadata.audioInfo?.bitrate,
    'bits_per_sample': media.metadata.audioInfo?.bitsPerSample,
    'file_size': media.fileSize,
    'modified_at': media.modifiedAt?.millisecondsSinceEpoch,
    'is_available': media.isAvailable,
    'is_favorite': media.isFavorite,
    'added_at': media.addedAt.millisecondsSinceEpoch,
    'last_played_at': media.lastPlayedAt?.millisecondsSinceEpoch,
    'play_count': media.playCount,
  };
}

MediaItemRecord _mediaFromMap(Map<String, Object?> map) {
  final audioCodec = map['audio_codec'] as String?;
  final sampleRate = map['sample_rate'] as int?;
  final channels = map['channels'] as int?;
  final bitrate = map['bitrate'] as int?;
  final bitsPerSample = map['bits_per_sample'] as int?;
  final hasAudio =
      audioCodec != null ||
      sampleRate != null ||
      channels != null ||
      bitrate != null ||
      bitsPerSample != null;

  final kindStr = map['kind'] as String?;
  final kind = MediaKind.values.firstWhere(
    (k) => k.name == kindStr,
    orElse: () => MediaKind.unknown,
  );

  return MediaItemRecord(
    id: map['id'] as String,
    canonicalSource: map['canonical_source'] as String,
    path: map['path'] as String,
    kind: kind,
    metadata: MediaMetadata(
      title: map['title'] as String?,
      artist: map['artist'] as String?,
      albumArtist: map['album_artist'] as String?,
      album: map['album'] as String?,
      genre: map['genre'] as String?,
      year: map['year'] as int?,
      trackNumber: map['track_number'] as int?,
      discNumber: map['disc_number'] as int?,
      duration: Duration(milliseconds: (map['duration_ms'] as int?) ?? 0),
      artworkUri: map['artwork_uri'] as String?,
      audioInfo: hasAudio
          ? AudioTechnicalInfo(
              codec: audioCodec,
              sampleRate: sampleRate,
              channels: channels,
              bitrate: bitrate,
              bitsPerSample: bitsPerSample,
            )
          : null,
    ),
    fileSize: (map['file_size'] as int?) ?? 0,
    modifiedAt: map['modified_at'] != null
        ? DateTime.fromMillisecondsSinceEpoch(map['modified_at'] as int)
        : null,
    isAvailable: (map['is_available'] as int? ?? 1) == 1,
    isFavorite: (map['is_favorite'] as int? ?? 0) == 1,
    addedAt: DateTime.fromMillisecondsSinceEpoch(
      (map['added_at'] as int?) ?? 0,
    ),
    lastPlayedAt: map['last_played_at'] != null
        ? DateTime.fromMillisecondsSinceEpoch(map['last_played_at'] as int)
        : null,
    playCount: (map['play_count'] as int?) ?? 0,
  );
}

Map<String, Object?> _playlistToMap(PlaylistRecord playlist) {
  return <String, Object?>{
    'id': playlist.id,
    'title': playlist.title,
    'created_at': playlist.createdAt.millisecondsSinceEpoch,
    'updated_at': playlist.updatedAt.millisecondsSinceEpoch,
    'entry_count': playlist.entryCount,
  };
}

PlaylistRecord _playlistFromMap(Map<String, Object?> map) {
  return PlaylistRecord(
    id: map['id'] as String,
    title: map['title'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    entryCount: (map['entry_count'] as int?) ?? 0,
  );
}

PlaylistEntryRecord _playlistEntryFromMap(Map<String, Object?> map) {
  final mediaItemMap = map['mediaItem'] != null
      ? (map['mediaItem'] as Map).cast<String, Object?>()
      : null;

  return PlaylistEntryRecord(
    id: map['id'] as String,
    playlistId: map['playlist_id'] as String,
    mediaId: map['media_id'] as String,
    position: (map['position'] as int?) ?? 0,
    addedAt: DateTime.fromMillisecondsSinceEpoch(
      (map['added_at'] as int?) ?? 0,
    ),
    mediaItem: mediaItemMap != null ? _mediaFromMap(mediaItemMap) : null,
  );
}
