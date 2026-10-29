import 'dart:async';

import 'package:flutter/foundation.dart';

/// Interpolates the playback position between engine reports.
///
/// libmpv reports `time-pos` roughly 15 times a second while audio is playing,
/// in 50-90 ms jumps (measured on the bundled Windows build). A control bound
/// directly to those reports visibly steps instead of gliding, so the value
/// shown to the user advances on a display cadence and is re-anchored on every
/// engine report.
///
/// The engine value stays the source of truth. Interpolation is bounded: it
/// never trails the newest report, never leads it by more than one engine
/// report interval plus slack, and never exceeds the duration. It also stops as
/// soon as playback is not advancing, so pausing, buffering, or a report that
/// never arrives cannot drift the readout.
class PlaybackPositionSmoother {
  PlaybackPositionSmoother();

  /// How far ahead of the newest engine report the interpolated value may run.
  ///
  /// One engine report interval plus slack, which keeps the visible error well
  /// under a tenth of a second even when reports stall.
  static const Duration _maxLead = Duration(milliseconds: 250);

  /// Display cadence while the window is focused.
  ///
  /// A music timeline moves a couple of pixels per second, so five updates a
  /// second are visually continuous while costing a fraction of a full frame
  /// rate; the timecode itself only changes once a second.
  static const Duration _foregroundInterval = Duration(milliseconds: 200);

  /// Background windows update the readout once a second.
  static const Duration _backgroundInterval = Duration(seconds: 1);

  /// The interpolated position. Intended for display only.
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(
    Duration.zero,
  );

  Duration _reported = Duration.zero;
  Duration _duration = Duration.zero;
  double _rate = 0;
  bool _advancing = false;
  bool _suspended = false;
  bool _lowPower = false;
  bool _disposed = false;
  Duration _interval = _foregroundInterval;

  final Stopwatch _clock = Stopwatch();
  Timer? _timer;

  /// Uses the background cadence while the window is not focused.
  void setLowPower(bool lowPower) {
    if (_disposed || _lowPower == lowPower) return;
    _lowPower = lowPower;
    _interval = lowPower ? _backgroundInterval : _foregroundInterval;
    _reanchor();
  }

  /// Stops display updates while the window cannot show them (minimized or
  /// hidden). Engine reports keep the anchor current; resuming republishes it.
  void setSuspended(bool suspended) {
    if (_disposed || _suspended == suspended) return;
    _suspended = suspended;
    if (suspended) {
      _timer?.cancel();
      _timer = null;
      _clock.stop();
      return;
    }
    _reanchor();
  }

  void _reanchor() {
    _timer?.cancel();
    _timer = null;
    if (_suspended) {
      _clock.stop();
      return;
    }
    _clock
      ..reset()
      ..start();
    _publish(_reported);
    _syncTimer();
  }

  /// Re-anchors the interpolation on an engine report.
  ///
  /// [advancing] must be false whenever playback is paused, buffering, at the
  /// end of the file, or has no media loaded; the readout then shows [reported]
  /// exactly and the display timer stops.
  void update({
    required Duration reported,
    required Duration duration,
    required double rate,
    required bool advancing,
  }) {
    if (_disposed) return;
    _reported = reported;
    _duration = duration;
    // A non-positive rate does not advance the position.
    _rate = rate > 0 ? rate : 0;
    _advancing = advancing;
    // reset() leaves the stopwatch stopped, so it has to be started again.
    _clock.reset();
    if (!_suspended) {
      _clock.start();
      _publish(reported);
    }
    _syncTimer();
  }

  void _syncTimer() {
    if (!_suspended && _advancing && !_disposed) {
      _timer ??= Timer.periodic(_interval, _onTick);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _onTick(Timer timer) {
    if (_disposed || _suspended || !_advancing) return;
    _publish(_interpolated());
  }

  Duration _interpolated() {
    final elapsed = _rate == 0 ? Duration.zero : _clock.elapsed * _rate;
    var value = _reported + elapsed;
    // Never trail the newest report, and never run ahead of it by more than one
    // report interval.
    if (value < _reported) value = _reported;
    final ceiling = _reported + _maxLead;
    if (value > ceiling) value = ceiling;
    if (_duration > Duration.zero && value > _duration) value = _duration;
    return value;
  }

  void _publish(Duration value) {
    if (position.value == value) return;
    position.value = value;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    position.dispose();
  }
}
