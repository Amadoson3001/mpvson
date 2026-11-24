import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/native_media_events.dart';
import 'package:mpvson/data/services/process_runner.dart';
import 'package:mpvson/data/services/stream_manifest_service.dart';
import 'package:mpvson/data/services/streaming_coordinator.dart';
import 'package:mpvson/data/services/yt_dlp_resolver.dart';
import 'package:mpvson/domain/models/stream_playback_state.dart';
import 'package:mpvson/domain/models/resolved_stream.dart';

void main() {
  group('StreamingCoordinator lifecycle & attempt isolation', () {
    late StreamingCoordinator coordinator;

    setUp(() {
      coordinator = StreamingCoordinator();
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('issues unique incrementing attempt IDs and tracks states', () async {
      final info = await coordinator.prepareStream(
        'https://example.com/video.mp4',
      );
      expect(info, isNotNull);
      expect(info!.attemptId, equals(1));
      expect(coordinator.currentAttemptId, equals(1));
      expect(coordinator.state.stage, equals(StreamStage.connecting));
      expect(
        coordinator.state.originalUrl,
        equals('https://example.com/video.mp4'),
      );

      final info2 = await coordinator.prepareStream(
        'https://example.com/video2.mp4',
      );
      expect(info2, isNotNull);
      expect(info2!.attemptId, equals(2));
      expect(coordinator.currentAttemptId, equals(2));
      expect(
        coordinator.state.originalUrl,
        equals('https://example.com/video2.mp4'),
      );
    });

    test('new attempts clear manifest and resume position', () async {
      final service = _FakeStreamManifestService(
        const StreamManifestInfo(
          masterUrl: 'https://example.com/live',
          format: StreamFormat.hls,
          isLive: true,
        ),
      );
      final subject = StreamingCoordinator(manifestService: service);
      addTearDown(subject.dispose);
      await subject.prepareStream('https://example.com/live');
      expect(subject.activeFormat, StreamFormat.hls);
      subject.updatePosition(const Duration(minutes: 5));
      await subject.prepareStream('https://example.com/next.mp4');
      expect(subject.activeFormat, StreamFormat.progressive);
      Duration? position;
      subject.onReconnectRequired = (_, value) async => position = value;
      subject.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -8,
        ),
        attemptId: subject.currentAttemptId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(position, Duration.zero);
    });

    test('stop cancels a scheduled reconnect', () async {
      await coordinator.prepareStream('https://example.com/stream.mp4');
      var called = false;
      coordinator.onReconnectRequired = (_, _) async {
        called = true;
      };
      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -8,
        ),
        attemptId: coordinator.currentAttemptId,
      );
      coordinator.stop();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(called, isFalse);
    });

    test('seeking back to zero resets reconnect position', () async {
      await coordinator.prepareStream('https://example.com/video.mp4');
      coordinator.updatePosition(const Duration(minutes: 5));
      coordinator.updatePosition(Duration.zero);
      Duration? resumed;
      coordinator.onReconnectRequired = (_, position) async {
        resumed = position;
      };
      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -8,
        ),
        attemptId: coordinator.currentAttemptId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(resumed, Duration.zero);
    });

    test('late refresh cannot overwrite a replacement attempt', () async {
      final resolver = _RefreshResolver();
      final subject = StreamingCoordinator(ytDlpResolver: resolver);
      addTearDown(subject.dispose);
      await subject.prepareStream('https://example.com/page');
      final refresh = subject.refreshExpiringStream();
      await subject.prepareStream('https://example.com/replacement.mp4');
      expect(resolver.refreshToken?.isCancelled, isTrue);
      resolver.result.complete(
        const ResolvedStream(
          originalUrl: 'https://example.com/page',
          streamUrl: 'https://example.com/late.mp4',
        ),
      );
      expect(await refresh, isNull);
      expect(subject.state.streamUrl, 'https://example.com/replacement.mp4');
    });

    test('403 on expiring source refreshes once then fails', () async {
      final resolver = _RefreshResolver();
      final subject = StreamingCoordinator(ytDlpResolver: resolver);
      addTearDown(subject.dispose);
      await subject.prepareStream('https://example.com/page');
      var reconnects = 0;
      subject.onReconnectRequired = (_, _) async {
        reconnects++;
      };
      const error = NativeMediaEvent.ended(
        endReason: NativeEndReason.error,
        errorCode: -13,
      );
      subject.handleNativeLifecycleEvent(
        error,
        attemptId: subject.currentAttemptId,
        httpStatusCode: 403,
      );
      expect(reconnects, 1);
      subject.handleNativeLifecycleEvent(
        error,
        attemptId: subject.currentAttemptId,
        httpStatusCode: 403,
      );
      expect(reconnects, 1);
      expect(subject.state.stage, StreamStage.failed);
    });

    test(
      'late old quality dimensions do not confirm a new selection',
      () async {
        const low = StreamRendition(
          id: 'low',
          label: '360p',
          width: 640,
          height: 360,
        );
        const high = StreamRendition(
          id: 'high',
          label: '720p',
          width: 1280,
          height: 720,
        );
        final subject = StreamingCoordinator(
          manifestService: _FakeStreamManifestService(
            const StreamManifestInfo(
              masterUrl: 'https://example.com/master.m3u8',
              format: StreamFormat.hls,
              variants: [low, high],
            ),
          ),
        );
        addTearDown(subject.dispose);
        await subject.prepareStream('https://example.com/master.m3u8');
        subject.updateDemuxerStats(width: 640, height: 360);
        subject.selectRendition(high);
        subject.updateDemuxerStats(width: 640, height: 360);
        expect(subject.state.activeRendition, low);
        expect(subject.state.stage, StreamStage.switchingQuality);
        subject.updateDemuxerStats(width: 1280, height: 720);
        expect(subject.state.activeRendition, high);
        expect(subject.state.stage, StreamStage.ready);
      },
    );

    test('live reconnect uses the live edge', () async {
      final subject = StreamingCoordinator(
        manifestService: _FakeStreamManifestService(
          const StreamManifestInfo(
            masterUrl: 'https://example.com/live.m3u8',
            format: StreamFormat.hls,
            isLive: true,
          ),
        ),
      );
      addTearDown(subject.dispose);
      await subject.prepareStream('https://example.com/live.m3u8');
      subject.updatePosition(const Duration(minutes: 5));
      Duration? resumed;
      subject.onReconnectRequired = (_, position) async {
        resumed = position;
      };
      subject.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -8,
        ),
        attemptId: subject.currentAttemptId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(resumed, Duration.zero);
    });

    test('stop cancels an in-flight refresh', () async {
      final resolver = _RefreshResolver();
      final subject = StreamingCoordinator(ytDlpResolver: resolver);
      addTearDown(subject.dispose);
      await subject.prepareStream('https://example.com/page');
      final refresh = subject.refreshExpiringStream();
      subject.stop();
      expect(resolver.refreshToken?.isCancelled, isTrue);
      resolver.result.complete(
        const ResolvedStream(
          originalUrl: 'https://example.com/page',
          streamUrl: 'https://example.com/late.mp4',
        ),
      );
      expect(await refresh, isNull);
      expect(subject.state.stage, StreamStage.idle);
    });

    testWidgets('ambiguous dimensions time out without claiming a quality', (
      tester,
    ) async {
      const low = StreamRendition(
        id: 'low',
        label: '360p',
        width: 640,
        height: 360,
      );
      const one = StreamRendition(
        id: 'a',
        label: '720p A',
        width: 1280,
        height: 720,
      );
      const two = StreamRendition(
        id: 'b',
        label: '720p B',
        width: 1280,
        height: 720,
      );
      final subject = StreamingCoordinator(
        manifestService: _FakeStreamManifestService(
          const StreamManifestInfo(
            masterUrl: 'https://example.com/master.m3u8',
            format: StreamFormat.hls,
            variants: [low, one, two],
          ),
        ),
      );
      addTearDown(subject.dispose);
      await subject.prepareStream('https://example.com/master.m3u8');
      subject.updateDemuxerStats(width: 640, height: 360);
      subject.selectRendition(one);
      subject.selectRendition(two);
      subject.updateDemuxerStats(width: 1280, height: 720);
      expect(subject.state.activeRendition, low);
      expect(subject.state.stage, StreamStage.switchingQuality);
      await tester.pump(const Duration(seconds: 9));
      expect(subject.state.activeRendition, low);
      expect(subject.state.stage, StreamStage.ready);
      expect(subject.state.isAutoQuality, isTrue);
    });

    test('ignores native events from stale or obsolete attempt IDs', () async {
      await coordinator.prepareStream('https://example.com/video1.mp4');
      final firstAttemptId = coordinator.currentAttemptId;

      await coordinator.prepareStream('https://example.com/video2.mp4');
      final secondAttemptId = coordinator.currentAttemptId;

      // Event from first attempt should be ignored
      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.loaded(),
        attemptId: firstAttemptId,
      );
      expect(coordinator.state.stage, equals(StreamStage.connecting));

      // Event from active attempt should transition state
      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.loaded(),
        attemptId: secondAttemptId,
      );
      expect(coordinator.state.stage, equals(StreamStage.ready));
      expect(coordinator.state.firstOutputTime, isNotNull);
    });

    test('handles manual quality selection and preserves lock', () async {
      await coordinator.prepareStream('https://example.com/video.mp4');

      const rendition720p = StreamRendition(
        id: '720p',
        label: '720p',
        height: 720,
        bitrate: 2500000,
      );

      coordinator.selectRendition(rendition720p);
      expect(coordinator.state.isAutoQuality, isFalse);
      expect(coordinator.state.selectedRendition?.label, equals('720p'));
      expect(coordinator.state.stage, equals(StreamStage.switchingQuality));
      expect(coordinator.state.stageMessage, contains('720p'));
    });

    test('retries transient failure up to 2 times before terminal failure', () {
      coordinator.prepareStream('https://example.com/video.mp4');
      final attemptId = coordinator.currentAttemptId;

      // First error -> reconnect attempt 1
      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -1,
        ),
        attemptId: attemptId,
      );
      expect(coordinator.state.stage, equals(StreamStage.reconnecting));
      expect(coordinator.state.reconnectAttempts, equals(1));

      // Second error -> reconnect attempt 2
      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -1,
        ),
        attemptId: attemptId,
      );
      expect(coordinator.state.stage, equals(StreamStage.reconnecting));
      expect(coordinator.state.reconnectAttempts, equals(2));

      // Third error -> terminal failure
      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -1,
        ),
        attemptId: attemptId,
      );
      expect(coordinator.state.stage, equals(StreamStage.failed));
      expect(coordinator.state.error, contains('Tap Retry'));
    });

    test('cancels active attempt on stop', () async {
      await coordinator.prepareStream('https://example.com/video.mp4');
      expect(coordinator.state.stage, isNot(equals(StreamStage.idle)));

      coordinator.cancelActiveAttempt(reason: 'user stop');
      expect(coordinator.state.stage, equals(StreamStage.idle));
    });

    test(
      'terminal error (code -4 / file not found / 404) fails immediately without reconnecting',
      () async {
        await coordinator.prepareStream('https://example.com/notfound.mp4');
        final attemptId = coordinator.currentAttemptId;

        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.ended(
            endReason: NativeEndReason.error,
            errorCode: -4, // MPV_ERROR_FILE_NOT_FOUND (HTTP 404)
          ),
          attemptId: attemptId,
        );

        // Must be terminal failed, NOT reconnecting
        expect(coordinator.state.stage, equals(StreamStage.failed));
        expect(coordinator.state.reconnectAttempts, equals(0));
        expect(coordinator.state.error, contains('404'));
      },
    );

    test('a thrown reconnect advances to the next attempt', () async {
      await coordinator.prepareStream('https://example.com/stream.mp4');
      final attemptId = coordinator.currentAttemptId;
      var calls = 0;
      coordinator.onReconnectRequired = (_, _) async {
        calls++;
        throw StateError('open failed');
      };

      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -8,
        ),
        attemptId: attemptId,
      );
      expect(coordinator.state.stage, StreamStage.reconnecting);
      expect(coordinator.state.reconnectAttempts, 1);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(calls, 1);
      expect(coordinator.state.stage, StreamStage.reconnecting);
      expect(coordinator.state.reconnectAttempts, 2);

      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(calls, 2);
      expect(coordinator.state.stage, StreamStage.failed);
      expect(coordinator.state.error, contains('Tap Retry'));
    });

    test(
      'a thrown reconnect after stop does not fail the idle player',
      () async {
        await coordinator.prepareStream('https://example.com/stream.mp4');
        coordinator.onReconnectRequired = (_, _) async {
          coordinator.stop();
          throw StateError('open failed');
        };
        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.ended(
            endReason: NativeEndReason.error,
            errorCode: -8,
          ),
          attemptId: coordinator.currentAttemptId,
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(coordinator.state.stage, StreamStage.idle);
      },
    );

    test('refresh replaces expired quality urls', () async {
      const page = 'https://example.com/watch';
      const oldLow = 'https://cdn.example/low?expire=1';
      const oldHigh = 'https://cdn.example/high?expire=1';
      const newLow = 'https://cdn.example/low?expire=2';
      const newHigh = 'https://cdn.example/high?expire=2';
      final subject = StreamingCoordinator(
        ytDlpResolver: _SequenceResolver(
          initial: const ResolvedStream(
            originalUrl: page,
            streamUrl: oldLow,
            isExpiring: true,
            renditions: [
              StreamRendition(
                id: '360',
                label: '360p',
                height: 360,
                url: oldLow,
              ),
              StreamRendition(
                id: '720',
                label: '720p',
                height: 720,
                url: oldHigh,
              ),
            ],
          ),
          refreshed: const ResolvedStream(
            originalUrl: page,
            streamUrl: newLow,
            isExpiring: true,
            renditions: [
              StreamRendition(
                id: '360',
                label: '360p',
                height: 360,
                url: newLow,
              ),
              StreamRendition(
                id: '720',
                label: '720p',
                height: 720,
                url: newHigh,
              ),
            ],
          ),
        ),
      );
      addTearDown(subject.dispose);

      await subject.prepareStream(page);
      expect(
        subject.state.availableRenditions.map((rendition) => rendition.url),
        containsAll(<String?>[oldLow, oldHigh]),
      );

      final refreshed = await subject.refreshExpiringStream();
      expect(refreshed, isNotNull);
      final urls = subject.state.availableRenditions
          .map((rendition) => rendition.url)
          .toList();
      expect(urls, containsAll(<String?>[newLow, newHigh]));
      expect(urls, isNot(contains(oldLow)));
      expect(urls, isNot(contains(oldHigh)));
      expect(
        subject.state.availableRenditions.any((rendition) => rendition.isAuto),
        isTrue,
      );
    });

    test(
      'failed quality switch reopens the previous stream before reporting ready',
      () async {
        await coordinator.prepareStream('https://example.com/video.mp4');
        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: coordinator.currentAttemptId,
        );
        coordinator.updatePosition(const Duration(seconds: 12));
        StreamInputSnapshot? restored;
        coordinator.onRestorePreviousStream = (snapshot) async {
          restored = snapshot;
        };
        const high = StreamRendition(
          id: '720',
          label: '720p',
          height: 720,
          url: 'https://cdn.example/720.mp4',
        );
        coordinator.selectRendition(high);
        coordinator.failQualitySwitch(high);
        expect(coordinator.state.stage, StreamStage.switchingQuality);
        expect(coordinator.state.stageMessage, contains('Restoring'));

        await Future<void>.delayed(Duration.zero);
        expect(restored?.streamUrl, 'https://example.com/video.mp4');
        expect(restored?.position, const Duration(seconds: 12));
        expect(coordinator.state.stage, StreamStage.ready);
        expect(coordinator.state.isAutoQuality, isTrue);
        expect(coordinator.state.selectedRendition?.isAuto, isTrue);
      },
    );

    test('failed stream restore does not report playback as ready', () async {
      await coordinator.prepareStream('https://example.com/video.mp4');
      coordinator.onRestorePreviousStream = (_) async {
        throw StateError('reopen failed');
      };
      const high = StreamRendition(
        id: '720',
        label: '720p',
        height: 720,
        url: 'https://cdn.example/720.mp4',
      );
      coordinator.selectRendition(high);
      coordinator.failQualitySwitch(high);
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.state.stage, StreamStage.failed);
      expect(coordinator.state.error, contains('previous stream'));
      expect(coordinator.state.isAutoQuality, isTrue);
    });

    test('transient error invokes onReconnectRequired callback', () async {
      await coordinator.prepareStream('https://example.com/stream.mp4');
      final attemptId = coordinator.currentAttemptId;
      coordinator.updatePosition(const Duration(seconds: 42));

      int? reconnectedAttempt;
      Duration? reconnectedPosition;
      coordinator.onReconnectRequired = (attId, pos) async {
        reconnectedAttempt = attId;
        reconnectedPosition = pos;
      };

      coordinator.handleNativeLifecycleEvent(
        const NativeMediaEvent.ended(
          endReason: NativeEndReason.error,
          errorCode: -8, // MPV_ERROR_LOADING_FAILED (transient socket drop)
        ),
        attemptId: attemptId,
      );

      expect(coordinator.state.stage, equals(StreamStage.reconnecting));
      expect(coordinator.state.reconnectAttempts, equals(1));

      // Wait for delay
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(reconnectedAttempt, equals(attemptId));
      expect(reconnectedPosition, equals(const Duration(seconds: 42)));
    });

    test(
      'stop clears all active state to idle and drops resolved references',
      () async {
        await coordinator.prepareStream('https://example.com/stream.mp4');
        expect(coordinator.state.stage, isNot(equals(StreamStage.idle)));

        coordinator.stop();
        expect(coordinator.state.stage, equals(StreamStage.idle));
        expect(coordinator.state.originalUrl, isEmpty);
        expect(coordinator.activeResolvedPage, isNull);
        expect(coordinator.activeManifest, isNull);
      },
    );

    test(
      'auto quality downshift triggers onAutoQualitySwitch callback',
      () async {
        const renditions = [
          StreamRendition(
            id: '360p',
            label: '360p',
            height: 360,
            bitrate: 800000,
          ),
          StreamRendition(
            id: '720p',
            label: '720p',
            height: 720,
            bitrate: 2000000,
          ),
        ];

        final fakeManifestService = _FakeStreamManifestService(
          const StreamManifestInfo(
            masterUrl: 'https://example.com/master.m3u8',
            format: StreamFormat.hls,
            variants: renditions,
          ),
        );

        final autoCoordinator = StreamingCoordinator(
          manifestService: fakeManifestService,
        );

        await autoCoordinator.prepareStream('https://example.com/master.m3u8');
        expect(
          autoCoordinator.state.availableRenditions.length,
          3,
        ); // Auto + 2 variants

        StreamRendition? autoSwitchedTarget;
        autoCoordinator.onAutoQualitySwitch = (target) async {
          autoSwitchedTarget = target;
        };

        // Set loaded (ready stage) on 720p
        autoCoordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: autoCoordinator.currentAttemptId,
        );
        expect(autoCoordinator.state.stage, equals(StreamStage.ready));

        autoCoordinator.updateDemuxerStats(width: 1280, height: 720);

        // Simulate underruns to trigger downshift
        autoCoordinator.updateDemuxerStats(
          bufferedDuration: const Duration(milliseconds: 500),
          rawInputRate: 50000,
          pausedForCache: true,
        );
        autoCoordinator.updateDemuxerStats(
          bufferedDuration: const Duration(milliseconds: 200),
          rawInputRate: 40000,
          pausedForCache: true,
        );

        // Verify downshift triggered
        expect(
          autoCoordinator.state.stage,
          equals(StreamStage.switchingQuality),
        );
        expect(autoSwitchedTarget, isNotNull);
        expect(autoSwitchedTarget?.label, equals('360p'));

        autoCoordinator.dispose();
      },
    );

    test(
      'updateDemuxerStats preserves bufferedDuration when null and completes switchingQuality across split width/height events',
      () async {
        await coordinator.prepareStream('https://example.com/master.m3u8');
        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: coordinator.currentAttemptId,
        );

        coordinator.updateDemuxerStats(
          bufferedDuration: const Duration(seconds: 12),
          rawInputRate: 500000,
        );
        expect(
          coordinator.state.bufferedDuration,
          equals(const Duration(seconds: 12)),
        );

        coordinator.selectRendition(
          const StreamRendition(id: '720p', label: '720p', height: 720),
        );
        expect(coordinator.state.stage, equals(StreamStage.switchingQuality));

        // Partial stat updates without bufferedDuration preserve previous buffer.
        coordinator.updateDemuxerStats(rawInputRate: 750000);
        expect(
          coordinator.state.bufferedDuration,
          equals(const Duration(seconds: 12)),
        );
        expect(coordinator.state.stage, equals(StreamStage.switchingQuality));

        // Split width then height events complete the quality switch cleanly.
        coordinator.updateDemuxerStats(width: 1280);
        expect(coordinator.state.stage, equals(StreamStage.switchingQuality));
        expect(coordinator.state.decodedWidth, equals(1280));

        coordinator.updateDemuxerStats(height: 720);
        expect(coordinator.state.stage, equals(StreamStage.ready));
        expect(coordinator.state.decodedWidth, equals(1280));
        expect(coordinator.state.decodedHeight, equals(720));
      },
    );

    test(
      'real libmpv terminal error codes and HTTP 404/403 fail immediately without reconnecting',
      () async {
        for (final code in [-16, -17, -18, -19]) {
          await coordinator.prepareStream('https://example.com/bad-$code.mp4');
          coordinator.handleNativeLifecycleEvent(
            NativeMediaEvent.ended(
              endReason: NativeEndReason.error,
              errorCode: code,
            ),
            attemptId: coordinator.currentAttemptId,
          );
          expect(coordinator.state.stage, equals(StreamStage.failed));
          expect(coordinator.state.reconnectAttempts, equals(0));
        }

        await coordinator.prepareStream('https://example.com/missing.mp4');
        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.ended(
            endReason: NativeEndReason.error,
            errorCode: -13,
          ),
          attemptId: coordinator.currentAttemptId,
          httpStatusCode: 404,
        );
        expect(coordinator.state.stage, equals(StreamStage.failed));
        expect(coordinator.state.reconnectAttempts, equals(0));
        expect(coordinator.state.error, contains('404'));

        await coordinator.prepareStream('https://example.com/forbidden.mp4');
        coordinator.handleNativeLifecycleEvent(
          const NativeMediaEvent.ended(
            endReason: NativeEndReason.error,
            errorCode: -13,
          ),
          attemptId: coordinator.currentAttemptId,
          httpStatusCode: 403,
        );
        expect(coordinator.state.stage, equals(StreamStage.failed));
        expect(coordinator.state.reconnectAttempts, equals(0));
        expect(coordinator.state.error, contains('403'));
      },
    );

    test(
      'missing yt-dlp on known video host fails cleanly instead of falling back',
      () async {
        final missingResolver = YtDlpResolver(
          runner: _MissingYtDlpRunner(),
          executablePath: 'yt-dlp',
        );
        final ytCoordinator = StreamingCoordinator(
          ytDlpResolver: missingResolver,
        );
        addTearDown(ytCoordinator.dispose);

        final prepared = await ytCoordinator.prepareStream(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        );
        expect(prepared, isNull);
        expect(ytCoordinator.state.stage, equals(StreamStage.failed));
        expect(ytCoordinator.state.error, contains('yt-dlp'));
      },
    );

    test(
      'auto quality applies conservative initial rendition for yt-dlp streams',
      () async {
        const muxed360 = StreamRendition(
          id: '18',
          label: '360p',
          width: 640,
          height: 360,
          bitrate: 500000,
          url: 'https://cdn.example.com/360.mp4',
          isMuxed: true,
        );
        const split720 = StreamRendition(
          id: '136',
          label: '720p',
          width: 1280,
          height: 720,
          bitrate: 1800000,
          url: 'https://cdn.example.com/720.mp4',
          audioUrl: 'https://cdn.example.com/audio.m4a',
          httpHeaders: {'Referer': 'https://example.com/'},
          isMuxed: false,
        );
        const split1080 = StreamRendition(
          id: '137',
          label: '1080p',
          width: 1920,
          height: 1080,
          bitrate: 4000000,
          url: 'https://cdn.example.com/1080.mp4',
          audioUrl: 'https://cdn.example.com/audio.m4a',
          isMuxed: false,
        );
        final subject = StreamingCoordinator(
          ytDlpResolver: _StaticResolvedStreamResolver(
            const ResolvedStream(
              originalUrl: 'https://example.com/watch',
              streamUrl: 'https://cdn.example.com/360.mp4',
              renditions: [split1080, split720, muxed360],
            ),
          ),
        );
        addTearDown(subject.dispose);

        final prepared = await subject.prepareStream(
          'https://example.com/watch',
        );
        expect(prepared, isNotNull);
        expect(prepared!.isAutoQuality, isTrue);
        expect(prepared.playableUrl, 'https://cdn.example.com/720.mp4');
        expect(prepared.audioUrl, 'https://cdn.example.com/audio.m4a');
        expect(subject.activeHttpHeaders, {'Referer': 'https://example.com/'});
      },
    );

    test(
      'multi-codec yt-dlp streams disambiguate active rendition and confirm switches',
      () async {
        const low = StreamRendition(
          id: '18',
          label: '360p',
          width: 640,
          height: 360,
          bitrate: 500000,
          url: 'https://cdn.example.com/360.mp4',
          isMuxed: true,
        );
        const vp9_720 = StreamRendition(
          id: '247',
          label: '720p',
          width: 1280,
          height: 720,
          bitrate: 1500000,
          url: 'https://cdn.example.com/720-vp9.webm',
          audioUrl: 'https://cdn.example.com/audio.webm',
          isMuxed: false,
        );
        const avc_720 = StreamRendition(
          id: '136',
          label: '720p',
          width: 1280,
          height: 720,
          bitrate: 1900000,
          url: 'https://cdn.example.com/720-avc.mp4',
          audioUrl: 'https://cdn.example.com/audio.m4a',
          isMuxed: false,
        );
        final subject = StreamingCoordinator(
          ytDlpResolver: _StaticResolvedStreamResolver(
            const ResolvedStream(
              originalUrl: 'https://example.com/watch',
              streamUrl: 'https://cdn.example.com/360.mp4',
              renditions: [avc_720, vp9_720, low],
            ),
          ),
        );
        addTearDown(subject.dispose);

        await subject.prepareStream('https://example.com/watch');
        subject.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: subject.currentAttemptId,
        );
        // Active rendition resolves immediately to avc_720 (exact URL match).
        expect(subject.state.activeRendition, avc_720);

        // Switching to another codec at the same 720p resolution confirms cleanly.
        subject.selectRendition(vp9_720);
        expect(subject.state.stage, StreamStage.switchingQuality);
        subject.recordStreamInput(vp9_720.url!, vp9_720.audioUrl);
        subject.handleNativeLifecycleEvent(
          const NativeMediaEvent.loaded(),
          attemptId: subject.currentAttemptId,
        );
        expect(subject.state.stage, StreamStage.ready);
        expect(subject.state.activeRendition, vp9_720);

        // Re-enable Auto and verify downshift steps down to 360p (not 720p).
        subject.selectRendition(StreamRendition.auto);
        StreamRendition? downshiftTarget;
        subject.onAutoQualitySwitch = (target) async {
          downshiftTarget = target;
        };
        subject.updateDemuxerStats(
          bufferedDuration: const Duration(milliseconds: 400),
          pausedForCache: true,
        );
        subject.updateDemuxerStats(
          bufferedDuration: const Duration(milliseconds: 200),
          pausedForCache: true,
        );
        expect(downshiftTarget, low);
      },
    );

    test('DASH manifest with DRM fails immediately with DRM error', () async {
      final subject = StreamingCoordinator(
        manifestService: _FakeStreamManifestService(
          const StreamManifestInfo(
            masterUrl: 'https://example.com/drm.mpd',
            format: StreamFormat.dash,
            hasUnsupportedDrm: true,
          ),
        ),
      );
      addTearDown(subject.dispose);

      final prepared = await subject.prepareStream(
        'https://example.com/drm.mpd',
      );
      expect(prepared, isNull);
      expect(subject.state.stage, StreamStage.failed);
      expect(subject.state.error, contains('DRM'));
    });

    test(
      'direct fallback does not advertise bogus quality renditions',
      () async {
        final subject = StreamingCoordinator(
          manifestService: _FakeStreamManifestService(
            StreamManifestInfo.directFallback('https://example.com/media'),
          ),
        );
        addTearDown(subject.dispose);

        final prepared = await subject.prepareStream(
          'https://example.com/media',
        );
        expect(prepared, isNotNull);
        expect(subject.state.availableRenditions, isEmpty);
      },
    );
  });
}

class _StaticResolvedStreamResolver extends YtDlpResolver {
  _StaticResolvedStreamResolver(this.stream);
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

class _MissingYtDlpRunner extends ProcessRunner {
  @override
  Future<ProcessExecutionResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
    Duration? timeout,
  }) {
    throw ProcessException(executable, arguments, 'Not found', 2);
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    throw ProcessException(executable, arguments, 'Not found', 2);
  }
}

class _FakeStreamManifestService extends StreamManifestService {
  _FakeStreamManifestService(this.info);
  final StreamManifestInfo info;

  @override
  Future<StreamManifestInfo> discover(
    String source, {
    dynamic client,
    Duration? timeout,
  }) async => info;
}

class _SequenceResolver extends YtDlpResolver {
  _SequenceResolver({required this.initial, required this.refreshed});

  final ResolvedStream initial;
  final ResolvedStream refreshed;

  @override
  bool canResolve(String url) => url == initial.originalUrl;

  @override
  Future<ResolvedStream> resolve(
    String url, {
    Duration timeout = const Duration(seconds: 35),
    CancellationToken? cancelToken,
  }) async => initial;

  @override
  Future<ResolvedStream> refresh(
    ResolvedStream stream, {
    Duration timeout = const Duration(seconds: 35),
    CancellationToken? cancelToken,
  }) async => refreshed;
}

class _RefreshResolver extends YtDlpResolver {
  final result = Completer<ResolvedStream>();
  CancellationToken? refreshToken;
  @override
  bool canResolve(String url) => url.endsWith('/page');
  @override
  Future<ResolvedStream> resolve(
    String url, {
    Duration timeout = const Duration(seconds: 35),
    CancellationToken? cancelToken,
  }) async => ResolvedStream(
    originalUrl: url,
    streamUrl: 'https://example.com/first.mp4',
    isExpiring: true,
  );
  @override
  Future<ResolvedStream> refresh(
    ResolvedStream stream, {
    Duration timeout = const Duration(seconds: 35),
    CancellationToken? cancelToken,
  }) {
    refreshToken = cancelToken;
    return result.future;
  }
}
