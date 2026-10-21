import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/control_density.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/domain/models/playback_settings.dart';
import 'package:mpvson/domain/models/session_progress.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;
  late List<File> mediaFiles;

  test('an early file open survives delayed startup restoration', () async {
    final saved = mediaFiles
        .map((file) => MediaEntry.fromPath(file.path, id: file.path))
        .toList();
    final sessions = _DelayedStartupSessionRepository(
      temporaryDirectory,
      PlaybackSession(queue: saved, currentId: saved.last.id),
    );
    final playback = _FakePlaybackService();
    final controller = PlayerController(playback: playback, sessions: sessions);
    final restoring = controller.initialize();
    await sessions.started.future;
    await controller.openPaths([mediaFiles.first.path]);
    final requestedId = controller.current!.id;
    sessions.release.complete();
    try {
      await restoring;
      expect(controller.current?.id, requestedId);
      expect(controller.currentIndex, 0);
      expect(controller.isPlaying, isTrue);
    } finally {
      await controller.close();
    }
  });

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('mpvson-test-');
    mediaFiles = <File>[];
    for (var index = 0; index < 3; index++) {
      final file = File(p.join(temporaryDirectory.path, 'video-$index.mp4'));
      await file.writeAsBytes(<int>[0, 1, 2, index]);
      mediaFiles.add(file);
    }
  });

  tearDown(() async {
    // Windows fails a recursive delete with `errno = 145` (directory is not
    // empty) when a queued session or checkpoint write recreates a file while
    // the tree is being walked. That is the coalesced persistence under test
    // still settling, not a failure, so the cleanup retries briefly.
    await deleteSandbox(temporaryDirectory);
  });

  test(
    'duplicate sources keep unique queue identity through reordering',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
        mediaFiles[0].path,
      ]);

      final ids = controller.queue.map((entry) => entry.id).toList();
      expect(ids.toSet(), hasLength(3));
      await controller.playIndex(1);
      final currentId = controller.current!.id;

      // ReorderableListView passes the insertion slot before removing the old row.
      await controller.reorder(0, 3);

      expect(controller.queue.map((entry) => entry.id), <String>[
        ids[1],
        ids[2],
        ids[0],
      ]);
      expect(controller.current!.id, currentId);
      expect(controller.currentIndex, 0);
      await controller.close();
    },
  );

  test('hasMedia distinguishes a loaded source from an empty queue', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    final mediaStates = <bool>[];
    controller.addListener(() => mediaStates.add(controller.hasMedia));
    await controller.initialize();
    expect(controller.hasMedia, isFalse);

    await controller.openPaths(<String>[mediaFiles[0].path]);
    expect(controller.hasMedia, isTrue);
    await controller.togglePlayPause();
    expect(
      controller.hasMedia,
      isTrue,
      reason: 'Pausing keeps the source loaded in the native engine.',
    );

    await controller.clearQueue();
    expect(controller.hasMedia, isFalse);
    expect(mediaStates, containsAllInOrder(<bool>[false, true, false]));
    await controller.close();
  });

  test(
    'control density persists across restart with the restored queue stopped',
    () async {
      final sessions = SessionRepository(
        directory: Directory('${temporaryDirectory.path}/session'),
      );
      final firstPlayback = _FakePlaybackService();
      final first = PlayerController(
        playback: firstPlayback,
        sessions: sessions,
      );
      await first.initialize();
      await first.openPaths(<String>[mediaFiles[0].path, mediaFiles[1].path]);

      var notifications = 0;
      first.addListener(() => notifications++);
      first.setControlDensity(ControlDensity.normal);
      expect(first.controlDensity, ControlDensity.normal);
      expect(notifications, 1);
      first.setControlDensity(ControlDensity.normal);
      expect(notifications, 1, reason: 'Setting the same value is a no-op.');
      final closing = first.close();
      first.setControlDensity(ControlDensity.compact);
      expect(
        first.controlDensity,
        ControlDensity.normal,
        reason: 'A closing controller must ignore preference changes.',
      );
      await closing;
      first.setControlDensity(ControlDensity.compact);
      expect(
        (await sessions.load())?.controlDensity,
        ControlDensity.normal,
        reason: 'A closed controller must ignore preference changes.',
      );

      final restoredPlayback = _FakePlaybackService();
      final restored = PlayerController(
        playback: restoredPlayback,
        sessions: sessions,
      );
      await restored.initialize();

      expect(restored.controlDensity, ControlDensity.normal);
      expect(restored.queue, hasLength(2));
      expect(restored.current, isNotNull);
      expect(restored.isPlaying, isFalse);
      expect(restored.hasMedia, isFalse);
      expect(restoredPlayback.openedPaths, isEmpty);
      await restored.close();
    },
  );

  test(
    'closing before initialization does not overwrite the saved session',
    () async {
      final sessions = SessionRepository(
        directory: Directory('${temporaryDirectory.path}/session'),
      );
      final saved = PlaybackSession(
        queue: <MediaEntry>[
          MediaEntry.fromPath(mediaFiles[0].path, id: 'saved-queue-id'),
        ],
        currentId: 'saved-queue-id',
      );
      await sessions.save(saved);

      final controller = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      await controller.close();

      expect((await sessions.load())?.currentId, 'saved-queue-id');
    },
  );

  test(
    'shuffle toggle keeps its requested state with synchronous snapshots',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();

      await controller.toggleShuffle();
      expect(controller.shuffle, isTrue);
      await controller.toggleShuffle();
      expect(controller.shuffle, isFalse);
      await controller.close();
    },
  );

  test(
    'rapid shuffle toggles serialize native writes and keep latest intent',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      playback
        ..shuffleWrites.clear()
        ..delayShuffleWrites = true;

      final firstToggle = controller.toggleShuffle();
      expect(controller.shuffle, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(playback.shuffleWrites, <bool>[true]);
      expect(playback.pendingShuffleWrites, hasLength(1));

      final secondToggle = controller.toggleShuffle();
      expect(controller.shuffle, isFalse);
      expect(playback.shuffleWrites, <bool>[true]);

      playback.completeNextShuffleWrite();
      await Future<void>.delayed(Duration.zero);
      expect(playback.shuffleWrites, <bool>[true, false]);
      expect(playback.pendingShuffleWrites, hasLength(1));
      playback.completeNextShuffleWrite();
      await Future.wait(<Future<void>>[firstToggle, secondToggle]);

      expect(controller.shuffle, isFalse);
      expect(playback.state.shuffle, isFalse);
      expect(playback.shuffleWrites, <bool>[true, false]);
      await controller.close();
    },
  );

  test(
    'rapid repeat cycles serialize native writes and keep latest mode',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      playback
        ..repeatWrites.clear()
        ..delayRepeatWrites = true;

      final firstCycle = controller.cycleRepeat();
      expect(controller.repeatMode, 'all');
      await Future<void>.delayed(Duration.zero);
      expect(playback.repeatWrites, <String>['all']);
      expect(playback.pendingRepeatWrites, hasLength(1));

      final secondCycle = controller.cycleRepeat();
      expect(controller.repeatMode, 'one');
      expect(playback.repeatWrites, <String>['all']);

      playback.completeNextRepeatWrite();
      await Future<void>.delayed(Duration.zero);
      expect(playback.repeatWrites, <String>['all', 'one']);
      expect(playback.pendingRepeatWrites, hasLength(1));
      playback.completeNextRepeatWrite();
      await Future.wait(<Future<void>>[firstCycle, secondCycle]);

      expect(controller.repeatMode, 'one');
      expect(playback.repeatWrites, <String>['all', 'one']);
      await controller.close();
    },
  );

  test('close waits for an in-flight queue preference write', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    playback
      ..shuffleWrites.clear()
      ..delayShuffleWrites = true;
    final toggle = controller.toggleShuffle();
    await Future<void>.delayed(Duration.zero);
    expect(playback.pendingShuffleWrites, hasLength(1));

    final closing = controller.close(discard: true);
    await Future<void>.delayed(Duration.zero);
    expect(playback.disposed, isFalse);

    playback.completeNextShuffleWrite();
    await Future.wait(<Future<void>>[toggle, closing]);

    expect(playback.disposed, isTrue);
    expect(playback.shuffleWrites, <bool>[true]);
  });

  test(
    'shuffle covers the queue before repeating and history follows play order',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(mediaFiles.map((file) => file.path).toList());
      final firstId = controller.current!.id;

      await controller.toggleShuffle();
      expect(controller.current!.id, firstId);
      await controller.cycleRepeat();
      final playOrder = <String>[firstId];
      await controller.next();
      playOrder.add(controller.current!.id);
      await controller.next();
      playOrder.add(controller.current!.id);

      expect(playOrder.toSet(), hasLength(mediaFiles.length));
      final lastBeforeCycle = controller.current!.id;
      await controller.next();
      playOrder.add(controller.current!.id);
      expect(controller.current!.id, isNot(lastBeforeCycle));

      await controller.previous();
      expect(controller.current!.id, playOrder[2]);
      await controller.next();
      expect(controller.current!.id, playOrder[3]);
      await controller.close();
    },
  );

  test(
    'repeat one restarts the current item and manual next still advances',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(mediaFiles.map((file) => file.path).toList());
      await controller.cycleRepeat();
      await controller.cycleRepeat();
      expect(controller.repeatMode, 'one');

      playback.emit(completed: true);
      for (
        var attempt = 0;
        attempt < 100 && playback.openedPaths.length < 2;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(playback.openedPaths, hasLength(2));
      expect(controller.current?.path, mediaFiles[0].path);

      await controller.next();
      expect(controller.current?.path, mediaFiles[1].path);
      await controller.close();
    },
  );

  test('repeat off stops after the last queued item', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[
      mediaFiles[0].path,
      mediaFiles[1].path,
    ]);

    await controller.next();
    expect(controller.current?.path, mediaFiles[1].path);
    await controller.next();

    expect(controller.hasMedia, isFalse);
    expect(controller.isPlaying, isFalse);
    await controller.close();
  });

  test(
    'playback settings can retry the same value after a failed apply',
    () async {
      final playback = _RetryingPlaybackSettingsService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(controller.playbackSettingsError, 'Video output is not ready.');
      expect(playback.applyCount, 1);

      await controller.setPlaybackSettings(PlaybackSettings.defaults);

      expect(playback.applyCount, 2);
      expect(controller.playbackSettingsError, isNull);
      await controller.close();
    },
  );

  test('relative volume bursts serialize and keep the newest target', () async {
    final playback = _DelayedVolumePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    playback
      ..volumeRequests.clear()
      ..delayVolumeWrites = true;

    final first = controller.adjustVolume(-10);
    final second = controller.adjustVolume(-10);
    final third = controller.adjustVolume(-10);

    expect(controller.volume, 70);
    expect(playback.volumeRequests, <double>[90]);
    expect(playback.pendingVolumeWrites, hasLength(1));

    playback.completeNextVolumeWrite();
    await Future<void>.delayed(Duration.zero);
    expect(controller.volume, 70);
    expect(playback.volumeRequests, <double>[90, 70]);
    expect(playback.pendingVolumeWrites, hasLength(1));

    playback.completeNextVolumeWrite();
    await Future.wait(<Future<void>>[first, second, third]);
    expect(playback.state.volume, 70);
    await controller.close();
  });

  test(
    'volume clamps and mute restore share state across input sources',
    () async {
      final sessions = SessionRepository(
        directory: Directory('${temporaryDirectory.path}/session'),
      );
      await sessions.save(const PlaybackSession(volume: 42));
      final firstPlayback = _FakePlaybackService();
      final first = PlayerController(
        playback: firstPlayback,
        sessions: sessions,
      );
      await first.initialize();
      expect(first.volume, 42);

      await first.adjustVolume(-7);
      expect(first.volume, 35);
      await first.toggleMute();
      expect(first.volume, 0);
      await first.toggleMute();
      expect(first.volume, 35);
      await first.saveSession();
      await first.close();

      final restoredPlayback = _FakePlaybackService();
      final restored = PlayerController(
        playback: restoredPlayback,
        sessions: sessions,
      );
      await restored.initialize();
      expect(restored.volume, 35);

      await restored.setVolume(150);
      expect(restored.volume, 100);
      await restored.adjustVolume(-250);
      expect(restored.volume, 0);
      await restored.adjustVolume(500);
      expect(restored.volume, 100);
      await restored.close();
    },
  );

  test('restored muted session has a usable default unmute level', () async {
    final sessions = SessionRepository(
      directory: Directory('${temporaryDirectory.path}/muted-session'),
    );
    await sessions.save(const PlaybackSession(volume: 0));
    final playback = _FakePlaybackService();
    playback.emit(volume: 24);
    final controller = PlayerController(playback: playback, sessions: sessions);

    await controller.initialize();
    expect(controller.volume, 0);
    await controller.toggleMute();
    expect(controller.volume, 100);
    await controller.close();
  });

  test('failed volume write rolls back to the last confirmed value', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    playback.failNextVolumeWrite = true;

    await controller.setVolume(42);

    expect(controller.volume, 100);
    expect(controller.error, contains('Could not set volume'));
    await controller.close();
  });

  test(
    'queue edits after removal invalidate whole-queue undo snapshots',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
      ]);
      await controller.removeAt(0);
      expect(controller.canUndo, isTrue);

      await controller.openPaths(<String>[mediaFiles[2].path], append: true);
      expect(controller.canUndo, isFalse);
      await controller.undoRemove();

      expect(controller.queue.map((entry) => entry.path), <String>[
        mediaFiles[1].path,
        mediaFiles[2].path,
      ]);
      await controller.close();
    },
  );

  test(
    'reordering after removal does not restore the old queue on undo',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(mediaFiles.map((file) => file.path).toList());
      await controller.removeAt(0);
      expect(controller.canUndo, isTrue);

      await controller.reorder(0, 2);
      expect(controller.canUndo, isFalse);
      await controller.undoRemove();

      expect(controller.queue.map((entry) => entry.path), <String>[
        mediaFiles[2].path,
        mediaFiles[1].path,
      ]);
      await controller.close();
    },
  );

  test(
    'removing the playing item advances and undo restores it by identity',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(mediaFiles.map((file) => file.path).toList());
      await controller.playIndex(1);
      final removedId = controller.current!.id;

      await controller.removeAt(controller.currentIndex);

      expect(controller.current!.path, mediaFiles[2].path);
      expect(controller.isPlaying, isTrue);
      expect(controller.canUndo, isTrue);
      await controller.undoRemove();

      expect(controller.queue.map((entry) => entry.path), <String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
        mediaFiles[2].path,
      ]);
      expect(controller.current!.id, removedId);
      expect(controller.currentIndex, 1);
      expect(playback.openedPaths, <String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
        mediaFiles[2].path,
        mediaFiles[1].path,
      ]);
      await controller.close();
    },
  );

  test(
    'history position restores without autoplay and is used on reopen',
    () async {
      final sessions = SessionRepository(
        directory: Directory('${temporaryDirectory.path}/session'),
      );
      final firstPlayback = _FakePlaybackService();
      final first = PlayerController(
        playback: firstPlayback,
        sessions: sessions,
      );
      await first.initialize();
      await first.openPaths(<String>[mediaFiles[0].path]);
      firstPlayback.emit(position: const Duration(seconds: 27));
      await first.saveSession();

      final saved = await sessions.load();
      expect(saved, isNotNull);
      expect(saved!.recent, hasLength(1));
      expect(
        saved.recent.single.id,
        MediaEntry.canonicalSource(mediaFiles[0].path),
      );
      expect(saved.recent.single.position, const Duration(seconds: 27));
      await first.close();

      final secondPlayback = _FakePlaybackService();
      final second = PlayerController(
        playback: secondPlayback,
        sessions: sessions,
      );
      await second.initialize();
      expect(second.current!.path, mediaFiles[0].path);
      expect(second.current!.position, const Duration(seconds: 27));
      expect(second.isPlaying, isFalse);
      expect(secondPlayback.openedPaths, isEmpty);

      await second.openPaths(<String>[mediaFiles[0].path]);
      expect(secondPlayback.seekCalls, contains(const Duration(seconds: 27)));
      expect(second.current!.position, const Duration(seconds: 27));
      await second.close();
    },
  );

  test(
    'restored stopped session exposes its saved position and duration',
    () async {
      final sessions = SessionRepository(
        directory: Directory('${temporaryDirectory.path}/restored-progress'),
      );
      final entry = MediaEntry(
        id: 'restored-entry',
        path: mediaFiles[0].path,
        title: 'video-0.mp4',
        position: const Duration(seconds: 40),
        duration: const Duration(minutes: 2),
        lastPlayed: DateTime.utc(2026, 10, 20),
      );
      await sessions.save(
        PlaybackSession(queue: <MediaEntry>[entry], currentId: entry.id),
      );

      final controller = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      await controller.initialize();

      expect(controller.current?.id, entry.id);
      expect(controller.position, const Duration(seconds: 40));
      expect(controller.duration, const Duration(minutes: 2));
      expect(controller.hasMedia, isFalse);
      await controller.close(discard: true);
    },
  );

  test(
    'a failed resume seek keeps the saved position over engine ticks',
    () async {
      final sessions = SessionRepository(
        directory: Directory('${temporaryDirectory.path}/failed-resume'),
      );
      final entry = MediaEntry(
        id: 'resume-entry',
        path: mediaFiles[0].path,
        title: 'video-0.mp4',
        position: const Duration(seconds: 90),
        duration: const Duration(minutes: 2),
        lastPlayed: DateTime.utc(2026, 10, 20),
      );
      await sessions.save(
        PlaybackSession(queue: <MediaEntry>[entry], currentId: entry.id),
      );

      final playback = _FailingSeekPlaybackService()..failSeeks = true;
      final controller = PlayerController(
        playback: playback,
        sessions: sessions,
      );
      await controller.initialize();
      await controller.playIndex(0);
      await Future<void>.delayed(Duration.zero);

      expect(controller.error, contains('Could not resume playback position'));
      expect(controller.position, const Duration(seconds: 90));

      // The engine reports the freshly opened source at zero; the saved resume
      // point must survive until the resume-floor grace period expires.
      playback.emit(position: Duration.zero);
      expect(controller.position, const Duration(seconds: 90));
      expect(controller.current?.position, const Duration(seconds: 90));

      await controller.close(discard: true);
    },
  );

  test('a resume seek cannot overwrite a newer user seek', () async {
    final sessions = SessionRepository(
      directory: Directory('${temporaryDirectory.path}/resume-race'),
    );
    final entry = MediaEntry(
      id: 'resume-race-entry',
      path: mediaFiles[0].path,
      title: 'video-0.mp4',
      position: const Duration(seconds: 90),
      duration: const Duration(minutes: 2),
      lastPlayed: DateTime.utc(2026, 10, 20),
    );
    await sessions.save(
      PlaybackSession(queue: <MediaEntry>[entry], currentId: entry.id),
    );

    final playback = _GatedSeekPlaybackService()..delaySeeks = true;
    final controller = PlayerController(playback: playback, sessions: sessions);
    await controller.initialize();
    await controller.playIndex(0);
    expect(controller.position, const Duration(seconds: 90));

    // The resume seek is still in flight when the user seeks elsewhere. The
    // late resume completion must not restore the old checkpoint.
    playback
      ..delaySeeks = false
      ..publishSeekCompletions = false;
    await controller.seek(const Duration(seconds: 15));
    expect(controller.position, const Duration(seconds: 15));

    playback.completeNextSeek();
    await Future<void>.delayed(Duration.zero);

    expect(controller.position, const Duration(seconds: 15));
    expect(controller.current?.position, const Duration(seconds: 15));
    expect(controller.queue.single.position, const Duration(seconds: 15));
    await controller.close(discard: true);
  });

  test('a failed open stops periodic progress checkpoints', () async {
    final repository = _RecordingProgressSessionRepository(
      directory: Directory('${temporaryDirectory.path}/failed-checkpoints'),
    );
    final playback = _FakePlaybackService();
    final controller = PlayerController(
      playback: playback,
      sessions: repository,
    );
    await controller.initialize();
    await controller.openPaths(<String>[mediaFiles[0].path]);
    expect(controller.isPlaying, isTrue);

    playback.failNextOpen = true;
    await controller.openPaths(<String>[mediaFiles[1].path]);
    expect(controller.hasMedia, isFalse);
    final writesAfterFailure = repository.writes.length;

    // A periodic timer would fire within two seconds; a stopped one never does.
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    expect(
      repository.writes.length,
      writesAfterFailure,
      reason: 'A failed source must not keep writing progress checkpoints.',
    );
    await controller.close(discard: true);
  });

  test(
    'buffering listenable follows pending transitions and queue resets',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
      ]);
      expect(controller.bufferingListenable.value, isFalse);

      final gate = Completer<void>();
      final started = Completer<void>();
      playback.openBeforeGates[mediaFiles[1].path] = gate;
      playback.openStartedSignals[mediaFiles[1].path] = started;
      final transition = controller.playIndex(1);
      await started.future;

      expect(controller.isBuffering, isTrue);
      expect(controller.bufferingListenable.value, isTrue);

      await controller.clearQueue();
      expect(controller.isBuffering, isFalse);
      expect(controller.bufferingListenable.value, isFalse);
      expect(controller.queue, isEmpty);

      gate.complete();
      await transition;
      await controller.close(discard: true);
    },
  );

  test('repeat all advances the domain queue at end of file', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[
      mediaFiles[0].path,
      mediaFiles[1].path,
    ]);
    await controller.cycleRepeat();
    expect(controller.repeatMode, 'all');

    playback.emit(completed: true);
    while (!controller.hasMedia) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(controller.current!.path, mediaFiles[1].path);

    playback.emit(completed: true);
    while (controller.current!.path != mediaFiles[0].path ||
        !controller.hasMedia) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(controller.current!.path, mediaFiles[0].path);
    await controller.close();
  });

  test(
    'overlapping queue operations coalesce native transitions and newest selection wins',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(mediaFiles.map((f) => f.path).toList());
      expect(controller.currentIndex, 0);

      // Gate the next open operations
      final firstOpenGate = Completer<void>();
      playback.openGates[mediaFiles[1].path] = firstOpenGate;

      // Start transition to index 1
      final playFirst = controller.playIndex(1);
      expect(controller.currentIndex, 1);
      expect(controller.hasMedia, isFalse);

      // Before index 1 finishes opening, immediately select index 2
      final secondOpenGate = Completer<void>();
      playback.openGates[mediaFiles[2].path] = secondOpenGate;
      final playSecond = controller.playIndex(2);
      expect(controller.currentIndex, 2);

      // Now complete the first open (which was for index 1)
      firstOpenGate.complete();
      await playFirst;

      // Ensure index 1 was aborted and did NOT win or set hasMedia
      expect(controller.currentIndex, 2);
      expect(controller.current!.path, mediaFiles[2].path);

      // Now complete the second open (which was for index 2)
      secondOpenGate.complete();
      await playSecond;

      expect(controller.currentIndex, 2);
      expect(controller.current!.path, mediaFiles[2].path);
      expect(controller.hasMedia, isTrue);

      await controller.close(discard: true);
    },
  );

  test('stale playback events across transition boundary are suppressed', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[
      mediaFiles[0].path,
      mediaFiles[1].path,
    ]);
    expect(controller.hasMedia, isTrue);
    expect(controller.currentIndex, 0);

    // Capture boundary before track 1 transition begins
    final boundaryBeforeOpen = playback.sourceStart;

    // Gate the open for track 1
    final openGate = Completer<void>();
    playback.openGates[mediaFiles[1].path] = openGate;

    final transition = controller.playIndex(1);
    expect(controller.currentIndex, 1);
    expect(
      controller.hasMedia,
      isFalse,
      reason: 'hasMedia is false while loading',
    );

    // While loading track 1, emit stale events from track 0 (completed, position)
    playback.emit(
      position: const Duration(seconds: 90),
      completed: true,
      sourceStart: boundaryBeforeOpen,
    );

    // Verify completion was suppressed (did not advance queue or clobber position)
    expect(controller.currentIndex, 1);
    expect(controller.position, Duration.zero);

    // Open succeeds
    openGate.complete();
    await transition;
    expect(controller.hasMedia, isTrue);

    // Even after open finishes, an event with stale sourceStart is suppressed
    playback.emit(
      position: const Duration(seconds: 99),
      completed: true,
      sourceStart: boundaryBeforeOpen,
    );
    expect(controller.position, Duration.zero);
    expect(controller.currentIndex, 1);

    // A fresh event with current sourceStart updates position
    playback.emit(
      position: const Duration(seconds: 15),
      completed: false,
      sourceStart: playback.sourceStart,
    );
    expect(controller.position, const Duration(seconds: 15));

    await controller.close(discard: true);
  });

  test(
    'converts local paths and file URIs to absolute and preserves HTTP/HTTPS',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();

      const httpUri = 'http://example.com/stream/video.mp4';
      const httpsUri = 'https://example.com/live/playlist.m3u8?token=xyz';
      const relativePath = 'local_file.mp4';
      final expectedAbsolute = p.normalize(p.absolute(relativePath));

      await controller.openPaths(<String>[httpUri, httpsUri, relativePath]);

      expect(controller.queue[0].path, httpUri);
      expect(controller.queue[1].path, httpsUri);
      expect(controller.queue[2].path, expectedAbsolute);

      // Verify file URI conversion
      final fileUri = Uri.file(mediaFiles[0].path).toString();
      final entry = MediaEntry.fromPath(fileUri, id: 'test-id');
      expect(entry.path, mediaFiles[0].path);

      await controller.close(discard: true);
    },
  );

  test(
    'clears previous errors on transition start and retains errors from new attempt',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();

      // Trigger an initial error with a non-existent file
      await controller.openPaths(<String>['non_existent_file_xyz.mp4']);
      expect(controller.error, isNotNull);
      expect(controller.error, contains('File not found'));

      // Start transition to a valid file: error must clear immediately
      final openGate = Completer<void>();
      playback.openGates[mediaFiles[0].path] = openGate;
      final transition = controller.openPaths(<String>[mediaFiles[0].path]);
      expect(
        controller.error,
        isNull,
        reason: 'Error must be cleared on transition start',
      );

      // Complete open successfully
      openGate.complete();
      await transition;
      expect(controller.error, isNull);

      // Now start transition to an attempt that fails open()
      playback.failNextOpen = true;
      await controller.openPaths(<String>[mediaFiles[1].path]);
      expect(controller.error, isNotNull);
      expect(controller.error, contains('Could not open'));

      await controller.close(discard: true);
    },
  );

  test(
    'failed-save shutdown throws SessionSaveException, keeps controller open, supports discard, and shares concurrent calls',
    () async {
      final failingRepo = _FailingSessionRepository(
        directory: Directory('${temporaryDirectory.path}/failed-save'),
      );
      final playback = _FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: failingRepo,
      );
      await controller.initialize();
      await controller.openPaths(<String>[mediaFiles[0].path]);

      failingRepo.failSaves = true;

      // Concurrent close calls share the same in-flight operation and both throw SessionSaveException
      final f1 = controller.close();
      final f2 = controller.close();
      expect(f1, throwsA(isA<SessionSaveException>()));
      expect(f2, throwsA(isA<SessionSaveException>()));

      try {
        await f1;
      } on SessionSaveException catch (_) {}

      // Controller remains open and operational because save failed
      expect(controller.hasMedia, isTrue);
      expect(controller.queue, hasLength(1));

      // Can close with discard: true to skip saving and cleanly close
      await controller.close(discard: true);
      expect(playback.disposed, isTrue);
    },
  );

  test(
    'discard close releases playback after a persistence flush failure',
    () async {
      final repository = _FailingFlushSessionRepository(
        directory: Directory('${temporaryDirectory.path}/flush-close'),
      );
      final playback = _FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: repository,
      );
      await controller.initialize();
      await controller.openPaths(<String>[mediaFiles[0].path]);

      repository.failFlush = true;
      await expectLater(
        controller.close(),
        throwsA(isA<SessionSaveException>()),
      );
      expect(controller.closingState, ControllerClosingState.awaitingDecision);
      expect(playback.disposed, isFalse);

      await controller.close(discard: true);

      expect(controller.closingState, ControllerClosingState.closed);
      expect(playback.disposed, isTrue);
    },
  );

  test('joined discard close completes after playback is released', () async {
    final repository = _FailingSessionRepository(
      directory: Directory('${temporaryDirectory.path}/joined-discard'),
    );
    final playback = _FakePlaybackService();
    final controller = PlayerController(
      playback: playback,
      sessions: repository,
    );
    await controller.initialize();
    await controller.openPaths(<String>[mediaFiles[0].path]);

    repository.failSaves = true;
    await expectLater(controller.close(), throwsA(isA<SessionSaveException>()));
    expect(controller.closingState, ControllerClosingState.awaitingDecision);

    playback.disposeGate = Completer<void>();
    var joinedCompleted = false;
    final joined = controller.close().then((_) {
      joinedCompleted = true;
    });
    final discard = controller.close(discard: true);
    await Future<void>.delayed(Duration.zero);

    expect(
      joinedCompleted,
      isFalse,
      reason: 'A joined close must not finish before playback is released.',
    );
    expect(playback.disposed, isFalse);

    playback.disposeGate!.complete();
    await Future.wait<void>(<Future<void>>[joined, discard]);
    expect(joinedCompleted, isTrue);
    expect(playback.disposed, isTrue);
  });

  test('history is recorded only on successful playback', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    expect(controller.recent, isEmpty);

    // 1. Missing file: should NOT be added to history
    await controller.openPaths(<String>['missing_media.mp4']);
    expect(
      controller.recent,
      isEmpty,
      reason: 'Missing file must not be recorded in history',
    );

    // 2. Playback open failure: should NOT be added to history
    playback.failNextOpen = true;
    await controller.openPaths(<String>[mediaFiles[0].path]);
    expect(
      controller.recent,
      isEmpty,
      reason: 'Failed open must not be recorded in history',
    );

    // 3. Successful open: SHOULD be added to history
    playback.failNextOpen = false;
    await controller.openPaths(<String>[mediaFiles[1].path]);
    expect(controller.recent, hasLength(1));
    expect(controller.recent.single.path, mediaFiles[1].path);

    await controller.close(discard: true);
  });

  test(
    'replacing the queue starts a new one while appending keeps it',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
      ]);
      expect(controller.queue, hasLength(2));
      expect(controller.current!.path, mediaFiles[0].path);

      await controller.openPaths(<String>[mediaFiles[2].path]);

      expect(
        controller.queue.map((entry) => entry.path),
        <String>[mediaFiles[2].path],
        reason: 'A replacing open must not keep the previous queue',
      );
      expect(controller.current!.path, mediaFiles[2].path);
      expect(controller.hasMedia, isTrue);

      await controller.openPaths(<String>[mediaFiles[1].path], append: true);

      expect(
        controller.queue.map((entry) => entry.path),
        <String>[mediaFiles[2].path, mediaFiles[1].path],
        reason: 'Appending keeps the queue and the playing source',
      );
      expect(controller.current!.path, mediaFiles[2].path);
      await controller.close(discard: true);
    },
  );

  test('a snapshot for an unrequested source is never adopted', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[
      mediaFiles[0].path,
      mediaFiles[1].path,
    ]);
    await controller.playIndex(0);
    expect(controller.hasMedia, isTrue);

    // libmpv can report a source the player never asked for, for example when a
    // previous transition finished late.
    playback.emitForeignSource(
      'https://media.example/other.mp4',
      position: const Duration(minutes: 5),
    );

    expect(controller.current!.id, controller.queue[0].id);
    expect(
      controller.position,
      isNot(const Duration(minutes: 5)),
      reason: 'Position from another source must not reach the current item',
    );
    expect(controller.queue[0].position, isNot(const Duration(minutes: 5)));

    // The engine keeps reporting its own source: the player stays on the entry
    // it selected instead of following the foreign identity.
    expect(controller.hasMedia, isTrue);
    expect(controller.current!.path, mediaFiles[0].path);
    await controller.close(discard: true);
  });

  test('the pending resume position holds until the engine reports it', () async {
    final sessions = SessionRepository(
      directory: Directory('${temporaryDirectory.path}/session'),
    );
    final firstPlayback = _FakePlaybackService();
    final first = PlayerController(playback: firstPlayback, sessions: sessions);
    await first.initialize();
    await first.openPaths(<String>[mediaFiles[0].path]);
    await first.seek(const Duration(seconds: 90));
    await first.saveSession();
    await first.close(discard: true);

    final playback = _GatedSeekPlaybackService()..delaySeeks = true;
    final controller = PlayerController(playback: playback, sessions: sessions);
    await controller.initialize();
    await controller.openPaths(<String>[mediaFiles[0].path]);
    expect(controller.position, const Duration(seconds: 90));

    // The engine publishes its own position for the freshly opened source while
    // the resume seek is still on its way; the saved target must survive it.
    playback.emit(position: Duration.zero);

    expect(controller.position, const Duration(seconds: 90));
    expect(controller.current!.position, const Duration(seconds: 90));

    // Once the seek lands, the engine's positions are trusted again.
    playback.completeNextSeek();
    await Future<void>.delayed(Duration.zero);
    expect(controller.position, const Duration(seconds: 90));

    playback.emit(position: const Duration(seconds: 95));

    expect(controller.position, const Duration(seconds: 95));
    expect(controller.current!.position, const Duration(seconds: 95));
    await controller.close(discard: true);
  });

  test(
    'a newer progress checkpoint wins over the session and an older one is ignored',
    () async {
      final directory = Directory('${temporaryDirectory.path}/session');
      final sessions = SessionRepository(directory: directory);

      // First run: the source is played once and the stopped session is stored.
      final seed = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      await seed.initialize();
      await seed.openPaths(<String>[mediaFiles[0].path]);
      await seed.close();

      // Second run: the restored item is stopped, so a seek updates the saved
      // progress directly and writes a checkpoint, which the session then records.
      final controller = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      await controller.initialize();
      expect(controller.hasMedia, isFalse);
      await controller.seek(const Duration(seconds: 40));
      await controller.saveSession();

      final stored = (await sessions.load())!;
      final entryId = stored.queue.single.id;
      final sessionRevision = stored.progressRevision;
      expect(
        sessionRevision,
        greaterThan(0),
        reason: 'The session records the revision of the checkpoint it applied',
      );

      // Written before the session revision: the full session already knows more.
      await sessions.saveProgress(
        SessionProgress(
          revision: sessionRevision - 1,
          entryId: entryId,
          position: const Duration(seconds: 5),
          duration: const Duration(minutes: 2),
        ),
      );
      final withStaleCheckpoint = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      await withStaleCheckpoint.initialize();
      expect(
        withStaleCheckpoint.current!.position,
        const Duration(seconds: 40),
      );
      await withStaleCheckpoint.close(discard: true);

      // Written after it: the checkpoint is the newer truth.
      await sessions.saveProgress(
        SessionProgress(
          revision: sessionRevision + 1,
          entryId: entryId,
          position: const Duration(seconds: 70),
          duration: const Duration(minutes: 2),
        ),
      );
      final withFreshCheckpoint = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      await withFreshCheckpoint.initialize();
      expect(
        withFreshCheckpoint.current!.position,
        const Duration(seconds: 70),
      );
      await withFreshCheckpoint.close(discard: true);
    },
  );

  test(
    'turning URL persistence off scrubs stored stream URLs and keeps local rows',
    () async {
      final directory = Directory('${temporaryDirectory.path}/session');
      final sessions = SessionRepository(directory: directory);
      final playback = _FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: sessions,
      );
      await controller.initialize();

      await controller.setSaveNetworkUrls(true);
      await controller.openPaths(<String>['https://media.example/live.m3u8']);
      await controller.openPaths(<String>[mediaFiles[0].path], append: true);
      await controller.saveSession();
      await controller.saveSession();

      await controller.setSaveNetworkUrls(false);

      for (final name in <String>[
        'session.json',
        'session.json.bak',
        'progress.json',
      ]) {
        final file = File(p.join(directory.path, name));
        if (!await file.exists()) continue;
        expect(
          await file.readAsString(),
          isNot(contains('media.example')),
          reason: '$name must not keep the stream URL the user removed',
        );
      }
      final restored = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      await restored.initialize();
      expect(
        restored.queue.map((entry) => entry.path),
        <String>[mediaFiles[0].path],
        reason: 'A restarted player must not restore the removed stream',
      );
      await restored.close(discard: true);
      await controller.close(discard: true);
    },
  );

  test(
    'startup migration finishes scrubbing an unconsented URL checkpoint',
    () async {
      final directory = Directory('${temporaryDirectory.path}/migration');
      await directory.create(recursive: true);
      const url =
          'https://user:password@example.test/video?token=REVIEW_SECRET';
      final stream = MediaEntry.fromPath(url, id: url);
      final legacy =
          PlaybackSession(
              queue: <MediaEntry>[stream],
              recent: <MediaEntry>[stream],
              currentId: stream.id,
            ).toJson()
            ..['version'] = 1
            ..remove('saveNetworkUrls');
      await File(
        p.join(directory.path, 'session.json'),
      ).writeAsString(jsonEncode(legacy));
      await File(p.join(directory.path, 'progress.json')).writeAsString(
        jsonEncode(
          SessionProgress(
            revision: 1,
            entryId: stream.id,
            position: const Duration(seconds: 45),
          ).toJson(),
        ),
      );

      final sessions = SessionRepository(directory: directory);
      final controller = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      try {
        await controller.initialize();

        for (final name in <String>[
          'session.json',
          'session.json.bak',
          'progress.json',
        ]) {
          final file = File(p.join(directory.path, name));
          expect(await file.exists(), isTrue, reason: '$name should be ready');
          expect(
            await file.readAsString(),
            isNot(contains('REVIEW_SECRET')),
            reason: 'Initialization must finish scrubbing $name',
          );
        }
        expect(await sessions.loadProgress(), isNull);
        expect(controller.queue, isEmpty);
      } finally {
        await controller.close(discard: true);
      }
    },
  );

  test('URL opt-out resumes periodic checkpoints for local playback', () async {
    final sessions = SessionRepository(
      directory: Directory(p.join(temporaryDirectory.path, 'opt-out-progress')),
    );
    final playback = _FakePlaybackService();
    final controller = PlayerController(playback: playback, sessions: sessions);
    try {
      await controller.initialize();
      await controller.setSaveNetworkUrls(true);
      await controller.openPaths(<String>[mediaFiles[0].path]);
      await controller.setSaveNetworkUrls(false);
      playback.emit(position: const Duration(seconds: 31));
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      await sessions.flush();
      expect(
        (await sessions.loadProgress())?.position,
        const Duration(seconds: 31),
      );
    } finally {
      await controller.close(discard: true);
    }
  });

  test('a later URL opt-in wins over an in-flight opt-out scrub', () async {
    final sessions = _GatedScrubRepository(
      directory: Directory(p.join(temporaryDirectory.path, 'consent-race')),
    );
    final controller = PlayerController(
      playback: _FakePlaybackService(),
      sessions: sessions,
    );
    try {
      await controller.initialize();
      await controller.setSaveNetworkUrls(true);
      await controller.openPaths(<String>[
        'https://example.test/live?token=CONSENTED',
      ]);
      final disabling = controller.setSaveNetworkUrls(false);
      await sessions.scrubEntered.future;
      await controller.setSaveNetworkUrls(true);
      sessions.allowScrub.complete();
      await disabling;
      final stored = (await sessions.load())!;
      expect(controller.saveNetworkUrls, isTrue);
      expect(stored.saveNetworkUrls, isTrue);
      expect(stored.queue.single.path, contains('CONSENTED'));
    } finally {
      if (!sessions.allowScrub.isCompleted) sessions.allowScrub.complete();
      await controller.close(discard: true);
    }
  });

  test(
    'startup scrubs a URL-shaped checkpoint beside an already-clean session',
    () async {
      final directory = Directory(
        '${temporaryDirectory.path}/clean-checkpoint',
      );
      final sessions = SessionRepository(directory: directory);
      final local = MediaEntry.fromPath(
        '${temporaryDirectory.path}/local.mkv',
        id: 'local-entry',
      );
      final cleanSession = PlaybackSession(
        queue: <MediaEntry>[local],
        currentId: local.id,
      );
      await sessions.save(cleanSession);
      await sessions.save(cleanSession);

      const secretUrl =
          'https://user:password@example.test/video?token=CHECKPOINT_SECRET';
      await File(p.join(directory.path, 'progress.json')).writeAsString(
        jsonEncode(
          const SessionProgress(
            revision: 7,
            entryId: secretUrl,
            position: Duration(seconds: 30),
          ).toJson(),
        ),
      );

      final controller = PlayerController(
        playback: _FakePlaybackService(),
        sessions: sessions,
      );
      try {
        await controller.initialize();

        expect(controller.queue.map((entry) => entry.id), <String>[local.id]);
        expect(await sessions.loadProgress(), isNull);
        for (final name in <String>[
          'session.json',
          'session.json.bak',
          'progress.json',
        ]) {
          expect(
            await File(p.join(directory.path, name)).readAsString(),
            isNot(contains('CHECKPOINT_SECRET')),
            reason: 'Initialization must scrub $name even for a clean queue',
          );
        }
      } finally {
        await controller.close(discard: true);
      }
    },
  );

  test('close waits for a session write already in progress', () async {
    final directory = Directory('${temporaryDirectory.path}/close-session');
    final encoderStarted = Completer<void>();
    final releaseEncoder = Completer<void>();
    var encodeCount = 0;
    final sessions = SessionRepository(
      directory: directory,
      encoder: (session) async {
        encodeCount++;
        if (encodeCount == 1) {
          encoderStarted.complete();
          await releaseEncoder.future;
        }
        return jsonEncode(session.toJson());
      },
    );
    final playback = _FakePlaybackService();
    final controller = PlayerController(playback: playback, sessions: sessions);
    await controller.initialize();

    final saving = controller.saveSession();
    await encoderStarted.future;
    var closed = false;
    final closing = controller.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(playback.disposed, isFalse);

    releaseEncoder.complete();
    await Future.wait<void>(<Future<void>>[saving, closing]);
    expect(playback.disposed, isTrue);
    expect(encodeCount, greaterThanOrEqualTo(2));
  });

  test(
    'close drains a progress checkpoint before releasing playback',
    () async {
      final repository = _GatedProgressSessionRepository();
      final playback = _FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: repository,
      );
      await controller.initialize();
      await controller.openPaths(<String>[mediaFiles.first.path]);
      await controller.togglePlayPause();
      await repository.writeStarted.future;
      await controller.togglePlayPause();
      playback.emit(position: const Duration(seconds: 45));
      await controller.togglePlayPause();

      var closed = false;
      final closing = controller.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(playback.disposed, isFalse);

      repository.releaseWrite.complete();
      await closing;
      expect(repository.saved?.entryId, controller.queueSnapshot.currentId);
      expect(repository.saved?.position, const Duration(seconds: 45));
      expect(playback.disposed, isTrue);
    },
  );

  test(
    'coalesced checkpoint keeps the newest source and its position',
    () async {
      final repository = _CoalescedProgressSessionRepository();
      final playback = _FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: repository,
      );
      try {
        await controller.initialize();
        await controller.openPaths(<String>[
          mediaFiles[0].path,
          mediaFiles[1].path,
        ]);
        playback.emit(position: const Duration(seconds: 10));
        await controller.togglePlayPause();
        await repository.firstWrite.future.timeout(const Duration(seconds: 4));

        await controller.playIndex(1);
        final newestEntryId = controller.current!.id;
        playback.emit(position: const Duration(seconds: 55));
        await controller.togglePlayPause();

        repository.releaseFirst.complete();
        await repository.secondWrite.future.timeout(const Duration(seconds: 4));
        expect(repository.writes.last.entryId, newestEntryId);
        expect(repository.writes.last.position, const Duration(seconds: 55));
      } finally {
        if (!repository.releaseFirst.isCompleted) {
          repository.releaseFirst.complete();
        }
        await controller.close(discard: true);
      }
    },
  );

  test(
    'playback ticks do not increment queueRevision or clone the queue',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
      ]);

      final initialRevision = controller.queueRevision;
      final initialQueue = controller.queue;
      expect(initialQueue, hasLength(2));

      var queueNotifications = 0;
      controller.queueListenable.addListener(() => queueNotifications++);
      var controllerNotifications = 0;
      controller.addListener(() => controllerNotifications++);

      var positionNotifications = 0;
      controller.positionListenable.addListener(() => positionNotifications++);

      // Simulate multiple playback ticks advancing position.
      for (var sec = 1; sec <= 10; sec++) {
        playback.emit(position: Duration(seconds: sec));
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.position, const Duration(seconds: 10));
      expect(positionNotifications, greaterThan(0));
      expect(
        controllerNotifications,
        0,
        reason: 'Position-only changes use the timeline listenable',
      );
      expect(
        controller.queueRevision,
        initialRevision,
        reason: 'Playback ticks must not bump queue structural revision',
      );
      expect(
        queueNotifications,
        0,
        reason: 'queueListenable must not notify on position ticks',
      );
      expect(
        identical(controller.queue, initialQueue),
        isTrue,
        reason:
            'Queue getter must return the immutable snapshot without cloning',
      );

      await controller.close(discard: true);
    },
  );

  test('queue filtering stays stable until row metadata changes', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[
      mediaFiles[0].path,
      mediaFiles[1].path,
    ]);

    final filter1 = controller.filterQueue('video-0');
    final filter2 = controller.filterQueue('video-0');
    expect(
      identical(filter1, filter2),
      isTrue,
      reason: 'Subsequent calls for the same query must return cached instance',
    );

    final indexed1 = controller.filterQueueIndexed('video-0');
    final indexed2 = controller.filterQueueIndexed('video-0');
    expect(identical(indexed1, indexed2), isTrue);

    final initialRevision = controller.queueRevision;

    // Simulate position tick.
    playback.emit(position: const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);

    expect(controller.queueRevision, initialRevision);
    final filterAfterTick = controller.filterQueue('video-0');
    expect(
      identical(filterAfterTick, filter1),
      isTrue,
      reason: 'Position-only ticks do not replace queue metadata snapshots',
    );

    await controller.seek(const Duration(seconds: 15));
    final updatedIndexed = controller.filterQueueIndexed('video-0');
    expect(identical(updatedIndexed, indexed1), isFalse);
    final updatedEntry = updatedIndexed.single.$2;
    expect(updatedEntry.position, const Duration(seconds: 15));
    expect(updatedEntry.duration, const Duration(minutes: 2));

    // Structural change: remove item at index 1.
    await controller.removeAt(1);
    expect(controller.queueRevision, greaterThan(initialRevision));

    final filterAfterStructural = controller.filterQueue('video-0');
    expect(filterAfterStructural, hasLength(1));

    await controller.close(discard: true);
  });

  test('progress snapshots resolve cached matches to current entries', () {
    final entry = MediaEntry.fromPath('video.mp4', id: 'video');
    final first = QueueSnapshot(entries: <MediaEntry>[entry], revision: 1);
    first.filterIndexed('video');

    final latestEntry = entry.copyWith(
      position: const Duration(seconds: 20),
      duration: const Duration(minutes: 2),
    );
    final next = first.withUpdatedProgress(<MediaEntry>[latestEntry]);
    final refreshed = next.filterIndexed('video').single.$2;

    expect(refreshed.position, const Duration(seconds: 20));
    expect(refreshed.duration, const Duration(minutes: 2));
  });

  test('retained queue snapshots keep immutable progress metadata', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[mediaFiles[0].path]);

    final retained = controller.queueSnapshot;
    final retainedRow = retained.filterIndexed('video-0').single.$2;
    final retainedFilter = retained.filter('video-0');
    final liveQueueView = controller.queue;
    await controller.seek(const Duration(seconds: 8));

    final latest = controller.queueSnapshot;
    expect(retained.entries.single.position, Duration.zero);
    expect(retainedRow.position, Duration.zero);
    expect(retainedFilter.single.position, Duration.zero);
    expect(latest.entries.single.position, const Duration(seconds: 8));
    expect(controller.queue.single.position, const Duration(seconds: 8));
    expect(
      identical(controller.queue, liveQueueView),
      isTrue,
      reason:
          'The stable live queue view must not be rebuilt on progress ticks',
    );

    await controller.close(discard: true);
  });

  test('QueueSnapshot copies and freezes its source entries', () {
    final original = MediaEntry.fromPath('video.mp4', id: 'video');
    final supplied = <MediaEntry>[original];
    final snapshot = QueueSnapshot(entries: supplied, revision: 1);

    supplied[0] = original.copyWith(position: const Duration(seconds: 9));

    expect(snapshot.entries.single.position, Duration.zero);
    expect(() => snapshot.entries[0] = original, throwsUnsupportedError);
  });

  test('queue query LRU is refreshed by cached filtered views', () {
    final entries = List<MediaEntry>.generate(
      10,
      (index) => MediaEntry(
        id: 'entry-$index',
        path: '/library/query-$index.mkv',
        title: 'query-$index.mkv',
        lastPlayed: DateTime.utc(2026, 10, 18),
      ),
      growable: false,
    );
    final snapshot = QueueSnapshot(entries: entries, revision: 1);
    final retainedViews = <String, List<(int, MediaEntry)>>{};

    for (var index = 0; index < 8; index++) {
      retainedViews['query-$index'] = snapshot.filterIndexed('query-$index');
    }
    expect(snapshot.cachedQueryCount, 8);

    // Both a cached indexed view and an entry-only view must refresh the same
    // matching-index LRU entry.
    expect(
      identical(snapshot.filterIndexed('query-0'), retainedViews['query-0']),
      isTrue,
    );
    snapshot.filter('query-1');
    snapshot.filterIndexed('query-8');

    expect(snapshot.cachedQueryCount, 8);
    expect(
      identical(snapshot.filterIndexed('query-0'), retainedViews['query-0']),
      isTrue,
      reason: 'The recently accessed first query should remain cached',
    );
    expect(
      identical(snapshot.filterIndexed('query-1'), retainedViews['query-1']),
      isTrue,
      reason: 'The entry-only cache hit should refresh the query LRU',
    );
    expect(
      identical(snapshot.filterIndexed('query-2'), retainedViews['query-2']),
      isFalse,
      reason: 'The least recently used query should be evicted',
    );
  });

  test('queue query index cache stays bounded for 10,000 entries', () {
    final entries = List<MediaEntry>.generate(
      10000,
      (index) => MediaEntry(
        id: 'entry-$index',
        path: '/library/item-$index.mkv',
        title: 'item-$index.mkv',
        lastPlayed: DateTime.utc(2026, 10, 18),
      ),
      growable: false,
    );
    final snapshot = QueueSnapshot(entries: entries, revision: 1);

    for (var index = 0; index < 80; index++) {
      expect(snapshot.filterIndexed('item-$index.mkv'), isNotEmpty);
    }

    expect(snapshot.cachedQueryCount, lessThanOrEqualTo(8));
    expect(snapshot.filterIndexed('item-9999.mkv').single.$1, 9999);
    expect(snapshot.cachedQueryCount, lessThanOrEqualTo(8));
  });

  test(
    'granular notifications for position, duration, and buffering fire independently',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[mediaFiles[0].path]);

      Duration? reportedPosition;
      Duration? reportedDuration;
      bool? reportedBuffering;
      var queueNotified = false;

      controller.positionListenable.addListener(() {
        reportedPosition = controller.positionListenable.value;
      });
      controller.durationListenable.addListener(() {
        reportedDuration = controller.durationListenable.value;
      });
      controller.bufferingListenable.addListener(() {
        reportedBuffering = controller.bufferingListenable.value;
      });
      controller.queueListenable.addListener(() {
        queueNotified = true;
      });

      playback.emit(position: const Duration(seconds: 4));
      await Future<void>.delayed(Duration.zero);
      expect(reportedPosition, const Duration(seconds: 4));
      expect(queueNotified, isFalse);

      playback.emit(duration: const Duration(minutes: 5));
      await Future<void>.delayed(Duration.zero);
      expect(reportedDuration, const Duration(minutes: 5));
      expect(
        queueNotified,
        isTrue,
        reason: 'Resolved duration is queue metadata and refreshes its row',
      );

      playback.emit(isBuffering: true);
      await Future<void>.delayed(Duration.zero);
      expect(reportedBuffering, isTrue);

      await controller.close(discard: true);
    },
  );

  test(
    'isBuffering clears to false when opening or resuming a source',
    () async {
      final sessionDir = Directory(
        '${temporaryDirectory.path}/session_buffering_clear',
      );
      final sessions = SessionRepository(directory: sessionDir);
      final playback = _FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: sessions,
      );

      await controller.openPaths(<String>[mediaFiles[0].path]);
      expect(controller.isBuffering, isFalse);
      expect(controller.isLoading, isFalse);

      await controller.seek(const Duration(seconds: 30));
      await controller.playIndex(0);
      expect(controller.isBuffering, isFalse);
      expect(controller.isLoading, isFalse);

      await controller.close(discard: true);
    },
  );

  test(
    'playback ticks do not trigger full session persistence while checkpoints persist progress',
    () async {
      final sessionDir = Directory('${temporaryDirectory.path}/session_ticks');
      final sessions = SessionRepository(directory: sessionDir);
      final playback = _FakePlaybackService();
      final controller = PlayerController(
        playback: playback,
        sessions: sessions,
      );
      await controller.initialize();
      await controller.openPaths(<String>[mediaFiles[0].path]);

      final sessionFile = File(p.join(sessionDir.path, 'session.json'));
      // Wait for initial session save to settle.
      for (var i = 0; i < 30; i++) {
        if (await sessionFile.exists()) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await sessionFile.exists(), isTrue);
      final initialModified = (await sessionFile.stat()).modified;

      // Small delay so timestamp resolution can distinguish modifications.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Emit continuous position ticks.
      for (var sec = 1; sec <= 5; sec++) {
        playback.emit(position: Duration(seconds: sec));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      // Progress checkpoint persists via progress.json.
      final progressFile = File(p.join(sessionDir.path, 'progress.json'));
      for (var i = 0; i < 30; i++) {
        if (await progressFile.exists()) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await progressFile.exists(), isTrue);

      // Verify session.json was NOT rewritten during position ticks.
      final tickModified = (await sessionFile.stat()).modified;
      expect(
        tickModified,
        equals(initialModified),
        reason: 'Position updates must not rewrite the full session file',
      );

      // A settings change (e.g. rate) DOES trigger a full save after debounce.
      await controller.setRate(1.5);
      for (var i = 0; i < 40; i++) {
        if ((await sessionFile.stat()).modified.isAfter(initialModified)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        (await sessionFile.stat()).modified.isAfter(initialModified),
        isTrue,
        reason: 'Settings change must persist to full session file',
      );

      await controller.close();
    },
  );

  test(
    'lazy views and index cache capping at 8 queries and 20,000 retained matches',
    () {
      final entries = List<MediaEntry>.generate(
        10000,
        (index) => MediaEntry(
          id: 'entry-$index',
          path: '/media/video-$index.mp4',
          title: index < 5000 ? 'alpha-$index' : 'beta-$index',
          lastPlayed: DateTime.utc(2026, 1, 1),
        ),
        growable: false,
      );
      final snapshot = QueueSnapshot(entries: entries, revision: 1);

      // Verify lazy views implement List and are unmodifiable.
      final lazyFilter = snapshot.filter('alpha');
      expect(lazyFilter, isA<List<MediaEntry>>());
      expect(lazyFilter.length, 5000);
      expect(lazyFilter[0].title, 'alpha-0');
      expect(() => lazyFilter.add(entries[0]), throwsUnsupportedError);
      expect(() => lazyFilter[0] = entries[0], throwsUnsupportedError);

      final lazyIndexed = snapshot.filterIndexed('alpha');
      expect(lazyIndexed, isA<List<(int, MediaEntry)>>());
      expect(lazyIndexed.length, 5000);
      expect(lazyIndexed[0], (0, entries[0]));
      expect(() => lazyIndexed.add((0, entries[0])), throwsUnsupportedError);
      expect(() => lazyIndexed[0] = (0, entries[0]), throwsUnsupportedError);

      // Query 12 different terms to test capping at 8 queries.
      for (var i = 0; i < 12; i++) {
        snapshot.filterIndexed('alpha-$i');
      }
      expect(snapshot.cachedQueryCount, lessThanOrEqualTo(8));

      // Test total matches capping at 20,000 matches.
      // Create snapshot with 3 groups of 8,000 matching entries.
      final largeEntries = List<MediaEntry>.generate(24000, (index) {
        final tag = index < 8000
            ? 'group1'
            : index < 16000
            ? 'group2'
            : 'group3';
        return MediaEntry(
          id: 'large-$index',
          path: '/path/$tag-$index.mp4',
          title: '$tag video $index',
          lastPlayed: DateTime.utc(2026, 1, 1),
        );
      }, growable: false);
      final largeSnapshot = QueueSnapshot(entries: largeEntries, revision: 1);

      // Query group1 (8000 matches). Total = 8000 <= 20000.
      largeSnapshot.filterIndexed('group1');
      expect(largeSnapshot.cachedQueryCount, 1);
      expect(largeSnapshot.totalRetainedMatches, 8000);

      // Query group2 (8000 matches). Total = 16000 <= 20000.
      largeSnapshot.filterIndexed('group2');
      expect(largeSnapshot.cachedQueryCount, 2);
      expect(largeSnapshot.totalRetainedMatches, 16000);

      // Query group3 (8000 matches). Total would be 24000 > 20000.
      // group1 must be evicted so total <= 20000.
      largeSnapshot.filterIndexed('group3');
      expect(largeSnapshot.cachedQueryCount, 2);
      expect(largeSnapshot.totalRetainedMatches, 16000);

      // A single query larger than the whole match budget must not be retained
      // indirectly by its lazy indexed view.
      final oversizedView = largeSnapshot.filterIndexed('video');
      expect(oversizedView, hasLength(24000));
      expect(largeSnapshot.cachedQueryCount, 0);
      expect(
        identical(largeSnapshot.filterIndexed('video'), oversizedView),
        isFalse,
      );
      expect(largeSnapshot.cachedQueryCount, 0);
    },
  );

  test(
    'single-entry undo restores removed entry at original index without copying queue',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
        mediaFiles[2].path,
      ]);

      await controller.playIndex(0);
      final initialRevision = controller.queueRevision;

      // Remove middle item (index 1).
      final removedEntry = controller.queue[1];
      await controller.removeAt(1);

      expect(controller.queue.length, 2);
      expect(
        controller.queue.map((e) => e.path),
        isNot(contains(removedEntry.path)),
      );
      expect(controller.canUndo, isTrue);

      // Undo restore.
      await controller.undoRemove();
      expect(controller.queue.length, 3);
      expect(controller.queue[1].path, removedEntry.path);
      expect(controller.currentIndex, 0);
      expect(controller.queueRevision, greaterThan(initialRevision));

      await controller.close();
    },
  );

  test(
    'batched import processes in batches of 100 entries and aborts on stale operations',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();

      // Generate 250 paths.
      final paths = List<String>.generate(
        250,
        (i) => '${temporaryDirectory.path}/batch-video-$i.mp4',
      );
      for (final p in paths) {
        final f = File(p);
        await f.writeAsBytes(<int>[1, 2, 3]);
      }

      // Normal import completes all 250 entries.
      await controller.openPaths(paths);
      expect(controller.queue.length, 250);

      // Stale import: clearing the queue while importing aborts remaining batches.
      final morePaths = List<String>.generate(
        250,
        (i) => '${temporaryDirectory.path}/stale-video-$i.mp4',
      );
      for (final p in morePaths) {
        final f = File(p);
        await f.writeAsBytes(<int>[4, 5, 6]);
      }

      // Start openPaths and clearQueue right after to make it stale.
      final openFuture = controller.openPaths(morePaths);
      await controller.clearQueue();
      await openFuture;

      // The stale batches were aborted, so queue remains empty from clearQueue.
      expect(controller.queue, isEmpty);

      await controller.close();
    },
  );

  test(
    '201-entry replacement keeps displayed row actions on the old queue',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
      ]);
      final displayedPaths = controller.queue
          .map((entry) => entry.path)
          .toList();
      final displayedSnapshot = controller.queueSnapshot;

      final importedPaths = List<String>.generate(
        201,
        (index) => '${temporaryDirectory.path}/staged-video-$index.mp4',
      );
      final import = controller.openPaths(importedPaths);
      // The importer yields after staging its first 100 paths. An index callback
      // from the still-displayed queue must continue to select that queue row.
      await Future<void>.delayed(Duration.zero);
      expect(controller.queue.map((entry) => entry.path), displayedPaths);
      expect(identical(controller.queueSnapshot, displayedSnapshot), isTrue);

      await controller.playIndex(1);
      await import;

      expect(controller.current?.path, mediaFiles[1].path);
      expect(playback.openedPaths.last, mediaFiles[1].path);
      expect(controller.queue.map((entry) => entry.path), displayedPaths);

      await controller.close(discard: true);
    },
  );

  test('a structural edit cancels an in-flight append import', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[
      mediaFiles[0].path,
      mediaFiles[1].path,
    ]);

    final importedPaths = List<String>.generate(
      201,
      (index) => '${temporaryDirectory.path}/append-video-$index.mp4',
    );
    final import = controller.openPaths(importedPaths, append: true);
    await controller.removeAt(1);
    await import;

    expect(controller.queue.map((entry) => entry.path), <String>[
      mediaFiles[0].path,
    ]);
    expect(controller.canUndo, isTrue);

    await controller.close(discard: true);
  });

  test('an append import preserves the current pending open', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[
      mediaFiles[0].path,
      mediaFiles[1].path,
    ]);

    final openGate = Completer<void>();
    final openStarted = Completer<void>();
    playback.openBeforeGates[mediaFiles[1].path] = openGate;
    playback.openStartedSignals[mediaFiles[1].path] = openStarted;
    final initialOpen = controller.playIndex(1);
    await openStarted.future;
    expect(controller.isLoading, isTrue);

    final importedPaths = List<String>.generate(
      201,
      (index) => '${temporaryDirectory.path}/pending-append-$index.mp4',
    );
    final append = controller.openPaths(importedPaths, append: true);
    openGate.complete();
    await initialOpen;
    await append;

    expect(controller.queue, hasLength(203));
    expect(controller.current?.path, mediaFiles[1].path);
    expect(playback.openedPaths, <String>[
      mediaFiles[0].path,
      mediaFiles[1].path,
    ]);

    await controller.close(discard: true);
  });

  test('a transport command cancels an in-flight staged import', () async {
    final playback = _FakePlaybackService();
    final controller = _controller(playback, temporaryDirectory);
    await controller.initialize();
    await controller.openPaths(<String>[mediaFiles[0].path]);
    expect(controller.isPlaying, isTrue);

    final importedPaths = List<String>.generate(
      201,
      (index) => '${temporaryDirectory.path}/cancelled-video-$index.mp4',
    );
    final import = controller.openPaths(importedPaths, append: true);
    await controller.togglePlayPause();
    await import;

    expect(controller.isPlaying, isFalse);
    expect(controller.queue.map((entry) => entry.path), <String>[
      mediaFiles[0].path,
    ]);

    await controller.close(discard: true);
  });

  test(
    'duration updates and seeking do not copy the queue or bump queue revision',
    () async {
      final playback = _FakePlaybackService();
      final controller = _controller(playback, temporaryDirectory);
      await controller.initialize();
      await controller.openPaths(<String>[
        mediaFiles[0].path,
        mediaFiles[1].path,
      ]);

      final initialRevision = controller.queueRevision;
      final initialQueueInstance = controller.queue;

      // Seek: should not bump queue revision or create a new queue list.
      await controller.seek(const Duration(seconds: 10));
      expect(controller.queueRevision, initialRevision);
      expect(identical(controller.queue, initialQueueInstance), isTrue);

      // Duration metadata update: does not bump structural revision.
      playback.emit(duration: const Duration(minutes: 5));
      expect(controller.queueRevision, initialRevision);
      expect(identical(controller.queue, initialQueueInstance), isTrue);

      await controller.close();
    },
  );
}

PlayerController _controller(
  _FakePlaybackService playback,
  Directory directory,
) => PlayerController(
  playback: playback,
  sessions: SessionRepository(
    directory: Directory('${directory.path}/session'),
  ),
);

/// Removes a test sandbox while a controller may still be settling its writes.
///
/// Windows reports `FileSystemException: Deletion failed ... OS Error: The
/// directory is removed only after controller and repository writes have
/// drained, so cleanup cannot hide late persistence races.
Future<void> deleteSandbox(Directory directory) =>
    directory.delete(recursive: true);

class _GatedScrubRepository extends SessionRepository {
  _GatedScrubRepository({required super.directory});
  final scrubEntered = Completer<void>();
  final allowScrub = Completer<void>();

  @override
  Future<void> scrubNetworkUrls() async {
    if (!scrubEntered.isCompleted) scrubEntered.complete();
    await allowScrub.future;
    await super.scrubNetworkUrls();
  }
}

class _FakePlaybackService implements PlaybackService {
  final StreamController<PlaybackSnapshot> _events =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);
  final List<String> openedPaths = <String>[];
  final List<Duration> seekCalls = <Duration>[];
  PlaybackSnapshot _state = const PlaybackSnapshot();
  bool disposed = false;
  Completer<void>? disposeGate;
  bool failNextVolumeWrite = false;
  bool failNextOpen = false;
  bool delayShuffleWrites = false;
  bool delayRepeatWrites = false;
  final List<bool> shuffleWrites = <bool>[];
  final List<String> repeatWrites = <String>[];
  final List<Completer<void>> pendingShuffleWrites = <Completer<void>>[];
  final List<Completer<void>> pendingRepeatWrites = <Completer<void>>[];
  final Map<String, Completer<void>> openGates = <String, Completer<void>>{};
  final Map<String, Completer<void>> openBeforeGates =
      <String, Completer<void>>{};
  final Map<String, Completer<void>> openStartedSignals =
      <String, Completer<void>>{};
  int _sourceStart = 0;

  VideoOutputPolicy _videoOutputPolicy = const VideoOutputPolicy();
  @override
  VideoOutputPolicy get videoOutputPolicy => _videoOutputPolicy;
  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    _videoOutputPolicy = policy;
  }

  int get sourceStart => _sourceStart;

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _events.stream;

  @override
  String get engineVersion => 'fake libmpv';

  @override
  Player get player => throw UnsupportedError('No native player in unit tests');

  @override
  VideoController get videoController =>
      throw UnsupportedError('No native video controller in unit tests');

  @override
  Future<void> prepare() async {}

  @override
  Future<void> open(String path, {bool play = true}) async {
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('Simulated open failure for $path');
    }
    final started = openStartedSignals[path];
    if (started != null && !started.isCompleted) started.complete();
    final beforeGate = openBeforeGates[path];
    if (beforeGate != null) await beforeGate.future;
    final boundary = ++_sourceStart;
    openedPaths.add(path);
    _publish(
      _state.copyWith(
        sourceStart: boundary,
        nativeSource: MediaEntry.canonicalSource(path),
        sourceLoaded: true,
        isPlaying: play,
        isBuffering: false,
        position: Duration.zero,
        duration: const Duration(minutes: 2),
        completed: false,
        clearError: true,
      ),
    );
    final gate = openGates[path];
    if (gate != null) {
      await gate.future;
    }
  }

  @override
  Future<void> stop() async {
    final boundary = ++_sourceStart;
    _publish(
      _state.copyWith(
        sourceStart: boundary,
        isPlaying: false,
        isBuffering: false,
        position: Duration.zero,
        duration: Duration.zero,
        completed: false,
        clearNativeSource: true,
        sourceLoaded: false,
      ),
    );
  }

  @override
  Future<void> play() async => _publish(_state.copyWith(isPlaying: true));

  @override
  Future<void> pause() async => _publish(_state.copyWith(isPlaying: false));

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    _publish(_state.copyWith(position: position));
  }

  @override
  Future<void> setVolume(double value) async {
    if (failNextVolumeWrite) {
      failNextVolumeWrite = false;
      throw StateError('fake volume failure');
    }
    _publish(_state.copyWith(volume: value));
  }

  @override
  Future<void> setRate(double value) async =>
      _publish(_state.copyWith(rate: value));

  @override
  Future<void> setShuffle(bool value) async {
    shuffleWrites.add(value);
    if (delayShuffleWrites) {
      final gate = Completer<void>();
      pendingShuffleWrites.add(gate);
      await gate.future;
    }
    _publish(_state.copyWith(shuffle: value));
  }

  @override
  Future<void> setRepeatMode(String value) async {
    repeatWrites.add(value);
    if (delayRepeatWrites) {
      final gate = Completer<void>();
      pendingRepeatWrites.add(gate);
      await gate.future;
    }
  }

  void completeNextShuffleWrite() =>
      pendingShuffleWrites.removeAt(0).complete();

  void completeNextRepeatWrite() => pendingRepeatWrites.removeAt(0).complete();

  @override
  Future<void> setAudioTrack(AudioTrack track) async =>
      _publish(_state.copyWith(currentAudioTrack: track));

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async =>
      _publish(_state.copyWith(currentSubtitleTrack: track));

  @override
  Future<void> loadSubtitle(String path) async {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    final gate = disposeGate;
    if (gate != null) await gate.future;
    disposed = true;
    await _events.close();
  }

  void emit({
    Duration? position,
    Duration? duration,
    bool? completed,
    double? volume,
    int? sourceStart,
    bool? isBuffering,
    String? error,
  }) {
    _publish(
      _state.copyWith(
        position: position,
        duration: duration,
        completed: completed,
        volume: volume,
        sourceStart: sourceStart ?? _sourceStart,
        isBuffering: isBuffering,
        error: error,
      ),
    );
  }

  /// Reports a source identity the player never requested.
  void emitForeignSource(String source, {Duration? position}) {
    _publish(
      _state.copyWith(
        nativeSource: source,
        sourceLoaded: true,
        position: position,
      ),
    );
  }

  void _publish(PlaybackSnapshot value) {
    _state = value;
    if (!_events.isClosed) _events.add(value);
  }
}

class _RetryingPlaybackSettingsService extends _FakePlaybackService
    implements PlaybackSettingsCapability {
  int applyCount = 0;

  @override
  Future<PlaybackSettingsApplyResult> applyPlaybackSettings(
    PlaybackSettings settings,
  ) async {
    applyCount++;
    if (applyCount == 1) {
      return const PlaybackSettingsApplyResult(
        supported: false,
        reason: 'Video output is not ready.',
      );
    }
    return const PlaybackSettingsApplyResult();
  }
}

class _GatedSeekPlaybackService extends _FakePlaybackService {
  final List<Completer<void>> pendingSeeks = <Completer<void>>[];
  bool delaySeeks = false;
  bool publishSeekCompletions = true;

  @override
  Future<void> seek(Duration position) {
    if (!delaySeeks) return super.seek(position);
    seekCalls.add(position);
    final pending = Completer<void>();
    pendingSeeks.add(pending);
    return pending.future.then((_) {
      if (publishSeekCompletions) {
        _publish(_state.copyWith(position: position));
      }
    });
  }

  void completeNextSeek() {
    pendingSeeks.removeAt(0).complete();
  }
}

class _FailingSeekPlaybackService extends _FakePlaybackService {
  bool failSeeks = false;

  @override
  Future<void> seek(Duration position) async {
    if (failSeeks) throw StateError('Simulated seek failure');
    await super.seek(position);
  }
}

class _GatedProgressSessionRepository extends SessionRepository {
  final Completer<void> writeStarted = Completer<void>();
  final Completer<void> releaseWrite = Completer<void>();
  SessionProgress? saved;

  @override
  Future<SessionLoadResult> loadDetailed() async => const SessionLoadResult();

  @override
  Future<SessionProgress?> loadProgress() async => null;

  @override
  Future<void> save(PlaybackSession session) async {}

  @override
  Future<void> saveScrubbed(PlaybackSession session) async {}

  @override
  Future<void> saveProgress(SessionProgress progress) {
    if (!writeStarted.isCompleted) {
      writeStarted.complete();
      return releaseWrite.future.then<void>((_) {
        saved = progress;
      });
    }
    saved = progress;
    return Future<void>.value();
  }
}

class _CoalescedProgressSessionRepository extends SessionRepository {
  final Completer<void> firstWrite = Completer<void>();
  final Completer<void> secondWrite = Completer<void>();
  final Completer<void> releaseFirst = Completer<void>();
  final List<SessionProgress> writes = <SessionProgress>[];

  @override
  Future<SessionLoadResult> loadDetailed() async => const SessionLoadResult();

  @override
  Future<SessionProgress?> loadProgress() async => null;

  @override
  Future<void> save(PlaybackSession session) async {}

  @override
  Future<void> saveScrubbed(PlaybackSession session) async {}

  @override
  Future<void> saveProgress(SessionProgress progress) async {
    writes.add(progress);
    if (writes.length == 1) {
      firstWrite.complete();
      await releaseFirst.future;
    } else if (!secondWrite.isCompleted) {
      secondWrite.complete();
    }
  }
}

class _RecordingProgressSessionRepository extends SessionRepository {
  _RecordingProgressSessionRepository({required super.directory});

  final List<SessionProgress> writes = <SessionProgress>[];

  @override
  Future<void> saveProgress(SessionProgress progress) async {
    writes.add(progress);
  }
}

class _FailingFlushSessionRepository extends SessionRepository {
  _FailingFlushSessionRepository({required super.directory});

  bool failFlush = false;

  @override
  Future<void> flush() async {
    if (failFlush) throw StateError('Simulated flush failure');
    await super.flush();
  }
}

class _FailingSessionRepository extends SessionRepository {
  _FailingSessionRepository({super.directory});

  bool failSaves = false;

  @override
  Future<void> save(PlaybackSession session) async {
    if (failSaves) {
      throw const SessionSaveException('Simulated session save failure');
    }
    return super.save(session);
  }

  @override
  Future<void> saveScrubbed(PlaybackSession session) async {
    if (failSaves) {
      throw const SessionSaveException('Simulated session save failure');
    }
    return super.saveScrubbed(session);
  }
}

class _DelayedStartupSessionRepository extends SessionRepository {
  _DelayedStartupSessionRepository(Directory directory, this.saved)
    : super(directory: directory);
  final PlaybackSession saved;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SessionLoadResult> loadDetailed() async {
    started.complete();
    await release.future;
    return SessionLoadResult(session: saved);
  }
}

class _DelayedVolumePlaybackService extends _FakePlaybackService {
  final List<double> volumeRequests = <double>[];
  final List<Completer<void>> pendingVolumeWrites = <Completer<void>>[];
  bool delayVolumeWrites = false;

  @override
  Future<void> setVolume(double value) {
    volumeRequests.add(value);
    if (!delayVolumeWrites) return super.setVolume(value);
    final pending = Completer<void>();
    pendingVolumeWrites.add(pending);
    return pending.future.then((_) {
      _publish(_state.copyWith(volume: value));
    });
  }

  void completeNextVolumeWrite() {
    pendingVolumeWrites.removeAt(0).complete();
  }
}
