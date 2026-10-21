import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import 'support/player_test_fakes.dart';

void main() {
  group('PlayerController MediaKind and MediaMetadata classification', () {
    test('initial state has unknown media kind and empty metadata', () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: const SessionLoadResult(),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      expect(controller.mediaKind, MediaKind.unknown);
      expect(controller.currentMediaKind, MediaKind.unknown);
      expect(controller.isAudio, isFalse);
      expect(controller.isVideo, isFalse);
      expect(controller.metadata, MediaMetadata.empty);
      expect(controller.currentMetadata, MediaMetadata.empty);

      await controller.close(discard: true);
    });

    test('audio file is classified as MediaKind.audio based on extension', () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: const SessionLoadResult(),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      await controller.openPaths(['https://media.example/song.mp3']);

      expect(controller.mediaKind, MediaKind.audio);
      expect(controller.isAudio, isTrue);
      expect(controller.isVideo, isFalse);
      expect(controller.metadata.title, isNotNull);

      await controller.close(discard: true);
    });

    test('video file is classified as MediaKind.video based on extension and tracks', () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: const SessionLoadResult(),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      await controller.openPaths(['https://media.example/movie.mp4']);

      expect(controller.mediaKind, MediaKind.video);
      expect(controller.isAudio, isFalse);
      expect(controller.isVideo, isTrue);

      await controller.close(discard: true);
    });

    test('audio with embedded cover art is classified as audio', () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: const SessionLoadResult(),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      await controller.openPaths(['https://media.example/track_with_art.mkv']);

      // Initially MKV extension hints video, but when engine reports tracks with only albumart:
      playback.emit(
        playback.state.copyWith(
          videoTracks: const [
            VideoTrack(
              '1',
              'Front Cover',
              null,
              albumart: true,
              image: true,
            ),
          ],
          audioTracks: const [
            AudioTrack('1', 'Stereo', 'eng'),
          ],
        ),
      );

      // Embedded cover art means the presentation is audio, not video
      expect(controller.mediaKind, MediaKind.audio);
      expect(controller.isAudio, isTrue);
      expect(controller.isVideo, isFalse);

      await controller.close(discard: true);
    });

    test('only files with ordinary video tracks are classified as video', () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: const SessionLoadResult(),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      // Open a file with both an ordinary video stream and an album art image track
      await controller.openPaths(['https://media.example/clip.mp4']);

      playback.emit(
        playback.state.copyWith(
          videoTracks: const [
            VideoTrack('1', 'Video Stream', null, albumart: false, image: false),
            VideoTrack('2', 'Cover Art', null, albumart: true, image: true),
          ],
          audioTracks: const [
            AudioTrack('1', 'Stereo', 'eng'),
          ],
        ),
      );

      expect(controller.mediaKind, MediaKind.video);
      expect(controller.isVideo, isTrue);
      expect(controller.isAudio, isFalse);

      await controller.close(discard: true);
    });

    test('media kind changes notify listeners', () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: const SessionLoadResult(),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      final kinds = <MediaKind>[];
      controller.addListener(() {
        if (kinds.isEmpty || kinds.last != controller.mediaKind) {
          kinds.add(controller.mediaKind);
        }
      });

      await controller.openPaths(['https://media.example/song.mp3']);
      expect(kinds, contains(MediaKind.audio));

      await controller.openPaths(['https://media.example/movie.mp4']);
      expect(kinds, contains(MediaKind.video));

      await controller.clearQueue();
      expect(kinds.last, MediaKind.unknown);

      await controller.close(discard: true);
    });

    test('metadata getter exposes current media metadata and updates', () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: const SessionLoadResult(),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      await controller.openPaths(['https://media.example/track.flac']);
      expect(controller.metadata.title, isNotEmpty);

      const customMeta = MediaMetadata(
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        album: 'A Night at the Opera',
        duration: Duration(minutes: 5, seconds: 55),
      );
      controller.updateMetadata(customMeta);

      expect(controller.metadata.title, 'Bohemian Rhapsody');
      expect(controller.metadata.artist, 'Queen');
      expect(controller.metadata.album, 'A Night at the Opera');
      expect(controller.metadata.effectiveArtist, 'Queen');

      await controller.close(discard: true);
    });
  });

  group('PlayerController Resume and Fresh Play Behavior', () {
    test(
      'music selected for fresh play starts at beginning (Duration.zero) even when in recent history',
      () async {
        final playback = FakePlaybackService();
        final recentSong = MediaEntry.fromPath(
          'https://media.example/song.mp3',
          id: 'recent-song',
        ).copyWith(
          position: const Duration(seconds: 45),
          duration: const Duration(minutes: 3),
        );

        final sessions = BlockingSessionRepository(
          blockDetailed: false,
          initialResult: SessionLoadResult(
            session: PlaybackSession(
              queue: const [],
              recent: [recentSong],
              saveNetworkUrls: true,
            ),
          ),
        );

        final controller = PlayerController(playback: playback, sessions: sessions);
        await controller.initialize();

        // Fresh selection of music
        await controller.openPaths(['https://media.example/song.mp3']);

        // Music selected for fresh play MUST start at Duration.zero
        expect(controller.position, Duration.zero);
        expect(controller.current?.position, Duration.zero);
        expect(playback.seekWrites, isEmpty);

        await controller.close(discard: true);
      },
    );

    test(
      'video selected for fresh play retains position from recent history',
      () async {
        final playback = FakePlaybackService();
        final recentVideo = MediaEntry.fromPath(
          'https://media.example/movie.mp4',
          id: 'recent-movie',
        ).copyWith(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
        );

        final sessions = BlockingSessionRepository(
          blockDetailed: false,
          initialResult: SessionLoadResult(
            session: PlaybackSession(
              queue: const [],
              recent: [recentVideo],
              saveNetworkUrls: true,
            ),
          ),
        );

        final controller = PlayerController(playback: playback, sessions: sessions);
        await controller.initialize();

        // Fresh selection of video that was recently played
        await controller.openPaths(['https://media.example/movie.mp4']);

        // Video retains position from recent
        expect(controller.position, const Duration(seconds: 30));

        await controller.close(discard: true);
      },
    );

    test('resuming paused song retains its position', () async {
      final playback = FakePlaybackService();
      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: const SessionLoadResult(),
      );
      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      await controller.openPaths(['https://media.example/track.flac']);
      expect(controller.isPlaying, isTrue);

      // Simulate playing to 30 seconds
      await controller.seek(const Duration(seconds: 30));
      playback.emit(playback.state.copyWith(position: const Duration(seconds: 30)));
      expect(controller.position, const Duration(seconds: 30));

      // Pause playback
      await controller.togglePlayPause();
      expect(controller.isPlaying, isFalse);
      expect(controller.position, const Duration(seconds: 30));

      // Resume paused song
      await controller.togglePlayPause();
      expect(controller.isPlaying, isTrue);
      // Position is retained at 30 seconds
      expect(controller.position, const Duration(seconds: 30));

      await controller.close(discard: true);
    });

    test('saved session retains position for song upon restore and resume', () async {
      final playback = FakePlaybackService();
      final savedSong = MediaEntry.fromPath(
        'https://media.example/saved_track.mp3',
        id: 'saved-song',
      ).copyWith(
        position: const Duration(seconds: 52),
        duration: const Duration(minutes: 4),
      );

      final sessions = BlockingSessionRepository(
        blockDetailed: false,
        initialResult: SessionLoadResult(
          session: PlaybackSession(
            queue: [savedSong],
            currentId: savedSong.id,
            saveNetworkUrls: true,
          ),
        ),
      );

      final controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();

      // Restored session retains the position
      expect(controller.current?.position, const Duration(seconds: 52));
      expect(controller.position, const Duration(seconds: 52));
      expect(controller.mediaKind, MediaKind.audio);

      // Resume saved session
      await controller.togglePlayPause();

      // Seek was issued to resume at saved position
      expect(playback.seekWrites, contains(const Duration(seconds: 52)));

      await controller.close(discard: true);
    });
  });
}
