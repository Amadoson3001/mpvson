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
import 'package:mpvson/domain/models/stream_rendition.dart';

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
  });
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
