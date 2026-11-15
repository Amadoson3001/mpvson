import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/media_accent_scope.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/mini_player_overlay.dart';
import 'package:mpvson/ui/player/views/player_chrome_controller.dart';
import 'package:mpvson/ui/player/views/player_content.dart';
import 'package:mpvson/ui/player/views/player_layout_manager.dart';
import 'package:mpvson/ui/player/views/player_media_coordinator.dart';
import 'package:mpvson/ui/player/widgets/player_controls.dart';

import '../../support/fake_playback_service.dart';

/// Frame-cost regression guard for the two moving-geometry paths.
///
/// Both are measured by widget identity: a rebuilt subtree produces a new
/// widget instance, so `identical()` across animation ticks is a direct,
/// deterministic signal that the subtree was not recomposed. This is what a
/// DevTools trace would show as per-frame build work, without needing a device.
class _CostHost extends StatefulWidget {
  const _CostHost({required this.controller, required this.mediaBuilds});

  final PlayerController controller;

  /// Counts video-surface builds.
  final List<int> mediaBuilds;

  @override
  State<_CostHost> createState() => _CostHostState();
}

class _CostHostState extends State<_CostHost> {
  bool _showLibrary = true;

  late final MenuController _contextMenu;
  late final FocusNode _playerFocus;
  late final PlayerChromeController _chrome;
  late final PlayerLayoutManager _layout;
  late final PlayerMediaCoordinator _media;
  late final UpdateService _updates;
  late final EngineUpdateService _engineUpdates;

  @override
  void initState() {
    super.initState();
    _contextMenu = MenuController();
    _playerFocus = FocusNode(debugLabel: 'cost test player');
    _updates = UpdateService();
    _engineUpdates = EngineUpdateService();
    _chrome = PlayerChromeController(
      contextMenu: _contextMenu,
      playerFocus: _playerFocus,
      isFullscreen: () => false,
      reduceMotion: () => false,
    )..addListener(_onChanged);
    _layout = PlayerLayoutManager(
      controller: widget.controller,
      desktopWindow: false,
      isShowingLibrary: () => _showLibrary,
      showMessage: (_) {},
      showFeedback: (_, _, {centered = false}) {},
      playerFocus: _playerFocus,
    )..addListener(_onChanged);
    _media = PlayerMediaCoordinator(
      getContext: () => context,
      controller: widget.controller,
      updates: _updates,
      engineUpdates: _engineUpdates,
      showMessage: (_) {},
      withControlsVisible: <T>(Future<T> Function() action) async => action(),
      onCloseContextMenu: () {},
      onOpenLibrary: () {},
      onClearFocusedQueueEntry: () {},
    );
  }

  /// Mirrors the screen flipping its own navigation flag.
  void setShowLibrary(bool value) {
    setState(() => _showLibrary = value);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _chrome.removeListener(_onChanged);
    _layout.removeListener(_onChanged);
    _chrome.dispose();
    _layout.dispose();
    _playerFocus.dispose();
    _updates.dispose();
    _engineUpdates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, child) => AppToastHost(
        child: AppPreferencesScope(
          preferences: const DesktopPreferences(),
          child: MediaAccentScope(controller: widget.controller, child: child!),
        ),
      ),
      home: Scaffold(
        body: PlayerContent(
          controller: widget.controller,
          chrome: _chrome,
          media: _media,
          layoutManager: _layout,
          libraryRepository: null,
          updates: _updates,
          engineUpdates: _engineUpdates,
          appPreferences: null,
          desktopIntegration: null,
          videoBuilder: (context, controller) {
            widget.mediaBuilds.add(widget.mediaBuilds.length);
            return const ColoredBox(color: Color(0xFF102030));
          },
          contextMenu: _contextMenu,
          videoSurfaceKey: GlobalKey(),
          queuePanelKey: GlobalKey(),
          queueFocusScope: _chrome.queueFocusScope,
          desktopWindow: false,
          nativeWindow: false,
          enableNativeDrop: false,
          isShowingLibrary: _showLibrary,
          settingsOpen: false,
          homeNavigationRequest: 0,
          draggingFiles: false,
          onVideoTap: () {},
          onVideoDoubleTap: () {},
          onBackToHome: () {},
          onOpenLibrary: () {},
          onReturnToPlayer: () {
            setState(() => _showLibrary = false);
          },
          onSettingsOpened: () {},
          onSettingsClosed: () {},
          onDragStateChanged: (_) {},
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File videoFile;
  late FakePlaybackService playback;
  late SessionRepository sessions;
  late PlayerController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mpvson_cost_test_');
    videoFile = await File(
      '${tempDir.path}${Platform.pathSeparator}sample.mp4',
    ).writeAsBytes(const <int>[0, 1, 2, 3]);
    playback = FakePlaybackService();
    sessions = SessionRepository(directory: tempDir);
    controller = PlayerController(playback: playback, sessions: sessions);
  });

  tearDown(() async {
    controller.dispose();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Advances the fake clock a frame at a time, like a 60 Hz display.
  Future<void> tick(WidgetTester tester, {int frames = 1}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('docking rebuilds the video surface once, not per frame', (
    tester,
  ) async {
    final mediaBuilds = <int>[];
    await tester.runAsync(() => controller.openPaths([videoFile.path]));
    await tester.pump();
    await tester.runAsync(() => controller.togglePlayPause());
    await tester.pump();

    await tester.pumpWidget(
      _CostHost(controller: controller, mediaBuilds: mediaBuilds),
    );
    // One frame for the initial structure publish to land, then measure.
    await tick(tester);
    final buildsAtStart = mediaBuilds.length;

    for (var i = 0; i < 12; i++) {
      await tick(tester);
      expect(mediaBuilds.length, buildsAtStart);
    }

    await tester.pumpAndSettle();
    expect(mediaBuilds.length, buildsAtStart);
    expect(find.byType(PlayerControls), findsNothing);
    expect(find.byType(PlayerTopBar), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('opening the queue does not recompose the controls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);

    await tester.runAsync(() => controller.openPaths([videoFile.path]));
    await tester.pump();
    await tester.runAsync(() => controller.togglePlayPause());
    await tester.pump();

    await tester.pumpWidget(
      _CostHost(controller: controller, mediaBuilds: <int>[]),
    );
    await tester.pumpAndSettle();
    // Leave the library so the player owns the full stage.
    final host = tester.state<_CostHostState>(find.byType(_CostHost));
    host.setShowLibrary(false);
    await tester.pumpAndSettle();

    host._chrome.toggleQueue();
    await tester.pump();
    final controls = tester.widget<PlayerControls>(find.byType(PlayerControls));
    final topBar = tester.widget<PlayerTopBar>(find.byType(PlayerTopBar));

    // The queue slot widens on every tick, which resizes the player area.
    await tick(tester, frames: 10);
    expect(
      identical(
        tester.widget<PlayerControls>(find.byType(PlayerControls)),
        controls,
      ),
      isTrue,
    );
    expect(
      identical(tester.widget<PlayerTopBar>(find.byType(PlayerTopBar)), topBar),
      isTrue,
    );

    await teardownTree(tester);
  });

  testWidgets('auto-hiding the controls keeps them mounted while fading', (
    tester,
  ) async {
    await tester.runAsync(() => controller.openPaths([videoFile.path]));
    await tester.pump();
    await tester.runAsync(() => controller.togglePlayPause());
    await tester.pump();

    await tester.pumpWidget(
      _CostHost(controller: controller, mediaBuilds: <int>[]),
    );
    await tester.pumpAndSettle();
    final host = tester.state<_CostHostState>(find.byType(_CostHost));
    host.setShowLibrary(false);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerControls), findsOneWidget);
    final fade = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(PlayerControls),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(fade.opacity, 1.0);

    // Auto-hide must animate out, not drop the controls from the tree.
    host._chrome.scheduleHide(restart: true);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(PlayerControls), findsOneWidget);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byType(PlayerControls),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity,
      0.0,
    );

    await teardownTree(tester);
  });

  testWidgets('crossing the dock clip threshold does not remount the stage', (
    tester,
  ) async {
    await tester.runAsync(() => controller.openPaths([videoFile.path]));
    await tester.pump();
    await tester.runAsync(() => controller.togglePlayPause());
    await tester.pump();

    await tester.pumpWidget(
      _CostHost(controller: controller, mediaBuilds: <int>[]),
    );
    await tester.pumpAndSettle();
    final host = tester.state<_CostHostState>(find.byType(_CostHost));
    host.setShowLibrary(false);
    await tester.pumpAndSettle();

    // Undocked: no clip yet. This element stays mounted for the whole dock, so
    // its identity is a remount detector.
    final surface = tester.element(find.byKey(const ValueKey('video-surface')));

    // Dock forward across the 1% clip threshold.
    host.setShowLibrary(true);
    await tester.pumpAndSettle();
    expect(
      identical(
        tester.element(find.byKey(const ValueKey('video-surface'))),
        surface,
      ),
      isTrue,
    );

    // And back across it on the way out.
    host.setShowLibrary(false);
    await tester.pumpAndSettle();
    expect(
      identical(
        tester.element(find.byKey(const ValueKey('video-surface'))),
        surface,
      ),
      isTrue,
    );

    await teardownTree(tester);
  });

  testWidgets('undocking brings the chrome back', (tester) async {
    await tester.runAsync(() => controller.openPaths([videoFile.path]));
    await tester.pump();
    await tester.runAsync(() => controller.togglePlayPause());
    await tester.pump();

    await tester.pumpWidget(
      _CostHost(controller: controller, mediaBuilds: <int>[]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlayerControls), findsNothing);

    final host = tester.state<_CostHostState>(find.byType(_CostHost));
    host.setShowLibrary(false);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerControls), findsOneWidget);
    expect(find.byType(PlayerTopBar), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('docking from player hides chrome and mounts mini overlay', (
    tester,
  ) async {
    final mediaBuilds = <int>[];
    await tester.runAsync(() => controller.openPaths([videoFile.path]));
    await tester.pump();
    await tester.runAsync(() => controller.togglePlayPause());
    await tester.pump();

    await tester.pumpWidget(
      _CostHost(controller: controller, mediaBuilds: mediaBuilds),
    );
    await tester.pumpAndSettle();

    final host = tester.state<_CostHostState>(find.byType(_CostHost));
    host.setShowLibrary(false);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerControls), findsOneWidget);
    expect(find.byType(PlayerTopBar), findsOneWidget);
    expect(find.byType(MiniPlayerOverlay), findsNothing);

    final buildsBeforeDock = mediaBuilds.length;
    host.setShowLibrary(true);
    await tick(tester);
    final buildsAtDockStart = mediaBuilds.length;
    expect(buildsAtDockStart, buildsBeforeDock + 1);
    await tick(tester, frames: 12);
    expect(mediaBuilds.length, buildsAtDockStart);

    await tester.pumpAndSettle();
    expect(mediaBuilds.length, buildsAtDockStart);
    expect(find.byType(PlayerControls), findsNothing);
    expect(find.byType(PlayerTopBar), findsNothing);
    expect(find.byType(MiniPlayerOverlay), findsOneWidget);

    await teardownTree(tester);
  });
}

/// Unmounts the tree, then lets the seek-preview service's idle-release timer
/// run so the test does not end with a pending timer, which the binding treats
/// as a failure.
Future<void> teardownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 6));
}
