import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/media_library_repository.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/streaming_coordinator.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/stream_rendition.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/media_accent_scope.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';
import 'package:mpvson/ui/player/player_controller.dart';

/// Playback service double that records the paths opened and exposes the
/// snapshot stream the controller subscribes to.
class FakePlaybackService implements PlaybackService {
  PlaybackSnapshot _state = const PlaybackSnapshot();
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final List<String> openedPaths = <String>[];

  @override
  late final StreamingCoordinator streamingCoordinator = StreamingCoordinator();

  @override
  Future<void> selectQuality(StreamRendition rendition) async {}

  @override
  Player get player => throw UnimplementedError('Native Player not used');

  @override
  VideoController get videoController =>
      throw UnimplementedError('Native VideoController not used');

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  String get engineVersion => 'test-mpv';

  @override
  VideoOutputPolicy get videoOutputPolicy => const VideoOutputPolicy();

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {}

  @override
  Future<void> prepare() async {}

  @override
  Future<void> open(String path, {bool play = true}) async {
    openedPaths.add(path);
    _state = _state.copyWith(
      isPlaying: play,
      isBuffering: false,
      sourceLoaded: true,
      nativeSource: path,
      sourceStart: _state.sourceStart + 1,
    );
    _states.add(_state);
  }

  @override
  Future<void> stop() async {
    _state = _state.copyWith(
      isPlaying: false,
      isBuffering: false,
      sourceLoaded: false,
      clearNativeSource: true,
    );
    _states.add(_state);
  }

  @override
  Future<void> play() async {
    _state = _state.copyWith(isPlaying: true);
    _states.add(_state);
  }

  @override
  Future<void> pause() async {
    _state = _state.copyWith(isPlaying: false);
    _states.add(_state);
  }

  @override
  Future<void> seek(Duration position) async {
    _state = _state.copyWith(position: position);
    _states.add(_state);
  }

  @override
  Future<void> setVolume(double value) async {
    _state = _state.copyWith(volume: value);
    _states.add(_state);
  }

  @override
  Future<void> setRate(double value) async {
    _state = _state.copyWith(rate: value);
    _states.add(_state);
  }

  @override
  Future<void> setShuffle(bool value) async {
    _state = _state.copyWith(shuffle: value);
    _states.add(_state);
  }

  @override
  Future<void> setRepeatMode(String value) async {}

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    _state = _state.copyWith(currentAudioTrack: track);
    _states.add(_state);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    _state = _state.copyWith(currentSubtitleTrack: track);
    _states.add(_state);
  }

  @override
  Future<void> loadSubtitle(String path) async {}

  @override
  Future<void> dispose() async {
    await _states.close();
  }
}

/// In-memory [MediaLibraryRepository] for library view tests.
///
/// Query timing is scriptable so a test can hold a refresh open and assert what
/// the view shows before it lands. A fake that resolved inside the same
/// microtask would hide a broken local update.
class FakeMediaLibraryRepository extends MediaLibraryRepository {
  FakeMediaLibraryRepository({
    List<MediaItemRecord>? items,
    List<PlaylistRecord>? playlists,
    Map<String, List<PlaylistEntryRecord>>? playlistEntries,
    List<String> albums = const <String>[],
    List<String> artists = const <String>[],
  }) : _items = List<MediaItemRecord>.of(items ?? const []),
       _playlists = List<PlaylistRecord>.of(playlists ?? const []),
       _playlistEntries = {
         for (final entry in (playlistEntries ?? const {}).entries)
           entry.key: List<PlaylistEntryRecord>.of(entry.value),
       },
       _albums = List<String>.of(albums),
       _artists = List<String>.of(artists);

  final List<MediaItemRecord> _items;
  final List<PlaylistRecord> _playlists;
  final Map<String, List<PlaylistEntryRecord>> _playlistEntries;
  final List<String> _albums;
  final List<String> _artists;

  final List<(String playlistId, List<String> paths)> addedPathsToPlaylists =
      [];
  final List<String> deletedMediaIds = <String>[];
  final List<(String mediaId, bool isFavorite)> favoriteToggles =
      <(String, bool)>[];

  int _nextPlaylistId = 1;
  int _nextEntryId = 1;

  /// How many times [queryMedia] has been called.
  int queryCallCount = 0;

  /// Offset every [queryMedia] call asked for, in call order.
  final List<int> queryOffsets = <int>[];

  /// 1-based call indices of [queryMedia] that should fail.
  final Set<int> failQueryCalls = <int>{};

  /// Holds the next [queryMedia] call open until the test completes it.
  ///
  /// Consumed on use, so each assignment gates exactly one query.
  Completer<void>? queryGate;

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
  }) async {
    queryCallCount++;
    queryOffsets.add(offset ?? 0);
    final gate = queryGate;
    if (gate != null) {
      queryGate = null;
      await gate.future;
    }
    if (failQueryCalls.contains(queryCallCount)) {
      throw StateError('scripted query failure #$queryCallCount');
    }
    Iterable<MediaItemRecord> result = _items;
    if (kind != null) {
      result = result.where((item) => item.kind == kind);
    }
    if (onlyFavorites == true) {
      result = result.where((item) => item.isFavorite);
    }
    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      final q = searchQuery.trim().toLowerCase();
      result = result.where(
        (item) =>
            item.title.toLowerCase().contains(q) ||
            item.artist.toLowerCase().contains(q),
      );
    }
    if (artist != null) {
      final wanted = artist.toLowerCase();
      result = result.where(
        (item) => item.metadata.effectiveArtist.toLowerCase() == wanted,
      );
    }
    if (album != null) {
      final wanted = album.toLowerCase();
      result = result.where(
        (item) => item.metadata.effectiveAlbum.toLowerCase() == wanted,
      );
    }
    final list = result.toList();
    final start = (offset ?? 0).clamp(0, list.length);
    final end = limit == null
        ? list.length
        : (start + limit).clamp(start, list.length);
    return list.sublist(start, end);
  }

  @override
  Future<MediaItemRecord?> getMediaByCanonicalSource(
    String canonicalSource,
  ) async {
    for (final item in _items) {
      if (item.canonicalSource == canonicalSource) return item;
    }
    return null;
  }

  @override
  Future<MediaItemRecord?> getMediaById(String id) async {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  Future<void> toggleFavorite(String mediaId, bool isFavorite) async {
    favoriteToggles.add((mediaId, isFavorite));
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].id == mediaId) {
        _items[i] = _items[i].copyWith(isFavorite: isFavorite);
      }
    }
    notifyListeners();
  }

  @override
  Future<void> recordPlayback(String canonicalSource) async {}

  @override
  Future<void> deleteMedia(String mediaId) async {
    deletedMediaIds.add(mediaId);
    _items.removeWhere((item) => item.id == mediaId);
    notifyListeners();
  }

  @override
  Future<List<PlaylistRecord>> getPlaylists() async =>
      List<PlaylistRecord>.unmodifiable(_playlists);

  @override
  Future<PlaylistRecord> createPlaylist(String title) async {
    final now = DateTime(2026, 1, 1);
    final record = PlaylistRecord(
      id: 'pl-created-${_nextPlaylistId++}',
      title: title,
      createdAt: now,
      updatedAt: now,
      entryCount: 0,
    );
    _playlists.add(record);
    _playlistEntries[record.id] = [];
    notifyListeners();
    return record;
  }

  @override
  Future<void> deletePlaylist(String playlistId) async {
    _playlists.removeWhere((p) => p.id == playlistId);
    _playlistEntries.remove(playlistId);
    notifyListeners();
  }

  @override
  Future<void> renamePlaylist(String playlistId, String newTitle) async {}

  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {}

  @override
  Future<void> addPathsToPlaylist(String playlistId, List<String> paths) async {
    addedPathsToPlaylists.add((playlistId, List<String>.of(paths)));
    final entries = _playlistEntries.putIfAbsent(playlistId, () => []);
    final now = DateTime(2026, 1, 1);
    for (final path in paths) {
      final canonical = MediaEntry.canonicalSource(path);
      final match = await getMediaByCanonicalSource(canonical);
      entries.add(
        PlaylistEntryRecord(
          id: 'pe-${_nextEntryId++}',
          playlistId: playlistId,
          mediaId: match?.id ?? 'm-${_nextEntryId++}',
          position: entries.length,
          addedAt: now,
          mediaItem: match,
        ),
      );
    }
    for (var i = 0; i < _playlists.length; i++) {
      if (_playlists[i].id == playlistId) {
        _playlists[i] = _playlists[i].copyWith(entryCount: entries.length);
      }
    }
    notifyListeners();
  }

  @override
  Future<void> removeFromPlaylist(
    String playlistId,
    String playlistEntryId,
  ) async {
    _playlistEntries[playlistId]?.removeWhere((e) => e.id == playlistEntryId);
    notifyListeners();
  }

  @override
  Future<void> reorderPlaylist(
    String playlistId,
    int oldIndex,
    int newIndex, {
    String? entryId,
  }) async {}

  @override
  Future<void> clearPlaylist(String playlistId) async {
    _playlistEntries[playlistId]?.clear();
    notifyListeners();
  }

  @override
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(
    String playlistId,
  ) async => List<PlaylistEntryRecord>.unmodifiable(
    _playlistEntries[playlistId] ?? const [],
  );

  @override
  Future<List<String>> getDistinctArtists({MediaKind? kind}) async =>
      List<String>.unmodifiable(_artists);

  @override
  Future<List<String>> getDistinctAlbums({String? artist}) async =>
      List<String>.unmodifiable(_albums);

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

/// Wraps [home] in the theme, preference, accent, and toast scopes the library
/// views expect.
Widget buildLibraryTestApp({
  required PlayerController controller,
  required Widget home,
  bool includeToastHost = true,
}) {
  return MaterialApp(
    theme: AppTheme.lightTheme(),
    darkTheme: AppTheme.darkTheme(),
    themeMode: ThemeMode.dark,
    builder: (context, child) {
      final scoped = AppPreferencesScope(
        preferences: const DesktopPreferences(),
        child: MediaAccentScope(controller: controller, child: child!),
      );
      return includeToastHost ? AppToastHost(child: scoped) : scoped;
    },
    home: Scaffold(body: home),
  );
}

MediaItemRecord makeLibraryRecord({
  required String id,
  required String path,
  required MediaKind kind,
  String? title,
  String? artist,
  String? album,
  bool isAvailable = true,
  Duration duration = const Duration(minutes: 2),
}) {
  return MediaItemRecord(
    id: id,
    canonicalSource: MediaEntry.canonicalSource(path),
    path: path,
    kind: kind,
    isAvailable: isAvailable,
    addedAt: DateTime(2026, 1, 1),
    metadata: MediaMetadata(
      title: title,
      artist: artist ?? (kind == MediaKind.audio ? 'Test Artist' : null),
      album: album ?? (kind == MediaKind.audio ? 'Test Album' : null),
      duration: duration,
    ),
  );
}

/// Pumps until loading indicators are gone and pending IO has settled.
Future<void> pumpAfterIo(WidgetTester tester, {bool settle = true}) async {
  await tester.pump();
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty && i >= 2) {
      break;
    }
  }
  if (settle) {
    await tester.pumpAndSettle();
  }
}

/// Completes [gate] in the real async zone and lets the continuations run.
///
/// A gated repository query only resumes once the test completes it, and its
/// continuation needs a real microtask turn before the view rebuilds.
Future<void> releaseGate(WidgetTester tester, Completer<void> gate) async {
  await tester.runAsync(() async {
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pump();
}

/// Fails [gate] in the real async zone and lets the continuations run.
Future<void> failGate(
  WidgetTester tester,
  Completer<void> gate,
  Object error,
) async {
  await tester.runAsync(() async {
    gate.completeError(error);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pump();
}
