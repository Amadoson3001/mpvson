import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/native_media_events.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/streaming_coordinator.dart';
import 'package:mpvson/domain/models/stream_playback_state.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/widgets/controls/stream_quality_menu.dart';

import '../support/fake_playback_service.dart';
import '../support/streaming_fixture_server.dart';

void main() {
  var nativeLibmpvReady = false;

  setUpAll(() {
    // Initialize libmpv native engine if available on Windows.
    if (Platform.isWindows) {
      final candidates = <String>[
        p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Debug',
          'libmpv-2.dll',
        ),
        p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Release',
          'libmpv-2.dll',
        ),
      ];
      for (final dllPath in candidates) {
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

  group('Native streaming quality & segment verification', () {
    late StreamingFixtureServer server;

    setUp(() async {
      HttpOverrides.global = null;
      server = await StreamingFixtureServer.startServer();
    });

    tearDown(() async {
      await server.stop();
    });

    test(
      'HLS quality switch updates requested segments and updates resolution displayed',
      () async {
        final coordinator = StreamingCoordinator();
        addTearDown(coordinator.dispose);

        final hlsUrl = server.urlStringFor('/hls/master.m3u8');
        final resolved = await coordinator.prepareStream(hlsUrl);

        expect(resolved, isNotNull);
        expect(coordinator.state.stage, equals(StreamStage.connecting));
        expect(
          coordinator.state.availableRenditions.length,
          4,
        ); // Auto, 360p, 720p, 1080p

        // The active rendition is unknown until the player reports dimensions.
        expect(coordinator.state.activeRendition, isNull);
        expect(coordinator.state.isAutoQuality, isTrue);

        // Mark stream loaded at initial 360p resolution
        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: coordinator.currentAttemptId,
        );
        coordinator.updateDemuxerStats(
          bufferedDuration: const Duration(seconds: 10),
          width: 640,
          height: 360,
        );

        expect(coordinator.state.stage, equals(StreamStage.ready));
        expect(coordinator.state.decodedWidth, equals(640));
        expect(coordinator.state.decodedHeight, equals(360));
        expect(coordinator.state.activeRendition?.label, equals('360p'));

        // Switch quality to 720p
        final rendition720p = coordinator.state.availableRenditions.firstWhere(
          (r) => r.label == '720p',
        );

        coordinator.selectRendition(rendition720p);
        expect(coordinator.state.stage, equals(StreamStage.switchingQuality));
        expect(coordinator.state.selectedRendition, equals(rendition720p));
        expect(coordinator.state.isAutoQuality, isFalse);

        // Emulate segment requests for 360p and 720p rungs
        final client = HttpClient();
        addTearDown(client.close);

        final req360 = await client.getUrl(server.urlFor('/hls/seg-360p-0.ts'));
        final resp360 = await req360.close();
        await resp360.drain<void>();

        final req720 = await client.getUrl(server.urlFor('/hls/seg-720p-0.ts'));
        final resp720 = await req720.close();
        await resp720.drain<void>();

        // Assert both 360p and 720p segments appear in fixture server ledger
        expect(server.requestsFor('/hls/seg-360p-0.ts'), hasLength(1));
        expect(server.requestsFor('/hls/seg-720p-0.ts'), hasLength(1));

        // Engine reports new decoded resolution 1280x720 for switched rung
        coordinator.updateDemuxerStats(
          bufferedDuration: const Duration(seconds: 8),
          width: 1280,
          height: 720,
        );

        expect(coordinator.state.stage, equals(StreamStage.ready));
        expect(coordinator.state.activeRendition?.label, equals('720p'));
        expect(coordinator.state.decodedWidth, equals(1280));
        expect(coordinator.state.decodedHeight, equals(720));
      },
    );

    test(
      'DASH quality switch changes requested media and updates decoded resolution',
      () async {
        final coordinator = StreamingCoordinator();
        addTearDown(coordinator.dispose);

        final dashUrl = server.urlStringFor('/dash/manifest.mpd');
        final resolved = await coordinator.prepareStream(dashUrl);

        expect(resolved, isNotNull);
        expect(
          coordinator.state.availableRenditions.length,
          3,
        ); // Auto, 360p, 720p

        // Initial conservative rung within budget is 360p
        expect(coordinator.state.activeRendition, isNull);

        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: coordinator.currentAttemptId,
        );
        coordinator.updateDemuxerStats(
          bufferedDuration: const Duration(seconds: 12),
          width: 640,
          height: 360,
        );

        expect(coordinator.state.decodedWidth, equals(640));
        expect(coordinator.state.decodedHeight, equals(360));

        // Fetch 360p representation
        final client = HttpClient();
        addTearDown(client.close);

        final req360 = await client.getUrl(
          server.urlFor('/dash/video-360p.mp4'),
        );
        final resp360 = await req360.close();
        await resp360.drain<void>();

        // Switch quality to 720p
        final rendition720p = coordinator.state.availableRenditions.firstWhere(
          (r) => r.label == '720p',
        );
        coordinator.selectRendition(rendition720p);

        // Fetch 720p representation
        final req720 = await client.getUrl(
          server.urlFor('/dash/video-720p.mp4'),
        );
        final resp720 = await req720.close();
        await resp720.drain<void>();

        // Both representations were requested in ledger
        expect(server.requestsFor('/dash/video-360p.mp4'), hasLength(1));
        expect(server.requestsFor('/dash/video-720p.mp4'), hasLength(1));

        // Resolution update to 1280x720
        coordinator.updateDemuxerStats(
          bufferedDuration: const Duration(seconds: 10),
          width: 1280,
          height: 720,
        );

        expect(coordinator.state.activeRendition?.label, equals('720p'));
        expect(coordinator.state.decodedWidth, equals(1280));
        expect(coordinator.state.decodedHeight, equals(720));
      },
    );

    testWidgets(
      'StreamQualityMenu reflects quality switch and displayed resolution label',
      (tester) async {
        final coordinator = StreamingCoordinator();
        addTearDown(coordinator.dispose);

        final hlsUrl = server.urlStringFor('/hls/master.m3u8');
        await tester.runAsync(() async {
          await coordinator.prepareStream(hlsUrl);
        });

        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: coordinator.currentAttemptId,
        );
        coordinator.updateDemuxerStats(
          bufferedDuration: const Duration(seconds: 10),
          width: 640,
          height: 360,
        );

        // Set up test controller
        final testPlayback = FakePlaybackService(
          streamingCoordinator: coordinator,
        );
        final tempDir = Directory.systemTemp.createTempSync('mpvson-test-');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final controller = PlayerController(
          playback: testPlayback,
          sessions: SessionRepository(
            directory: tempDir,
            encoder: (s) => s.toJson().toString(),
          ),
        );
        await tester.runAsync(() async {
          await controller.initialize();
          await controller.openPaths([hlsUrl]);
        });
        addTearDown(() async {
          await testPlayback.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamQualityMenu(
                controller: controller,
                onMenuVisibilityChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Initially displays Auto with active rendition 360p
        expect(find.text('360p'), findsOneWidget);

        // Switch to 720p
        final rendition720p = coordinator.state.availableRenditions.firstWhere(
          (r) => r.label == '720p',
        );
        await controller.selectStreamQuality(rendition720p);

        coordinator.updateDemuxerStats(
          bufferedDuration: const Duration(seconds: 10),
          width: 1280,
          height: 720,
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // UI label updates to 720p
        expect(find.text('720p'), findsOneWidget);
        expect(coordinator.state.decodedWidth, equals(1280));
        expect(coordinator.state.decodedHeight, equals(720));

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await tester.runAsync(() async {
          await controller.close(discard: true);
        });
        controller.dispose();
      },
    );

    test(
      'Terminal error (HTTP 404) does not advance queue or mark completed',
      () async {
        final coordinator = StreamingCoordinator();
        addTearDown(coordinator.dispose);

        await coordinator.prepareStream('https://example.com/missing.mp4');
        // Simulate terminal HTTP 404
        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.ended(
            endReason: NativeEndReason.error,
            errorCode: -4, // MPV_ERROR_FILE_NOT_FOUND (HTTP 404)
          ),
          attemptId: coordinator.currentAttemptId,
        );

        expect(coordinator.state.stage, equals(StreamStage.failed));
        expect(coordinator.state.reconnectAttempts, equals(0));

        // PlaybackSnapshot completed is strictly false on error
        var snapshot = const PlaybackSnapshot();
        snapshot = applyNativeEvent(
          snapshot,
          const NativeMediaEvent.ended(
            endReason: NativeEndReason.error,
            errorCode: -4,
          ),
        );

        expect(snapshot.completed, isFalse);
      },
    );

    test(
      'setPropertyList clears audio-files without triggering external file open error',
      () async {
        if (!nativeLibmpvReady) return;
        final samplePath = p.join(
          Directory.current.path,
          'packaging',
          'linux',
          'smoke-sample.mp4',
        );
        expect(File(samplePath).existsSync(), isTrue);

        final player = Player(
          configuration: const PlayerConfiguration(vo: 'null'),
        );
        final service = MediaKitPlaybackService(
          player: player,
          videoController: _TestVideoController(player),
        );
        addTearDown(service.dispose);

        final errors = <String>[];
        final stateSub = service.states.listen((s) {
          if (s.error != null && s.error!.isNotEmpty) {
            errors.add(s.error!);
          }
        });
        final playerErrSub = player.stream.error.listen((msg) {
          if (msg.isNotEmpty) {
            errors.add(msg);
          }
        });
        addTearDown(() async {
          await stateSub.cancel();
          await playerErrSub.cancel();
        });

        final native = player.platform! as NativePlayer;
        await native.future;

        await native.setPropertyList('audio-files', <String>[
          samplePath,
        ], waitForInitialization: false);
        await native.setPropertyList(
          'audio-files',
          const <String>[],
          waitForInitialization: false,
        );

        await service.open(samplePath, play: false);
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline) &&
            !service.state.sourceLoaded &&
            errors.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(
          errors.where((e) => e.contains('Can not open external file')),
          isEmpty,
        );
        expect(service.state.error, isNull);
      },
    );

    test('PlayerController.closePlayer clears active error state', () async {
      final tempDir = Directory.systemTemp.createTempSync('mpvson-close-err-');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(
          directory: tempDir,
          encoder: (s) => s.toJson().toString(),
        ),
      );
      addTearDown(() async {
        await controller.close(discard: true);
        controller.dispose();
        await playback.dispose();
      });

      await controller.initialize();
      await controller.openPaths([p.join(tempDir.path, 'does-not-exist.mp4')]);
      expect(controller.error, isNotNull);

      await controller.closePlayer();
      expect(controller.current, isNull);
      expect(controller.error, isNull);
    });
  });
}

class _TestVideoController implements VideoController {
  _TestVideoController(this.player);

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
