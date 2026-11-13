import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';

void main() {
  group('VideoOutputPolicy.fitVideo', () {
    test('fits inside the viewport without upscaling', () {
      const policy = VideoOutputPolicy(
        physicalWidth: 1280,
        physicalHeight: 720,
      );

      expect(policy.fitVideo(width: 1920, height: 1080), (
        width: 1280,
        height: 720,
      ));
      expect(policy.fitVideo(width: 640, height: 360), (
        width: 640,
        height: 360,
      ));
    });

    test('snaps odd fitted sizes down to even pixels', () {
      const policy = VideoOutputPolicy(
        physicalWidth: 1281,
        physicalHeight: 721,
      );

      expect(policy.fitVideo(width: 1920, height: 1080), (
        width: 1280,
        height: 720,
      ));
    });

    test('returns null when the viewport or video is missing', () {
      const policy = VideoOutputPolicy(
        physicalWidth: 1280,
        physicalHeight: 720,
      );

      expect(policy.fitVideo(width: null, height: 1080), isNull);
      expect(
        const VideoOutputPolicy().fitVideo(width: 1920, height: 1080),
        isNull,
      );
    });
  });

  group('VideoOutputPolicy.significantSizeChange', () {
    test('treats the first size as a change', () {
      expect(
        VideoOutputPolicy.significantSizeChange(
          previousWidth: null,
          previousHeight: null,
          width: 1280,
          height: 720,
        ),
        isTrue,
      );
    });

    test('ignores sub-slack jitter', () {
      expect(
        VideoOutputPolicy.significantSizeChange(
          previousWidth: 1280,
          previousHeight: 720,
          width: 1284,
          height: 722,
        ),
        isFalse,
      );
    });

    test('applies a resize once the slack is crossed', () {
      expect(
        VideoOutputPolicy.significantSizeChange(
          previousWidth: 1280,
          previousHeight: 720,
          width: 1200,
          height: 720,
        ),
        isTrue,
      );
    });
  });
}
