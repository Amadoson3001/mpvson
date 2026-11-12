import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop runners disable Impeller', () {
    test('Windows runner opts out of the default Impeller compositor', () {
      final source = File('windows/runner/main.cpp').readAsStringSync();

      expect(source, contains('set_impeller_switch'));
      expect(source, contains('ImpellerSwitch::Disabled'));
    });

    test('Linux runner opts out of the default Impeller compositor', () {
      final source = File('linux/runner/my_application.cc').readAsStringSync();

      expect(source, contains('fl_dart_project_set_enable_impeller'));
      expect(source, contains('FALSE'));
    });
  });

  group('Windows video output avoids flicker on resize', () {
    test('keeps the Flutter texture ID across size changes', () {
      final source = File(
        'packages/media_kit_video/windows/video_output.cc',
      ).readAsStringSync();

      expect(
        source,
        contains('Keep the Flutter texture ID across size changes'),
      );
      expect(source, contains('MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME'));
      expect(source.contains('video-timing-offset'), isFalse);
    });

    test('copies the finished frame on the render worker', () {
      final source = File(
        'packages/media_kit_video/windows/angle_surface_manager.cc',
      ).readAsStringSync();

      expect(
        source,
        contains('Copy into the public texture Flutter is not sampling'),
      );
      expect(source, contains('ReleasePreviousTextures'));
      expect(source, contains('RecreateSurface'));
      expect(source, contains('eglCreateDeviceANGLE'));
      expect(source, contains('public_texture_[back]'));
    });

    test('fills the new DXGI surface before Flutter can sample it', () {
      final source = File(
        'packages/media_kit_video/windows/video_output.cc',
      ).readAsStringSync();

      expect(source, contains('PresentHardwareFrame'));
      expect(source, contains('Fill the new surface before publishing'));
      expect(source.contains('surface_manager_->Read()'), isFalse);
    });
  });

  group('Flutter presents video without extra bilinear', () {
    test('native video texture uses nearest sampling', () {
      final source = File('lib/app.dart').readAsStringSync();

      expect(source, contains('filterQuality: FilterQuality.none'));
      expect(source, contains('wakelock: false'));
    });

    test('control-bar blur is skipped on constrained hardware', () {
      final source = File(
        'lib/ui/player/widgets/player_controls.dart',
      ).readAsStringSync();

      expect(source, contains('AppMotion.lowPower(context)'));
      expect(source, contains('controller.isPlaying'));
      expect(source, contains('BackdropFilter'));
    });
  });

  group('Flutter UI stays off the video rebuild path', () {
    test('context menu reuses the video child across controller ticks', () {
      final source = File(
        'lib/ui/player/widgets/player_context_menu.dart',
      ).readAsStringSync();

      expect(source, contains('builder: (context, videoChild)'));
      expect(source, contains('child: videoChild,'));
      expect(source, contains('child: child,'));
    });

    test('now playing follows structure, not every controller tick', () {
      final source = File(
        'lib/ui/library/views/now_playing_view.dart',
      ).readAsStringSync();

      expect(source, contains('structureListenable.addListener'));
      expect(
        source.contains('controller.addListener(_onControllerChanged)'),
        isFalse,
      );
    });

    test('music rows follow structure and transport only', () {
      final source = File(
        'lib/ui/library/views/music_view.dart',
      ).readAsStringSync();

      expect(source, contains('structureListenable'));
      expect(source, contains('transportListenable'));
      expect(
        source.contains('controller.addListener(_onPlaybackChanged)'),
        isFalse,
      );
    });

    test('volume widgets follow volumeListenable', () {
      final inline = File(
        'lib/ui/player/widgets/controls/volume_section.dart',
      ).readAsStringSync();
      final audio = File(
        'lib/ui/library/widgets/audio_volume_control.dart',
      ).readAsStringSync();
      final stage = File(
        'lib/ui/player/views/player_stage.dart',
      ).readAsStringSync();

      expect(inline, contains('volumeListenable'));
      expect(audio, contains('volumeListenable'));
      expect(stage.contains('volumeListenable'), isFalse);
    });
  });
}
