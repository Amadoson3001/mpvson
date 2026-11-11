import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/session_progress.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import '../../support/app_harness.dart';

class _SlowPlaybackService extends FakePlaybackService {
  Completer<void>? slowOpenCompleter;
  String? slowPath;

  @override
  Future<void> open(String path, {bool play = true}) async {
    if (path == slowPath && slowOpenCompleter != null) {
      await slowOpenCompleter!.future;
    }
    emit(
      state.copyWith(
        isPlaying: play,
        sourceLoaded: true,
        nativeSource: MediaEntry.canonicalSource(path),
        duration: const Duration(minutes: 4, seconds: 12),
        position: const Duration(seconds: 73),
        sourceStart: state.sourceStart + 1,
      ),
    );
  }
}

class _TrackingSessionRepository extends SessionRepository {
  final List<SessionProgress> savedCheckpoints = [];

  @override
  Future<void> saveProgress(SessionProgress progress) async {
    savedCheckpoints.add(progress);
    return super.saveProgress(progress);
  }
}

Future<File> _createMediaFile(String name) async {
  final dir = await Directory.systemTemp.createTemp('mpvson_player_test_');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}${Platform.pathSeparator}$name')..createSync();
}

void main() {
  test(
    'previous() during slow load of a track with resume position > 3s returns to previous track without seeking to 0',
    () async {
      final playback = _SlowPlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
      addTearDown(controller.dispose);

      final file1 = await _createMediaFile('track1.mp4');
      final file2 = await _createMediaFile('track2.mp4');

      final slowCompleter = Completer<void>();
      playback.slowPath = file2.path;
      playback.slowOpenCompleter = slowCompleter;

      const resumePosition = Duration(seconds: 45);
      controller.restoreRecentList([
        MediaEntry(
          id: 'recent-track-2',
          path: file2.path,
          title: 'Track Two',
          duration: const Duration(minutes: 10),
          position: resumePosition,
          lastPlayed: DateTime(2026, 1, 1),
        ),
      ]);

      await controller.openPaths([file1.path, file2.path]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.currentIndex, 0);
      expect(controller.current?.path, file1.path);
      expect(controller.queue[1].position, resumePosition);

      // Navigate to track 2, which loads slowly.
      unawaited(controller.next());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.isLoading, isTrue);
      expect(controller.currentIndex, 1);
      expect(controller.current?.path, file2.path);
      expect(controller.position, resumePosition);

      // Tapping previous while track 2 is loading must return to track 1
      // and NOT seek to 0 or wipe track 2's resume position.
      await controller.previous();
      slowCompleter.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.currentIndex, 0);
      expect(controller.current?.path, file1.path);
      expect(controller.queue[1].position, resumePosition);
    },
  );

  test(
    'previous() during slow load falls back to previous queue track when history is empty',
    () async {
      final playback = _SlowPlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
      addTearDown(controller.dispose);

      final file1 = await _createMediaFile('track1.mp4');
      final file2 = await _createMediaFile('track2.mp4');

      final slowCompleter = Completer<void>();
      playback.slowPath = file2.path;
      playback.slowOpenCompleter = slowCompleter;

      const resumePosition = Duration(seconds: 50);
      controller.restoreRecentList([
        MediaEntry(
          id: 'recent-track-2',
          path: file2.path,
          title: 'Track Two',
          duration: const Duration(minutes: 10),
          position: resumePosition,
          lastPlayed: DateTime(2026, 1, 1),
        ),
      ]);

      // Open queue starting directly at track 2 (initialIndex: 1), so no prior history exists.
      unawaited(
        controller.openPaths([file1.path, file2.path], initialIndex: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.isLoading, isTrue);
      expect(controller.currentIndex, 1);
      expect(controller.current?.path, file2.path);
      expect(controller.position, resumePosition);

      // Tapping previous must navigate back to track 1 in the queue without seeking to 0.
      await controller.previous();
      slowCompleter.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.currentIndex, 0);
      expect(controller.current?.path, file1.path);
      expect(controller.queue[1].position, resumePosition);
    },
  );

  test(
    'previous() when a track has confirmed and played > 3s seeks to 0',
    () async {
      final playback = FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
      addTearDown(controller.dispose);

      final file1 = await _createMediaFile('track1.mp4');
      final file2 = await _createMediaFile('track2.mp4');

      await controller.openPaths([file1.path, file2.path]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.currentIndex, 0);

      // Seek confirmed track to 10 seconds.
      await controller.seek(const Duration(seconds: 10));
      expect(controller.position, const Duration(seconds: 10));

      // With position > 3s on confirmed track, previous seeks to zero.
      await controller.previous();
      expect(controller.currentIndex, 0);
      expect(controller.position, Duration.zero);
    },
  );

  test(
    'seek() during slow load is ignored and does not wipe stored resume position',
    () async {
      final playback = _SlowPlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
      addTearDown(controller.dispose);

      final file1 = await _createMediaFile('track1.mp4');
      final file2 = await _createMediaFile('track2.mp4');

      final slowCompleter = Completer<void>();
      playback.slowPath = file2.path;
      playback.slowOpenCompleter = slowCompleter;

      const resumePosition = Duration(seconds: 40);
      controller.restoreRecentList([
        MediaEntry(
          id: 'recent-track-2',
          path: file2.path,
          title: 'Track Two',
          duration: const Duration(minutes: 10),
          position: resumePosition,
          lastPlayed: DateTime(2026, 1, 1),
        ),
      ]);

      await controller.openPaths([file1.path, file2.path]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Start loading track 2.
      unawaited(controller.next());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.isLoading, isTrue);

      // Calling seek during load should not wipe the stored resume position.
      await controller.seek(Duration.zero);
      expect(controller.queue[1].position, resumePosition);

      slowCompleter.complete();
    },
  );

  test(
    'checkpointing does not write progress for unconfirmed loading track',
    () async {
      final playback = _SlowPlaybackService();
      final sessions = _TrackingSessionRepository();
      final controller = PlayerController(
        playback: playback,
        sessions: sessions,
      );
      addTearDown(controller.dispose);

      final file1 = await _createMediaFile('track1.mp4');
      final file2 = await _createMediaFile('track2.mp4');

      final slowCompleter = Completer<void>();
      playback.slowPath = file2.path;
      playback.slowOpenCompleter = slowCompleter;

      const resumePosition = Duration(seconds: 40);
      controller.restoreRecentList([
        MediaEntry(
          id: 'recent-track-2',
          path: file2.path,
          title: 'Track Two',
          duration: const Duration(minutes: 10),
          position: resumePosition,
          lastPlayed: DateTime(2026, 1, 1),
        ),
      ]);

      await controller.openPaths([file1.path, file2.path]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final initialCheckpointCount = sessions.savedCheckpoints.length;

      // Start loading track 2.
      unawaited(controller.next());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.isLoading, isTrue);

      // Checkpoints during this slow load must not include track 2 while unconfirmed.
      final duringLoadCheckpoints = sessions.savedCheckpoints
          .skip(initialCheckpointCount)
          .where((cp) => cp.entryId == controller.queue[1].id);
      expect(duringLoadCheckpoints, isEmpty);

      slowCompleter.complete();
    },
  );
}
