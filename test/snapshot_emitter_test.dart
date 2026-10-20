import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/snapshot_emitter.dart';

// Regression: the application smoke run ended with
// "Playback engine unavailable: Bad state: Cannot fire new event. Controller is
// already firing an event". A listener (the playback controller) stopped the
// engine from inside the snapshot that reported completion, and stopping
// publishes again. On a synchronous broadcast controller that nested publish
// throws and loses both the command and the state after it.
void main() {
  late StreamController<int> controller;
  late SnapshotEmitter<int> emitter;

  setUp(() {
    controller = StreamController<int>.broadcast(sync: true);
    emitter = SnapshotEmitter<int>(controller);
    addTearDown(() async {
      if (!controller.isClosed) await controller.close();
    });
  });

  test('delivers a direct publish synchronously', () {
    final seen = <int>[];
    controller.stream.listen(seen.add);

    emitter.add(1);

    expect(seen, <int>[1]);
  });

  test('queues a publish made from inside a listener', () {
    final seen = <int>[];
    controller.stream.listen((value) {
      seen.add(value);
      // What the controller does when playback completes: stop the engine,
      // which publishes the stopped state while the current dispatch runs.
      if (value == 1) emitter.add(2);
    });

    emitter.add(1);

    expect(seen, <int>[1, 2]);
  });

  test('coalesces nested publishes to the newest state', () {
    final seen = <int>[];
    controller.stream.listen((value) {
      seen.add(value);
      if (value == 1) {
        emitter.add(2);
        emitter.add(3);
      }
    });

    emitter.add(1);

    // Snapshots are absolute state; the intermediate one carries nothing the
    // newest state does not already describe.
    expect(seen, <int>[1, 3]);
  });

  test('keeps draining a chain of nested publishes', () {
    final seen = <int>[];
    controller.stream.listen((value) {
      seen.add(value);
      if (value < 3) emitter.add(value + 1);
    });

    emitter.add(1);

    expect(seen, <int>[1, 2, 3]);
  });

  test('ignores publishes after the stream is closed', () async {
    final seen = <int>[];
    controller.stream.listen(seen.add);
    await controller.close();

    expect(() => emitter.add(1), returnsNormally);
    expect(seen, isEmpty);
  });
}
