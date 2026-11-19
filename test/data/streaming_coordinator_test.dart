import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/native_media_events.dart';
import 'package:mpvson/data/services/streaming_coordinator.dart';
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
  });
}
