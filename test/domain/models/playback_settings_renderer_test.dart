import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/playback_settings.dart';

void main() {
  group('PlaybackSettings.rendererProperties', () {
    test('performance is the cheap old-hardware profile', () {
      final properties = const PlaybackSettings(
        qualityPreset: PlaybackQualityPreset.performance,
      ).rendererProperties;

      expect(properties['scale'], 'bilinear');
      expect(properties['dscale'], 'bilinear');
      expect(properties['deband'], 'no');
      expect(properties['gpu-dumb-mode'], 'yes');
      expect(properties['dither'], 'no');
      expect(properties['correct-downscaling'], 'no');
      expect(properties['linear-downscaling'], 'no');
      expect(properties['sigmoid-upscaling'], 'no');
      expect(properties['hdr-compute-peak'], 'no');
      expect(properties['fbo-format'], 'rgba8');
    });

    test('balanced keeps a modern picture without EWA or HDR peak', () {
      final properties = const PlaybackSettings(
        qualityPreset: PlaybackQualityPreset.balanced,
      ).rendererProperties;

      expect(properties['scale'], 'lanczos');
      expect(properties['dscale'], 'mitchell');
      expect(properties['deband'], 'no');
      expect(properties['gpu-dumb-mode'], 'no');
      expect(properties['dither'], 'auto');
      expect(properties['correct-downscaling'], 'yes');
      expect(properties.containsKey('fbo-format'), isFalse);
    });

    test('quality restores extra processing for capable GPUs', () {
      final properties = const PlaybackSettings(
        qualityPreset: PlaybackQualityPreset.quality,
      ).rendererProperties;

      expect(properties['scale'], 'lanczos');
      expect(properties['cscale'], 'lanczos');
      expect(properties['dscale'], 'mitchell');
      expect(properties['deband'], 'yes');
      expect(properties['dither'], 'yes');
      expect(properties['linear-downscaling'], 'yes');
      expect(properties['sigmoid-upscaling'], 'yes');
      expect(properties['hdr-compute-peak'], 'yes');
      expect(properties['gpu-dumb-mode'], 'no');
      expect(properties.containsKey('fbo-format'), isFalse);
    });
  });
}
