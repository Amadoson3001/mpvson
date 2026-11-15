import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/media_library_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/media_accent_scope.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';
import 'package:mpvson/ui/library/views/home_view.dart';
import 'package:mpvson/ui/library/views/music_view.dart';
import 'package:mpvson/ui/library/views/playlists_view.dart';
import 'package:mpvson/ui/library/views/videos_view.dart';
import 'package:mpvson/ui/library/widgets/library_item_action_menu.dart';
import 'package:mpvson/ui/library/widgets/media_context_menu.dart';
import 'package:mpvson/ui/library/widgets/library_item_actions.dart';
import 'package:mpvson/ui/library/widgets/media_properties_dialog.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/widgets/empty_library.dart';
import 'package:mpvson/ui/player/widgets/queue_panel.dart';

class _FakePlaybackService implements PlaybackService {
  PlaybackSnapshot _state = const PlaybackSnapshot();
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final List<String> openedPaths = <String>[];

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

class _FakeMediaLibraryRepository extends MediaLibraryRepository {
  _FakeMediaLibraryRepository({
    List<MediaItemRecord>? items,
    List<PlaylistRecord>? playlists,
    Map<String, List<PlaylistEntryRecord>>? playlistEntries,
  }) : _items = List<MediaItemRecord>.of(items ?? const []),
       _playlists = List<PlaylistRecord>.of(playlists ?? const []),
       _playlistEntries = {
         for (final entry in (playlistEntries ?? const {}).entries)
           entry.key: List<PlaylistEntryRecord>.of(entry.value),
       };

  final List<MediaItemRecord> _items;
  final List<PlaylistRecord> _playlists;
  final Map<String, List<PlaylistEntryRecord>> _playlistEntries;
  final List<(String playlistId, List<String> paths)> addedPathsToPlaylists =
      [];
  final List<String> deletedMediaIds = [];
  int _nextPlaylistId = 1;
  int _nextEntryId = 1;

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

Widget _buildTestApp({
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

MediaItemRecord _makeRecord({
  required String id,
  required String path,
  required MediaKind kind,
  String? title,
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
      artist: kind == MediaKind.audio ? 'Test Artist' : null,
      album: kind == MediaKind.audio ? 'Test Album' : null,
      duration: duration,
    ),
  );
}

Future<void> _pumpAfterIo(WidgetTester tester, {bool settle = true}) async {
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

void main() {
  late Directory tempDir;
  late File videoFileA;
  late File videoFileB;
  late File audioFileA;
  late _FakePlaybackService playback;
  late SessionRepository sessions;
  late PlayerController controller;
  late _FakeMediaLibraryRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mpvson_ctx_menu_test_');
    videoFileA = await File(
      '${tempDir.path}${Platform.pathSeparator}sample_a.mp4',
    ).writeAsBytes(const <int>[0, 1, 2, 3]);
    videoFileB = await File(
      '${tempDir.path}${Platform.pathSeparator}sample_b.mp4',
    ).writeAsBytes(const <int>[4, 5, 6, 7]);
    audioFileA = await File(
      '${tempDir.path}${Platform.pathSeparator}track_a.mp3',
    ).writeAsBytes(const <int>[8, 9, 10, 11]);

    playback = _FakePlaybackService();
    sessions = SessionRepository(directory: tempDir);
    controller = PlayerController(playback: playback, sessions: sessions);

    final playlistId = 'pl-1';
    final videoRecordA = _makeRecord(
      id: 'vid-a',
      path: videoFileA.path,
      kind: MediaKind.video,
      title: 'Sample Video A',
    );
    final videoRecordB = _makeRecord(
      id: 'vid-b',
      path: videoFileB.path,
      kind: MediaKind.video,
      title: 'Sample Video B',
    );
    final audioRecordA = _makeRecord(
      id: 'aud-a',
      path: audioFileA.path,
      kind: MediaKind.audio,
      title: 'Sample Audio A',
    );

    repository = _FakeMediaLibraryRepository(
      items: [videoRecordA, videoRecordB, audioRecordA],
      playlists: [
        PlaylistRecord(
          id: playlistId,
          title: 'Favorites Mix',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          entryCount: 1,
        ),
      ],
      playlistEntries: {
        playlistId: [
          PlaylistEntryRecord(
            id: 'entry-1',
            playlistId: playlistId,
            mediaId: audioRecordA.id,
            position: 0,
            addedAt: DateTime(2026, 1, 1),
            mediaItem: audioRecordA,
          ),
        ],
      },
    );
  });

  tearDown(() async {
    await controller.close(discard: true, force: true);
    await repository.dispose();
    await playback.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('MediaContextMenu & Properties', () {
    testWidgets(
      'Properties opens MediaPropertiesDialog even when AppToastHost mounts Overlay.wrap above Navigator',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final target = LibraryItemTarget(
          id: 'vid-a',
          path: videoFileA.path,
          title: 'Sample Video A',
          kind: MediaKind.video,
          duration: const Duration(minutes: 3, seconds: 15),
        );

        await tester.pumpWidget(
          _buildTestApp(
            controller: controller,
            includeToastHost: true,
            home: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    unawaited(
                      showMediaContextMenu(
                        context: context,
                        globalPosition: const Offset(200, 200),
                        target: target,
                        repository: repository,
                        controller: controller,
                      ),
                    );
                  },
                  child: const Text('Open Menu'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Menu'));
        await tester.pumpAndSettle();

        expect(find.text('Properties'), findsOneWidget);
        await tester.tap(find.text('Properties'));
        await _pumpAfterIo(tester);

        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsOneWidget);
        expect(find.text('Sample Video A'), findsOneWidget);

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(MediaPropertiesDialog), findsNothing);
      },
    );

    testWidgets(
      'Properties and New playlist guard missing Navigator without throwing',
      (tester) async {
        final target = LibraryItemTarget(
          id: 'vid-a',
          path: videoFileA.path,
          title: 'Sample Video A',
          kind: MediaKind.video,
        );

        // Overlay.wrap directly without any Navigator ancestor.
        await tester.pumpWidget(
          Theme(
            data: AppTheme.darkTheme(),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Overlay.wrap(
                child: Builder(
                  builder: (context) => ElevatedButton(
                    onPressed: () {
                      unawaited(
                        showMediaContextMenu(
                          context: context,
                          globalPosition: const Offset(100, 100),
                          target: target,
                          repository: repository,
                          controller: controller,
                        ),
                      );
                    },
                    child: const Text('Open Bare'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Bare'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Properties'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsNothing);
      },
    );

    testWidgets('Add to queue and Play next work without crashing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final targetA = LibraryItemTarget(
        id: 'vid-a',
        path: videoFileA.path,
        title: 'Sample Video A',
        kind: MediaKind.video,
      );
      final targetB = LibraryItemTarget(
        id: 'vid-b',
        path: videoFileB.path,
        title: 'Sample Video B',
        kind: MediaKind.video,
      );
      final targetAudio = LibraryItemTarget(
        id: 'aud-a',
        path: audioFileA.path,
        title: 'Sample Audio A',
        kind: MediaKind.audio,
      );

      await tester.pumpWidget(
        _buildTestApp(
          controller: controller,
          home: Row(
            children: [
              Expanded(
                child: Builder(
                  builder: (context) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: () => unawaited(
                          showMediaContextMenu(
                            context: context,
                            globalPosition: const Offset(150, 150),
                            target: targetA,
                            repository: repository,
                            controller: controller,
                          ),
                        ),
                        child: const Text('Menu A'),
                      ),
                      ElevatedButton(
                        onPressed: () => unawaited(
                          showMediaContextMenu(
                            context: context,
                            globalPosition: const Offset(150, 150),
                            target: targetB,
                            repository: repository,
                            controller: controller,
                          ),
                        ),
                        child: const Text('Menu B'),
                      ),
                      ElevatedButton(
                        onPressed: () => unawaited(
                          showMediaContextMenu(
                            context: context,
                            globalPosition: const Offset(150, 150),
                            target: targetAudio,
                            repository: repository,
                            controller: controller,
                          ),
                        ),
                        child: const Text('Menu Audio'),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 320,
                child: QueuePanel(
                  controller: controller,
                  onClose: () {},
                  onQueueFocus: (_) {},
                  onAddFiles: () {},
                ),
              ),
            ],
          ),
        ),
      );

      // 1) Add to queue when queue is initially empty.
      await tester.tap(find.text('Menu A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to queue'));
      await _pumpAfterIo(tester, settle: false);

      expect(tester.takeException(), isNull);
      expect(controller.queue.map((e) => e.path), [videoFileA.path]);
      expect(find.textContaining('Added to queue:'), findsOneWidget);

      // 2) Add to queue when queue already has an active item.
      await tester.tap(find.text('Menu B'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Add to queue'));
      await _pumpAfterIo(tester, settle: false);

      expect(tester.takeException(), isNull);
      expect(controller.queue.map((e) => e.path), [
        videoFileA.path,
        videoFileB.path,
      ]);

      // 3) Play next inserts right after currentIndex (0 -> index 1).
      await tester.tap(find.text('Menu Audio'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Play next'));
      await _pumpAfterIo(tester, settle: false);

      expect(tester.takeException(), isNull);
      expect(controller.queue.map((e) => e.path), [
        videoFileA.path,
        audioFileA.path,
        videoFileB.path,
      ]);
      expect(find.textContaining('Playing next:'), findsOneWidget);

      // 4) Force session save with isolate serialization to verify snapshot immutability.
      await tester.runAsync(() => controller.saveSession());
      await tester.runAsync(() => controller.close(discard: true, force: true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Open in File Explorer passes missing local path directly and supports F3',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final missingPath =
            '${tempDir.path}${Platform.pathSeparator}deleted_item.mp4';
        final revealedPaths = <String>[];
        final missingTarget = LibraryItemTarget(
          id: 'vid-missing',
          path: missingPath,
          title: 'Deleted Item',
          kind: MediaKind.video,
          isAvailable: false,
        );

        await tester.pumpWidget(
          _buildTestApp(
            controller: controller,
            home: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => unawaited(
                    showMediaContextMenu(
                      context: context,
                      globalPosition: const Offset(150, 150),
                      target: missingTarget,
                      repository: repository,
                      controller: controller,
                      onShowInFolder: revealedPaths.add,
                    ),
                  ),
                  child: const Text('Open Missing Menu'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open Missing Menu'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Open in File Explorer'));
        await tester.pumpAndSettle();
        expect(revealedPaths, [missingPath]);

        // Re-open menu and trigger via F3 keyboard shortcut.
        await tester.tap(find.text('Open Missing Menu'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.f3);
        await tester.pumpAndSettle();
        expect(revealedPaths, [missingPath, missingPath]);
      },
    );

    testWidgets(
      'Play, Add to playlist (existing & New playlist...), Remove, and Select work',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        var played = false;
        var removed = false;
        var selected = false;

        final target = LibraryItemTarget(
          id: 'vid-a',
          path: videoFileA.path,
          title: 'Sample Video A',
          kind: MediaKind.video,
        );

        await tester.pumpWidget(
          _buildTestApp(
            controller: controller,
            home: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => unawaited(
                    showMediaContextMenu(
                      context: context,
                      globalPosition: const Offset(180, 180),
                      target: target,
                      repository: repository,
                      controller: controller,
                      onPlay: () => played = true,
                      onRemove: () => removed = true,
                      onSelect: () => selected = true,
                    ),
                  ),
                  child: const Text('Trigger'),
                ),
              ),
            ),
          ),
        );

        // Play
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Play'));
        await tester.pumpAndSettle();
        expect(played, isTrue);

        // Remove
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        expect(removed, isTrue);

        // Select
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();
        expect(selected, isTrue);

        // Add to existing playlist via submenu
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to playlist'));
        await tester.pumpAndSettle();
        expect(find.text('Favorites Mix'), findsOneWidget);
        await tester.tap(find.text('Favorites Mix'));
        await tester.pumpAndSettle();
        expect(repository.addedPathsToPlaylists, hasLength(1));
        expect(repository.addedPathsToPlaylists.first.$1, 'pl-1');

        // Create new playlist via submenu inside AppToastHost
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to playlist'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New playlist...'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Weekend Watch');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(repository.addedPathsToPlaylists, hasLength(2));
        expect(
          repository.addedPathsToPlaylists.last.$2,
          equals([videoFileA.path]),
        );
      },
    );

    testWidgets(
      'LibraryItemActionMenu handles Add to queue, Play next, Open in File Explorer, and Properties',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final revealed = <String>[];
        final record = _makeRecord(
          id: 'aud-a',
          path: audioFileA.path,
          kind: MediaKind.audio,
          title: 'Sample Audio A',
        );

        await tester.pumpWidget(
          _buildTestApp(
            controller: controller,
            home: Builder(
              builder: (context) => Center(
                child: LibraryItemActionMenu(
                  item: record,
                  repository: repository,
                  controller: controller,
                  libraryContext: context,
                  onShowInFolder: revealed.add,
                ),
              ),
            ),
          ),
        );

        // Add to queue
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add to queue'));
        await _pumpAfterIo(tester);
        expect(tester.takeException(), isNull);
        expect(controller.queue.map((e) => e.path), [audioFileA.path]);

        // Open in File Explorer
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open in File Explorer'));
        await tester.pumpAndSettle();
        expect(revealed, [audioFileA.path]);

        // Properties
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Properties'));
        await _pumpAfterIo(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpAndSettle();
      },
    );
  });

  group('Right-click across library views & EmptyLibrary', () {
    testWidgets(
      'HomeView recent tile right-click opens context menu and Properties',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final recentEntry = MediaEntry.fromPath(
          videoFileA.path,
          id: 'rec-home-1',
        );

        await tester.pumpWidget(
          _buildTestApp(
            controller: controller,
            home: HomeView(
              recent: [recentEntry],
              repository: repository,
              controller: controller,
              onOpenFiles: () {},
              onOpenUrl: () {},
              onOpenRecent: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        final tile = find.text(recentEntry.title).first;
        await tester.tap(tile, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();

        expect(find.text('Properties'), findsOneWidget);
        await tester.tap(find.text('Properties'));
        await _pumpAfterIo(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('VideosView right-click opens context menu and adds to queue', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _buildTestApp(
          controller: controller,
          home: VideosView(repository: repository, controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      final itemTitle = find.text('Sample Video A').first;
      await tester.tap(itemTitle, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();

      expect(find.text('Add to queue'), findsOneWidget);
      await tester.tap(find.text('Add to queue'));
      await _pumpAfterIo(tester);

      expect(tester.takeException(), isNull);
      expect(controller.queue.map((e) => e.path), [videoFileA.path]);
      await tester.runAsync(() => controller.close(discard: true, force: true));
      await tester.pumpAndSettle();
    });

    testWidgets(
      'MusicView song row right-click opens context menu and Properties',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _buildTestApp(
            controller: controller,
            home: MusicView(repository: repository, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        final songTitle = find.text('Sample Audio A').first;
        await tester.tap(songTitle, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();

        expect(find.text('Add to queue'), findsOneWidget);
        expect(find.text('Properties'), findsOneWidget);

        await tester.tap(find.text('Properties'));
        await _pumpAfterIo(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(MediaPropertiesDialog), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'PlaylistsView track row right-click opens context menu and adds to queue',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _buildTestApp(
            controller: controller,
            home: PlaylistsView(repository: repository, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        // Open the playlist detail view.
        await tester.tap(find.text('Favorites Mix'));
        await tester.pumpAndSettle();

        final trackTitle = find.text('Sample Audio A').first;
        await tester.tap(trackTitle, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();

        expect(find.text('Add to queue'), findsOneWidget);
        await tester.tap(find.text('Add to queue'));
        await _pumpAfterIo(tester);

        expect(tester.takeException(), isNull);
        expect(controller.queue.map((e) => e.path), [audioFileA.path]);
        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpAndSettle();
      },
    );

    testWidgets('EmptyLibrary recent tile right-click triggers menu actions', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var removedCalled = false;
      final recentEntry = MediaEntry.fromPath(
        videoFileA.path,
        id: 'rec-home-1',
      );

      await tester.pumpWidget(
        _buildTestApp(
          controller: controller,
          home: EmptyLibrary(
            recent: [recentEntry],
            onOpenFiles: () {},
            onOpenUrl: () {},
            onOpenRecent: (_) {},
            onRemoveRecent: (_) => removedCalled = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.text(recentEntry.title).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Remove from recently played'), findsOneWidget);
      await tester.tap(find.text('Remove from recently played'));
      await tester.pumpAndSettle();
      expect(removedCalled, isTrue);
    });
  });
}
