import 'dart:async';

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
}
