import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/diagnostic_log.dart';
import 'package:mpvson/data/services/thumbnail_service.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:path/path.dart' as p;

// Opt in with an existing local video and the already-built runtime library.
// Runs without a video widget and must not open a native playback window.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native shared decoder renders again after sidecar duration probing',
    () async {
      MediaKit.ensureInitialized(
        libmpv: Platform.isWindows
            ? p.absolute('build/windows/x64/runner/Release/libmpv-2.dll')
            : null,
      );
      final root = await Directory.systemTemp.createTemp('mpvson-reuse-test-');
      final diagnostics = MemoryDiagnosticLog();
      final service = MediaKitThumbnailService(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        diagnostics: diagnostics,
      );
      try {
        final original = File(p.absolute('test-output/smoke.mp4'));
        final replay = await original.copy(p.join(root.path, 'replay.mp4'));
        final sidecar = File(
          p.absolute('test-output/thumbnail-native-fixtures/sidecar-video.mp4'),
        );
        final embedded = File(
          p.absolute(
            'test-output/thumbnail-native-fixtures/video-with-cover.mp4',
          ),
        );
        for (final source in [original, sidecar, embedded, replay]) {
          final thumbnail = await service
              .load(MediaEntry.fromPath(source.path, id: source.path))
              .timeout(const Duration(seconds: 25));
          expect(
            thumbnail,
            isNotNull,
            reason: '${source.path}\n${diagnostics.records.join('\n')}',
          );
          expect(thumbnail!.duration.inMilliseconds, closeTo(8000, 100));
          final codec = await ui.instantiateImageCodec(thumbnail.bytes);
          final frame = await codec.getNextFrame();
          expect(frame.image.width, inInclusiveRange(1, 320));
          expect(frame.image.height, inInclusiveRange(1, 320));
          frame.image.dispose();
          codec.dispose();
        }
      } finally {
        await service.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('MPVSON_TEST_THUMBNAILS'),
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'native thumbnail extraction returns a frame without changing playback',
    () async {
      final source = File(p.absolute('test-output/smoke.mp4'));
      expect(await source.exists(), isTrue);
      MediaKit.ensureInitialized(
        libmpv: Platform.isWindows
            ? p.absolute('build/windows/x64/runner/Release/libmpv-2.dll')
            : null,
      );
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final platform = player.platform! as NativePlayer;
      await platform.setProperty('vid', 'auto');
      await platform.setProperty('aid', 'no');
      await platform.setProperty('cache-on-disk', 'no');
      await player.open(Media(source.path), play: false);
      final ready = Stopwatch()..start();
      while (player.state.playlist.medias.isEmpty &&
          ready.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(player.state.playlist.medias, isNotEmpty);
      final originalPlaylist = player.state.playlist.medias.first.uri;
      final originalPosition = player.state.position;
      final cache = await Directory.systemTemp.createTemp('mpvson-frame-test-');
      final service = MediaKitThumbnailService(cacheDirectory: cache);
      try {
        final thumbnail = await service
            .load(MediaEntry.fromPath(source.path, id: 'native-frame'))
            .timeout(const Duration(seconds: 25));
        expect(thumbnail, isNotNull);
        expect(thumbnail!.bytes.length, greaterThan(100));
        expect(thumbnail.duration, greaterThan(Duration.zero));
        expect(player.state.playlist.medias.first.uri, originalPlaylist);
        expect(player.state.playing, isFalse);
        expect(player.state.position, originalPosition);
        final output = File(
          p.absolute('test-output/thumbnail-native/frame.png'),
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(thumbnail.bytes, flush: true);
      } finally {
        await service.dispose();
        await player.dispose();
        await cache.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('MPVSON_TEST_THUMBNAILS'),
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'native thumbnail extraction prefers embedded cover art to video frames',
    () async {
      final source = File(
        p.absolute(
          'test-output/thumbnail-native-fixtures/video-with-cover.mp4',
        ),
      );
      expect(await source.exists(), isTrue);
      MediaKit.ensureInitialized(
        libmpv: Platform.isWindows
            ? p.absolute('build/windows/x64/runner/Release/libmpv-2.dll')
            : null,
      );
      final cache = await Directory.systemTemp.createTemp('mpvson-cover-test-');
      final service = MediaKitThumbnailService(cacheDirectory: cache);
      try {
        final thumbnail = await service
            .load(MediaEntry.fromPath(source.path, id: 'native-cover'))
            .timeout(const Duration(seconds: 25));
        expect(thumbnail, isNotNull);
        final codec = await ui.instantiateImageCodec(thumbnail!.bytes);
        final frame = await codec.getNextFrame();
        final pixels = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final middle =
            ((frame.image.height ~/ 2) * frame.image.width +
                frame.image.width ~/ 2) *
            4;
        expect(pixels!.getUint8(middle), closeTo(96, 10));
        expect(pixels.getUint8(middle + 1), closeTo(205, 10));
        expect(pixels.getUint8(middle + 2), closeTo(255, 10));
        frame.image.dispose();
        codec.dispose();
        final output = File(
          p.absolute('test-output/thumbnail-native/embedded-cover.png'),
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(thumbnail.bytes, flush: true);
      } finally {
        await service.dispose();
        await cache.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('MPVSON_TEST_THUMBNAILS'),
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'native sidecar artwork keeps the discovered video duration',
    () async {
      final source = File(
        p.absolute('test-output/thumbnail-native-fixtures/sidecar-video.mp4'),
      );
      final cover = File(p.setExtension(source.path, '.jpg'));
      expect(await source.exists(), isTrue);
      expect(await cover.exists(), isTrue);
      MediaKit.ensureInitialized(
        libmpv: Platform.isWindows
            ? p.absolute('build/windows/x64/runner/Release/libmpv-2.dll')
            : null,
      );
      final cache = await Directory.systemTemp.createTemp(
        'mpvson-sidecar-test-',
      );
      final service = MediaKitThumbnailService(cacheDirectory: cache);
      try {
        final thumbnail = await service
            .load(MediaEntry.fromPath(source.path, id: 'native-sidecar'))
            .timeout(const Duration(seconds: 25));
        expect(thumbnail, isNotNull);
        expect(thumbnail!.bytes, await cover.readAsBytes());
        expect(thumbnail.duration.inMilliseconds, closeTo(8000, 100));
      } finally {
        await service.dispose();
        await cache.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('MPVSON_TEST_THUMBNAILS'),
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
