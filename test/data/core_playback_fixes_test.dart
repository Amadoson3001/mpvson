import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/native_media_events.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/streaming_coordinator.dart';
import 'package:mpvson/data/services/yt_dlp_resolver.dart';
import 'package:mpvson/domain/models/graphics_settings.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_settings.dart';
import 'package:mpvson/domain/models/resolved_stream.dart';
import 'package:mpvson/domain/models/stream_playback_state.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:path/path.dart' as p;

import '../support/fake_playback_service.dart';

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  final List<String> openedUris = <String>[];
  int stopCalls = 0;
  Completer<void>? openGate;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedUris.add(playable.uri);
    }
    final gate = openGate;
    if (gate != null) {
      await gate.future;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> dispose() async {
    await super.dispose();
  }
}

class _FakeNativeMediaEvents implements NativeMediaEvents {
  final StreamController<NativeMediaEvent> _controller =
      StreamController<NativeMediaEvent>.broadcast(sync: true);

  @override
  Stream<NativeMediaEvent> get events => _controller.stream;

  void emit(NativeMediaEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  @override
  Future<bool> start() async => true;

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

class _CapturingPreviewBackend implements SeekPreviewBackend {
  final List<({String source, Map<String, String>? headers})> opens =
      <({String source, Map<String, String>? headers})>[];

  @override
  int? get liveTextureId => null;

  @override
  bool get supportsLiveTexture => false;

  @override
  Future<void> open(
    String source, {
    Map<String, String>? httpHeaders,
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    opens.add((source: source, headers: httpHeaders));
  }

  @override
  Future<void> seekLive(Duration target, {required bool exact}) async {}

  @override
  Future<SeekPreviewFrame?> extractFrame(
    Duration target, {
    required bool exact,
    Duration timeout = const Duration(seconds: 3),
  }) async => null;

  @override
  void cancelExtraction() {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _BoundaryTestPlaybackService extends FakePlaybackService {
  PlaybackSnapshot _customState = const PlaybackSnapshot();
  final StreamController<PlaybackSnapshot> _customStates =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);
  int _boundary = 0;

  @override
  PlaybackSnapshot get state => _customState;

  @override
  Stream<PlaybackSnapshot> get states => _customStates.stream;

  void emitRaw(PlaybackSnapshot snapshot) {
    _customState = snapshot;
    _customStates.add(snapshot);
  }

  @override
  Future<void> open(String path, {bool play = true}) async {
    openedPaths.add(path);
    _boundary++;
    emitRaw(
      _customState.copyWith(
        sourceStart: _boundary,
        isPlaying: false,
        isBuffering: true,
        sourceLoaded: false,
        clearNativeSource: true,
        clearError: true,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _customStates.close();
    await super.dispose();
  }
}

class _StaticUrlResolver extends YtDlpResolver {
  _StaticUrlResolver(this.stream);
  final ResolvedStream stream;

  @override
  bool canResolve(String url) => url == stream.originalUrl;

  @override
  Future<ResolvedStream> resolve(
    String url, {
    Duration timeout = const Duration(seconds: 35),
    CancellationToken? cancelToken,
  }) async => stream;
}

void main() {
  var nativeLibmpvReady = false;

  setUpAll(() {
    if (Platform.isWindows) {
      for (final buildType in const ['Debug', 'Release']) {
        final dllPath = p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          buildType,
          'libmpv-2.dll',
        );
        if (File(dllPath).existsSync()) {
          try {
            MediaKit.ensureInitialized(libmpv: dllPath);
            nativeLibmpvReady = true;
            break;
          } catch (_) {}
        }
      }
    }
  });

  group('Core playback logic regression fixes', () {
    test(
      'startFile with empty source maps playlistEntryId so endFile error triggers StreamingCoordinator recovery',
      () async {
        final platform = _FakePlatformPlayer();
        final player = Player(platformPlayer: platform);
        final nativeEvents = _FakeNativeMediaEvents();
        final service = MediaKitPlaybackService(
          player: player,
          videoController: _NoopVideoController(player),
          nativeEvents: nativeEvents,
        );
        addTearDown(() async {
          await service.dispose();
          await nativeEvents.dispose();
        });

        await service.prepare();
        await service.open('https://example.com/live-drop.mp4');

        // Real libmpv emits MPV_EVENT_START_FILE with an empty source and a
        // playlistEntryId before `path` is notified.
        nativeEvents.emit(
          const NativeMediaEvent.started('', playlistEntryId: 7),
        );
        expect(service.streamingCoordinator.state.stage, StreamStage.buffering);

        // When MPV_EVENT_END_FILE fires with the same playlistEntryId and an
        // error, StreamingCoordinator must receive it and enter reconnecting.
        nativeEvents.emit(
          const NativeMediaEvent.ended(
            endReason: NativeEndReason.error,
            errorCode: -8,
            playlistEntryId: 7,
          ),
        );
        expect(
          service.streamingCoordinator.state.stage,
          StreamStage.reconnecting,
        );
        expect(service.streamingCoordinator.state.reconnectAttempts, 1);

        // Terminal error with a fresh playlistEntryId fails cleanly.
        nativeEvents.emit(
          const NativeMediaEvent.started('', playlistEntryId: 8),
        );
        nativeEvents.emit(
          const NativeMediaEvent.ended(
            endReason: NativeEndReason.error,
            errorCode: -16,
            playlistEntryId: 8,
          ),
        );
        expect(service.streamingCoordinator.state.stage, StreamStage.failed);
        expect(service.state.error, isNotNull);
      },
    );

    test(
      'stop() serializes behind an in-flight open() and prevents races',
      () async {
        final platform = _FakePlatformPlayer();
        final gate = Completer<void>();
        platform.openGate = gate;
        final player = Player(platformPlayer: platform);
        final nativeEvents = _FakeNativeMediaEvents();
        final service = MediaKitPlaybackService(
          player: player,
          videoController: _NoopVideoController(player),
          nativeEvents: nativeEvents,
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await service.dispose();
          await nativeEvents.dispose();
        });

        final openFuture = service.open('https://example.com/slow.mp4');
        // Let _runQueuedOpen reach platform.open(...)
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(platform.openedUris, hasLength(1));

        final stopFuture = service.stop();
        // Immediate state is stopped, but native stop waits for in-flight open.
        expect(service.state.isPlaying, isFalse);
        expect(service.state.isBuffering, isFalse);
        expect(platform.stopCalls, 0);

        // Release the in-flight open; queued stop then executes cleanly.
        gate.complete();
        await Future.wait([openFuture, stopFuture]);
        expect(platform.stopCalls, 1);
        expect(service.state.sourceLoaded, isFalse);
        expect(service.state.isBuffering, isFalse);
      },
    );

    test(
      'pending.boundary drops late boundary-1 error snapshots after moving to boundary-2',
      () async {
        final dir = Directory.systemTemp.createTempSync('mpvson-boundary-');
        final playback = _BoundaryTestPlaybackService();
        final controller = PlayerController(
          playback: playback,
          sessions: SessionRepository(
            directory: dir,
            encoder: (s) => s.toJson().toString(),
          ),
        );
        addTearDown(() async {
          await controller.close(discard: true);
          controller.dispose();
          await playback.dispose();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        await controller.initialize();
        await controller.openPaths([
          'https://example.com/first.mp4',
          'https://example.com/second.mp4',
        ]);
        // First item is still pending at boundary 1; user immediately skips to item 2 (boundary 2).
        expect(controller.isLoading, isTrue);
        await controller.playIndex(1);
        expect(controller.isLoading, isTrue);

        // A late failure snapshot from boundary 1 without nativeSource must be
        // dropped instead of failing boundary 2.
        playback.emitRaw(
          const PlaybackSnapshot(
            sourceStart: 1,
            error: 'Stale boundary-1 error',
          ),
        );
        expect(controller.isLoading, isTrue);
        expect(controller.error, isNull);

        // Boundary 2 confirming still succeeds cleanly.
        playback.emitRaw(
          PlaybackSnapshot(
            sourceStart: 2,
            nativeSource: MediaEntry.canonicalSource(
              'https://example.com/second.mp4',
            ),
            sourceLoaded: true,
            isPlaying: true,
            duration: const Duration(minutes: 1),
          ),
        );
        expect(controller.isLoading, isFalse);
        expect(controller.hasMedia, isTrue);
        expect(controller.error, isNull);
      },
    );

    test(
      'SeekPreviewService receives resolved stream URL and httpHeaders for yt-dlp pages and updates on rendition change',
      () async {
        final dir = Directory.systemTemp.createTempSync('mpvson-preview-url-');
        final backend = _CapturingPreviewBackend();
        const pageUrl = 'https://www.youtube.com/watch?v=test123';
        const resolvedUrl1 = 'https://cdn.example.com/video-720p.mp4';
        const resolvedUrl2 = 'https://cdn.example.com/video-1080p.mp4';
        const headers = {'User-Agent': 'MpvsonTest/1.0'};

        final coordinator = StreamingCoordinator(
          ytDlpResolver: _StaticUrlResolver(
            const ResolvedStream(
              originalUrl: pageUrl,
              streamUrl: resolvedUrl1,
              httpHeaders: headers,
              renditions: [
                StreamRendition(
                  id: '720',
                  label: '720p',
                  height: 720,
                  url: resolvedUrl1,
                  httpHeaders: headers,
                ),
                StreamRendition(
                  id: '1080',
                  label: '1080p',
                  height: 1080,
                  url: resolvedUrl2,
                  httpHeaders: headers,
                ),
              ],
            ),
          ),
        );
        final playback = FakePlaybackService(streamingCoordinator: coordinator);
        final controller = PlayerController(
          playback: playback,
          sessions: SessionRepository(
            directory: dir,
            encoder: (s) => s.toJson().toString(),
          ),
          previewBackendFactory: () => backend,
        );
        addTearDown(() async {
          await controller.close(discard: true);
          controller.dispose();
          await playback.dispose();
          coordinator.dispose();
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });

        await controller.initialize();
        await coordinator.prepareStream(pageUrl);
        await controller.openPaths([pageUrl]);

        // Trigger a seek-preview hover to open the preview backend.
        controller.seekPreview.onPointerMove(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(backend.opens, isNotEmpty);
        expect(backend.opens.first.source, resolvedUrl1);
        expect(backend.opens.first.headers, headers);

        // Simulate switching to 1080p (changing resolved streamUrl).
        coordinator.recordStreamInput(resolvedUrl2, null, httpHeaders: headers);
        controller.seekPreview.onPointerMove(const Duration(seconds: 30));
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(backend.opens.last.source, resolvedUrl2);
        expect(backend.opens.last.headers, headers);
      },
    );

    test(
      'native libmpv applies limitDemuxerCache and low-spec buffering policy on open and at runtime',
      () async {
        if (!nativeLibmpvReady) return;
        final samplePath = p.join(
          Directory.current.path,
          'packaging',
          'linux',
          'smoke-sample.mp4',
        );
        if (!File(samplePath).existsSync()) return;

        final player = Player(
          configuration: const PlayerConfiguration(vo: 'null'),
        );
        final service = MediaKitPlaybackService(
          player: player,
          videoController: _NoopVideoController(player),
        );
        addTearDown(service.dispose);

        final native = player.platform! as NativePlayer;
        await native.future;

        await service.open(samplePath, play: false);
        final limitedBytes = int.parse(
          (await native.getProperty('demuxer-max-bytes')).trim(),
        );
        expect(
          limitedBytes,
          demuxerCacheLimits(limit: true, lowSpec: false).forwardBytes,
        );

        // Disabling limitDemuxerCache updates the active engine at runtime.
        service.applyGraphicsSettings(
          const GraphicsSettings(limitDemuxerCache: false),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final unlimitedBytes = int.parse(
          (await native.getProperty('demuxer-max-bytes')).trim(),
        );
        expect(
          unlimitedBytes,
          demuxerCacheLimits(limit: false, lowSpec: false).forwardBytes,
        );

        // Re-enabling limitDemuxerCache + lowSpec updates caps to 48 MiB.
        service.applyGraphicsSettings(
          const GraphicsSettings(limitDemuxerCache: true),
        );
        await service.applyPlaybackSettings(
          const PlaybackSettings(
            qualityPreset: PlaybackQualityPreset.performance,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final lowSpecBytes = int.parse(
          (await native.getProperty('demuxer-max-bytes')).trim(),
        );
        expect(
          lowSpecBytes,
          demuxerCacheLimits(limit: true, lowSpec: true).forwardBytes,
        );
      },
    );
  });
}

class _NoopVideoController implements VideoController {
  _NoopVideoController(this.player);

  @override
  final Player player;

  @override
  final Completer<PlatformVideoController> platform =
      Completer<PlatformVideoController>();

  @override
  final ValueNotifier<PlatformVideoController?> notifier =
      ValueNotifier<PlatformVideoController?>(null);

  @override
  final ValueNotifier<int?> id = ValueNotifier<int?>(null);

  @override
  final ValueNotifier<Rect?> rect = ValueNotifier<Rect?>(null);

  @override
  Future<void> setSize({int? width, int? height}) async {}

  @override
  Future<void> setRenderVisibility(bool visible) async {}

  @override
  Future<void> get waitUntilFirstFrameRendered async {}
}
