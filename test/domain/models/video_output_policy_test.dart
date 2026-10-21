import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';

void main() {
  test('4K video renders only the pixels the viewport can display', () {
    const policy = VideoOutputPolicy(physicalWidth: 1280, physicalHeight: 800);
    expect(policy.fitVideo(width: 3840, height: 2160), (
      width: 1280,
      height: 720,
    ));
  });

  test('small source keeps its native resolution', () {
    const policy = VideoOutputPolicy(physicalWidth: 1920, physicalHeight: 1080);
    expect(policy.fitVideo(width: 640, height: 360), (width: 640, height: 360));
  });

  test('portrait display dimensions fit by height', () {
    const policy = VideoOutputPolicy(physicalWidth: 1280, physicalHeight: 720);
    expect(policy.fitVideo(width: 1080, height: 1920), (
      width: 405,
      height: 720,
    ));
  });

  test('extreme aspect ratio never requests a zero-sized texture', () {
    const policy = VideoOutputPolicy(physicalWidth: 1, physicalHeight: 1);
    expect(policy.fitVideo(width: 8192, height: 1), (width: 1, height: 1));
    expect(policy.fitVideo(width: 1, height: 8192), (width: 1, height: 1));
  });

  test('missing or invalid viewport and source sizes do not allocate', () {
    const policy = VideoOutputPolicy(physicalWidth: 1280, physicalHeight: 720);
    expect(policy.fitVideo(width: null, height: 1080), isNull);
    expect(policy.fitVideo(width: 1920, height: 0), isNull);
    expect(policy.fitVideo(width: -1, height: 1080), isNull);
    expect(
      const VideoOutputPolicy().fitVideo(width: 1920, height: 1080),
      isNull,
    );
    expect(
      const VideoOutputPolicy(
        physicalWidth: 0,
        physicalHeight: 720,
      ).fitVideo(width: 1920, height: 1080),
      isNull,
    );
  });
}
