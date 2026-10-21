import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/domain/models/playback_settings.dart';

void main() {
  test('persisted values fall back and clamp to supported ranges', () {
    final settings = PlaybackSettings.fromJson(<String, Object?>{
      'qualityPreset': 'unknown-preset',
      'preferHardwareDecoding': 'yes',
      'brightness': 400,
      'contrast': -250,
      'saturation': double.nan,
      'gamma': 12.5,
      'audioDelaySeconds': 900,
      'subtitleDelaySeconds': -900,
    });

    expect(settings.qualityPreset, PlaybackQualityPreset.balanced);
    expect(settings.preferHardwareDecoding, isTrue);
    expect(settings.brightness, 100);
    expect(settings.contrast, -100);
    expect(settings.saturation, 0);
    expect(settings.gamma, 12.5);
    expect(settings.audioDelaySeconds, 10);
    expect(settings.subtitleDelaySeconds, -10);
  });

  test('playback settings round-trip through the saved session', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mpvson-playback-settings-test-',
    );
    try {
      const settings = PlaybackSettings(
        qualityPreset: PlaybackQualityPreset.quality,
        preferHardwareDecoding: false,
        brightness: 15,
        contrast: -12,
        saturation: 24,
        gamma: 5,
        audioDelaySeconds: -0.3,
        subtitleDelaySeconds: 1.2,
      );
      final repository = SessionRepository(directory: directory);
      await repository.save(const PlaybackSession(playbackSettings: settings));

      final loaded = await repository.load();

      expect(loaded?.playbackSettings, settings);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
