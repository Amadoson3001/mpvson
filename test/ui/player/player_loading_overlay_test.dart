import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/native_media_events.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/streaming_coordinator.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/player_hotkeys.dart';
import 'package:mpvson/domain/models/stream_playback_state.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/player_hotkey_handler.dart';
import 'package:mpvson/ui/player/views/player_loading_overlay.dart';
import 'package:mpvson/ui/player/widgets/controls/seek_bar_section.dart';
import 'package:mpvson/ui/player/widgets/open_url_dialog.dart';
import 'package:mpvson/ui/player/widgets/player_control_style.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_playback_service.dart';

class _HoldOpenPlaybackService extends FakePlaybackService {
  PlaybackSnapshot _customState = const PlaybackSnapshot();
  final StreamController<PlaybackSnapshot> _customStates =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);

  bool holdOpen = false;
  Completer<void>? _openGate;
  int stopCalls = 0;

  @override
  PlaybackSnapshot get state => _customState;

  @override
  Stream<PlaybackSnapshot> get states => _customStates.stream;

  void _completeIfPending(Completer<void>? completer) {
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void emitSnapshot(PlaybackSnapshot snapshot) {
    _customState = snapshot;
    _customStates.add(snapshot);
  }

  void finishHeldOpen({required String path, bool play = true}) {
    emitSnapshot(
      _customState.copyWith(
        isPlaying: play,
        isBuffering: false,
        sourceLoaded: true,
        nativeSource: MediaEntry.canonicalSource(path),
        duration: const Duration(minutes: 2),
      ),
    );
    _completeIfPending(_openGate);
    _openGate = null;
  }

  @override
  Future<void> open(String path, {bool play = true}) async {
    openedPaths.add(path);
    if (!holdOpen) {
      await super.open(path, play: play);
      emitSnapshot(super.state);
      return;
    }
    _completeIfPending(_openGate);
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
    stopCalls++;
    _completeIfPending(_openGate);
    _openGate = null;
    await super.stop();
    emitSnapshot(
      super.state.copyWith(
        clearError: true,
        streamPlaybackState: const StreamPlaybackState(),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _completeIfPending(_openGate);
    _openGate = null;
    await _customStates.close();
    await super.dispose();
  }
}

(PlayerController, _HoldOpenPlaybackService, Directory) _createSyncHarness() {
  final dir = Directory.systemTemp.createTempSync('mpvson-load-widget-test-');
  final playback = _HoldOpenPlaybackService();
  final sessions = SessionRepository(
    directory: dir,
    encoder: (session) => session.toJson().toString(),
  );
  final controller = PlayerController(playback: playback, sessions: sessions);
  return (controller, playback, dir);
}

Future<(PlayerController, _HoldOpenPlaybackService, Directory)>
_createHarness() async {
  final dir = await Directory.systemTemp.createTemp('mpvson-load-test-');
  final playback = _HoldOpenPlaybackService();
  final sessions = SessionRepository(
    directory: dir,
    encoder: (session) => session.toJson().toString(),
  );
  final controller = PlayerController(playback: playback, sessions: sessions);
  await controller.initialize();
  return (controller, playback, dir);
}

void main() {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final urlEntry = MediaEntry(
    id: '1',
    path: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    title: 'watch',
    lastPlayed: epoch,
  );
  final localEntry = MediaEntry(
    id: '2',
    path: r'C:\Videos\concert_live.mkv',
    title: 'concert_live',
    lastPlayed: epoch,
  );
  final directUrlEntry = MediaEntry(
    id: '3',
    path: 'https://cdn.example.com/media/Big%20Buck%20Bunny.mp4',
    title: 'Big Buck Bunny',
    lastPlayed: epoch,
  );
  final hlsEntry = MediaEntry(
    id: '4',
    path: 'https://cdn.example.com/streams/master.m3u8',
    title: 'master',
    lastPlayed: epoch,
  );

  group('Loading label helpers', () {
    test('resolveLoadingStageLabel returns accurate labels per stage', () {
      expect(
        resolveLoadingStageLabel(
          transport: const TransportState(
            isLoading: true,
            streamPlaybackState: StreamPlaybackState(
              originalUrl: 'https://youtube.com/watch?v=1',
              stage: StreamStage.resolving,
              stageMessage: 'Resolving link',
            ),
          ),
          entry: urlEntry,
        ),
        'Resolving link',
      );
      expect(
        resolveLoadingStageLabel(
          transport: const TransportState(
            isLoading: true,
            streamPlaybackState: StreamPlaybackState(
              originalUrl: 'https://youtube.com/watch?v=1',
              stage: StreamStage.connecting,
            ),
          ),
          entry: urlEntry,
        ),
        'Connecting',
      );
      expect(
        resolveLoadingStageLabel(
          transport: const TransportState(
            hasMedia: true,
            streamPlaybackState: StreamPlaybackState(
              stage: StreamStage.switchingQuality,
              stageMessage: 'Switching to 1080p',
            ),
          ),
          entry: urlEntry,
        ),
        'Switching to 1080p',
      );
      expect(
        resolveLoadingStageLabel(
          transport: const TransportState(
            hasMedia: true,
            streamPlaybackState: StreamPlaybackState(
              stage: StreamStage.reconnecting,
              stageMessage: 'Reconnecting (attempt 1/2)...',
            ),
          ),
          entry: urlEntry,
        ),
        'Reconnecting (attempt 1/2)...',
      );
      expect(
        resolveLoadingStageLabel(
          transport: const TransportState(isLoading: true),
          entry: urlEntry,
        ),
        'Opening stream',
      );
      expect(
        resolveLoadingStageLabel(
          transport: const TransportState(isLoading: true),
          entry: localEntry,
        ),
        'Opening file',
      );
      expect(
        resolveLoadingStageLabel(
          transport: const TransportState(hasMedia: true, isBuffering: true),
          entry: localEntry,
        ),
        'Buffering',
      );
      expect(
        resolveLoadingStageLabel(
          transport: const TransportState(hasMedia: true),
          entry: localEntry,
        ),
        isNull,
      );
    });

    test('formatLoadingSourceLabel extracts clean host, file, or title', () {
      expect(
        formatLoadingSourceLabel(urlEntry, const StreamPlaybackState()),
        'youtube.com',
      );
      expect(
        formatLoadingSourceLabel(
          urlEntry,
          const StreamPlaybackState(resolvedTitle: 'Never Gonna Give You Up'),
        ),
        'Never Gonna Give You Up',
      );
      expect(
        formatLoadingSourceLabel(directUrlEntry, const StreamPlaybackState()),
        'Big Buck Bunny.mp4',
      );
      expect(
        formatLoadingSourceLabel(hlsEntry, const StreamPlaybackState()),
        'master.m3u8',
      );
      expect(
        formatLoadingSourceLabel(localEntry, const StreamPlaybackState()),
        'concert_live',
      );
    });
  });

  group('Controller streaming stage & cancellation lifecycle', () {
    test(
      'publishes live stream stages and resolved title during pending open, and cancelLoading aborts cleanly',
      () async {
        final (controller, playback, dir) = await _createHarness();
        addTearDown(() async {
          await controller.close(discard: true);
          controller.dispose();
          await playback.dispose();
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        playback.holdOpen = true;
        final stages = <StreamStage>[];
        void captureStage() {
          stages.add(controller.transportState.streamStage);
        }

        controller.transportListenable.addListener(captureStage);
        addTearDown(
          () => controller.transportListenable.removeListener(captureStage),
        );

        const url = 'https://www.youtube.com/watch?v=abc123';
        final opening = controller.openPaths(<String>[url]);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(controller.isLoading, isTrue);

        playback.emitSnapshot(
          playback.state.copyWith(
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: url,
              stage: StreamStage.resolving,
              stageMessage: 'Resolving link',
            ),
          ),
        );
        expect(controller.transportState.streamStage, StreamStage.resolving);

        playback.emitSnapshot(
          playback.state.copyWith(
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: url,
              streamUrl: 'https://cdn.example.com/media.mp4',
              resolvedTitle: 'Awesome Stream Video',
              stage: StreamStage.connecting,
              stageMessage: 'Connecting',
            ),
          ),
        );
        expect(controller.transportState.streamStage, StreamStage.connecting);
        expect(controller.current?.title, 'Awesome Stream Video');
        expect(controller.metadata.title, 'Awesome Stream Video');
        expect(
          stages,
          containsAllInOrder(<StreamStage>[
            StreamStage.resolving,
            StreamStage.connecting,
          ]),
        );

        await controller.cancelLoading();
        await opening;

        expect(controller.isLoading, isFalse);
        expect(controller.error, isNull);
        expect(controller.isStopped, isTrue);
        expect(playback.stopCalls, greaterThanOrEqualTo(1));
      },
    );

    test(
      'StreamingCoordinator transitions ready <-> buffering on pausedForCache',
      () async {
        final coordinator = StreamingCoordinator();
        addTearDown(coordinator.dispose);

        await coordinator.prepareStream('https://example.com/master.m3u8');
        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: coordinator.currentAttemptId,
        );
        expect(coordinator.state.stage, StreamStage.ready);

        coordinator.updateDemuxerStats(pausedForCache: true);
        expect(coordinator.state.stage, StreamStage.buffering);
        expect(coordinator.state.stageMessage, 'Buffering');

        coordinator.updateDemuxerStats(
          pausedForCache: false,
          bufferedDuration: const Duration(seconds: 10),
        );
        expect(coordinator.state.stage, StreamStage.ready);
        expect(coordinator.state.stageMessage, isNull);
      },
    );
  });

  group('PlayerLoadingOverlay', () {
    testWidgets(
      'shows immediately for network streams with stage/source and supports Cancel',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final (controller, playback, dir) = _createSyncHarness();
        playback.holdOpen = true;
        addTearDown(() async {
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  const SizedBox(),
                  PlayerLoadingOverlay(controller: controller, visible: true),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(PlayerLoadingBanner), findsNothing);

        const url = 'https://www.youtube.com/watch?v=test123';
        final opening = controller.openPaths(<String>[url]);
        await tester.pump();

        playback.emitSnapshot(
          playback.state.copyWith(
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: url,
              stage: StreamStage.resolving,
              stageMessage: 'Resolving link',
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));

        expect(find.byType(PlayerLoadingBanner), findsOneWidget);
        expect(find.text('Resolving link'), findsOneWidget);
        expect(find.text('youtube.com'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        await opening;
        expect(controller.isLoading, isFalse);
        expect(find.byType(PlayerLoadingBanner), findsNothing);

        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      },
    );

    testWidgets(
      'debounces local file loading indicator by 180ms so fast opens do not flash',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final (controller, playback, dir) = _createSyncHarness();
        playback.holdOpen = true;
        final file = File(p.join(dir.path, 'local_clip.mp4'))..createSync();
        addTearDown(() async {
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  const SizedBox(),
                  PlayerLoadingOverlay(controller: controller, visible: true),
                ],
              ),
            ),
          ),
        );

        final opening = controller.openPaths(<String>[file.path]);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(PlayerLoadingBanner), findsNothing);

        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(PlayerLoadingBanner), findsOneWidget);
        expect(find.text('Opening file'), findsOneWidget);

        // Drain real dart:io File.exists() and flush FakeAsync microtasks so
        // open() enters and awaits the gate.
        for (var i = 0; i < 20 && playback.openedPaths.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(playback.openedPaths, <String>[file.path]);

        playback.finishHeldOpen(path: file.path);
        await opening;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.byType(PlayerLoadingBanner), findsNothing);

        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      },
    );

    testWidgets(
      'hidden PlayerLoadingOverlay never collapses loose Stack inside Scaffold',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final (controller, playback, dir) = _createSyncHarness();
        addTearDown(() async {
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        const contentKey = Key('loose-stack-base');
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(child: SizedBox(key: contentKey)),
                  PlayerLoadingOverlay(controller: controller, visible: true),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.getSize(find.byKey(contentKey)), const Size(1280, 800));

        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      },
    );

    testWidgets(
      'PlayerLoadingBanner renders cleanly across Dark, OLED Black, Light, and reduced motion',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final themes = <ThemeData>[
          AppTheme.darkTheme(),
          AppTheme.darkTheme(oledBlack: true),
          AppTheme.lightTheme(),
        ];

        for (final theme in themes) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: Scaffold(
                body: Center(
                  child: PlayerLoadingBanner(
                    stageLabel: 'Connecting',
                    sourceLabel: 'example.com',
                    onCancel: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Connecting'), findsOneWidget);
          expect(find.text('example.com'), findsOneWidget);
          expect(find.text('Cancel'), findsOneWidget);
        }
      },
    );
  });

  group('PlayerStageLoadingOverlay', () {
    testWidgets(
      'shows centered initial load overlay and mid-playback top/center pills cleanly',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final (controller, playback, dir) = _createSyncHarness();
        playback.holdOpen = true;
        var backgroundTapped = false;
        addTearDown(() async {
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => backgroundTapped = true,
                    child: const SizedBox.expand(),
                  ),
                  PlayerStageLoadingOverlay(controller: controller),
                ],
              ),
            ),
          ),
        );

        const url = 'https://www.youtube.com/watch?v=stage1';
        final opening = controller.openPaths(<String>[url]);
        await tester.pump();
        playback.emitSnapshot(
          playback.state.copyWith(
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: url,
              stage: StreamStage.resolving,
              stageMessage: 'Resolving link',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('Resolving link'), findsOneWidget);
        expect(find.text('youtube.com'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        // Background remains clickable outside Cancel button.
        await tester.tapAt(const Offset(40, 40));
        expect(backgroundTapped, isTrue);

        // Attach media so hasMedia becomes true.
        playback.finishHeldOpen(path: url);
        await opening;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.text('Cancel'), findsNothing);

        // Quality switch pill settles cleanly near top center.
        playback.emitSnapshot(
          playback.state.copyWith(
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: url,
              stage: StreamStage.switchingQuality,
              stageMessage: 'Switching to 1080p',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.text('Switching to 1080p'), findsOneWidget);
        final topRect = tester.getRect(find.text('Switching to 1080p'));
        expect(topRect.top, lessThan(200));

        // Return to steady playback so the status pill hides before buffering.
        playback.emitSnapshot(
          playback.state.copyWith(
            isBuffering: false,
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: url,
              stage: StreamStage.ready,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.text('Switching to 1080p'), findsNothing);

        // Mid-playback buffering debounces at 250ms, then centers over video.
        playback.emitSnapshot(
          playback.state.copyWith(
            isBuffering: true,
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: url,
              stage: StreamStage.buffering,
              stageMessage: 'Buffering',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.text('Buffering'), findsNothing);
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text('Buffering'), findsOneWidget);
        final centerRect = tester.getRect(find.text('Buffering'));
        expect(centerRect.center.dy, closeTo(400, 40));

        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      },
    );
  });

  group('Seek buffer indicator, OpenUrlDialog Paste, and Esc cancel', () {
    testWidgets(
      'SharedSeekBar passes bufferedDuration as secondaryTrackValue',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final (controller, playback, dir) = _createSyncHarness();
        addTearDown(() async {
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        const url = 'https://cdn.example.com/stream.m3u8';
        await controller.openPaths(<String>[url]);
        playback.emitSnapshot(
          playback.state.copyWith(
            position: const Duration(seconds: 10),
            duration: const Duration(minutes: 2),
            seekable: true,
            streamPlaybackState: const StreamPlaybackState(
              originalUrl: url,
              stage: StreamStage.ready,
              bufferedDuration: Duration(seconds: 20),
            ),
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: Scaffold(
              body: PlayerControlStyle(
                compact: false,
                child: SizedBox(
                  width: 600,
                  child: AnimatedBuilder(
                    animation: controller.transportListenable,
                    builder: (context, _) => SharedSeekBar(
                      controller: controller,
                      onPreviewChanged: (_) {},
                      onInteractionChanged: null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final slider = tester.widget<Slider>(find.byType(Slider));
        expect(slider.secondaryTrackValue, closeTo(30000.0, 100.0));

        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      },
    );

    testWidgets(
      'OpenUrlDialog Paste button populates field from clipboard',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                return <String, Object?>{
                  'text': 'https://example.com/video.mp4',
                };
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme(),
            home: const Scaffold(body: OpenUrlDialog()),
          ),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('Paste URL'));
        await tester.pump();

        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('open-url-input')),
        );
        expect(field.controller?.text, 'https://example.com/video.mp4');
      },
    );

    testWidgets(
      'Escape cancels in-flight loading via PlayerHotkeyHandler',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        final (controller, playback, dir) = _createSyncHarness();
        playback.holdOpen = true;
        final hotkeyHandler = PlayerHotkeyHandler(
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
        );
        addTearDown(() async {
          hotkeyHandler.dispose();
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        final opening = controller.openPaths(<String>[
          'https://example.com/stream',
        ]);
        await tester.pump();
        expect(controller.isLoading, isTrue);

        await tester.pumpWidget(
          MaterialApp(
            home: Focus(
              autofocus: true,
              onKeyEvent: hotkeyHandler.handleKey,
              child: const SizedBox(),
            ),
          ),
        );
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await opening;
        expect(controller.isLoading, isFalse);

        await tester.runAsync(
          () => controller.close(discard: true, force: true),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      },
    );
  });
}
