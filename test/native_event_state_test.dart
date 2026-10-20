import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/native_media_events.dart';
import 'package:mpvson/data/services/playback_service.dart';

// Regression: the Windows smoke run played the whole file while
// `controller.duration` stayed zero, so "duration > 0 and playing" never held.
// The engine notified `path` twice for one load; the second notification cleared
// the snapshot's duration, and media_kit does not re-report a duration that has
// not changed, so the source was stranded at zero from then on.
void main() {
  const loaded = PlaybackSnapshot(
    isPlaying: true,
    position: Duration(seconds: 3),
    duration: Duration(seconds: 8),
  );

  test('a started event keeps the engine duration', () {
    final next = applyNativeEvent(
      loaded,
      const NativeMediaEvent.started(r'E:\media\smoke.mp4'),
    );

    expect(
      next.duration,
      const Duration(seconds: 8),
      reason:
          'media_kit reports a changed duration on its stream, but never '
          'repeats an unchanged one, so clearing it here cannot be undone.',
    );
    expect(next.position, Duration.zero);
    expect(next.isBuffering, isTrue);
    expect(next.completed, isFalse);
  });

  test('a started event clears completion from the previous source', () {
    const completed = PlaybackSnapshot(
      completed: true,
      position: Duration(seconds: 8),
      duration: Duration(seconds: 8),
    );

    final next = applyNativeEvent(
      completed,
      const NativeMediaEvent.started(r'E:\media\next.mp4'),
    );

    expect(next.completed, isFalse);
    expect(next.position, Duration.zero);
    expect(next.duration, const Duration(seconds: 8));
  });

  test('a loaded event confirms the source without changing progress', () {
    final next = applyNativeEvent(loaded, const NativeMediaEvent.loaded());

    expect(next.duration, loaded.duration);
    expect(next.position, loaded.position);
    expect(next.isPlaying, isTrue);
    expect(next.isBuffering, isFalse);
  });

  test('a loaded event clears isBuffering set by a started event', () {
    final started = applyNativeEvent(
      loaded,
      const NativeMediaEvent.started(r'E:\media\smoke.mp4'),
    );
    expect(started.isBuffering, isTrue);

    final next = applyNativeEvent(started, const NativeMediaEvent.loaded());
    expect(next.isBuffering, isFalse);
    expect(next.completed, isFalse);
  });

  test('an ended event stops and completes the source', () {
    final next = applyNativeEvent(loaded, const NativeMediaEvent.ended());

    expect(next.completed, isTrue);
    expect(next.isPlaying, isFalse);
    expect(next.isBuffering, isFalse);
    expect(next.duration, loaded.duration);
  });
}
