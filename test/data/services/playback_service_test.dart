import 'dart:async';

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
  Future<void> stop({bool open = false, bool notify = true}) async {
    stops++;
  }
}

/// Engine stand-in whose [open] only completes when the test releases its gate,
/// reproducing the slow native open that rapid next/previous used to race.
class _GatedEnginePlayer extends PlatformPlayer {
  _GatedEnginePlayer() : super(configuration: const PlayerConfiguration());

  /// Sources the engine was actually told to load, in dispatch order.
  final List<String> opened = <String>[];
  final List<Completer<void>> gates = <Completer<void>>[];

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
  }

  @override
  Future<void> stop({bool open = false, bool notify = true}) async {}
}

/// Runs pending microtasks so queued opens make progress.
Future<void> drain() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
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

  group('serialized engine opens and cancellation', () {
    test(
      'rapid opens while an open is in flight drop superseded requests and the last request wins',
      () async {
        final engine = _GatedEnginePlayer();
        final service = MediaKitPlaybackService(
          player: Player(platformPlayer: engine),
        );
        addTearDown(service.dispose);

        final first = service.open('C:/Media/track_0.mp3');
        await drain();
        expect(engine.opened, <String>['C:/Media/track_0.mp3']);

        // Ten rapid next/previous requests while the first open is stuck on the
        // slow native engine open.
        final requests = <Future<void>>[
          first,
          for (var i = 1; i <= 10; i++) service.open('C:/Media/track_$i.mp3'),
        ];

        // Release the in-flight engine open; the queued requests now drain.
        var guard = 0;
        while (engine.gates.any((gate) => !gate.isCompleted) && guard < 50) {
          guard++;
          for (final gate in List.of(engine.gates)) {
            if (!gate.isCompleted) gate.complete();
          }
          await drain();
        }

        // No request may hang: the queue completes every caller promptly, so no
        // long spinner can stay up after the final track was requested.
        await Future.wait(requests).timeout(const Duration(seconds: 5));

        // Only the open that was already in flight and the newest request
        // reached the engine; the stale ones were dropped instead of racing the
        // final load onto the engine after it.
        expect(engine.opened, <String>[
          'C:/Media/track_0.mp3',
          'C:/Media/track_10.mp3',
        ]);
        expect(service.state.sourceStart, service.requestedBoundary);
        expect(service.state.isBuffering, isFalse);
      },
    );

    test(
      'a burst of opens before the queue drains only opens the newest request',
      () async {
        final engine = _GatedEnginePlayer();
        final service = MediaKitPlaybackService(
          player: Player(platformPlayer: engine),
        );
        addTearDown(service.dispose);

        final requests = <Future<void>>[
          for (var i = 0; i < 10; i++) service.open('C:/Media/track_$i.mp3'),
        ];
        await drain();
        for (final gate in List.of(engine.gates)) {
          if (!gate.isCompleted) gate.complete();
        }
        await Future.wait(requests).timeout(const Duration(seconds: 5));

        expect(engine.opened, <String>['C:/Media/track_9.mp3']);
        expect(service.state.sourceStart, service.requestedBoundary);
      },
    );

    test(
      'a stop requested while an open is queued prevents the stale open',
      () async {
        final engine = _GatedEnginePlayer();
        final service = MediaKitPlaybackService(
          player: Player(platformPlayer: engine),
        );
        addTearDown(service.dispose);

        final request = service.open('C:/Media/track_0.mp3');
        await drain();
        expect(engine.opened, <String>['C:/Media/track_0.mp3']);

        // A newer open and then a stop both supersede the queued duplicate.
        final duplicate = service.open('C:/Media/track_0.mp3');
        await service.stop();

        for (final gate in List.of(engine.gates)) {
          if (!gate.isCompleted) gate.complete();
        }
        await Future.wait(<Future<void>>[
          request,
          duplicate,
        ]).timeout(const Duration(seconds: 5));

        // The duplicate never re-attached the source after the stop.
        expect(engine.opened, hasLength(1));
        expect(service.requestedBoundary, greaterThan(1));
      },
    );
  });
}
