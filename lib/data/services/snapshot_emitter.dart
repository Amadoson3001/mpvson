import 'dart:async';

/// Publishes state snapshots to a synchronous broadcast stream safely.
///
/// A synchronous broadcast controller throws `Bad state: Cannot fire new event.
/// Controller is already firing an event` when a listener calls back into the
/// publisher and that command publishes a new snapshot. Playback commands do
/// exactly that: reaching the end of the queue stops the engine from inside the
/// snapshot that reported completion, so the service must not add re-entrantly.
///
/// Nested publishes are queued instead, coalesced to the newest state, and
/// delivered as soon as the dispatch that produced them finishes. Snapshots are
/// absolute state, never deltas, so dropping intermediate ones is safe.
class SnapshotEmitter<T> {
  SnapshotEmitter(this._controller);

  final StreamController<T> _controller;
  bool _dispatching = false;
  T? _pending;
  bool _hasPending = false;

  /// Publishes [value], or schedules it when a dispatch is already running.
  ///
  /// Delivery of a direct call is synchronous, which keeps the ordering the
  /// state machines above rely on.
  void add(T value) {
    if (_dispatching) {
      _pending = value;
      _hasPending = true;
      return;
    }
    _dispatch(value);
    while (_hasPending) {
      final next = _pending as T;
      _pending = null;
      _hasPending = false;
      if (_controller.isClosed) return;
      _dispatch(next);
    }
  }

  void _dispatch(T value) {
    if (_controller.isClosed) return;
    _dispatching = true;
    try {
      _controller.add(value);
    } finally {
      _dispatching = false;
    }
  }
}
