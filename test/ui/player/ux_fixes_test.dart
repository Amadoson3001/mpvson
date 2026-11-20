import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/playback_statistics.dart';
import 'package:mpvson/data/services/streaming_coordinator.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/data/services/yt_dlp_resolver.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_chapter.dart';
import 'package:mpvson/domain/models/player_hotkeys.dart';
import 'package:mpvson/domain/models/resolved_stream.dart';
import 'package:mpvson/domain/models/stream_playback_state.dart';
import 'package:mpvson/ui/core/components/seek_bar.dart';
import 'package:mpvson/ui/core/toast/app_toast_host.dart';
import 'package:mpvson/ui/library/views/home_view.dart';
import 'package:mpvson/ui/library/views/library_shell.dart';
import 'package:mpvson/ui/library/views/now_playing_view.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/playback_info_dialog.dart';
import 'package:mpvson/ui/player/views/player_hotkey_handler.dart';
import 'package:mpvson/ui/player/views/player_media_coordinator.dart';
import 'package:mpvson/ui/player/views/player_stage.dart';
import 'package:mpvson/ui/player/views/settings/settings_playback_section.dart';
import 'package:mpvson/ui/player/widgets/open_url_dialog.dart';
import 'package:mpvson/ui/player/widgets/player_control_style.dart';
import 'package:mpvson/ui/player/widgets/player_controls.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_playback_service.dart';
import '../../support/library_view_fixtures.dart'
    show FakeMediaLibraryRepository;

class _TrackingPlaybackService extends FakePlaybackService
    implements FrameStepCapability {
  PlaybackSnapshot _customState = const PlaybackSnapshot();
  final StreamController<PlaybackSnapshot> _customStates =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);

  final List<String> loadedSubtitles = <String>[];
  final List<bool> frameSteps = <bool>[];
  bool holdOpen = false;
  Completer<void>? _openGate;

  @override
  PlaybackSnapshot get state => _customState;

  @override
  Stream<PlaybackSnapshot> get states => _customStates.stream;

  void emitSnapshot(PlaybackSnapshot snapshot) {
    _customState = snapshot;
    _customStates.add(snapshot);
  }

  @override
  Future<void> open(String path, {bool play = true}) async {
    openedPaths.add(path);
    if (!holdOpen) {
      await super.open(path, play: play);
      emitSnapshot(super.state);
      return;
    }
    if (_openGate != null && !_openGate!.isCompleted) {
      _openGate!.complete();
    }
    final gate = Completer<void>();
    _openGate = gate;
    emitSnapshot(
      _customState.copyWith(
        isPlaying: false,
        isBuffering: true,
        sourceLoaded: false,
        clearNativeSource: true,
        sourceStart: _customState.sourceStart + 1,
        clearError: true,
      ),
    );
    await gate.future;
  }

  @override
  Future<void> stop() async {
    if (_openGate != null && !_openGate!.isCompleted) {
      _openGate!.complete();
    }
    _openGate = null;
    await super.stop();
    emitSnapshot(super.state);
  }

  @override
  Future<void> loadSubtitle(String path) async {
    loadedSubtitles.add(path);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    await super.setAudioTrack(track);
    emitSnapshot(super.state);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    await super.setSubtitleTrack(track);
    emitSnapshot(super.state);
  }

  @override
  Future<void> setRate(double value) async {
    await super.setRate(value);
    emitSnapshot(super.state);
  }

  @override
  Future<void> seek(Duration position) async {
    await super.seek(position);
    emitSnapshot(super.state);
  }

  @override
  Future<void> frameStep({required bool forward}) async {
    frameSteps.add(forward);
  }

  @override
  Future<void> dispose() async {
    if (_openGate != null && !_openGate!.isCompleted) {
      _openGate!.complete();
    }
    await _customStates.close();
    await super.dispose();
  }
}

class _FakeYtDlpResolver extends YtDlpResolver {
  _FakeYtDlpResolver(this.streamToReturn);

  final ResolvedStream streamToReturn;

  @override
  bool canResolve(String url) => url.contains('watch');

  @override
  Future<ResolvedStream> resolve(
    String url, {
    Duration timeout = const Duration(seconds: 35),
    CancellationToken? cancelToken,
  }) async => streamToReturn;
}

Future<(PlayerController, _TrackingPlaybackService, Directory)>
_createHarness() async {
  final dir = await Directory.systemTemp.createTemp('mpvson-ux-test-');
  final playback = _TrackingPlaybackService();
  final sessions = SessionRepository(
    directory: dir,
    encoder: (session) => jsonEncode(session.toJson()),
  );
  final controller = PlayerController(playback: playback, sessions: sessions);
  await controller.initialize();
  return (controller, playback, dir);
}

Future<void> _disposeHarness(
  WidgetTester tester,
  PlayerController controller,
  _TrackingPlaybackService playback,
  Directory dir,
) async {
  await tester.runAsync(() async {
    await controller.close(discard: true);
    controller.dispose();
    await playback.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });
}

void main() {
  group('MediaCatalog subtitle extensions', () {
    test('recognizes subtitle files accurately', () {
      expect(MediaCatalog.isSubtitleFile('movie.srt'), isTrue);
      expect(MediaCatalog.isSubtitleFile(r'C:\subs\track.ASS'), isTrue);
      expect(MediaCatalog.isSubtitleFile('captions.vtt'), isTrue);
      expect(MediaCatalog.isSubtitleFile('movie.mp4'), isFalse);
    });
  });

  group('Subtitle drag-and-drop handling', () {
    testWidgets('dropping subtitle loads onto active media and guides when idle', (
      tester,
    ) async {
      late PlayerController controller;
      late _TrackingPlaybackService playback;
      late Directory dir;
      late File videoFile;
      late File subFile;

      await tester.runAsync(() async {
        (controller, playback, dir) = await _createHarness();
        videoFile = File(p.join(dir.path, 'clip.mp4'))..createSync();
        subFile = File(p.join(dir.path, 'clip.srt'))
          ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHi\n');
      });
      addTearDown(() => _disposeHarness(tester, controller, playback, dir));

      late BuildContext capturedContext;
      final updates = UpdateService();
      final engineUpdates = EngineUpdateService();
      addTearDown(() {
        updates.dispose();
        engineUpdates.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: AppToastHost(
            child: Scaffold(
              body: Builder(
                builder: (ctx) {
                  capturedContext = ctx;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      final media = PlayerMediaCoordinator(
        getContext: () => capturedContext,
        controller: controller,
        updates: updates,
        engineUpdates: engineUpdates,
        showMessage: (_) {},
        withControlsVisible: <T>(action) => action(),
        onCloseContextMenu: () {},
        onOpenLibrary: () {},
        onClearFocusedQueueEntry: () {},
      );

      // Idle: dropping only a subtitle file shows guidance instead of queuing it.
      await tester.runAsync(() => media.handleDroppedPaths([subFile.path]));
      await tester.pump();
      expect(controller.queue, isEmpty);
      expect(playback.loadedSubtitles, isEmpty);
      expect(find.text('Open a video first to load subtitles.'), findsOne);

      // Open video, then drop subtitle -> attaches subtitle without replacing queue.
      await tester.runAsync(() => controller.openPaths([videoFile.path]));
      await tester.pump();
      await tester.runAsync(() => media.handleDroppedPaths([subFile.path]));
      await tester.pump();
      expect(controller.queue.length, 1);
      expect(playback.loadedSubtitles, [subFile.path]);
      expect(find.text('Subtitle loaded'), findsOne);
    });
  });

  group('Live stream UI', () {
    testWidgets(
      'TimeReadout and SeekBar render Live instead of --:-- or 0:00',
      (tester) async {
        late PlayerController controller;
        late _TrackingPlaybackService playback;
        late Directory dir;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createHarness();
        });
        addTearDown(() => _disposeHarness(tester, controller, playback, dir));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const TimeReadout(
                    position: Duration(seconds: 42),
                    duration: Duration.zero,
                    isLive: true,
                  ),
                  SeekBar(controller: controller),
                ],
              ),
            ),
          ),
        );

        expect(find.text('Live  00:42'), findsOneWidget);
        expect(find.text('--:--'), findsNothing);

        playback.emitSnapshot(
          playback.state.copyWith(
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: 'https://example.com/live.m3u8',
              stage: StreamStage.ready,
              isLive: true,
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Live'), findsOneWidget);
        expect(find.text('0:00'), findsOneWidget); // left elapsed position only
      },
    );
  });

  group('Home search & network stream badges', () {
    testWidgets(
      'Ctrl+F focuses Home search, filters recents & library matches, Esc clears',
      (tester) async {
        late PlayerController controller;
        late _TrackingPlaybackService playback;
        late Directory dir;
        final repo = FakeMediaLibraryRepository(
          items: [
            MediaItemRecord(
              id: 'lib-1',
              canonicalSource: r'C:\Videos\cosmic_nebula.mp4',
              path: r'C:\Videos\cosmic_nebula.mp4',
              kind: MediaKind.video,
              addedAt: DateTime(2026),
            ),
          ],
        );
        await tester.runAsync(() async {
          await repo.initialize();
          (controller, playback, dir) = await _createHarness();
        });
        addTearDown(() async {
          await repo.dispose();
          await _disposeHarness(tester, controller, playback, dir);
        });

        final recents = [
          MediaEntry(
            id: 'r1',
            path: r'C:\Videos\holiday_vlog.mp4',
            title: 'Holiday Vlog',
            lastPlayed: DateTime(2026),
          ),
          MediaEntry(
            id: 'r2',
            path: 'https://example.com/live/concert.m3u8',
            title: 'Cosmic Concert Stream',
            lastPlayed: DateTime(2026),
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: AppToastHost(
              child: LibraryShell(
                repository: repo,
                controller: controller,
                home: HomeView(
                  recent: recents,
                  repository: repo,
                  controller: controller,
                  onOpenFiles: () {},
                  onOpenUrl: () {},
                  onOpenRecent: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const ValueKey('home-search-field')), findsOneWidget);
        expect(find.byKey(const ValueKey('recent-stream-badge-r2')), findsOne);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        final searchEditable = find.descendant(
          of: find.byKey(const ValueKey('home-search-field')),
          matching: find.byType(EditableText),
        );
        expect(
          tester.widget<EditableText>(searchEditable).focusNode.hasFocus,
          isTrue,
        );

        await tester.enterText(
          find.byKey(const ValueKey('home-search-field')),
          'cosmic',
        );
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pump();

        expect(find.text('Cosmic Concert Stream'), findsOneWidget);
        expect(find.text('Holiday Vlog'), findsNothing);
        expect(find.text('Library matches'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.text('Holiday Vlog'), findsOneWidget);
      },
    );
  });

  group('Clear-queue Undo', () {
    testWidgets(
      'clearQueue enables canUndo and undoRemove restores all entries',
      (tester) async {
        late PlayerController controller;
        late _TrackingPlaybackService playback;
        late Directory dir;
        late File f1;
        late File f2;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createHarness();
          f1 = File(p.join(dir.path, 'alpha.mp4'))..createSync();
          f2 = File(p.join(dir.path, 'beta.mp4'))..createSync();
          await controller.openPaths([f1.path, f2.path]);
        });
        addTearDown(() => _disposeHarness(tester, controller, playback, dir));

        expect(controller.queue.length, 2);
        await tester.runAsync(() => controller.clearQueue());
        expect(controller.queue, isEmpty);
        expect(controller.canUndo, isTrue);

        await tester.runAsync(() => controller.undoRemove());
        expect(controller.queue.length, 2);
        expect(controller.canUndo, isFalse);
        expect(controller.current?.title, 'alpha');
      },
    );
  });

  group('Hotkeys & Hold-Space 2x pill', () {
    test(
      'PlayerHotkeys.defaults has zero collisions and handles upgrade JSON',
      () {
        final hotkeys = PlayerHotkeys.defaults;
        for (final action in PlayerAction.values) {
          final binding = hotkeys.bindingFor(action);
          expect(
            hotkeys.actionBoundTo(binding, excluding: action),
            isNull,
            reason: '$action collided on ${binding.label}',
          );
        }

        // Round-trip
        final restored = PlayerHotkeys.fromJson(hotkeys.toJson());
        for (final action in PlayerAction.values) {
          expect(restored.bindingFor(action), hotkeys.bindingFor(action));
        }

        // Upgrade collision safety: older config bound mute to S
        final upgraded = PlayerHotkeys.fromJson(<String, Object?>{
          'mute': HotkeyBinding.key(LogicalKeyboardKey.keyS).toJson(),
        });
        expect(
          upgraded.actionBoundTo(
            upgraded.bindingFor(PlayerAction.screenshot),
            excluding: PlayerAction.screenshot,
          ),
          isNull,
        );
      },
    );

    testWidgets(
      'hold Space triggers 2x OSD pill callback and new actions invoke handlers',
      (tester) async {
        late PlayerController controller;
        late _TrackingPlaybackService playback;
        late Directory dir;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createHarness();
        });
        addTearDown(() => _disposeHarness(tester, controller, playback, dir));

        final holdStates = <bool>[];
        var nextCalls = 0;
        var prevCalls = 0;
        var cycleSubCalls = 0;
        var cycleAudioCalls = 0;
        final speedDeltas = <double>[];
        var speedResets = 0;
        final frameSteps = <bool>[];
        var screenshots = 0;

        final handler = PlayerHotkeyHandler(
          controller: controller,
          getHotkeys: () => PlayerHotkeys.defaults,
          isQueueOpen: () => false,
          isContextMenuOpen: () => false,
          isFullscreen: () => false,
          isDesktopWindow: true,
          isNativeWindow: true,
          hasLibraryRepository: true,
          getSeekStepSeconds: () => 5,
          getFocusedQueueEntryId: () => null,
          isControlsFocusActive: () => false,
          isQueueFocusActive: () => false,
          isInsidePlayer: (_) => true,
          onCloseContextMenu: () {},
          onCloseQueue: () {},
          onToggleQueue: () {},
          onOpenContextMenu: () {},
          onToggleFullscreen: () {},
          onSetFullscreen: (_) async {},
          onToggleMiniPlayer: () {},
          onOpenFiles: () {},
          onOpenUrl: () {},
          onOpenLibrary: () {},
          onRemoveQueueEntry: (_) async {},
          onAdjustVolume: (_) {},
          onToggleMute: () {},
          onAdjustDelay: ({required audio, required later}) async {},
          onShowPlaybackInfo: () {},
          onShowControls: () {},
          onHoldSpeedChanged: holdStates.add,
          onNextTrack: () => nextCalls++,
          onPreviousTrack: () => prevCalls++,
          onCycleSubtitle: () => cycleSubCalls++,
          onCycleAudio: () => cycleAudioCalls++,
          onAdjustSpeed: speedDeltas.add,
          onResetSpeed: () => speedResets++,
          onFrameStep: frameSteps.add,
          onScreenshot: () => screenshots++,
        );
        addTearDown(handler.dispose);

        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Focus(
              focusNode: focusNode,
              autofocus: true,
              onKeyEvent: handler.handleKey,
              child: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump();

        // Hold Space > 180ms -> release
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 220));
        expect(holdStates, [true]);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(holdStates, [true, false]);

        // New hotkeys
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.sendKeyEvent(LogicalKeyboardKey.minus);
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.sendKeyEvent(LogicalKeyboardKey.period);
        await tester.sendKeyEvent(LogicalKeyboardKey.comma);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.pump();

        expect(nextCalls, 1);
        expect(prevCalls, 1);
        expect(cycleSubCalls, 1);
        expect(cycleAudioCalls, 1);
        expect(speedDeltas, [0.25, -0.25]);
        expect(speedResets, 1);
        expect(frameSteps, [true, false]);
        expect(screenshots, 1);
      },
    );

    testWidgets(
      'PlayerStage displays hold-speed-pill when holdSpeedActive is true',
      (tester) async {
        late PlayerController controller;
        late _TrackingPlaybackService playback;
        late Directory dir;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createHarness();
        });
        addTearDown(() => _disposeHarness(tester, controller, playback, dir));

        final controlsScope = FocusScopeNode();
        addTearDown(controlsScope.dispose);
        final menuController = MenuController();
        final surfaceKey = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            home: AppToastHost(
              child: Scaffold(
                body: PlayerStage(
                  controller: controller,
                  videoBuilder: (_, _) => const SizedBox.shrink(),
                  contextMenu: menuController,
                  videoSurfaceKey: surfaceKey,
                  controlsFocusScope: controlsScope,
                  controlsVisible: true,
                  controlMenuOpen: false,
                  draggingFiles: false,
                  feedbackLabel: null,
                  feedbackIcon: Icons.volume_up_rounded,
                  feedbackProgress: null,
                  feedbackCentered: false,
                  isFullscreen: false,
                  isMiniPlayer: false,
                  queueOpen: false,
                  desktopWindow: true,
                  nativeWindow: true,
                  hasLibraryRepository: true,
                  hotkeys: PlayerHotkeys.defaults,
                  holdSpeedActive: true,
                  onPointerSignal: (_) {},
                  onVideoTap: () {},
                  onVideoDoubleTap: () {},
                  onControlsPointerEnter: (_) {},
                  onControlsPointerExit: (_) {},
                  onMenuVisibilityChanged: (_) {},
                  onControlInteractionChanged: (_) {},
                  onVolumeChanged: (_) {},
                  onBackToHome: () {},
                  onExitMiniPlayer: () {},
                  onTopBarFocusChange: (_) {},
                  onOpenFiles: () {},
                  onOpenUrl: () {},
                  onOpenRecent: (_) {},
                  onToggleQueue: () {},
                  onSettings: ({bool showMediaLibrary = false}) async {},
                  onPlaybackInfo: () async {},
                  onOpenLibrary: () {},
                  onFullscreen: () {},
                  onToggleMiniPlayer: () {},
                  onLoadSubtitle: () async {},
                  onToggleMute: () {},
                  onAdjustVolume: (_) {},
                  onUpdateViewportDimensions: (_, _) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byKey(const ValueKey('hold-speed-pill')), findsOneWidget);
        expect(find.text('2×'), findsOneWidget);
      },
    );
  });

  group('TracksMenu & ChaptersMenu', () {
    testWidgets('TracksMenu switches subtitles and triggers external loader', (
      tester,
    ) async {
      late PlayerController controller;
      late _TrackingPlaybackService playback;
      late Directory dir;

      await tester.runAsync(() async {
        (controller, playback, dir) = await _createHarness();
      });
      addTearDown(() => _disposeHarness(tester, controller, playback, dir));

      playback.emitSnapshot(
        playback.state.copyWith(
          subtitleTracks: const [SubtitleTrack('sub1', 'English', 'eng')],
          audioTracks: const [AudioTrack('aud1', 'Japanese', 'jpn')],
        ),
      );

      var externalLoadCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControlStyle(
              compact: false,
              child: TracksMenu(
                controller: controller,
                onMenuVisibilityChanged: (_) {},
                onLoadSubtitle: () => externalLoadCalls++,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('tracks-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English (eng)'));
      await tester.pumpAndSettle();
      expect(controller.currentSubtitleTrack.id, 'sub1');

      await tester.tap(find.byKey(const ValueKey('tracks-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load external subtitle…'));
      await tester.pumpAndSettle();
      expect(externalLoadCalls, 1);
    });

    testWidgets('ChaptersMenu hides when empty and seeks when chapter chosen', (
      tester,
    ) async {
      late PlayerController controller;
      late _TrackingPlaybackService playback;
      late Directory dir;
      late File videoFile;

      await tester.runAsync(() async {
        (controller, playback, dir) = await _createHarness();
        videoFile = File(p.join(dir.path, 'chapters.mp4'))..createSync();
        await controller.openPaths([videoFile.path]);
      });
      addTearDown(() => _disposeHarness(tester, controller, playback, dir));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerControlStyle(
              compact: false,
              child: ChaptersMenu(
                controller: controller,
                onMenuVisibilityChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('chapters-menu-button')), findsNothing);

      playback.emitSnapshot(
        playback.state.copyWith(
          chapters: const [
            PlaybackChapter(title: 'Intro', start: Duration.zero),
            PlaybackChapter(title: 'Chorus', start: Duration(seconds: 60)),
          ],
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('chapters-menu-button')), findsOne);

      await tester.tap(find.byKey(const ValueKey('chapters-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chorus'));
      await tester.pumpAndSettle();
      expect(controller.position, const Duration(seconds: 60));
    });
  });

  group('OpenUrlDialog clipboard, recent & enqueue', () {
    testWidgets(
      'shows clipboard chip, recent streams, and Add to queue result',
      (tester) async {
        Object? poppedResult;
        final recent = [
          MediaEntry(
            id: 'net1',
            path: 'https://cdn.example.com/live.m3u8?token=secret',
            title: 'Live Event',
            lastPlayed: DateTime(2026),
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () async {
                    poppedResult = await OpenUrlDialog.show(
                      ctx,
                      allowEnqueue: true,
                      recentUrls: recent,
                      readClipboard: () async =>
                          'https://video.example.org/watch',
                    );
                  },
                  child: const Text('Launch'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Launch'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('open-url-clipboard-chip')),
          findsOneWidget,
        );
        expect(find.text('Recent streams'), findsOneWidget);
        expect(find.text('Live Event'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('open-url-clipboard-chip')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('open-url-enqueue')));
        await tester.pumpAndSettle();

        expect(poppedResult, isA<OpenUrlResult>());
        final result = poppedResult! as OpenUrlResult;
        expect(result.url, 'https://video.example.org/watch');
        expect(result.enqueue, isTrue);
      },
    );
  });

  group('Streaming preferences, yt-dlp settings & PlaybackInfoDialog', () {
    test(
      'StreamingCoordinator picks PreferredStreamQuality.p720 and .best',
      () async {
        final coordinator = StreamingCoordinator(
          ytDlpResolver: _FakeYtDlpResolver(
            ResolvedStream(
              originalUrl: 'https://site.test/watch?v=1',
              streamUrl: 'https://cdn.test/720.mp4',
              title: 'Sample Video',
              renditions: const [
                StreamRendition(
                  id: '360',
                  label: '360p',
                  height: 360,
                  bitrate: 800000,
                  url: 'https://cdn.test/360.mp4',
                ),
                StreamRendition(
                  id: '720',
                  label: '720p',
                  height: 720,
                  bitrate: 2500000,
                  url: 'https://cdn.test/720.mp4',
                ),
                StreamRendition(
                  id: '1080',
                  label: '1080p',
                  height: 1080,
                  bitrate: 5000000,
                  url: 'https://cdn.test/1080.mp4',
                ),
              ],
            ),
          ),
        );
        addTearDown(coordinator.dispose);

        coordinator.configureStreamingPreferences(
          preferredQuality: PreferredStreamQuality.p720,
        );
        final p720 = await coordinator.prepareStream(
          'https://site.test/watch?v=1',
        );
        expect(p720?.selectedRendition?.id, '720');
        expect(p720?.isAutoQuality, isFalse);
        expect(p720?.playableUrl, 'https://cdn.test/720.mp4');

        coordinator.configureStreamingPreferences(
          preferredQuality: PreferredStreamQuality.best,
        );
        final best = await coordinator.prepareStream(
          'https://site.test/watch?v=1',
        );
        expect(best?.selectedRendition?.id, '1080');
        expect(best?.playableUrl, 'https://cdn.test/1080.mp4');
      },
    );

    testWidgets(
      'PlaybackSettingsSection displays yt-dlp status and updates quality',
      (tester) async {
        late PlayerController controller;
        late _TrackingPlaybackService playback;
        late Directory dir;
        late AppPreferencesRepository prefs;

        await tester.runAsync(() async {
          (controller, playback, dir) = await _createHarness();
          prefs = AppPreferencesRepository(
            preferenceFile: File(p.join(dir.path, 'prefs.json')),
          );
          await prefs.load();
        });
        addTearDown(() async {
          prefs.dispose();
          await _disposeHarness(tester, controller, playback, dir);
        });

        await tester.pumpWidget(
          MaterialApp(
            home: AppToastHost(
              child: Scaffold(
                body: SingleChildScrollView(
                  child: PlaybackSettingsSection(
                    controller: controller,
                    pickSubtitle: () async => null,
                    appPreferences: prefs,
                    checkYtDlpStatus: (_) async => const YtDlpStatus(
                      availability: YtDlpAvailability.available,
                      version: '2026.01.15',
                      executablePath: r'C:\tools\yt-dlp.exe',
                    ),
                    pickYtDlpExecutable: () async => r'C:\custom\yt-dlp.exe',
                    onOpenAppFolder: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Streaming & yt-dlp'), findsOneWidget);
        expect(find.text('Detected (2026.01.15)'), findsOneWidget);
        expect(find.text(r'C:\tools\yt-dlp.exe'), findsOneWidget);

        await tester.ensureVisible(find.byKey(const ValueKey('yt-dlp-choose')));
        await tester.tap(find.byKey(const ValueKey('yt-dlp-choose')));
        await tester.pumpAndSettle();
        expect(prefs.preferences.ytDlpPath, r'C:\custom\yt-dlp.exe');
      },
    );

    testWidgets('PlaybackInfoDialog copies formatted diagnostics', (
      tester,
    ) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AppToastHost(
            child: Scaffold(
              body: PlaybackInfoDialog(
                readStatistics: () async => const PlaybackStatistics({
                  'Playback engine': 'mpv test',
                  'Stream stage': 'ready',
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('playback-info-copy')));
      await tester.pump();

      expect(copiedText, 'Playback engine: mpv test\nStream stage: ready');
      expect(find.text('Copied'), findsOneWidget);
    });
  });

  group('NowPlayingView loading state', () {
    testWidgets('shows stream loading status and cancels cleanly', (
      tester,
    ) async {
      late PlayerController controller;
      late _TrackingPlaybackService playback;
      late Directory dir;
      late File track;

      await tester.runAsync(() async {
        (controller, playback, dir) = await _createHarness();
        playback.holdOpen = true;
        track = File(p.join(dir.path, 'song.mp3'))..createSync();
      });
      addTearDown(() => _disposeHarness(tester, controller, playback, dir));

      await tester.pumpWidget(
        MaterialApp(
          home: AppToastHost(child: NowPlayingView(controller: controller)),
        ),
      );

      await tester.runAsync(() async {
        unawaited(controller.openPaths([track.path]));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();

      expect(find.byKey(const ValueKey('now-playing-status')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('now-playing-cancel-load')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('now-playing-cancel-load')));
      await tester.pump();
      expect(controller.isLoading, isFalse);
      expect(find.byKey(const ValueKey('now-playing-status')), findsNothing);
    });
  });
}
