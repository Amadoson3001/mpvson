import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';

/// Engine stand-in whose native handle can never be retrieved, so the video
/// controller's native initialization always fails the way a broken platform
/// channel or a missing decoder does.
class _HandlelessEnginePlayer extends PlatformPlayer {
  _HandlelessEnginePlayer() : super(configuration: const PlayerConfiguration());

  @override
  Future<int> get handle => throw UnimplementedError('no native handle');
}

/// Renders a frame so the controller's post-frame native initialization runs,
/// then advances fake time past the debounced resize so no timer stays pending.
Future<void> _settleController(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.expand());
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets(
    'a failed VideoController creation is not cached and the next access recreates it',
    (tester) async {
      final engine = _HandlelessEnginePlayer();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: engine),
      );
      addTearDown(service.dispose);

      final first = service.videoController;
      await _settleController(tester);
      final failed = await first.platform.future.then<bool>(
        (_) => false,
        onError: (_, _) => true,
      );
      expect(failed, isTrue);

      // The broken controller must have been dropped from the cache, so the
      // next access builds a fresh one instead of reusing the failure.
      final second = service.videoController;
      expect(identical(first, second), isFalse);
      await _settleController(tester);
    },
  );

  testWidgets(
    'setRenderVisibility failures never surface as unhandled async errors',
    (tester) async {
      final engine = _HandlelessEnginePlayer();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: engine),
      );
      addTearDown(service.dispose);

      // Arming a hidden policy before the controller exists schedules a
      // visibility write that fails once the native side errors; the frame
      // pump lets it happen. This test fails if any unhandled async error is
      // reported.
      service.applyVideoOutputPolicy(const VideoOutputPolicy(visible: false));
      final controller = service.videoController;
      await _settleController(tester);
      expect(controller.platform.isCompleted, isTrue);
      // Flip the policy again after the failure: the retry must also be
      // swallowed instead of escaping as an unhandled error.
      service.applyVideoOutputPolicy(const VideoOutputPolicy(visible: true));
      await _settleController(tester);
    },
  );
}
