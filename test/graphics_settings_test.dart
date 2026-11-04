import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/domain/models/graphics_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  group('GraphicsSettings', () {
    test('defaults are safe and opt-in for automatic GPU selection', () {
      const settings = GraphicsSettings.defaults;

      expect(settings.preferredGpu, GpuPreferenceMode.systemDefault);
      expect(settings.videoMemoryMode, VideoMemoryMode.zeroCopy);
      expect(settings.trimOnMinimize, isTrue);
      expect(settings.limitDemuxerCache, isTrue);
      expect(
        settings.resolvePreferredGpu(onAcPower: true),
        GpuPreferenceMode.systemDefault,
      );
    });

    test('round-trips every field through JSON', () {
      const settings = GraphicsSettings(
        preferredGpu: GpuPreferenceMode.highPerformance,
        videoMemoryMode: VideoMemoryMode.ramStaged,
        trimOnMinimize: false,
        limitDemuxerCache: false,
      );

      final Object? decoded = jsonDecode(jsonEncode(settings.toJson()));
      final restored = GraphicsSettings.fromJson(decoded);

      expect(restored, settings);
      expect(restored.normalized(), settings);
    });

    test('unknown or corrupt values fall back to defaults', () {
      final settings = GraphicsSettings.fromJson(<String, Object?>{
        'preferredGpu': 'pinned-device',
        'videoMemoryMode': 'gpu-direct',
        'trimOnMinimize': 'sometimes',
        'limitDemuxerCache': null,
      });

      expect(settings.preferredGpu, GpuPreferenceMode.systemDefault);
      expect(settings.videoMemoryMode, VideoMemoryMode.zeroCopy);
      expect(settings.trimOnMinimize, isTrue);
      expect(settings.limitDemuxerCache, isTrue);
      expect(GraphicsSettings.fromJson(null), GraphicsSettings.defaults);
      expect(
        GraphicsSettings.fromJson(<String, Object?>{}),
        GraphicsSettings.defaults,
      );
    });

    test('automatic resolves from AC state without becoming a pin', () {
      const settings = GraphicsSettings(
        preferredGpu: GpuPreferenceMode.automatic,
      );

      expect(
        settings.resolvePreferredGpu(onAcPower: true),
        GpuPreferenceMode.highPerformance,
      );
      expect(
        settings.resolvePreferredGpu(onAcPower: false),
        GpuPreferenceMode.powerSaving,
      );
      expect(
        settings.resolvePreferredGpu(onAcPower: null),
        GpuPreferenceMode.systemDefault,
      );
    });

    test('maps GPU preference modes to registry levels', () {
      expect(GpuPreferenceMode.systemDefault.registryLevel, 0);
      expect(GpuPreferenceMode.powerSaving.registryLevel, 1);
      expect(GpuPreferenceMode.highPerformance.registryLevel, 2);
      expect(GpuPreferenceMode.automatic.registryLevel, isNull);
    });
  });

  group('hwdec resolution', () {
    test('follows the memory mode table', () {
      expect(
        resolveHwdec(
          preferHardwareDecoding: true,
          mode: VideoMemoryMode.zeroCopy,
          isWindows: true,
        ),
        'auto-safe',
      );
      expect(
        resolveHwdec(
          preferHardwareDecoding: true,
          mode: VideoMemoryMode.zeroCopy,
          isWindows: false,
        ),
        'auto',
      );
      expect(
        resolveHwdec(
          preferHardwareDecoding: true,
          mode: VideoMemoryMode.ramStaged,
          isWindows: true,
        ),
        'd3d11va-copy',
      );
      expect(
        resolveHwdec(
          preferHardwareDecoding: true,
          mode: VideoMemoryMode.ramStaged,
          isWindows: false,
        ),
        'auto-copy',
      );
      expect(
        resolveHwdec(
          preferHardwareDecoding: false,
          mode: VideoMemoryMode.ramStaged,
          isWindows: true,
        ),
        'no',
      );
    });
  });

  group('demuxer cache limits', () {
    test('uses measured normal and eco caps when enabled', () {
      final normal = demuxerCacheLimits(limit: true, lowSpec: false);
      expect(normal.forwardBytes, 128 * 1024 * 1024);
      expect(normal.backBytes, 48 * 1024 * 1024);

      final eco = demuxerCacheLimits(limit: true, lowSpec: true);
      expect(eco.forwardBytes, 48 * 1024 * 1024);
      expect(eco.backBytes, 16 * 1024 * 1024);
    });

    test('restores mpv defaults when the limit is disabled', () {
      final normal = demuxerCacheLimits(limit: false, lowSpec: false);
      final eco = demuxerCacheLimits(limit: false, lowSpec: true);

      expect(normal.forwardBytes, 150 * 1024 * 1024);
      expect(normal.backBytes, 75 * 1024 * 1024);
      expect(eco, normal);
    });
  });

  group('DesktopPreferences persistence', () {
    const graphics = GraphicsSettings(
      preferredGpu: GpuPreferenceMode.powerSaving,
      videoMemoryMode: VideoMemoryMode.ramStaged,
      trimOnMinimize: false,
      limitDemuxerCache: false,
    );

    test('round-trips graphics settings', () {
      const preferences = DesktopPreferences(graphics: graphics);
      final Object? decoded = jsonDecode(jsonEncode(preferences.toJson()));
      final restored = DesktopPreferences.fromJson(
        Map<String, Object?>.from(decoded! as Map<Object?, Object?>),
      );

      expect(restored.graphics, graphics);
    });

    test('older files without graphics fall back to defaults', () {
      final restored = DesktopPreferences.fromJson(<String, Object?>{});

      expect(restored.graphics, GraphicsSettings.defaults);
    });

    test('repository writes and reloads graphics settings', () async {
      final directory = await Directory.systemTemp.createTemp(
        'mpvson_graphics_test_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(p.join(directory.path, 'app_preferences.json'));

      final repository = AppPreferencesRepository(preferenceFile: file);
      await repository.load();
      await repository.setGraphicsSettings(graphics);
      await repository.flush();

      final reloaded = AppPreferencesRepository(preferenceFile: file);
      await reloaded.load();

      expect(reloaded.graphicsSettings, graphics);
    });
  });
}
