import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/app_preferences_repository.dart';
import 'package:mpvson/data/services/desktop_integration_service_impl.dart';
import 'package:mpvson/data/services/open_request_coordinator.dart';

MethodChannel _controlsChannel() =>
    const MethodChannel('mpvson/media_controls');
MethodChannel _powerChannel() => const MethodChannel('mpvson/power');

/// Dispatches an incoming platform message to the handler the service
/// registered, returning the handler's reply (or its error).
Future<Object?> _dispatch(MethodChannel channel, MethodCall call) async {
  final reply = Completer<Object?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(call),
        (data) {
          if (data == null) {
            reply.complete(null);
            return;
          }
          try {
            reply.complete(channel.codec.decodeEnvelope(data));
          } on Object catch (error) {
            reply.completeError(error);
          }
        },
      );
  return reply.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('media controls commands', () {
    test('raise invokes the injected raise handler', () async {
      var raised = 0;
      final service = DesktopIntegrationServiceImpl(
        mediaControlsChannel: _controlsChannel(),
        powerChannel: _powerChannel(),
        onRaiseWindow: () async => raised++,
      );
      await service.initialize();

      final reply = await _dispatch(
        _controlsChannel(),
        const MethodCall('raise'),
      );

      expect(reply, isTrue);
      expect(raised, 1);
      service.dispose();
    });

    test('quit invokes the injected quit handler', () async {
      var quitCalls = 0;
      final service = DesktopIntegrationServiceImpl(
        mediaControlsChannel: _controlsChannel(),
        powerChannel: _powerChannel(),
        onQuitApplication: () async => quitCalls++,
      );
      await service.initialize();

      final reply = await _dispatch(
        _controlsChannel(),
        const MethodCall('quit'),
      );

      expect(reply, isTrue);
      expect(quitCalls, 1);
      service.dispose();
    });

    test('openUri routes through the open request coordinator', () async {
      final played = <({List<String> paths, bool playNow})>[];
      final coordinator = OpenRequestCoordinator(
        preferences: AppPreferencesRepository(),
        isPlaybackActive: () => false,
        executePlaybackCommand:
            ({required List<String> paths, required bool playNow}) async {
              played.add((paths: paths, playNow: playNow));
            },
        showPreferenceDialog: () async => null,
      );
      final service = DesktopIntegrationServiceImpl(
        mediaControlsChannel: _controlsChannel(),
        powerChannel: _powerChannel(),
        openRequestCoordinator: coordinator,
      );
      await service.initialize();

      final reply = await _dispatch(
        _controlsChannel(),
        const MethodCall('openUri', <String, String>{
          'uri': 'https://example.com/stream.m3u8',
        }),
      );

      expect(reply, isTrue);
      expect(played, hasLength(1));
      expect(played.single.paths, <String>['https://example.com/stream.m3u8']);
      expect(played.single.playNow, isTrue);
      service.dispose();
    });

    test('openUri rejects unparseable and unsupported URIs', () async {
      final service = DesktopIntegrationServiceImpl(
        mediaControlsChannel: _controlsChannel(),
        powerChannel: _powerChannel(),
      );
      await service.initialize();

      final unparseable = await _dispatch(
        _controlsChannel(),
        const MethodCall('openUri', <String, String>{'uri': 'http://[::1'}),
      );
      expect(unparseable, isFalse);

      final unsupported = await _dispatch(
        _controlsChannel(),
        const MethodCall('openUri', <String, String>{'uri': 'mailto:x@y.z'}),
      );
      expect(unsupported, isFalse);

      final empty = await _dispatch(
        _controlsChannel(),
        const MethodCall('openUri', <String, String>{'uri': '   '}),
      );
      expect(empty, isFalse);
      service.dispose();
    });

    test(
      'unknown command follows the unimplemented-reply convention',
      () async {
        final service = DesktopIntegrationServiceImpl(
          mediaControlsChannel: _controlsChannel(),
          powerChannel: _powerChannel(),
        );
        await service.initialize();

        // The handler throws MissingPluginException; the channel wrapper turns
        // that into an empty reply, matching the native "not implemented"
        // convention (implemented commands reply with `true`).
        final reply = await _dispatch(
          _controlsChannel(),
          const MethodCall('timeTravel'),
        );
        expect(reply, isNull);
        service.dispose();
      },
    );
  });

  group('dispose keep-awake safety', () {
    test('a failing async keep-awake release cannot crash disposal', () async {
      final power = _powerChannel();
      final service = DesktopIntegrationServiceImpl(
        mediaControlsChannel: _controlsChannel(),
        powerChannel: power,
      );
      await service.initialize();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(power, (call) async {
            if (call.method == 'setKeepAwake' &&
                call.arguments['enable'] == false) {
              // Simulate the platform channel dying between calls.
              await Future<void>.delayed(Duration.zero);
              throw StateError('channel gone');
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(power, null);
      });

      await service.setKeepAwake(true, isVideoPlaying: true);
      expect(service.isAwakeInhibited, isTrue);

      // Must complete synchronously; the late async channel error is swallowed
      // by the unawaited(...catchError(...)) wrapper. Any unhandled error
      // would fail this test.
      service.dispose();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });
  });
}
