import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_playback_service.dart';

void main() {
  Future<(PlayerController, FakePlaybackService, Directory)>
  createHarness() async {
    final dir = await Directory.systemTemp.createTemp('mpvson-ctrl-test-');
    final playback = FakePlaybackService();
    final sessions = SessionRepository(
      directory: dir,
      encoder: (session) => session.toJson().toString(),
    );
    final controller = PlayerController(playback: playback, sessions: sessions);
    await controller.initialize();
    return (controller, playback, dir);
  }

  group('PlayerController', () {
    test('opens paths, appends items, reorders, removes, and undoes', () async {
      final (controller, playback, dir) = await createHarness();
      addTearDown(() async {
        await controller.close(discard: true);
        controller.dispose();
        await playback.dispose();
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final one = File(p.join(dir.path, 'one.mp4'))..createSync();
      final two = File(p.join(dir.path, 'two.mp4'))..createSync();
      final three = File(p.join(dir.path, 'three.mp4'))..createSync();

      await controller.openPaths(<String>[one.path, two.path]);
      expect(controller.queue.length, 2);
      expect(controller.current?.title, 'one');
      expect(playback.openedPaths, <String>[one.path]);

      await controller.openPaths(<String>[three.path], append: true);
      expect(controller.queue.length, 3);

      await controller.reorder(0, 2);
      expect(controller.queue.map((e) => e.title).toList(), <String>[
        'two',
        'three',
        'one',
      ]);
      expect(controller.currentIndex, 2);

      await controller.removeAt(1);
      expect(controller.queue.map((e) => e.title).toList(), <String>[
        'two',
        'one',
      ]);
      expect(controller.canUndo, isTrue);

      await controller.undoRemove();
      expect(controller.queue.map((e) => e.title).toList(), <String>[
        'two',
        'three',
        'one',
      ]);
      expect(controller.canUndo, isFalse);
    });

    test('cycles repeat modes and toggles shuffle', () async {
      final (controller, playback, dir) = await createHarness();
      addTearDown(() async {
        await controller.close(discard: true);
        controller.dispose();
        await playback.dispose();
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      expect(controller.playerRepeatMode, PlayerRepeatMode.off);
      await controller.cycleRepeat();
      expect(controller.playerRepeatMode, PlayerRepeatMode.all);
      await controller.cycleRepeat();
      expect(controller.playerRepeatMode, PlayerRepeatMode.one);
      await controller.cycleRepeat();
      expect(controller.playerRepeatMode, PlayerRepeatMode.off);

      expect(controller.shuffle, isFalse);
      await controller.toggleShuffle();
      expect(controller.shuffle, isTrue);
    });

    test(
      'reordering an item to play next overrides stale forward navigation history',
      () async {
        final (controller, playback, dir) = await createHarness();
        addTearDown(() async {
          await controller.close(discard: true);
          controller.dispose();
          await playback.dispose();
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final one = File(p.join(dir.path, 'one.mp4'))..createSync();
        final two = File(p.join(dir.path, 'two.mp4'))..createSync();
        final three = File(p.join(dir.path, 'three.mp4'))..createSync();

        await controller.openPaths(<String>[one.path, two.path, three.path]);
        await controller.next();
        expect(controller.current?.title, 'two');
        await controller.previous();
        expect(controller.current?.title, 'one');

        // Drag `three` right below currently playing `one` so it plays next.
        await controller.reorder(2, 1);
        expect(controller.queue.map((e) => e.title).toList(), <String>[
          'one',
          'three',
          'two',
        ]);

        await controller.next();
        expect(controller.current?.title, 'three');
      },
    );

    test(
      'shuffle plays prioritized playNext and reordered-next items next',
      () async {
        final (controller, playback, dir) = await createHarness();
        addTearDown(() async {
          await controller.close(discard: true);
          controller.dispose();
          await playback.dispose();
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final one = File(p.join(dir.path, 'one.mp4'))..createSync();
        final two = File(p.join(dir.path, 'two.mp4'))..createSync();
        final three = File(p.join(dir.path, 'three.mp4'))..createSync();
        final four = File(p.join(dir.path, 'four.mp4'))..createSync();

        await controller.openPaths(<String>[one.path, two.path, three.path]);
        await controller.setShuffle(true);

        await controller.reorder(2, 1);
        await controller.next();
        expect(controller.current?.title, 'three');

        await controller.playNext(<String>[four.path]);
        await controller.next();
        expect(controller.current?.title, 'four');
      },
    );
  });
}
