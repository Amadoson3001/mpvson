import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';

/// Engine stand-in that records the sources it was told to load.
///
/// The hidden-suspension state machine under test is source-kind independent,
/// so audio sources keep the test hermetic: they never allocate a native video
/// controller, which a fake engine cannot back.
class _RecordingEnginePlayer extends PlatformPlayer {
  _RecordingEnginePlayer() : super(configuration: const PlayerConfiguration());

  final List<String> opened = <String>[];

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
  }

  @override
  Future<void> stop({bool open = false, bool notify = true}) async {}
}

void main() {
  testWidgets(
    'opening the next track while hidden re-applies the video suspension',
    (tester) async {
      final vidWrites = <String>[];
      final engine = _RecordingEnginePlayer();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: engine),
        propertyWriterForTesting: (property, value) async {
          if (property == 'vid') vidWrites.add(value);
        },
      );
      addTearDown(service.dispose);

      // The video output is hidden (minimized or behind the library): the
      // suspension only engages after its grace period.
      service.applyVideoOutputPolicy(const VideoOutputPolicy(visible: false));
      await service.open('C:/Media/first.mp3');
      expect(vidWrites, isEmpty);
      await tester.pump(const Duration(seconds: 5));
      expect(vidWrites, <String>['no']);

      // The next track loads while still hidden. A file load resets mpv's
      // file-local `vid` selection, so without a re-apply the new source
      // would keep decoding video behind the hidden output forever.
      await service.open('C:/Media/second.mp3');
      await tester.pump(const Duration(milliseconds: 10));
      expect(vidWrites, <String>['no', 'no']);
      expect(engine.opened, <String>[
        'C:/Media/first.mp3',
        'C:/Media/second.mp3',
      ]);
      // Settle the debounced resize so no timer stays pending.
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'restoring the video output resumes decoding after a hidden re-suspension',
    (tester) async {
      final vidWrites = <String>[];
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: _RecordingEnginePlayer()),
        propertyWriterForTesting: (property, value) async {
          if (property == 'vid') vidWrites.add(value);
        },
      );
      addTearDown(service.dispose);

      service.applyVideoOutputPolicy(const VideoOutputPolicy(visible: false));
      await service.open('C:/Media/first.mp3');
      await tester.pump(const Duration(seconds: 5));
      await service.open('C:/Media/second.mp3');
      await tester.pump(const Duration(milliseconds: 10));
      expect(vidWrites, <String>['no', 'no']);

      service.applyVideoOutputPolicy(const VideoOutputPolicy(visible: true));
      await tester.pump(const Duration(milliseconds: 10));
      expect(vidWrites.last, 'auto');

      // Hiding again re-arms the grace period from a clean state instead of
      // inheriting the stale suspension.
      service.applyVideoOutputPolicy(const VideoOutputPolicy(visible: false));
      await tester.pump(const Duration(milliseconds: 10));
      expect(vidWrites.last, 'auto');
      await tester.pump(const Duration(seconds: 5));
      expect(vidWrites.last, 'no');
    },
  );
}
