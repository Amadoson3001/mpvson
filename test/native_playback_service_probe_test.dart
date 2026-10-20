import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:path/path.dart' as p;

// Opt-in diagnostic probe. It runs the production PlaybackService against the
// real bundled engine and prints how native attribution resolves for the first
// source a process opens, which is the sequence the application smoke path
// depends on:
//   flutter test --dart-define=MPVSON_PROBE_PLAYBACK_SERVICE=true \
//     test/native_playback_service_probe_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reports how native attribution resolves for the first opened source',
    () async {
      final dll = File(
        p.normalize(
          p.absolute('build/windows/x64/runner/Release/libmpv-2.dll'),
        ),
      );
      final media = File(p.normalize(p.absolute('test-output/smoke.mp4')));
      expect(dll.existsSync(), isTrue, reason: 'Build the Windows release.');
      expect(media.existsSync(), isTrue);

      MediaKit.ensureInitialized(libmpv: Platform.isWindows ? dll.path : null);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final service = MediaKitPlaybackService(player: player);
      // VideoController attaches itself to the player and finishes
      // initialization through the media_kit_video texture channel. A plain
      // test() never pumps the frame that starts it, and flutter test has no
      // texture channel, so every native player command would wait on that
      // initialization forever. The probe runs with vo=null; release the gate
      // so prepare() and open() can exercise the native event path.
      final platform = player.platform;
      if (platform != null && !platform.videoControllerCompleter.isCompleted) {
        platform.videoControllerCompleter.complete();
      }
      final watch = Stopwatch()..start();
      final log = StringBuffer();
      void record(String line) {
        final ms = watch.elapsedMilliseconds.toString().padLeft(6);
        log.writeln('$ms ms  $line');
        // ignore: avoid_print
        print('$ms ms  $line');
      }

      final subscription = service.states.listen((state) {
        record(
          'snapshot start=${state.sourceStart} native=${state.nativeSource} '
          'loaded=${state.sourceLoaded} playing=${state.isPlaying} '
          'buffering=${state.isBuffering} position=${state.position.inMilliseconds} '
          'duration=${state.duration.inMilliseconds} completed=${state.completed} '
          'error=${state.error}',
        );
      });

      record('prepare() start');
      try {
        await service.prepare().timeout(const Duration(seconds: 5));
        record('prepare() done');
      } on Object catch (error) {
        record('prepare() failed: $error');
      }

      record('open() start: ${media.path}');
      await service.open(media.path);
      record('open() returned');

      await Future<void>.delayed(const Duration(seconds: 6));
      record(
        'final state playing=${service.state.isPlaying} '
        'duration=${service.state.duration.inMilliseconds} '
        'loaded=${service.state.sourceLoaded} '
        'native=${service.state.nativeSource}',
      );

      await subscription.cancel();
      await service.dispose();
      await File(
        p.absolute('test-output/native-playback-service-probe.log'),
      ).writeAsString(log.toString(), flush: true);
    },
    skip: !const bool.fromEnvironment('MPVSON_PROBE_PLAYBACK_SERVICE'),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
