import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/data/services/seek_preview_service.dart';

/// Engine stand-in for the preview worker. The video output wait fails before
/// any engine command is reached, so nothing else needs stubbing.
class _StubEnginePlayer extends PlatformPlayer {
  _StubEnginePlayer() : super(configuration: const PlayerConfiguration());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'backend open fails bounded instead of hanging on a never-completing video output',
    () async {
      final backend = MediaKitSeekPreviewBackend(
        playerFactory: () => Player(platformPlayer: _StubEnginePlayer()),
        // A real VideoController created without a rendered frame never
        // completes its platform initialization: the stalled future.
        videoControllerFactory: (player) => VideoController(player),
        platformInitTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(backend.dispose);

      await expectLater(
        backend.open('C:/Media/video.mp4').timeout(const Duration(seconds: 5)),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test(
    'service dispose completes while a preview open is stuck on the platform future',
    () async {
      final service = SeekPreviewService(
        backendFactory: () => MediaKitSeekPreviewBackend(
          playerFactory: () => Player(platformPlayer: _StubEnginePlayer()),
          videoControllerFactory: (player) => VideoController(player),
          platformInitTimeout: const Duration(milliseconds: 50),
        ),
      );

      await service.setSource('C:/Media/video.mp4');
      // Starts an extraction whose backend open waits for the platform future.
      service.onPointerMove(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Dispose is queued behind the stuck open; it must still complete.
      await service.dispose().timeout(const Duration(seconds: 5));
    },
  );

  test(
    'SeekPreviewLRUCache pre-emptively evicts keyframe entries under memory pressure',
    () {
      final cache = SeekPreviewLRUCache(
        maxEntries: 10,
        maxBytes: 1000,
        pressureThreshold: 0.8,
      );

      // Add 8 keyframe entries (each 100 bytes = 800 bytes, reaching 80% threshold)
      for (var i = 0; i < 8; i++) {
        cache.put(
          SeekPreviewFrame(
            bytes: Uint8List(100),
            requestedTime: Duration(seconds: i),
            capturedTime: Duration(seconds: i),
            quality: SeekPreviewQuality.keyframe,
          ),
        );
      }

      // Add 1 exact entry (100 bytes)
      cache.put(
        SeekPreviewFrame(
          bytes: Uint8List(100),
          requestedTime: const Duration(seconds: 100),
          capturedTime: const Duration(seconds: 100),
          quality: SeekPreviewQuality.exact,
        ),
      );

      // Total would be 900 bytes > 800 bytes (80% threshold), so pre-emptive eviction
      // reduced keyframe entries down towards 75% (750 bytes / 7 entries).
      expect(cache.currentBytes, lessThanOrEqualTo(800));
      // The exact entry should still be preserved
      final exactFrame = cache.get(const Duration(seconds: 100), exactOnly: true);
      expect(exactFrame, isNotNull);
      expect(exactFrame!.quality, SeekPreviewQuality.exact);
    },
  );

  test(
    'SeekPreviewService drops and cancels stale extraction when scrubber moves to new bucket',
    () async {
      var cancelExtractionCalled = false;
      final extractCompleter = Completer<SeekPreviewFrame?>();

      final fakeBackend = _MockSeekBackend(
        onCancelExtraction: () {
          cancelExtractionCalled = true;
          if (!extractCompleter.isCompleted) {
            extractCompleter.complete(null);
          }
        },
        onExtract: (target, exact) => extractCompleter.future,
      );

      final service = SeekPreviewService(
        backendFactory: () => fakeBackend,
      );
      addTearDown(service.dispose);

      await service.setSource('C:/Media/video.mp4');

      // Request hover at 5 seconds
      service.onPointerMove(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.state.targetTime, const Duration(seconds: 5));

      // User rapidly scrubs to 45 seconds while 5s is in flight
      service.onPointerMove(const Duration(seconds: 45));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(cancelExtractionCalled, isTrue);
      expect(service.state.targetTime, const Duration(seconds: 45));
    },
  );
}

class _MockSeekBackend implements SeekPreviewBackend {
  _MockSeekBackend({
    this.onCancelExtraction,
    this.onExtract,
  });

  final void Function()? onCancelExtraction;
  final Future<SeekPreviewFrame?> Function(Duration target, bool exact)? onExtract;

  @override
  Future<void> open(
    String source, {
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) async {}

  @override
  Future<SeekPreviewFrame?> extractFrame(
    Duration target, {
    required bool exact,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    return onExtract != null ? await onExtract!(target, exact) : null;
  }

  @override
  void cancelExtraction() {
    onCancelExtraction?.call();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
