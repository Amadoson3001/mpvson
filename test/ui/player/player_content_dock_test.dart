import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/models/control_density.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/media_accent_scope.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/mini_player_overlay.dart';
import 'package:mpvson/ui/player/views/player_chrome_controller.dart';
import 'package:mpvson/ui/player/views/player_content.dart';
import 'package:mpvson/ui/player/views/player_layout_manager.dart';
import 'package:mpvson/ui/player/views/player_media_coordinator.dart';

import '../../support/fake_playback_service.dart';

/// Host that mirrors how `PlayerScreen` wires [PlayerContent]: the library flag
/// lives here and flips only when the dock animation hands control back, and
/// chrome/layout notifications rebuild the content the way the screen does.
class _DockHost extends StatefulWidget {
  const _DockHost({
    required this.controller,
    required this.videoBuildCounter,
    this.showLibrary = true,
  });

  final PlayerController controller;
  final bool showLibrary;

  /// Counts video-surface builds so a test can prove the stage was not
  /// recomposed by an animation tick.
  final List<int> videoBuildCounter;

  @override
  State<_DockHost> createState() => _DockHostState();
}

class _DockHostState extends State<_DockHost> {
  bool _showLibrary = true;
  int _returnCount = 0;

  /// The stage's video surface key, kept here so a test can assert it still
  /// resolves after the dock rearranges the stage.
  final GlobalKey videoSurfaceKey = GlobalKey();

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
    _showLibrary = widget.showLibrary;
    _contextMenu = MenuController();
    _playerFocus = FocusNode(debugLabel: 'dock test player');
    _updates = UpdateService();
    _engineUpdates = EngineUpdateService();
    _chrome = PlayerChromeController(
      contextMenu: _contextMenu,
      playerFocus: _playerFocus,
      isFullscreen: () => false,
      reduceMotion: () => false,
    )..addListener(_onChromeChanged);
    _layout = PlayerLayoutManager(
      controller: widget.controller,
      desktopWindow: false,
      isShowingLibrary: () => _showLibrary,
      showMessage: (_) {},
      showFeedback: (_, _, {centered = false}) {},
      playerFocus: _playerFocus,
    )..addListener(_onChromeChanged);
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

  void _onChromeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _chrome.removeListener(_onChromeChanged);
    _layout.removeListener(_onChromeChanged);
    _chrome.dispose();
    _layout.dispose();
    _playerFocus.dispose();
    _updates.dispose();
    _engineUpdates.dispose();
    super.dispose();
  }

  /// Mirrors the screen flipping its own navigation flag.
  void setShowLibrary(bool value) {
    setState(() => _showLibrary = value);
  }

  void _returnToPlayer() {
    setState(() {
      _returnCount++;
      _showLibrary = false;
    });
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
          // No library repository: the dock transition is what is under test,
          // not the shell layered on top of it.
          libraryRepository: null,
          updates: _updates,
          engineUpdates: _engineUpdates,
          appPreferences: null,
          desktopIntegration: null,
          videoBuilder: (context, controller) {
            widget.videoBuildCounter.add(widget.videoBuildCounter.length);
            return const ColoredBox(color: Color(0xFF102030));
          },
          contextMenu: _contextMenu,
          videoSurfaceKey: videoSurfaceKey,
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
          onReturnToPlayer: _returnToPlayer,
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
    tempDir = await Directory.systemTemp.createTemp('mpvson_dock_test_');
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

  /// Opens the fixture and waits for the engine to report it as attached.
  ///
  /// File IO and the controller's own futures run inside [runAsync]: a widget
  /// test body runs on a fake clock, where real IO never completes. Playback
  /// is left paused because the position smoother's periodic timer would keep
  /// scheduling frames and stop `pumpAndSettle` from ever settling.
  Future<void> openVideo(WidgetTester tester) async {
    await tester.runAsync(() => controller.openPaths([videoFile.path]));
    await tester.pump();
    await tester.runAsync(() => controller.togglePlayPause());
    await tester.pump();
    expect(controller.hasMedia, isTrue);
    expect(controller.isVideo, isTrue);
  }

  /// Taps the docked mini video, which is the gesture that asks to go back.
  Future<void> tapToReturn(WidgetTester tester) async {
    await tester.tap(find.byType(MiniPlayerOverlay));
    await tester.pump();
  }

  _DockHostState hostState(WidgetTester tester) =>
      tester.state<_DockHostState>(find.byType(_DockHost));

  /// Unmounts the tree, then lets the seek-preview service's idle-release
  /// timer run so the test does not end with a pending timer, which the
  /// binding treats as a failure.
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('a structure update mid-undock still returns to the player', (
    tester,
  ) async {
    await openVideo(tester);

    await tester.pumpWidget(
      _DockHost(controller: controller, videoBuildCounter: <int>[]),
    );
    // Dock forward: the video shrinks into the transport bar's artwork slot.
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayerOverlay), findsOneWidget);

    // Ask to go back, then let the expand run about halfway.
    await tapToReturn(tester);
    await tester.pump(const Duration(milliseconds: 100));

    // Playback publishes a structure change while the reverse is in flight.
    // The old code answered it with forward(), cancelling the reverse and
    // stranding the user on the library.
    controller.setControlDensity(ControlDensity.normal);
    await tester.pump();

    await tester.pumpAndSettle();

    final host = hostState(tester);
    expect(host._returnCount, 1);
    expect(host._showLibrary, isFalse);
    expect(find.byType(MiniPlayerOverlay), findsNothing);
    // The keyboard context menu anchors to this key, so the dock must not
    // detach it from the tree.
    expect(host.videoSurfaceKey.currentContext, isNotNull);
    await teardownTree(tester);
  });

  testWidgets('repeated structure updates do not return twice', (tester) async {
    await openVideo(tester);
    await tester.pumpWidget(
      _DockHost(controller: controller, videoBuildCounter: <int>[]),
    );
    await tester.pumpAndSettle();

    await tapToReturn(tester);
    await tester.pump(const Duration(milliseconds: 60));
    controller.setControlDensity(ControlDensity.normal);
    await tester.pump();
    controller.setControlDensity(ControlDensity.compact);
    await tester.pumpAndSettle();

    expect(hostState(tester)._returnCount, 1);
    await teardownTree(tester);
  });

  testWidgets('the stage docks again after a completed return', (tester) async {
    await openVideo(tester);
    await tester.pumpWidget(
      _DockHost(controller: controller, videoBuildCounter: <int>[]),
    );
    await tester.pumpAndSettle();

    await tapToReturn(tester);
    await tester.pumpAndSettle();
    var host = hostState(tester);
    expect(host._returnCount, 1);
    expect(host._showLibrary, isFalse);

    // Re-opening the library must dock again: the return's destination has to
    // be released once the parent confirms the player is showing.
    host.setShowLibrary(true);
    await tester.pumpAndSettle();
    host = hostState(tester);
    expect(host._returnCount, 1);
    expect(find.byType(MiniPlayerOverlay), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('a queue tick does not recompose the stage', (tester) async {
    // Wide layout: only the inline slot resizes the player area, which is the
    // path under test. The default 800x600 test surface would use the drawer.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);

    final builds = <int>[];
    await openVideo(tester);
    await tester.pumpWidget(
      _DockHost(
        controller: controller,
        videoBuildCounter: builds,
        // The player must own the stage for the inline queue slot to resize it.
        showLibrary: false,
      ),
    );
    await tester.pumpAndSettle();

    // Opening the queue widens its slot, which re-runs the player area's
    // LayoutBuilder on every tick. The stage must survive those ticks as the
    // animation's child instead of being rebuilt with the new constraints.
    hostState(tester)._chrome.toggleQueue();
    await tester.pump();
    final afterOpen = builds.length;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds.length, afterOpen);
    await teardownTree(tester);
  });
}
