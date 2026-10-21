import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/desktop_integration_service.dart';
import 'package:mpvson/data/services/desktop_integration_service_impl.dart';
import 'package:mpvson/data/services/open_request_coordinator.dart';
import 'package:mpvson/domain/models/open_request.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import '../../ui/player/support/player_test_fakes.dart';

class TestPlaybackService extends FakePlaybackService {
  VideoOutputPolicy _policy = const VideoOutputPolicy();

  @override
  VideoOutputPolicy get videoOutputPolicy => _policy;

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    _policy = policy;
  }
}

class FakeOpenRequestCoordinator extends OpenRequestCoordinator {
  FakeOpenRequestCoordinator({AppPreferencesRepository? preferences})
      : super(
          preferences: preferences ?? AppPreferencesRepository(),
          isPlaybackActive: () => false,
          executePlaybackCommand: ({required paths, required playNow}) async {},
          showPreferenceDialog: () async => null,
        );

  final List<OpenRequest> handledRequests = <OpenRequest>[];

  @override
  Future<bool> handleOpenRequest(OpenRequest request) async {
    handledRequests.add(request);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel singleInstanceChannel;
  late MethodChannel mediaControlsChannel;
  late MethodChannel powerChannel;

  late List<MethodCall> singleInstanceCalls;
  late List<MethodCall> mediaControlsCalls;
  late List<MethodCall> powerCalls;

  late Directory tempDir;
  late TestPlaybackService fakePlayback;
  late SessionRepository sessionRepo;
  late PlayerController controller;

  Future<void> sendIncoming(MethodChannel channel, MethodCall call) async {
    final completer = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(call),
      (ByteData? reply) {
        completer.complete();
      },
    );
    await completer.future;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('desktop_service_test_');
    singleInstanceChannel = const MethodChannel('mpvson/single_instance');
    mediaControlsChannel = const MethodChannel('mpvson/media_controls');
    powerChannel = const MethodChannel('mpvson/power');

    singleInstanceCalls = <MethodCall>[];
    mediaControlsCalls = <MethodCall>[];
    powerCalls = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(singleInstanceChannel, (MethodCall call) async {
      singleInstanceCalls.add(call);
      return true;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(mediaControlsChannel, (MethodCall call) async {
      mediaControlsCalls.add(call);
      if (call.method == 'openDefaultAppsSettings') {
        return true;
      }
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(powerChannel, (MethodCall call) async {
      powerCalls.add(call);
      return null;
    });

    fakePlayback = TestPlaybackService();
    sessionRepo = SessionRepository(directory: Directory('${tempDir.path}/sessions'));
    controller = PlayerController(
      playback: fakePlayback,
      sessions: sessionRepo,
    );
    await controller.initialize();
  });

  tearDown(() async {
    controller.dispose();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Ignore cleanup error on windows.
    }
  });

  group('Single instance channel (mpvson/single_instance)', () {
    test('receives secondary instance activation and invokes OpenRequestCoordinator', () async {
      final coordinator = FakeOpenRequestCoordinator();
      final service = DesktopIntegrationServiceImpl(
        openRequestCoordinator: coordinator,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      await sendIncoming(
        singleInstanceChannel,
        const MethodCall('activate', <dynamic>['C:\\video.mp4', '--flag', 'D:\\song.mp3']),
      );

      expect(coordinator.handledRequests, hasLength(1));
      final req = coordinator.handledRequests.first;
      expect(req.sources, equals(<String>['C:\\video.mp4', 'D:\\song.mp3']));
      expect(req.origin, equals(OpenOrigin.osActivation));
      expect(req.intent, equals(OpenIntent.normal));

      service.dispose();
    });

    test('parses intent from map arguments in activation', () async {
      final coordinator = FakeOpenRequestCoordinator();
      final service = DesktopIntegrationServiceImpl(
        openRequestCoordinator: coordinator,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      await sendIncoming(
        singleInstanceChannel,
        const MethodCall('activate', <String, Object?>{
          'paths': <String>['E:\\movie.mkv'],
          'intent': 'playNow',
        }),
      );

      expect(coordinator.handledRequests, hasLength(1));
      expect(coordinator.handledRequests.first.intent, equals(OpenIntent.playNow));

      service.dispose();
    });
  });

  group('Media controls channel (mpvson/media_controls)', () {
    test('publishes playback state and timeline updates', () async {
      final service = DesktopIntegrationServiceImpl(
        controller: controller,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      await service.updatePlaybackState(
        status: SystemPlaybackStatus.playing,
        position: const Duration(seconds: 15),
        duration: const Duration(minutes: 3),
        playbackRate: 1.5,
      );

      final stateCalls =
          mediaControlsCalls.where((c) => c.method == 'updatePlaybackState').toList();
      expect(stateCalls, isNotEmpty);
      final args = (stateCalls.last.arguments as Map).cast<String, Object?>();
      expect(args['status'], equals('playing'));
      expect(args['positionMs'], equals(15000));
      expect(args['durationMs'], equals(180000));
      expect(args['playbackRate'], equals(1.5));
      expect(service.playbackStatus, equals(SystemPlaybackStatus.playing));

      service.dispose();
    });

    test('publishes metadata updates', () async {
      final service = DesktopIntegrationServiceImpl(
        controller: controller,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      const meta = MediaMetadata(
        title: 'Song Title',
        artist: 'Artist Name',
        album: 'Album Name',
        artworkUri: 'C:\\artwork.png',
        duration: Duration(minutes: 4),
      );
      await service.updateMetadata(meta);

      final metaCalls =
          mediaControlsCalls.where((c) => c.method == 'updateMetadata').toList();
      expect(metaCalls, isNotEmpty);
      final args = (metaCalls.last.arguments as Map).cast<String, Object?>();
      expect(args['title'], equals('Song Title'));
      expect(args['artist'], equals('Artist Name'));
      expect(args['album'], equals('Album Name'));
      expect(args['artworkPath'], equals('C:\\artwork.png'));
      expect(args['durationMs'], equals(240000));
      expect(service.currentMetadata.title, equals('Song Title'));

      service.dispose();
    });

    test('forwards media key commands (play, pause, toggle, next, prev) to PlayerController', () async {
      final testFile1 = File('${tempDir.path}/test1.mp4')..writeAsStringSync('a');
      final testFile2 = File('${tempDir.path}/test2.mp4')..writeAsStringSync('b');

      final service = DesktopIntegrationServiceImpl(
        controller: controller,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      await controller.openPaths(<String>[testFile1.path, testFile2.path]);
      expect(controller.queue, hasLength(2));
      expect(controller.currentIndex, equals(0));

      // Media key: next
      await sendIncoming(mediaControlsChannel, const MethodCall('next'));
      expect(controller.currentIndex, equals(1));

      // Media key: prev
      await sendIncoming(mediaControlsChannel, const MethodCall('prev'));
      expect(controller.currentIndex, equals(0));

      // Media key: pause
      expect(controller.isPlaying, isTrue);
      await sendIncoming(mediaControlsChannel, const MethodCall('pause'));
      expect(controller.isPlaying, isFalse);

      // Media key: play
      await sendIncoming(mediaControlsChannel, const MethodCall('play'));
      expect(controller.isPlaying, isTrue);

      // Media key: toggle
      await sendIncoming(mediaControlsChannel, const MethodCall('toggle'));
      expect(controller.isPlaying, isFalse);

      service.dispose();
    });

    test('forwards valid seek command and rejects stale position command for previous track', () async {
      final testFile1 = File('${tempDir.path}/track1.mp4')..writeAsStringSync('a');
      final testFile2 = File('${tempDir.path}/track2.mp4')..writeAsStringSync('b');

      final service = DesktopIntegrationServiceImpl(
        controller: controller,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      await controller.openPaths(<String>[testFile1.path, testFile2.path]);
      final track1Id = controller.current!.id;

      // Move to track 2
      await controller.next();
      final track2Id = controller.current!.id;
      expect(track1Id, isNot(equals(track2Id)));

      // 1. Send stale seek command specifying track 1 id -> should be REJECTED
      fakePlayback.seekWrites.clear();
      await sendIncoming(
        mediaControlsChannel,
        MethodCall('seek', <String, Object?>{
          'positionMs': 45000,
          'entryId': track1Id,
        }),
      );
      expect(fakePlayback.seekWrites, isEmpty);

      // 2. Send valid seek command for current track (track 2) -> should be ACCEPTED
      await sendIncoming(
        mediaControlsChannel,
        MethodCall('seek', <String, Object?>{
          'positionMs': 30000,
          'entryId': track2Id,
        }),
      );
      expect(fakePlayback.seekWrites, contains(const Duration(seconds: 30)));

      // 3. Send stale seek command with mismatched duration (>2s discrepancy) -> REJECTED
      fakePlayback.seekWrites.clear();
      await sendIncoming(
        mediaControlsChannel,
        MethodCall('seek', <String, Object?>{
          'positionMs': 15000,
          'durationMs': 600000, // 10 minutes, but track is 2 minutes in fakePlayback
        }),
      );
      expect(fakePlayback.seekWrites, isEmpty);

      service.dispose();
    });
  });

  group('Power assertion and wake lock channel (mpvson/power)', () {
    test('inhibits display idle for visible video and releases on pause, stop, exit, or disabled preference', () async {
      final videoFile = File('${tempDir.path}/video.mp4')..writeAsStringSync('v');
      final prefFile = File('${tempDir.path}/prefs.json');
      final preferences = AppPreferencesRepository(preferenceFile: prefFile);
      await preferences.load();

      final service = DesktopIntegrationServiceImpl(
        controller: controller,
        preferences: preferences,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      // Open and play video
      await controller.openPaths(<String>[videoFile.path]);
      expect(controller.isPlaying, isTrue);

      final powerSetCalls = powerCalls.where((c) => c.method == 'setKeepAwake').toList();
      expect(powerSetCalls, isNotEmpty);
      final lastPowerArgs = (powerSetCalls.last.arguments as Map).cast<String, Object?>();
      expect(lastPowerArgs['enable'], isTrue);
      expect(lastPowerArgs['isVideoPlaying'], isTrue);
      expect(service.isAwakeInhibited, isTrue);

      // Pause playback -> power lock must release
      await controller.togglePlayPause();
      expect(controller.isPlaying, isFalse);
      expect(service.isAwakeInhibited, isFalse);
      final pausePowerArgs = (powerCalls.last.arguments as Map).cast<String, Object?>();
      expect(pausePowerArgs['enable'], isFalse);

      // Resume playback -> power lock re-engages
      await controller.togglePlayPause();
      expect(controller.isPlaying, isTrue);
      expect(service.isAwakeInhibited, isTrue);

      // Disable preference -> power lock must release immediately
      await preferences.updatePreferences(
        preferences.preferences.copyWith(keepAwakeDuringPlayback: false),
      );
      expect(service.isAwakeInhibited, isFalse);
      final disabledPrefPowerArgs = (powerCalls.last.arguments as Map).cast<String, Object?>();
      expect(disabledPrefPowerArgs['enable'], isFalse);

      service.dispose();
      expect(service.isAwakeInhibited, isFalse);
    });

    test('audio allows display sleep while visible video inhibits display idle', () async {
      final audioFile = File('${tempDir.path}/audio.mp3')..writeAsStringSync('a');
      final videoFile = File('${tempDir.path}/video.mkv')..writeAsStringSync('v');

      final service = DesktopIntegrationServiceImpl(
        controller: controller,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      // Play audio -> isVideoPlaying should be false (allows display sleep)
      await controller.openPaths(<String>[audioFile.path]);
      expect(controller.isPlaying, isTrue);
      var args = (powerCalls.last.arguments as Map).cast<String, Object?>();
      expect(args['enable'], isTrue);
      expect(args['isVideoPlaying'], isFalse);

      // Play video -> isVideoPlaying should be true (inhibits display idle)
      await controller.openPaths(<String>[videoFile.path]);
      expect(controller.isPlaying, isTrue);
      args = (powerCalls.last.arguments as Map).cast<String, Object?>();
      expect(args['enable'], isTrue);
      expect(args['isVideoPlaying'], isTrue);

      // Hidden video policy (video minimized) -> allows display sleep
      controller.applyVideoOutputPolicy(const VideoOutputPolicy(visible: false));
      service.sync();
      args = (powerCalls.last.arguments as Map).cast<String, Object?>();
      expect(args['isVideoPlaying'], isFalse);

      service.dispose();
    });
  });

  group('Default apps settings', () {
    test('openDefaultAppsSettings invokes platform channel or url launcher', () async {
      var launchedUrl = false;
      final service = DesktopIntegrationServiceImpl(
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
        urlLauncher: (Uri uri) async {
          if (uri.toString() == 'ms-settings:defaultapps') {
            launchedUrl = true;
            return true;
          }
          return false;
        },
      );
      await service.initialize();

      await service.openDefaultAppsSettings();

      final channelCalls =
          mediaControlsCalls.where((c) => c.method == 'openDefaultAppsSettings').toList();
      expect(channelCalls, isNotEmpty);
      expect(launchedUrl, isFalse);

      service.dispose();
    });
  });

  group('Bridge to PlayerController auto-sync', () {
    test('auto-syncs status, metadata, capabilities and wake locks as controller state changes', () async {
      final testFile = File('${tempDir.path}/Artist Name - My Song.mp3')
        ..writeAsStringSync('c');

      final service = DesktopIntegrationServiceImpl(
        controller: controller,
        singleInstanceChannel: singleInstanceChannel,
        mediaControlsChannel: mediaControlsChannel,
        powerChannel: powerChannel,
      );
      await service.initialize();

      await controller.openPaths(<String>[testFile.path]);

      expect(service.playbackStatus, equals(SystemPlaybackStatus.playing));
      expect(service.currentMetadata.title, equals('My Song'));
      expect(service.currentMetadata.artist, equals('Artist Name'));

      // Capabilities should be synced
      final capCalls =
          mediaControlsCalls.where((c) => c.method == 'updateCapabilities').toList();
      expect(capCalls, isNotEmpty);

      // Close controller -> status updates to closed and lock released
      await controller.close();
      service.sync();
      expect(service.playbackStatus, equals(SystemPlaybackStatus.closed));
      expect(service.isAwakeInhibited, isFalse);

      service.dispose();
    });
  });
}
