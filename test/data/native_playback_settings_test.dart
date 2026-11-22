import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/playback_settings.dart';

void main() {
  test(
    'native libmpv confirms all PlaybackSettings presets and setRate',
    () async {
      if (!Platform.isWindows) return;
      final candidates = <String>[
        p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Debug',
          'libmpv-2.dll',
        ),
        p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Release',
          'libmpv-2.dll',
        ),
      ];
      String? dllPath;
      for (final candidate in candidates) {
        if (File(candidate).existsSync()) {
          dllPath = candidate;
          break;
        }
      }
      if (dllPath == null) return;

      MediaKit.ensureInitialized(libmpv: dllPath);

      final service = MediaKitPlaybackService();
      addTearDown(service.dispose);
      final native = service.player.platform as NativePlayer;

      for (final preset in PlaybackQualityPreset.values) {
        final result = await service.applyPlaybackSettings(
          PlaybackSettings(qualityPreset: preset),
        );
        expect(
          result.succeeded,
          isTrue,
          reason:
              'Preset ${preset.name} failed on ${result.failedProperties}: ${result.reason}',
        );
        expect(result.failedProperties, isEmpty);
      }

      for (final rate in const <double>[0.5, 1.5, 2.0, 1.0]) {
        await service.setRate(rate);
        final actual = double.parse((await native.getProperty('speed')).trim());
        expect(actual, closeTo(rate, 0.001));
        expect(service.state.rate, closeTo(rate, 0.001));
      }
    },
  );
}
