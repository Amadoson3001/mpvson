// Opt-in native regression probe for the bundled Windows libmpv runtime.
//
// Run with:
//   flutter test --dart-define=MPVSON_PROBE_NATIVE_EVENTS=true \
//     test/native_source_probe_test.dart
//
// This deliberately uses a headless video controller. The test exercises the
// production playback service and native property adapter without asking the
// Flutter test runner to create a desktop texture.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/src/video_controller/native_video_controller/native_video_controller.dart';
import 'package:mpvson/data/services/native_media_events.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/playback_statistics.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_settings.dart';
import 'package:path/path.dart' as p;

const bool _enabled = bool.fromEnvironment('MPVSON_PROBE_NATIVE_EVENTS');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled libmpv reports source identity, stop, reload and completion',
    () async {
      final enginePath = p.join(
        Directory.current.path,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'libmpv-2.dll',
      );
      expect(
        File(enginePath).existsSync(),
        isTrue,
        reason: 'Build the Windows release app before running this probe.',
      );

      MediaKit.ensureInitialized(libmpv: enginePath);

      final fixtureDirectory = await Directory.systemTemp.createTemp(
        'mpvson-native-source-probe-',
      );
      final fixture = File(p.join(fixtureDirectory.path, 'probe.wav'));
      await fixture.writeAsBytes(_silentWave(sampleRate: 8000, seconds: 2));

      final player = Player(
        configuration: const PlayerConfiguration(
          title: 'Mpvson native source probe',
          vo: 'null',
          muted: true,
        ),
      );
      final videoController = _makeHeadlessVideoController(player);
      final nativeEvents = MediaKitNativeMediaEvents(player);
      final playback = MediaKitPlaybackService(
        player: player,
        videoController: videoController,
        nativeEvents: nativeEvents,
      );
      String? lastSnapshotSummary;
      final nativeSubscription = nativeEvents.events.listen((event) {
        debugPrint('native event: ${event.kind.name} ${event.source}');
      });
      final stateSubscription = playback.states.listen((snapshot) {
        final summary =
            'boundary=${snapshot.sourceStart} '
            'source=${snapshot.nativeSource} loaded=${snapshot.sourceLoaded} '
            'duration=${snapshot.duration.inMilliseconds} '
            'playing=${snapshot.isPlaying} buffering=${snapshot.isBuffering} '
            'completed=${snapshot.completed} error=${snapshot.error}';
        if (summary == lastSnapshotSummary) return;
        lastSnapshotSummary = summary;
        debugPrint(
          'snapshot: $summary position=${snapshot.position.inMilliseconds}',
        );
      });

      try {
        final nativePlayer = player.platform;
        expect(nativePlayer, isA<NativePlayer>());
        final native = nativePlayer as NativePlayer;
        await native
            .setProperty('ao', 'null')
            .timeout(const Duration(seconds: 15));
        await playback.prepare().timeout(const Duration(seconds: 15));
        final pinnedVersion = await _readPinnedVersion();
        final runtimeProperties = <String, String>{
          for (final property in <String>[
            'mpv-version',
            'ffmpeg-version',
            'libass-version',
            'mpv-configuration',
          ])
            property: await _readProperty(native, property),
        };
        expect(playback.engineVersion, contains(pinnedVersion));
        expect(runtimeProperties['mpv-version'], contains(pinnedVersion));
        await _writeRuntimeRecord(
          pinnedVersion: pinnedVersion,
          engineVersion: playback.engineVersion,
          properties: runtimeProperties,
        );
        debugPrint(
          'prepared idle: boundary=${playback.state.sourceStart} '
          'source=${playback.state.nativeSource} '
          'loaded=${playback.state.sourceLoaded}',
        );
        debugPrint(
          'engine: ${playback.engineVersion}; runtime record: '
          'test-output/engine-runtime.json',
        );
        expect(playback.state.sourceLoaded, isFalse);
        expect(playback.state.nativeSource, isNull);
        for (final preset in PlaybackQualityPreset.values) {
          final result = await playback.applyPlaybackSettings(
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
          expect(
            double.parse(await native.getProperty('sub-delay')),
            closeTo(0.35, 0.001),
          );
          expect(await native.getProperty('hwdec'), 'no');
        }
        final reset = await playback.applyPlaybackSettings(
          PlaybackSettings.defaults,
        );
        expect(reset.succeeded, isTrue, reason: reset.reason);
        expect(double.parse(await native.getProperty('brightness')), 0);
        expect(double.parse(await native.getProperty('audio-delay')), 0);
        expect(double.parse(await native.getProperty('sub-delay')), 0);
        final statistics = await readNativePlaybackStatistics(player);
        expect(statistics.values['Playback engine'], contains('mpv'));

        final source = MediaEntry.canonicalSource(fixture.path);
        await playback
            .open(fixture.path, play: false)
            .timeout(const Duration(seconds: 15));
        final firstLoad = await _waitForSnapshot(
          playback,
          (snapshot) =>
              snapshot.sourceLoaded && snapshot.nativeSource == source,
        );
        expect(firstLoad.sourceStart, 1);

        await playback.stop().timeout(const Duration(seconds: 10));
        expect(playback.state.sourceStart, 2);
        expect(playback.state.sourceLoaded, isFalse);
        expect(playback.state.nativeSource, isNull);

        await playback
            .open(fixture.path, play: true)
            .timeout(const Duration(seconds: 15));
        final reopened = await _waitForSnapshot(
          playback,
          (snapshot) =>
              snapshot.sourceStart == 3 &&
              snapshot.sourceLoaded &&
              snapshot.nativeSource == source,
        );
        expect(reopened.sourceStart, 3);

        final completed = await _waitForSnapshot(
          playback,
          (snapshot) => snapshot.sourceStart == 3 && snapshot.completed,
          timeout: const Duration(seconds: 20),
        );
        expect(completed.nativeSource, source);
      } finally {
        await playback.dispose();
        await stateSubscription.cancel();
        await nativeSubscription.cancel();
        await nativeEvents.dispose();
        final platformVideoController = await videoController.platform.future;
        platformVideoController.dispose();
        await fixtureDirectory.delete(recursive: true);
      }
    },
    skip: !_enabled
        ? 'Set MPVSON_PROBE_NATIVE_EVENTS=true to load the bundled libmpv.'
        : !Platform.isWindows
        ? 'The bundled native probe currently targets Windows.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native video creation can retry after a platform failure',
    () async {
      MediaKit.ensureInitialized(
        libmpv: p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Release',
          'libmpv-2.dll',
        ),
      );
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null', muted: true),
      );
      final handle = await player.handle;
      const channel = MethodChannel('com.alexmercerind/media_kit_video');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var creations = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'VideoOutputManager.Create') {
          creations++;
          if (creations == 1) {
            throw PlatformException(
              code: 'VIDEO_OUTPUT_CREATION_FAILED',
              message: 'Injected texture failure',
            );
          }
          await messenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('VideoOutput.Resize', {
                'handle': handle,
                'id': 42,
                'rect': {'left': 0, 'top': 0, 'width': 1, 'height': 1},
              }),
            ),
            (_) {},
          );
        }
        return null;
      });
      try {
        const configuration = VideoControllerConfiguration(vo: 'null');
        await expectLater(
          NativeVideoController.create(player, configuration),
          throwsA(isA<PlatformException>()),
        );
        final controller = await NativeVideoController.create(
          player,
          configuration,
        ).timeout(const Duration(seconds: 5));
        expect(creations, 2);
        expect(controller.id.value, 42);
      } finally {
        await player.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
    skip: !_enabled || !Platform.isWindows,
  );
}

Future<String> _readPinnedVersion() async {
  final file = File(
    p.join(
      Directory.current.path,
      'packaging',
      'windows',
      'engine-provenance.json',
    ),
  );
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map || decoded['engine'] is! Map) {
    throw const FormatException('Invalid Windows engine provenance file.');
  }
  final engine = decoded['engine'] as Map;
  final version = engine['version'];
  if (version is! String || version.trim().isEmpty) {
    throw const FormatException('The pinned engine version is missing.');
  }
  return version;
}

Future<String> _readProperty(NativePlayer player, String property) async {
  try {
    final value =
        (await player.getProperty(property).timeout(const Duration(seconds: 5)))
            .trim();
    return value.isEmpty ? '<empty>' : value;
  } on Object catch (error) {
    return '<unavailable: ${error.runtimeType}>';
  }
}

Future<void> _writeRuntimeRecord({
  required String pinnedVersion,
  required String engineVersion,
  required Map<String, String> properties,
}) async {
  final file = File(
    p.join(Directory.current.path, 'test-output', 'engine-runtime.json'),
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'platform': <String, String>{
        'operatingSystem': Platform.operatingSystem,
        'operatingSystemVersion': Platform.operatingSystemVersion,
        'dartVersion': Platform.version,
      },
      'pinnedMpvVersion': pinnedVersion,
      'reportedEngineVersion': engineVersion,
      'properties': properties,
    }),
  );
}

Future<PlaybackSnapshot> _waitForSnapshot(
  MediaKitPlaybackService playback,
  bool Function(PlaybackSnapshot snapshot) predicate, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (predicate(playback.state)) return playback.state;
  return playback.states.firstWhere(predicate).timeout(timeout);
}

VideoController _makeHeadlessVideoController(Player player) {
  final controller = VideoController(
    player,
    configuration: const VideoControllerConfiguration(vo: 'null'),
  );
  final stub = _HeadlessPlatformVideoController(player);
  controller.platform.complete(stub);

  // VideoController normally releases this gate after its post-frame native
  // texture setup. The probe has no Flutter texture channel, so release it
  // after installing the platform stub.
  final native = player.platform;
  if (native is NativePlayer && !native.videoControllerCompleter.isCompleted) {
    native.videoControllerCompleter.complete();
  }
  return controller;
}

class _HeadlessPlatformVideoController extends PlatformVideoController {
  _HeadlessPlatformVideoController(Player player)
    : super(player, const VideoControllerConfiguration(vo: 'null'));

  @override
  Future<void> setSize({int? width, int? height}) async {}
}

Uint8List _silentWave({required int sampleRate, required int seconds}) {
  const channels = 1;
  const bitsPerSample = 16;
  final sampleCount = sampleRate * seconds;
  final dataLength = sampleCount * channels * bitsPerSample ~/ 8;
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);

  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes[offset + index] = value.codeUnitAt(index);
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * bitsPerSample ~/ 8, Endian.little);
  data.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  return bytes;
}
