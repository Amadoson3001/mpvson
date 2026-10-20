import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/playback_statistics.dart';
import 'package:mpvson/domain/models/playback_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled mpv accepts tuning presets, picture and timing controls',
    () async {
      final dll = File(
        p.absolute('build/windows/x64/runner/Release/libmpv-2.dll'),
      );
      final media = File(p.absolute('test-output/smoke.mp4'));
      expect(
        dll.existsSync(),
        isTrue,
        reason: 'Build the Windows release first.',
      );
      expect(media.existsSync(), isTrue);
      MediaKit.ensureInitialized(libmpv: dll.path);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final service = MediaKitPlaybackService(
        player: player,
        videoController: _HeadlessVideoController(player),
      );
      try {
        await service.prepare();
        await service.setVolume(0);
        await service.open(media.path);
        await Future<void>.delayed(const Duration(seconds: 1));
        final native = player.platform! as NativePlayer;
        for (final preset in PlaybackQualityPreset.values) {
          final result = await service.applyPlaybackSettings(
            PlaybackSettings(
              qualityPreset: preset,
              preferHardwareDecoding: false,
              brightness: 7,
              contrast: -3,
              saturation: 11,
              gamma: 2,
              audioDelaySeconds: -0.15,
              subtitleDelaySeconds: 0.35,
            ),
          );
          expect(
            result.succeeded,
            isTrue,
            reason: '${preset.name}: ${result.reason}',
          );
          expect(double.parse(await native.getProperty('brightness')), 7);
          expect(
            double.parse(await native.getProperty('audio-delay')),
            closeTo(-0.15, 0.001),
          );
          expect(await native.getProperty('hwdec'), 'no');
        }
        final reset = await service.applyPlaybackSettings(
          PlaybackSettings.defaults,
        );
        expect(reset.succeeded, isTrue, reason: reset.reason);
        expect(double.parse(await native.getProperty('brightness')), 0);
        expect(double.parse(await native.getProperty('audio-delay')), 0);
        final statistics = await readNativePlaybackStatistics(player);
        expect(statistics.values['Playback engine'], contains('mpv'));
      } finally {
        await service.dispose();
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('MPVSON_NATIVE_TUNING'),
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// Supplies only the readiness gate. This test exercises real mpv properties
/// under vo=null; rendered video is verified by the native release smoke test.
class _HeadlessVideoController implements VideoController {
  _HeadlessVideoController(Player player) {
    platform.complete(_HeadlessPlatformVideoController(player));
  }

  @override
  final platform = Completer<PlatformVideoController>();

  @override
  Future<void> setSize({int? width, int? height}) async {}

  @override
  Future<void> setRenderVisibility(bool visible) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeadlessPlatformVideoController extends PlatformVideoController {
  _HeadlessPlatformVideoController(Player player)
    : super(player, const VideoControllerConfiguration());

  @override
  Future<void> setSize({int? width, int? height}) async {}
}
