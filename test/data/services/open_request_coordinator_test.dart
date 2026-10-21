import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/open_request_coordinator.dart';
import 'package:mpvson/domain/models/open_request.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:path/path.dart' as p;

import '../../ui/player/support/player_test_fakes.dart';

void main() {
  late Directory tempDir;
  late File prefFile;
  late AppPreferencesRepository preferences;
  late File sampleFile1;
  late File sampleFile2;
  late File sampleFile3;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('coordinator-test-');
    prefFile = File(p.join(tempDir.path, 'test_preferences.json'));
    preferences = AppPreferencesRepository(preferenceFile: prefFile);
    await preferences.load();

    sampleFile1 = File(p.join(tempDir.path, 'video1.mp4'));
    await sampleFile1.writeAsString('video1');
    sampleFile2 = File(p.join(tempDir.path, 'video2.mp4'));
    await sampleFile2.writeAsString('video2');
    sampleFile3 = File(p.join(tempDir.path, 'video3.mp4'));
    await sampleFile3.writeAsString('video3');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('OpenRequestCoordinator Unit Tests', () {
    test('1. First conflict prompts dialog when active/paused and no preference set', () async {
      var isPlaybackActive = true;
      var dialogPromptCount = 0;
      final executedCommands = <({List<String> paths, bool playNow})>[];

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => isPlaybackActive,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogPromptCount++;
          return OpenBehaviorPreference.playNewFilesNow;
        },
      );

      // Active playback with no preference set prompts dialog
      final result1 = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path]),
      );
      expect(result1, isTrue);
      expect(dialogPromptCount, 1);
      expect(executedCommands.length, 1);
      expect(executedCommands.first.playNow, isTrue);

      // Reset preference to test paused state
      await preferences.updatePreferences(const DesktopPreferences());
      isPlaybackActive = true; // Represents paused state where media is active in player

      final result2 = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req2', sources: [sampleFile2.path]),
      );
      expect(result2, isTrue);
      expect(dialogPromptCount, 2);
    });

    test('2. "Keep playing and add to queue" appends items, preserves playing or paused state', () async {
      final executedCommands = <({List<String> paths, bool playNow})>[];
      var dialogCount = 0;

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => true,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogCount++;
          return OpenBehaviorPreference.keepPlayingAndEnqueue;
        },
      );

      final success = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path, sampleFile2.path]),
      );

      expect(success, isTrue);
      expect(dialogCount, 1);
      expect(executedCommands.length, 1);
      // playNow: false indicates appending to queue preserving playing/paused state
      expect(executedCommands.first.playNow, isFalse);
      expect(executedCommands.first.paths, [sampleFile1.path, sampleFile2.path]);
    });

    test('3. "Play new files now" replaces queue and starts playback', () async {
      final executedCommands = <({List<String> paths, bool playNow})>[];
      var dialogCount = 0;

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => true,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogCount++;
          return OpenBehaviorPreference.playNewFilesNow;
        },
      );

      final success = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path]),
      );

      expect(success, isTrue);
      expect(dialogCount, 1);
      expect(executedCommands.length, 1);
      // playNow: true indicates queue replacement and immediate playback
      expect(executedCommands.first.playNow, isTrue);
      expect(executedCommands.first.paths, [sampleFile1.path]);
    });

    test('4. Preference persistence: when chosen, subsequent requests do not prompt dialog and follow preference', () async {
      final executedCommands = <({List<String> paths, bool playNow})>[];
      var dialogCount = 0;

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => true,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogCount++;
          return OpenBehaviorPreference.keepPlayingAndEnqueue;
        },
      );

      // First request: prompts dialog and user selects keepPlayingAndEnqueue
      final req1 = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path]),
      );
      expect(req1, isTrue);
      expect(dialogCount, 1);
      expect(executedCommands.last.playNow, isFalse);
      expect(preferences.preferences.openBehavior, OpenBehaviorPreference.keepPlayingAndEnqueue);

      // Second request: uses persisted preference, does NOT prompt dialog
      final req2 = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req2', sources: [sampleFile2.path]),
      );
      expect(req2, isTrue);
      expect(dialogCount, 1, reason: 'Dialog must not be prompted again');
      expect(executedCommands.last.playNow, isFalse);

      // Third request: verify persistence survives re-loading preferences from disk
      final reloadedPreferences = AppPreferencesRepository(preferenceFile: prefFile);
      await reloadedPreferences.load();
      expect(reloadedPreferences.preferences.openBehavior, OpenBehaviorPreference.keepPlayingAndEnqueue);

      final coordinator2 = OpenRequestCoordinator(
        preferences: reloadedPreferences,
        isPlaybackActive: () => true,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogCount++;
          return OpenBehaviorPreference.playNewFilesNow;
        },
      );

      final req3 = await coordinator2.handleOpenRequest(
        OpenRequest(id: 'req3', sources: [sampleFile3.path]),
      );
      expect(req3, isTrue);
      expect(dialogCount, 1, reason: 'Reloaded preference avoids prompting dialog');
      expect(executedCommands.last.playNow, isFalse);
    });

    test('5. Dialog cancellation: dismissing dialog cancels open request without changing playback or saving preference', () async {
      final executedCommands = <({List<String> paths, bool playNow})>[];
      var dialogCount = 0;

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => true,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogCount++;
          return null; // User dismissed / cancelled dialog
        },
      );

      final success = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path]),
      );

      expect(success, isFalse, reason: 'Cancelled request should return false');
      expect(dialogCount, 1);
      expect(executedCommands, isEmpty, reason: 'Playback command should not be executed');
      expect(preferences.preferences.openBehavior, isNull, reason: 'Preference must not be modified');
    });

    test('6. Explicit intent: OpenIntent.playNow and OpenIntent.enqueue bypass saved preferences without prompting', () async {
      final executedCommands = <({List<String> paths, bool playNow})>[];
      var dialogCount = 0;

      // Persist keepPlayingAndEnqueue
      await preferences.setOpenBehavior(OpenBehaviorPreference.keepPlayingAndEnqueue);

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => true,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogCount++;
          return OpenBehaviorPreference.keepPlayingAndEnqueue;
        },
      );

      // Explicit playNow overrides saved keepPlayingAndEnqueue
      final playNowResult = await coordinator.handleOpenRequest(
        OpenRequest(
          id: 'req1',
          sources: [sampleFile1.path],
          intent: OpenIntent.playNow,
        ),
      );
      expect(playNowResult, isTrue);
      expect(dialogCount, 0);
      expect(executedCommands.last.playNow, isTrue);

      // Change persisted preference to playNewFilesNow
      await preferences.setOpenBehavior(OpenBehaviorPreference.playNewFilesNow);

      // Explicit enqueue overrides saved playNewFilesNow
      final enqueueResult = await coordinator.handleOpenRequest(
        OpenRequest(
          id: 'req2',
          sources: [sampleFile2.path],
          intent: OpenIntent.enqueue,
        ),
      );
      expect(enqueueResult, isTrue);
      expect(dialogCount, 0);
      expect(executedCommands.last.playNow, isFalse);

      // Also verify explicit intent works when no preference is set without prompting dialog
      await preferences.updatePreferences(const DesktopPreferences());
      final unconfiguredResult = await coordinator.handleOpenRequest(
        OpenRequest(
          id: 'req3',
          sources: [sampleFile3.path],
          intent: OpenIntent.playNow,
        ),
      );
      expect(unconfiguredResult, isTrue);
      expect(dialogCount, 0);
      expect(executedCommands.last.playNow, isTrue);
    });

    test('7. Concurrent requests: serialized in order without opening overlapping dialogs', () async {
      final executedCommands = <({List<String> paths, bool playNow})>[];
      var activeDialogs = 0;
      var maxOverlappingDialogs = 0;
      var dialogPromptCount = 0;
      final dialogCompleter = Completer<OpenBehaviorPreference?>();

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => true,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogPromptCount++;
          activeDialogs++;
          if (activeDialogs > maxOverlappingDialogs) {
            maxOverlappingDialogs = activeDialogs;
          }
          final res = await dialogCompleter.future;
          activeDialogs--;
          return res;
        },
      );

      // Fire 3 requests concurrently
      final future1 = coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path]),
      );
      final future2 = coordinator.handleOpenRequest(
        OpenRequest(id: 'req2', sources: [sampleFile2.path]),
      );
      final future3 = coordinator.handleOpenRequest(
        OpenRequest(id: 'req3', sources: [sampleFile3.path]),
      );

      // Verify only 1 dialog is opened while all 3 are queued
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(dialogPromptCount, 1);
      expect(maxOverlappingDialogs, 1);

      // Complete the dialog with playNewFilesNow
      dialogCompleter.complete(OpenBehaviorPreference.playNewFilesNow);

      final results = await Future.wait([future1, future2, future3]);

      expect(results, [true, true, true]);
      expect(maxOverlappingDialogs, 1, reason: 'Dialogs must never overlap');
      expect(dialogPromptCount, 1, reason: 'Dialog should only prompt for first conflict');
      expect(executedCommands.length, 3);
      expect(executedCommands[0].paths, [sampleFile1.path]);
      expect(executedCommands[1].paths, [sampleFile2.path]);
      expect(executedCommands[2].paths, [sampleFile3.path]);
      for (final cmd in executedCommands) {
        expect(cmd.playNow, isTrue);
      }
    });

    test('8. Empty or inactive player opens selection directly without prompting', () async {
      final executedCommands = <({List<String> paths, bool playNow})>[];
      var dialogCount = 0;

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => false, // Inactive / empty player
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async {
          dialogCount++;
          return OpenBehaviorPreference.keepPlayingAndEnqueue;
        },
      );

      final success = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path]),
      );

      expect(success, isTrue);
      expect(dialogCount, 0, reason: 'Inactive player must not prompt dialog');
      expect(executedCommands.length, 1);
      expect(executedCommands.first.playNow, isTrue);
      expect(executedCommands.first.paths, [sampleFile1.path]);
    });

    test('filters out invalid or non-existent files', () async {
      final executedCommands = <({List<String> paths, bool playNow})>[];

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => false,
        executePlaybackCommand: ({required paths, required playNow}) async {
          executedCommands.add((paths: paths, playNow: playNow));
        },
        showPreferenceDialog: () async => OpenBehaviorPreference.playNewFilesNow,
      );

      // Non-existent path alongside valid file and web URL
      final success = await coordinator.handleOpenRequest(
        OpenRequest(
          id: 'req1',
          sources: [
            sampleFile1.path,
            p.join(tempDir.path, 'does_not_exist.mp4'),
            '  https://example.com/stream.m3u8  ',
            '   ',
          ],
        ),
      );

      expect(success, isTrue);
      expect(executedCommands.length, 1);
      expect(executedCommands.first.paths, [
        sampleFile1.path,
        'https://example.com/stream.m3u8',
      ]);

      // Request with entirely non-existent files fails and does not execute playback
      final failure = await coordinator.handleOpenRequest(
        OpenRequest(
          id: 'req2',
          sources: [p.join(tempDir.path, 'ghost.mp4')],
        ),
      );
      expect(failure, isFalse);
      expect(executedCommands.length, 1);
    });

    test('askEveryTime preference prompts dialog each time without saving preference', () async {
      await preferences.setOpenBehavior(OpenBehaviorPreference.askEveryTime);
      var dialogCount = 0;

      final coordinator = OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => true,
        executePlaybackCommand: ({required paths, required playNow}) async {},
        showPreferenceDialog: () async {
          dialogCount++;
          return OpenBehaviorPreference.playNewFilesNow;
        },
      );

      await coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path]),
      );
      expect(dialogCount, 1);
      expect(preferences.preferences.openBehavior, OpenBehaviorPreference.askEveryTime);

      await coordinator.handleOpenRequest(
        OpenRequest(id: 'req2', sources: [sampleFile2.path]),
      );
      expect(dialogCount, 2);
      expect(preferences.preferences.openBehavior, OpenBehaviorPreference.askEveryTime);
    });
  });

  group('OpenRequestCoordinator & PlayerController Integration Tests', () {
    late SessionRepository sessions;
    late FakePlaybackService playback;
    late PlayerController controller;

    setUp(() async {
      sessions = SessionRepository(
        directory: Directory(p.join(tempDir.path, 'sessions')),
      );
      playback = FakePlaybackService();
      controller = PlayerController(playback: playback, sessions: sessions);
      await controller.initialize();
    });

    tearDown(() async {
      await controller.close();
    });

    OpenRequestCoordinator createIntegratedCoordinator({
      required Future<OpenBehaviorPreference?> Function() onPrompt,
    }) {
      return OpenRequestCoordinator(
        preferences: preferences,
        isPlaybackActive: () => controller.current != null,
        executePlaybackCommand: ({required paths, required playNow}) async {
          await controller.openPaths(paths, append: !playNow);
        },
        showPreferenceDialog: onPrompt,
      );
    }

    test('inactive/empty player loads and starts playback directly', () async {
      var dialogCalled = false;
      final coordinator = createIntegratedCoordinator(
        onPrompt: () async {
          dialogCalled = true;
          return OpenBehaviorPreference.playNewFilesNow;
        },
      );

      expect(controller.current, isNull);
      final ok = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req1', sources: [sampleFile1.path]),
      );

      expect(ok, isTrue);
      expect(dialogCalled, isFalse);
      expect(controller.queue.length, 1);
      expect(controller.current?.path, sampleFile1.path);
      expect(controller.isPlaying, isTrue);
    });

    test('active playing player: "Keep playing and add to queue" appends and preserves playing state', () async {
      // Start initial playback
      await controller.openPaths([sampleFile1.path]);
      expect(controller.isPlaying, isTrue);
      expect(controller.currentIndex, 0);
      expect(controller.current?.path, sampleFile1.path);

      var dialogCalled = false;
      final coordinator = createIntegratedCoordinator(
        onPrompt: () async {
          dialogCalled = true;
          return OpenBehaviorPreference.keepPlayingAndEnqueue;
        },
      );

      final ok = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req2', sources: [sampleFile2.path]),
      );

      expect(ok, isTrue);
      expect(dialogCalled, isTrue);
      // Item was appended
      expect(controller.queue.length, 2);
      expect(controller.queue[0].path, sampleFile1.path);
      expect(controller.queue[1].path, sampleFile2.path);
      // Still on track 1, still playing
      expect(controller.currentIndex, 0);
      expect(controller.current?.path, sampleFile1.path);
      expect(controller.isPlaying, isTrue);
    });

    test('active paused player: "Keep playing and add to queue" appends and preserves paused state', () async {
      // Start initial playback, then pause
      await controller.openPaths([sampleFile1.path]);
      await controller.togglePlayPause();
      expect(controller.isPlaying, isFalse);
      expect(controller.currentIndex, 0);

      var dialogCalled = false;
      final coordinator = createIntegratedCoordinator(
        onPrompt: () async {
          dialogCalled = true;
          return OpenBehaviorPreference.keepPlayingAndEnqueue;
        },
      );

      final ok = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req2', sources: [sampleFile2.path]),
      );

      expect(ok, isTrue);
      expect(dialogCalled, isTrue);
      expect(controller.queue.length, 2);
      expect(controller.queue[0].path, sampleFile1.path);
      expect(controller.queue[1].path, sampleFile2.path);
      // Still on track 1, still paused
      expect(controller.currentIndex, 0);
      expect(controller.current?.path, sampleFile1.path);
      expect(controller.isPlaying, isFalse);
    });

    test('active player: "Play new files now" replaces queue and starts playback', () async {
      await controller.openPaths([sampleFile1.path]);
      expect(controller.queue.length, 1);
      expect(controller.current?.path, sampleFile1.path);

      var dialogCalled = false;
      final coordinator = createIntegratedCoordinator(
        onPrompt: () async {
          dialogCalled = true;
          return OpenBehaviorPreference.playNewFilesNow;
        },
      );

      final ok = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req2', sources: [sampleFile2.path]),
      );

      expect(ok, isTrue);
      expect(dialogCalled, isTrue);
      // Queue was replaced with new file
      expect(controller.queue.length, 1);
      expect(controller.current?.path, sampleFile2.path);
      expect(controller.isPlaying, isTrue);
    });

    test('active player: cancelling dialog leaves playback and queue untouched', () async {
      await controller.openPaths([sampleFile1.path]);
      expect(controller.queue.length, 1);
      expect(controller.current?.path, sampleFile1.path);
      expect(controller.isPlaying, isTrue);

      final coordinator = createIntegratedCoordinator(
        onPrompt: () async => null, // Dismissed dialog
      );

      final ok = await coordinator.handleOpenRequest(
        OpenRequest(id: 'req2', sources: [sampleFile2.path]),
      );

      expect(ok, isFalse);
      expect(controller.queue.length, 1);
      expect(controller.current?.path, sampleFile1.path);
      expect(controller.isPlaying, isTrue);
      expect(preferences.preferences.openBehavior, isNull);
    });
  });
}
