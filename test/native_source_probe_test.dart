import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

// Opt-in diagnostic probe. It answers, against the real bundled libmpv, which
// native signals identify a source load, a completed load and the end of a
// file. Run with:
//   flutter test --dart-define=MPVSON_PROBE_NATIVE_EVENTS=true test/native_source_probe_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'records native mpv property notifications across source transitions',
    () async {
      final source = File(p.absolute('test-output/smoke.mp4'));
      expect(await source.exists(), isTrue);
      MediaKit.ensureInitialized(
        libmpv: Platform.isWindows
            ? p.absolute('build/windows/x64/runner/Release/libmpv-2.dll')
            : null,
      );
      final work = await Directory.systemTemp.createTemp('mpvson-probe-');
      final a = File(p.join(work.path, 'probe-a.mp4'));
      final b = File(p.join(work.path, 'probe-b.mp4'));
      await source.copy(a.path);
      await source.copy(b.path);

      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final platform = player.platform! as NativePlayer;
      final watch = Stopwatch()..start();
      final log = StringBuffer();
      void record(String line) {
        final ms = watch.elapsedMilliseconds.toString().padLeft(6);
        log.writeln('$ms ms  $line');
        // ignore: avoid_print
        print('$ms ms  $line');
      }

      Future<void> observe(String property) async {
        await platform.observeProperty(property, (value) async {
          record('PROPERTY $property = "$value"');
        });
      }

      await observe('path');
      await observe('file-format');
      await observe('eof-reached');
      await observe('idle-active');
      await observe('duration');
      await observe('playlist-pos');
      await observe('media-title');
      await observe('stream-open-filename');
      await observe('working-directory');

      final subscriptions = <StreamSubscription<Object?>>[
        player.stream.playing.listen((v) => record('stream.playing = $v')),
        player.stream.buffering.listen((v) => record('stream.buffering = $v')),
        player.stream.completed.listen((v) => record('stream.completed = $v')),
        player.stream.duration.listen((v) => record('stream.duration = $v')),
        player.stream.tracks.listen(
          (v) => record(
            'stream.tracks = audio:${v.audio.length} video:${v.video.length}',
          ),
        ),
        player.stream.position.listen((v) {
          if (v.inMilliseconds % 1000 < 60) record('stream.position = $v');
        }),
      ];

      Future<void> step(String label, Future<void> Function() action) async {
        record('=== $label');
        await action();
        await Future<void>.delayed(const Duration(seconds: 3));
      }

      await step('open A (play)', () => player.open(Media(a.path), play: true));
      await step('open B (play)', () => player.open(Media(b.path), play: true));
      await step(
        'open A again (play)',
        () => player.open(Media(a.path), play: true),
      );
      await step(
        'reload same source A (play)',
        () => player.open(Media(a.path), play: true),
      );
      await step('stop', () => player.stop());
      await step(
        'open A after stop',
        () => player.open(Media(a.path), play: true),
      );
      await step('seek near end', () async {
        final duration = player.state.duration;
        final target = duration - const Duration(milliseconds: 400);
        await player.seek(target < Duration.zero ? Duration.zero : target);
      });
      await step('wait at end', () async {});

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await player.dispose();
      await File(
        p.absolute('test-output/native-source-probe.log'),
      ).writeAsString(log.toString(), flush: true);
      await work.delete(recursive: true);
    },
    skip: !const bool.fromEnvironment('MPVSON_PROBE_NATIVE_EVENTS'),
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
