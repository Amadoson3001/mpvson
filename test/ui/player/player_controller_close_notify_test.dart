import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import '../../support/app_harness.dart';

/// Engine stand-in whose stop always fails, reproducing an engine that was
/// released underneath a still-draining command.
class _FailingStopPlayback extends FakePlaybackService {
  int stopCalls = 0;

  @override
  Future<void> stop() async {
    stopCalls++;
    throw StateError('engine released');
  }
}

/// Creates one real media file so the controller's existence check passes.
Future<File> makeMediaFile() async {
  final dir = await Directory.systemTemp.createTemp('mpvson_close_notify_');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}${Platform.pathSeparator}song.mp3')..createSync();
}

void main() {
  test(
    'stop() survives a failing engine stop and keeps reporting state while open',
    () async {
      final playback = _FailingStopPlayback();
      final controller = PlayerController(
        playback: playback,
        sessions: SessionRepository(),
      );
      addTearDown(controller.dispose);

      final file = await makeMediaFile();
      await controller.openPaths([file.path]);
      // Let the fake engine's async snapshot adoption settle.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.current, isNotNull);

      var notifications = 0;
      controller.addListener(() => notifications++);
      final stopsBeforeStop = playback.stopCalls;

      // The engine failure must not escape stop() as an unhandled error.
      await controller.stop();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(playback.stopCalls, greaterThan(stopsBeforeStop));
      expect(notifications, greaterThan(0));
    },
  );

  test('recent-history mutations after close never notify listeners', () async {
    final controller = PlayerController(
      playback: FakePlaybackService(),
      sessions: SessionRepository(),
    );
    addTearDown(controller.dispose);

    final file = await makeMediaFile();
    await controller.openPaths([file.path]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.recent, isNotEmpty);
    final recentId = controller.recent.first.id;

    await controller.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    var notifications = 0;
    controller.addListener(() => notifications++);
    expect(controller.removeRecentById(recentId), isNull);
    expect(controller.clearRecent(), isEmpty);
    expect(notifications, 0);
  });
}
