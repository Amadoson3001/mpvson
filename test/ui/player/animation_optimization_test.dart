import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mpvson/app.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/models/hardware_profile.dart';
import 'package:mpvson/domain/models/player_controls_preferences.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/core/app_motion.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/core/components/media_accent_scope.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';
import 'package:mpvson/ui/library/views/home_view.dart';
import 'package:mpvson/ui/library/views/library_shell.dart';
import 'package:mpvson/ui/library/views/now_playing_view.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/mini_player_overlay.dart';
import 'package:mpvson/ui/player/views/player_chrome_controller.dart';
import 'package:mpvson/ui/player/views/player_content.dart';
import 'package:mpvson/ui/player/views/player_layout_manager.dart';
import 'package:mpvson/ui/player/views/player_media_coordinator.dart';
import 'package:mpvson/ui/player/views/settings/floating_video_settings.dart';
import 'package:mpvson/ui/player/widgets/player_controls.dart';

import '../../support/fake_playback_service.dart';
import '../../support/library_view_fixtures.dart' hide FakePlaybackService;

class _SpringHarness extends StatefulWidget {
  const _SpringHarness({
    required this.onReady,
    this.speed = AnimationSpeed.normal,
    this.reduceMotion = false,
  });

  final void Function(_SpringHarnessState state) onReady;
  final AnimationSpeed speed;
  final bool reduceMotion;

  @override
  State<_SpringHarness> createState() => _SpringHarnessState();
}

class _SpringHarnessState extends State<_SpringHarness>
    with SingleTickerProviderStateMixin {
  final List<bool> animatingEvents = <bool>[];
  int completedCount = 0;
  int dismissedCount = 0;

  late final SpringMotionController motion = SpringMotionController(
    vsync: this,
    initialForward: false,
    forwardSpring: AppMotion.dockSpring,
    reverseSpring: AppMotion.dockExpandSpring,
    tolerance: const Tolerance(distance: 0.002, velocity: 0.01),
    onAnimatingChanged: animatingEvents.add,
    onCompleted: () => completedCount++,
    onDismissed: () => dismissedCount++,
  );

  @override
  void initState() {
    super.initState();
    widget.onReady(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    motion.applyMotion(context);
  }

  @override
  void didUpdateWidget(covariant _SpringHarness oldWidget) {
    super.didUpdateWidget(oldWidget);
    motion.applyMotion(context);
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: motion.progress,
      builder: (context, _) => const SizedBox.expand(),
    );
  }
}

class _DockRepoHost extends StatefulWidget {
  const _DockRepoHost({
    required this.controller,
    required this.repository,
    required this.recordedConstraints,
  });

  final PlayerController controller;
  final FakeMediaLibraryRepository repository;
  final List<BoxConstraints> recordedConstraints;

  @override
  State<_DockRepoHost> createState() => _DockRepoHostState();
}

class _DockRepoHostState extends State<_DockRepoHost> {
  bool _showLibrary = false;

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
    _playerFocus = FocusNode(debugLabel: 'opt test player');
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
          libraryRepository: widget.repository,
          updates: _updates,
          engineUpdates: _engineUpdates,
          appPreferences: null,
          desktopIntegration: null,
          videoBuilder: (context, controller) {
            return LayoutBuilder(
              builder: (context, constraints) {
                widget.recordedConstraints.add(constraints);
                return const ColoredBox(color: Color(0xFF102030));
              },
            );
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

class _PolicyRecordingPlaybackService extends FakePlaybackService {
  VideoOutputPolicy _policy = const VideoOutputPolicy();
  final List<VideoOutputPolicy> appliedPolicies = <VideoOutputPolicy>[];

  @override
  VideoOutputPolicy get videoOutputPolicy => _policy;

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    _policy = policy;
    appliedPolicies.add(policy);
  }
}

Future<(PlayerController, FakePlaybackService, Directory)>
_createControllerHarness({FakePlaybackService? service}) async {
  final dir = await Directory.systemTemp.createTemp('mpvson_anim_opt_');
  final playback = service ?? FakePlaybackService();
  final sessions = SessionRepository(
    directory: dir,
    encoder: (session) => jsonEncode(session.toJson()),
  );
  final controller = PlayerController(playback: playback, sessions: sessions);
  await controller.initialize();
  return (controller, playback, dir);
}

Future<void> _disposeControllerHarness(
  WidgetTester tester,
  PlayerController controller,
  FakePlaybackService playback,
  Directory dir,
) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 6));
  await tester.runAsync(() async {
    await controller.close(discard: true);
    controller.dispose();
    await playback.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpringMotionController', () {
    testWidgets(
      'preserves continuous motion across mid-flight reversal and notifies cleanly',
      (tester) async {
        late _SpringHarnessState harness;

        await tester.pumpWidget(
          MaterialApp(
            home: AppPreferencesScope(
              preferences: const DesktopPreferences(),
              child: _SpringHarness(onReady: (s) => harness = s),
            ),
          ),
        );

        unawaited(harness.motion.drive(true));
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final vMid = harness.motion.value;
        expect(vMid, greaterThan(0.05));
        expect(vMid, lessThan(0.95));

        // Reverse mid-flight; momentum should keep trajectory continuous
        // without jumping straight to 0 or triggering completed/dismissed prematurely.
        unawaited(harness.motion.drive(false));
        await tester.pump(const Duration(milliseconds: 16));
        final vAfterReverse = harness.motion.value;
        expect((vAfterReverse - vMid).abs(), lessThan(0.25));
        expect(harness.completedCount, 0);
        expect(harness.dismissedCount, 0);

        await tester.pumpAndSettle();
        expect(harness.motion.value, 0.0);
        expect(harness.dismissedCount, 1);
        expect(harness.animatingEvents, <bool>[true, false]);
      },
    );

    testWidgets(
      'scales spring stiffness with AnimationSpeed and snaps instantly on reduceMotion',
      (tester) async {
        late _SpringHarnessState fastHarness;
        late _SpringHarnessState slowHarness;

        Widget buildScoped({
          required AnimationSpeed speed,
          required bool reduce,
          required void Function(_SpringHarnessState) onReady,
        }) {
          return MaterialApp(
            home: AppPreferencesScope(
              preferences: DesktopPreferences(
                animationSpeed: speed,
                reduceMotion: reduce,
              ),
              child: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduce),
                  child: _SpringHarness(
                    speed: speed,
                    reduceMotion: reduce,
                    onReady: onReady,
                  ),
                ),
              ),
            ),
          );
        }

        await tester.pumpWidget(
          buildScoped(
            speed: AnimationSpeed.fast,
            reduce: false,
            onReady: (s) => fastHarness = s,
          ),
        );
        unawaited(fastHarness.motion.drive(true));
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final fastProgressAt96ms = fastHarness.motion.value;

        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          buildScoped(
            speed: AnimationSpeed.slow,
            reduce: false,
            onReady: (s) => slowHarness = s,
          ),
        );
        unawaited(slowHarness.motion.drive(true));
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final slowProgressAt96ms = slowHarness.motion.value;

        expect(fastProgressAt96ms, greaterThan(slowProgressAt96ms + 0.1));

        // Flipping reduceMotion ON mid-flight must snap immediately to target.
        await tester.pumpWidget(
          buildScoped(
            speed: AnimationSpeed.slow,
            reduce: true,
            onReady: (_) {},
          ),
        );
        await tester.pump();
        expect(slowHarness.motion.value, 1.0);
        expect(slowHarness.motion.isAnimating, isFalse);
      },
    );
  });

  group('Zero-relayout GPU dock/undock and zero-remount chrome', () {
    testWidgets(
      'keeps chrome elements identical during dock fade and avoids per-frame PlayerStage relayouts',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        late PlayerController controller;
        late FakePlaybackService playback;
        late Directory dir;
        late File videoFile;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createControllerHarness();
          videoFile = await File(
            '${dir.path}${Platform.pathSeparator}sample.mp4',
          ).writeAsBytes(const <int>[0, 1, 2, 3]);
          await controller.openPaths([videoFile.path]);
        });
        await tester.pump();
        await tester.runAsync(() => controller.togglePlayPause());
        await tester.pump();

        final repo = FakeMediaLibraryRepository();
        final recordedConstraints = <BoxConstraints>[];
        addTearDown(() async {
          await repo.dispose();
          await _disposeControllerHarness(tester, controller, playback, dir);
        });

        await tester.pumpWidget(
          _DockRepoHost(
            controller: controller,
            repository: repo,
            recordedConstraints: recordedConstraints,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PlayerControls), findsOneWidget);
        expect(find.byType(PlayerTopBar), findsOneWidget);

        // Start docking to the library with a real FakeMediaLibraryRepository present.
        final host = tester.state<_DockRepoHostState>(
          find.byType(_DockRepoHost),
        );
        host.setShowLibrary(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        // Capture elements & constraint count once the dock Stack flight starts.
        expect(find.byType(PlayerControls), findsOneWidget);
        expect(find.byType(PlayerTopBar), findsOneWidget);
        final controlsElement = tester.element(find.byType(PlayerControls));
        final topBarElement = tester.element(find.byType(PlayerTopBar));
        final constraintsCountAfterFlightStart = recordedConstraints.length;

        // Cross the chrome inertness threshold (~4.5% dock progress) without
        // remounting PlayerControls or PlayerTopBar, and without relaying out videoBuilder.
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (find.byType(PlayerControls).evaluate().isNotEmpty) {
            expect(
              identical(
                tester.element(find.byType(PlayerControls)),
                controlsElement,
              ),
              isTrue,
            );
          }
          if (find.byType(PlayerTopBar).evaluate().isNotEmpty) {
            expect(
              identical(
                tester.element(find.byType(PlayerTopBar)),
                topBarElement,
              ),
              isTrue,
            );
          }
          expect(recordedConstraints.length, constraintsCountAfterFlightStart);
        }

        // Pump the remaining flight frames before settling at t == 1.0.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(recordedConstraints.length, constraintsCountAfterFlightStart);
        }

        // Settling into miniRect triggers exactly one final layout pass.
        await tester.pumpAndSettle();
        expect(
          recordedConstraints.length,
          greaterThan(constraintsCountAfterFlightStart),
        );
        expect(recordedConstraints.last.maxWidth, lessThan(300));
        expect(find.byType(PlayerControls), findsNothing);
        expect(find.byType(PlayerTopBar), findsNothing);
        expect(find.byType(MiniPlayerOverlay), findsOneWidget);

        // Tapping MiniPlayerOverlay expands smoothly with zero per-frame relayouts in flight.
        await tester.tap(find.byType(MiniPlayerOverlay));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final constraintsCountAfterUndockStart = recordedConstraints.length;

        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(recordedConstraints.length, constraintsCountAfterUndockStart);
        }

        await tester.pumpAndSettle();
        expect(find.byType(MiniPlayerOverlay), findsNothing);
        expect(find.byType(PlayerControls), findsOneWidget);
        expect(recordedConstraints.last.maxWidth, 1280);
      },
    );
  });

  group('BackdropFilter & panel identity stability', () {
    testWidgets(
      'toggling Play/Pause adds/removes BackdropFilter without remounting buttons or seek bar',
      (tester) async {
        final previousProfile = AppMotion.hardwareProfile;
        AppMotion.updateHardwareProfile(
          const HardwareProfile(tier: HardwareTier.balanced, cpuCount: 8),
        );
        addTearDown(() => AppMotion.updateHardwareProfile(previousProfile));

        late PlayerController controller;
        late FakePlaybackService playback;
        late Directory dir;
        late File videoFile;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createControllerHarness();
          videoFile = await File(
            '${dir.path}${Platform.pathSeparator}sample.mp4',
          ).writeAsBytes(const <int>[0, 1, 2, 3]);
          await controller.openPaths([videoFile.path]);
        });
        addTearDown(() async {
          await _disposeControllerHarness(tester, controller, playback, dir);
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: AppPreferencesScope(
              preferences: const DesktopPreferences(),
              child: MediaAccentScope(
                controller: controller,
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedBuilder(
                      animation: Listenable.merge(<Listenable>[
                        controller.transportListenable,
                        controller.structureListenable,
                      ]),
                      builder: (context, _) => PlayerControls(
                        controller: controller,
                        preferences: const PlayerControlsPreferences(
                          barStyle: PlayerControlBarStyle.floatingPill,
                          enableBlur: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(controller.isPlaying, isTrue);
        expect(find.byType(BackdropFilter), findsNothing);

        final playIconBefore = tester.element(find.byType(AnimatedIcon).first);
        final seekBarBefore = tester.element(find.byType(SharedSeekBar));

        // Pause -> BackdropFilter activates in sibling Stack layer; children stay identical.
        await tester.runAsync(() => controller.togglePlayPause());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(controller.isPlaying, isFalse);
        expect(find.byType(BackdropFilter), findsOneWidget);
        expect(
          identical(
            tester.element(find.byType(AnimatedIcon).first),
            playIconBefore,
          ),
          isTrue,
        );
        expect(
          identical(tester.element(find.byType(SharedSeekBar)), seekBarBefore),
          isTrue,
        );

        // Resume play -> BackdropFilter deactivates cleanly; children still identical.
        await tester.runAsync(() => controller.togglePlayPause());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(controller.isPlaying, isTrue);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(
          identical(
            tester.element(find.byType(AnimatedIcon).first),
            playIconBefore,
          ),
          isTrue,
        );
        expect(
          identical(tester.element(find.byType(SharedSeekBar)), seekBarBefore),
          isTrue,
        );
      },
    );

    testWidgets(
      'FloatingVideoSettings keeps slide transform and inner panel mounted when settled',
      (tester) async {
        late PlayerController controller;
        late FakePlaybackService playback;
        late Directory dir;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createControllerHarness();
        });
        addTearDown(() async {
          await _disposeControllerHarness(tester, controller, playback, dir);
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: AppPreferencesScope(
              preferences: const DesktopPreferences(),
              child: Scaffold(
                body: FloatingVideoSettings(
                  controller: controller,
                  pickSubtitle: () async => null,
                  onClose: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 32));

        final slideFinder = find.byKey(
          const ValueKey('floating-settings-slide'),
        );
        final titleFinder = find.text('Video Settings');
        expect(slideFinder, findsOneWidget);
        expect(titleFinder, findsOneWidget);

        final slideMidFlight = tester.element(slideFinder);
        final titleMidFlight = tester.element(titleFinder);

        await tester.pumpAndSettle();

        expect(identical(tester.element(slideFinder), slideMidFlight), isTrue);
        expect(identical(tester.element(titleFinder), titleMidFlight), isTrue);
      },
    );
  });

  group('LibraryShell Now Playing morph & navigation', () {
    testWidgets(
      'opens, reverses mid-flight, and closes Now Playing without exceptions',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        late PlayerController controller;
        late FakePlaybackService playback;
        late Directory dir;
        late File audioFile;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createControllerHarness();
          audioFile = await File(
            '${dir.path}${Platform.pathSeparator}track.mp3',
          ).writeAsBytes(const <int>[0, 1, 2, 3]);
          await controller.openPaths([audioFile.path]);
        });
        await tester.pump();
        await tester.runAsync(() => controller.togglePlayPause());
        await tester.pump();

        final repo = FakeMediaLibraryRepository();
        addTearDown(() async {
          await repo.dispose();
          await _disposeControllerHarness(tester, controller, playback, dir);
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: AppToastHost(
              child: AppPreferencesScope(
                preferences: const DesktopPreferences(),
                child: MediaAccentScope(
                  controller: controller,
                  child: LibraryShell(
                    repository: repo,
                    controller: controller,
                    home: HomeView(
                      repository: repo,
                      controller: controller,
                      recent: const [],
                      onOpenFiles: () {},
                      onOpenUrl: () {},
                      onOpenRecent: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(NowPlayingView), findsNothing);
        expect(find.byTooltip('Open Now Playing'), findsWidgets);

        // Open Now Playing via the mini player bar.
        await tester.tap(find.byTooltip('Open Now Playing').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 64));
        expect(tester.takeException(), isNull);
        expect(find.byType(NowPlayingView), findsOneWidget);

        // Reverse mid-flight using Back to library button.
        await tester.tap(find.byTooltip('Back to library'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 64));
        expect(tester.takeException(), isNull);

        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(NowPlayingView), findsNothing);

        // Open fully to settlement, then close cleanly.
        await tester.tap(find.byTooltip('Open Now Playing').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(NowPlayingView), findsOneWidget);

        await tester.tap(find.byTooltip('Back to library'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(NowPlayingView), findsNothing);

        // Library tabs remain interactive afterward.
        await tester.tap(find.text('Music'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('VideoOutputPolicy.deferResize & PlayerLayoutManager ref-counting', () {
    test(
      'VideoOutputPolicy copyWith, ==, and hashCode respect deferResize',
      () {
        const a = VideoOutputPolicy(visible: true, physicalWidth: 1920);
        final b = a.copyWith(deferResize: true);
        final c = const VideoOutputPolicy(
          visible: true,
          physicalWidth: 1920,
          deferResize: true,
        );

        expect(a.deferResize, isFalse);
        expect(b.deferResize, isTrue);
        expect(a == b, isFalse);
        expect(b, c);
        expect(b.hashCode, c.hashCode);
        expect(b.copyWith(deferResize: false), a);
      },
    );

    test(
      'PlayerLayoutManager reference-counts active layout transition tokens',
      () async {
        final service = _PolicyRecordingPlaybackService();
        final (controller, _, dir) = await _createControllerHarness(
          service: service,
        );
        final focus = FocusNode();
        final layout = PlayerLayoutManager(
          controller: controller,
          desktopWindow: false,
          isShowingLibrary: () => false,
          showMessage: (_) {},
          showFeedback: (_, _, {centered = false}) {},
          playerFocus: focus,
        );

        final t1 = Object();
        final t2 = Object();

        layout.setLayoutTransitionActive(t1, true);
        expect(service.videoOutputPolicy.deferResize, isTrue);

        layout.setLayoutTransitionActive(t2, true);
        expect(service.videoOutputPolicy.deferResize, isTrue);

        // Releasing only t1 keeps deferResize true because t2 is still active.
        layout.setLayoutTransitionActive(t1, false);
        expect(service.videoOutputPolicy.deferResize, isTrue);

        // Duplicate release is a no-op; releasing t2 clears deferResize.
        layout.setLayoutTransitionActive(t1, false);
        expect(service.videoOutputPolicy.deferResize, isTrue);

        layout.setLayoutTransitionActive(t2, false);
        expect(service.videoOutputPolicy.deferResize, isFalse);
        expect(
          service.appliedPolicies.map((p) => p.deferResize).toList(),
          <bool>[true, false],
        );

        layout.dispose();
        focus.dispose();
        await controller.close(discard: true);
        controller.dispose();
        await service.dispose();
        if (await dir.exists()) await dir.delete(recursive: true);
      },
    );
  });
}
