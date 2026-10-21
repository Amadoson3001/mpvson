import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/media_library_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/desktop_integration_service.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/settings_dialog.dart';

import 'support/player_test_fakes.dart';

class _FakePreferencesRepository extends AppPreferencesRepository {
  _FakePreferencesRepository({
    DesktopPreferences initial = const DesktopPreferences(),
  }) : _customPreferences = initial;

  DesktopPreferences _customPreferences;

  @override
  DesktopPreferences get preferences => _customPreferences;

  @override
  bool get isLoaded => true;

  @override
  Future<void> load() async {}

  @override
  Future<void> updatePreferences(DesktopPreferences preferences) async {
    _customPreferences = preferences;
    notifyListeners();
  }

  @override
  Future<void> setOpenBehavior(OpenBehaviorPreference preference) async {
    await updatePreferences(
      _customPreferences.copyWith(openBehavior: preference),
    );
  }

  @override
  Future<void> setKeepAwake(bool keepAwake) async {
    await updatePreferences(
      _customPreferences.copyWith(keepAwakeDuringPlayback: keepAwake),
    );
  }
}

class _FakeDesktopIntegrationService extends DesktopIntegrationService {
  int defaultAppsCallCount = 0;
  bool keepAwakeEnabled = true;

  @override
  SystemPlaybackStatus get playbackStatus => SystemPlaybackStatus.playing;

  @override
  MediaMetadata get currentMetadata => MediaMetadata.empty;

  @override
  bool get isAwakeInhibited => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> updatePlaybackState({
    required SystemPlaybackStatus status,
    required Duration position,
    required Duration duration,
    required double playbackRate,
  }) async {}

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {}

  @override
  Future<void> updateCapabilities({
    bool canPlay = true,
    bool canPause = true,
    bool canSeek = true,
    bool canGoNext = true,
    bool canGoPrevious = true,
  }) async {}

  @override
  Future<void> setKeepAwake(bool enable, {required bool isVideoPlaying}) async {
    keepAwakeEnabled = enable;
  }

  @override
  Future<void> openDefaultAppsSettings() async {
    defaultAppsCallCount++;
  }
}

class _FakeMediaLibraryRepository extends MediaLibraryRepository {
  _FakeMediaLibraryRepository({
    List<LibraryFolderRecord>? folders,
    this.scanStatus = const LibraryScanStatus(),
  })  : _folders = List.of(folders ?? const []);

  List<LibraryFolderRecord> _folders;
  @override
  LibraryScanStatus scanStatus;
  int rescanAllCallCount = 0;
  final List<String> addedFolders = [];
  final List<String> removedFolders = [];

  @override
  List<LibraryFolderRecord> get folders => List.unmodifiable(_folders);

  @override
  bool get isReady => true;

  @override
  String? get initializationError => null;

  void setScanStatus(LibraryScanStatus status) {
    scanStatus = status;
    notifyListeners();
  }

  void setFolders(List<LibraryFolderRecord> folders) {
    _folders = List.of(folders);
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> addFolder(String path) async {
    addedFolders.add(path);
    _folders.add(
      LibraryFolderRecord(
        path: path,
        addedAt: DateTime.now(),
        fileCount: 0,
        isAvailable: true,
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> removeFolder(String path) async {
    removedFolders.add(path);
    _folders.removeWhere((folder) => folder.path == path);
    notifyListeners();
  }

  @override
  Future<List<LibraryFolderRecord>> getFolders() async => folders;

  @override
  Future<void> rescanAll() async {
    rescanAllCallCount++;
  }

  @override
  Future<void> rescanFolder(String folderPath) async {}

  @override
  Future<void> cancelScan() async {}

  @override
  Future<void> markFolderAvailability(
    String folderPath,
    bool isAvailable,
  ) async {}

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
  }) async => const [];

  @override
  Future<MediaItemRecord?> getMediaByCanonicalSource(
    String canonicalSource,
  ) async => null;

  @override
  Future<MediaItemRecord?> getMediaById(String id) async => null;

  @override
  Future<void> toggleFavorite(String mediaId, bool isFavorite) async {}

  @override
  Future<void> recordPlayback(String canonicalSource) async {}

  @override
  Future<List<PlaylistRecord>> getPlaylists() async => const [];

  @override
  Future<PlaylistRecord> createPlaylist(String title) async => PlaylistRecord(
    id: '1',
    title: title,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  @override
  Future<void> deletePlaylist(String playlistId) async {}

  @override
  Future<void> renamePlaylist(String playlistId, String newTitle) async {}

  @override
  Future<void> addToPlaylist(String playlistId, List<String> mediaIds) async {}

  @override
  Future<void> removeFromPlaylist(
    String playlistId,
    String playlistEntryId,
  ) async {}

  @override
  Future<void> reorderPlaylist(
    String playlistId,
    int oldIndex,
    int newIndex,
  ) async {}

  @override
  Future<List<PlaylistEntryRecord>> getPlaylistEntries(
    String playlistId,
  ) async => const [];

  @override
  Future<List<String>> getDistinctArtists({MediaKind? kind}) async => const [];

  @override
  Future<List<String>> getDistinctAlbums({String? artist}) async => const [];

  @override
  Future<void> dispose() async {
    super.dispose();
  }
}

class _TestFixture {
  _TestFixture({
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.preferences,
    required this.desktopIntegration,
    required this.libraryRepository,
  });

  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final _FakePreferencesRepository preferences;
  final _FakeDesktopIntegrationService desktopIntegration;
  final _FakeMediaLibraryRepository libraryRepository;

  static Future<_TestFixture> create({
    DesktopPreferences? initialPreferences,
    List<LibraryFolderRecord>? initialFolders,
    LibraryScanStatus? initialScanStatus,
  }) async {
    final playback = FakePlaybackService();
    final sessions = BlockingSessionRepository(
      blockDetailed: false,
      initialResult: SessionLoadResult(
        session: const PlaybackSession(queue: []),
      ),
    );
    final controller = PlayerController(
      playback: playback,
      sessions: sessions,
    );
    await controller.initialize();
    return _TestFixture(
      controller: controller,
      updates: UpdateService(),
      engineUpdates: EngineUpdateService(),
      preferences: _FakePreferencesRepository(
        initial: initialPreferences ?? const DesktopPreferences(),
      ),
      desktopIntegration: _FakeDesktopIntegrationService(),
      libraryRepository: _FakeMediaLibraryRepository(
        folders: initialFolders,
        scanStatus: initialScanStatus ?? const LibraryScanStatus(),
      ),
    );
  }

  Future<void> dispose() async {
    await controller.close();
    updates.dispose();
    engineUpdates.dispose();
    preferences.dispose();
    desktopIntegration.dispose();
    await libraryRepository.dispose();
  }

  Widget buildApp({Future<String?> Function()? pickDirectory}) {
    return MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: SettingsDialog(
          controller: controller,
          updates: updates,
          engineUpdates: engineUpdates,
          pickSubtitle: () async => null,
          appPreferences: preferences,
          desktopIntegration: desktopIntegration,
          libraryRepository: libraryRepository,
          pickDirectory: pickDirectory,
        ),
      ),
    );
  }
}

void main() {
  group('SettingsDialog - Desktop integration', () {
    testWidgets('shows opening files options and updates preference when clicked', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _TestFixture.create();
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await fixture.dispose();
      });

      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Desktop integration'));
      await tester.pumpAndSettle();

      expect(find.text('Opening files'), findsOneWidget);
      expect(find.text('Keep playing and add to queue'), findsOneWidget);
      expect(find.text('Play new files now'), findsOneWidget);
      expect(find.text('Ask every time'), findsOneWidget);

      await tester.tap(find.text('Play new files now'));
      await tester.pumpAndSettle();
      expect(
        fixture.preferences.preferences.openBehavior,
        OpenBehaviorPreference.playNewFilesNow,
      );

      await tester.tap(find.text('Keep playing and add to queue'));
      await tester.pumpAndSettle();
      expect(
        fixture.preferences.preferences.openBehavior,
        OpenBehaviorPreference.keepPlayingAndEnqueue,
      );

      await tester.tap(find.text('Ask every time'));
      await tester.pumpAndSettle();
      expect(
        fixture.preferences.preferences.openBehavior,
        OpenBehaviorPreference.askEveryTime,
      );
    });

    testWidgets('toggles keep computer awake during playback', (tester) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _TestFixture.create(
        initialPreferences: const DesktopPreferences(
          keepAwakeDuringPlayback: true,
        ),
      );
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await fixture.dispose();
      });

      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Desktop integration'));
      await tester.pumpAndSettle();

      final switchFinder = find.byKey(const ValueKey('keep-awake-switch'));
      expect(switchFinder, findsOneWidget);
      expect(
        find.text('Keep computer awake during playback'),
        findsOneWidget,
      );
      expect(fixture.preferences.preferences.keepAwakeDuringPlayback, isTrue);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(fixture.preferences.preferences.keepAwakeDuringPlayback, isFalse);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(fixture.preferences.preferences.keepAwakeDuringPlayback, isTrue);
    });

    testWidgets('triggers openDefaultAppsSettings when Default apps button is clicked', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _TestFixture.create();
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await fixture.dispose();
      });

      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Desktop integration'));
      await tester.pumpAndSettle();

      final defaultAppsButton = find.byKey(const ValueKey('default-apps-button'));
      expect(defaultAppsButton, findsOneWidget);
      expect(fixture.desktopIntegration.defaultAppsCallCount, 0);

      await tester.ensureVisible(defaultAppsButton);
      await tester.tap(defaultAppsButton);
      await tester.pumpAndSettle();

      expect(fixture.desktopIntegration.defaultAppsCallCount, 1);
    });
  });

  group('SettingsDialog - Media library', () {
    testWidgets('displays registered folders with availability, file count, and remove button', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _TestFixture.create(
        initialFolders: [
          LibraryFolderRecord(
            path: 'C:/Movies',
            addedAt: DateTime(2026, 1, 1),
            fileCount: 42,
            isAvailable: true,
          ),
          LibraryFolderRecord(
            path: 'D:/Music',
            addedAt: DateTime(2026, 2, 1),
            fileCount: 108,
            isAvailable: false,
          ),
        ],
      );
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await fixture.dispose();
      });

      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Media library'));
      await tester.pumpAndSettle();

      expect(find.text('C:/Movies'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(find.text('42 files'), findsOneWidget);

      expect(find.text('D:/Music'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.text('108 files'), findsOneWidget);

      final removeBtn = find.byKey(const ValueKey('remove-folder-C:/Movies'));
      expect(removeBtn, findsOneWidget);

      await tester.tap(removeBtn);
      await tester.pumpAndSettle();

      expect(fixture.libraryRepository.removedFolders, contains('C:/Movies'));
      expect(find.text('C:/Movies'), findsNothing);
    });

    testWidgets('adds folder via Add folder button and picker callback', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _TestFixture.create();
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await fixture.dispose();
      });

      await tester.pumpWidget(
        fixture.buildApp(
          pickDirectory: () async => 'E:/Videos',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Media library'));
      await tester.pumpAndSettle();

      final addFolderBtn = find.byKey(const ValueKey('add-folder-button'));
      expect(addFolderBtn, findsOneWidget);

      await tester.tap(addFolderBtn);
      await tester.pumpAndSettle();

      expect(fixture.libraryRepository.addedFolders, contains('E:/Videos'));
      expect(find.text('E:/Videos'), findsOneWidget);
    });

    testWidgets('triggers rescanAll when Rescan all folders button is tapped', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _TestFixture.create();
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await fixture.dispose();
      });

      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Media library'));
      await tester.pumpAndSettle();

      final rescanBtn = find.byKey(const ValueKey('rescan-all-button'));
      expect(rescanBtn, findsOneWidget);
      expect(fixture.libraryRepository.rescanAllCallCount, 0);

      await tester.tap(rescanBtn);
      await tester.pumpAndSettle();

      expect(fixture.libraryRepository.rescanAllCallCount, 1);
    });

    testWidgets('displays live scan progress indicator with discovered and enriched counts', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final fixture = await _TestFixture.create(
        initialScanStatus: const LibraryScanStatus(
          phase: ScanPhase.enriching,
          discoveredCount: 120,
          enrichedCount: 45,
          totalToEnrich: 120,
        ),
      );
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await fixture.dispose();
      });

      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Media library'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('library-scan-progress')), findsOneWidget);
      expect(find.text('Scanning library…'), findsOneWidget);
      expect(find.text('Discovered: 120'), findsOneWidget);
      expect(find.text('Enriched: 45'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Transition to idle
      fixture.libraryRepository.setScanStatus(
        const LibraryScanStatus(
          phase: ScanPhase.idle,
          discoveredCount: 120,
          enrichedCount: 120,
          totalToEnrich: 120,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Scan idle'), findsOneWidget);
      expect(find.text('Discovered: 120'), findsOneWidget);
      expect(find.text('Enriched: 120'), findsOneWidget);
    });
  });

  group('SettingsDialog - Backwards compatibility', () {
    testWidgets('renders all existing sections and operates without optional repositories', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1240, 780);
      tester.view.devicePixelRatio = 1;
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: SessionLoadResult(
          session: const PlaybackSession(queue: []),
        ),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();
      final updates = UpdateService();
      final engineUpdates = EngineUpdateService();

      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await controller.close();
        updates.dispose();
        engineUpdates.dispose();
      });

      // Pass only the original required parameters
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SettingsDialog(
              controller: controller,
              updates: updates,
              engineUpdates: engineUpdates,
              pickSubtitle: () async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Appearance is open by default
      expect(find.text('Control size'), findsOneWidget);

      // Verify Playback section
      await tester.tap(find.text('Playback'));
      await tester.pumpAndSettle();
      expect(find.text('Shuffle'), findsOneWidget);

      // Verify Video & audio section
      await tester.tap(find.text('Video & audio'));
      await tester.pumpAndSettle();
      expect(find.text('Quality preset'), findsOneWidget);

      // Verify Desktop integration without crashing
      await tester.tap(find.text('Desktop integration'));
      await tester.pumpAndSettle();
      expect(find.text('Opening files'), findsOneWidget);

      // Verify Media library without crashing
      await tester.tap(find.text('Media library'));
      await tester.pumpAndSettle();
      expect(find.text('Add folder'), findsOneWidget);

      // Verify Shortcuts section
      await tester.tap(find.text('Shortcuts'));
      await tester.pumpAndSettle();
      expect(find.text('Video controls'), findsOneWidget);

      // Verify About section
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(find.text('Updates & about'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
