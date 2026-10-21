import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/control_density.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_settings.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import 'support/player_test_fakes.dart';

void main() {
  test(
    'startup restore keeps a source opened while the session is loading',
    () async {
      final sessions = BlockingSessionRepository();
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: sessions,
      );
      addTearDown(() => controller.close(discard: true));

      final initialize = controller.initialize();
      const openedUrl = 'https://media.example/now-playing.m3u8';
      await controller.openPaths(const <String>[openedUrl]);

      sessions.result.complete(
        SessionLoadResult(
          session: PlaybackSession(
            queue: <MediaEntry>[
              MediaEntry.fromPath('C:\\saved-first.mkv', id: 'saved-first'),
              MediaEntry.fromPath('C:\\saved-current.mkv', id: 'saved-current'),
            ],
            currentId: 'saved-current',
          ),
        ),
      );
      await initialize;

      expect(controller.queue, hasLength(1));
      expect(controller.currentIndex, 0);
      expect(controller.current?.path, openedUrl);
      expect(controller.hasMedia, isTrue);
      expect(controller.isPlaying, isTrue);
    },
  );

  test('rate writes stay ordered and the latest request wins', () async {
    final playback = FakePlaybackService();
    final controller = PlayerController(
      playback: playback,
      sessions: BlockingSessionRepository(),
    );
    addTearDown(() => controller.close(discard: true));

    final firstWrite = Completer<void>();
    playback.nextRateWrite = firstWrite;
    final first = controller.setRate(2);
    final second = controller.setRate(1.25);

    expect(playback.rateWrites, <double>[2]);
    expect(controller.rate, 1.25);

    firstWrite.complete();
    await Future.wait<void>(<Future<void>>[first, second]);

    expect(playback.rateWrites, <double>[2, 1.25]);
    expect(controller.rate, 1.25);
  });

  test(
    'a seek finishing after a source switch cannot change the new item',
    () async {
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: BlockingSessionRepository(),
      );
      addTearDown(() => controller.close(discard: true));

      await controller.openPaths(const <String>[
        'https://media.example/first.mp4',
        'https://media.example/second.mp4',
      ]);
      final seekWrite = Completer<void>();
      playback.nextSeekWrite = seekWrite;
      final staleSeek = controller.seek(const Duration(seconds: 40));

      await controller.playIndex(1);
      seekWrite.complete();
      await staleSeek;

      expect(controller.current?.title, 'second.mp4');
      expect(controller.position, Duration.zero);
      expect(controller.current?.position, Duration.zero);
    },
  );

  test('closed controller ignores subtitle track changes', () async {
    final playback = FakePlaybackService();
    final controller = PlayerController(
      playback: playback,
      sessions: BlockingSessionRepository(),
    );

    await controller.close(discard: true);
    await controller.setSubtitleTrack(const SubtitleTrack('no', null, null));

    expect(playback.subtitleTrackChanges, 0);
  });

  test(
    'startup settings read does not overwrite changes made during progress load',
    () async {
      final sessions = BlockingSessionRepository(blockProgress: true);
      final controller = PlayerController(
        playback: FakePlaybackService(),
        sessions: sessions,
      );
      addTearDown(() => controller.close(discard: true));

      sessions.result.complete(
        SessionLoadResult(
          session: PlaybackSession(
            queue: <MediaEntry>[
              MediaEntry.fromPath('C:\\saved-current.mkv', id: 'saved-current'),
            ],
            currentId: 'saved-current',
            volume: 70,
            rate: 2,
            shuffle: true,
            repeatMode: 'all',
            controlDensity: ControlDensity.normal,
            playbackSettings: const PlaybackSettings(brightness: 5),
          ),
        ),
      );
      final initialize = controller.initialize();
      await sessions.progressLoadStarted.future;

      await controller.setVolume(25);
      await controller.setRate(1.25);
      await controller.toggleShuffle();
      await controller.cycleRepeat();
      controller.setControlDensity(ControlDensity.compact);
      await controller.setPlaybackSettings(PlaybackSettings.defaults);

      sessions.progress.complete(null);
      await initialize;

      expect(controller.volume, 25);
      expect(controller.rate, 1.25);
      expect(controller.shuffle, isFalse);
      expect(controller.repeatMode, 'one');
      expect(controller.controlDensity, ControlDensity.compact);
      expect(controller.playbackSettings, PlaybackSettings.defaults);
    },
  );

  test(
    'startup shuffle and repeat writes serialize with newer user choices',
    () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: SessionLoadResult(
          session: PlaybackSession(shuffle: true, repeatMode: 'all'),
        ),
      );
      final controller = PlayerController(
        playback: playback,
        sessions: sessions,
      );
      final initialShuffleWrite = Completer<void>();
      playback.nextShuffleWrite = initialShuffleWrite;

      final initialize = controller.initialize();
      await playback.shuffleWriteStarted.future;

      final newerShuffleChoice = controller.toggleShuffle();
      final newerRepeatChoice = controller.cycleRepeat();
      expect(controller.shuffle, isFalse);
      expect(controller.repeatMode, 'one');

      // Startup and user commands share one drain. Release its in-flight write
      // before awaiting the coalesced calls so this test cannot deadlock.
      initialShuffleWrite.complete();
      await Future.wait<void>(<Future<void>>[
        initialize,
        newerShuffleChoice,
        newerRepeatChoice,
      ]);

      expect(playback.shuffleWrites, <bool>[true, false]);
      expect(playback.repeatModeWrites, <String>['one']);
      expect(playback.state.shuffle, isFalse);
      expect(controller.shuffle, isFalse);

      await controller.close(discard: true);
    },
  );

  test(
    'session restore stops when shutdown begins during progress loading',
    () async {
      final sessions = BlockingSessionRepository(blockProgress: true);
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: sessions,
      );

      sessions.result.complete(
        SessionLoadResult(
          session: PlaybackSession(
            queue: <MediaEntry>[
              MediaEntry.fromPath('C:\\saved-current.mkv', id: 'saved-current'),
            ],
            currentId: 'saved-current',
          ),
        ),
      );
      final initialize = controller.initialize();
      await sessions.progressLoadStarted.future;

      await controller.close(discard: true);
      sessions.progress.complete(null);
      await initialize;

      expect(playback.volumeWrites, isEmpty);
      expect(playback.rateWrites, isEmpty);
      expect(playback.shuffleWrites, isEmpty);
      expect(playback.repeatModeWrites, isEmpty);
    },
  );
}
