import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/playback_service.dart';

class _RecordingPlatformPlayer extends PlatformPlayer {
  _RecordingPlatformPlayer()
    : super(configuration: const PlayerConfiguration());

  final List<String> opened = <String>[];
  int stops = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('open dispatch is gated on the current boundary', () {
    test('a stop completed during open never reaches the player', () async {
      final platform = _RecordingPlatformPlayer();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: platform),
      );
      try {
        // open suspends while the buffering policy is applied; stop completes
        // inside that window and advances the boundary.
        final opening = service.open('stopped.mp3');
        final stopping = service.stop();
        await Future.wait<void>([opening, stopping]);

        expect(platform.opened, isEmpty);
        expect(platform.stops, 1);
      } finally {
        await service.dispose();
      }
    });

    test('a superseded open never reaches the player', () async {
      final platform = _RecordingPlatformPlayer();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: platform),
      );
      try {
        final first = service.open('first.mp3');
        final second = service.open('second.mp3');
        await Future.wait<void>([first, second]);

        expect(platform.opened, <String>['second.mp3']);
      } finally {
        await service.dispose();
      }
    });

    test('an open pending during dispose never reaches the player', () async {
      final platform = _RecordingPlatformPlayer();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: platform),
      );
      final opening = service.open('disposed.mp3');
      await service.dispose();
      await opening;

      expect(platform.opened, isEmpty);
    });

    test('an uninterrupted open still reaches the player', () async {
      final platform = _RecordingPlatformPlayer();
      final service = MediaKitPlaybackService(
        player: Player(platformPlayer: platform),
      );
      try {
        await service.open('normal.mp3');
        expect(platform.opened, <String>['normal.mp3']);
      } finally {
        await service.dispose();
      }
    });
  });
}
