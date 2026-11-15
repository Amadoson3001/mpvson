import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../domain/models/hardware_profile.dart';

/// Opt-in [FrameTiming] capture for animation baseline runs.
///
/// Disabled in [kReleaseMode] unless you explicitly opt in at compile time via
/// `--dart-define=MPVSON_RECORD_ANIM_TIMINGS=true` (not recommended for ship).
///
/// Attach it from `main()` in any mode: the flags below decide. The README's
/// capture recipe runs `--profile`, which is why the attachment point must not
/// be debug-only.
abstract final class AnimationTimingsRecorder {
  /// Flip to `true` locally for ad-hoc runs without setting an environment var.
  static const bool debugFlag = false;

  /// Free-form run label, e.g.
  /// `MPVSON_ANIM_RUN_LABEL='sha=1a2b3c4;machine=old-60hz;display=60'`.
  ///
  /// Logged with every summary so an excerpt pasted into a review still says
  /// which revision and machine produced it.
  static String get runLabel {
    if (kIsWeb) return '';
    return Platform.environment['MPVSON_ANIM_RUN_LABEL']?.trim() ?? '';
  }

  /// `debug`, `profile` or `release`, so two captures are never compared
  /// across build modes by accident.
  static String get buildMode =>
      kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');

  static bool get isEnabled {
    if (kReleaseMode) return false;
    const fromDefine = bool.fromEnvironment(
      'MPVSON_RECORD_ANIM_TIMINGS',
      defaultValue: false,
    );
    if (fromDefine) return true;
    if (!kIsWeb) {
      final env = Platform.environment['MPVSON_RECORD_ANIM_TIMINGS']?.trim();
      if (env == '1' || env?.toLowerCase() == 'true') return true;
    }
    return debugFlag;
  }

  static _AnimationTimingsSession? _session;

  /// Registers a global timings callback when [isEnabled].
  static void attachIfEnabled() {
    if (!isEnabled || _session != null) return;
    _session = _AnimationTimingsSession()..attach();
  }

  /// Removes the global callback and flushes a final summary.
  static void detach() {
    _session?.dispose();
    _session = null;
  }
}

/// Wraps a subtree; attaches the recorder for this widget's lifetime in debug.
class AnimationTimingsRecorderScope extends StatefulWidget {
  const AnimationTimingsRecorderScope({super.key, required this.child});

  final Widget child;

  @override
  State<AnimationTimingsRecorderScope> createState() =>
      _AnimationTimingsRecorderScopeState();
}

class _AnimationTimingsRecorderScopeState
    extends State<AnimationTimingsRecorderScope> {
  _AnimationTimingsSession? _localSession;

  @override
  void initState() {
    super.initState();
    if (AnimationTimingsRecorder.isEnabled &&
        AnimationTimingsRecorder._session == null) {
      _localSession = _AnimationTimingsSession()..attach();
    }
  }

  @override
  void dispose() {
    _localSession?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final class _AnimationTimingsSession {
  static const int _reportEveryFrames = 120;
  static const int _maxSamples = 2048;

  final List<int> _buildMicros = <int>[];
  final List<int> _rasterMicros = <int>[];
  final List<int> _totalMicros = <int>[];
  int _framesSinceReport = 0;

  void attach() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    final profile = HardwareProfile.initial(
      cpuCount: Platform.numberOfProcessors,
    );
    developer.log(
      'attached mode=${AnimationTimingsRecorder.buildMode} '
      'cpus=${profile.cpuCount} tier=${profile.tier.name} '
      'run="${AnimationTimingsRecorder.runLabel}"',
      name: 'mpvson.anim',
    );
  }

  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _emitSummary(label: 'final');
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _record(
        timing.buildDuration.inMicroseconds,
        timing.rasterDuration.inMicroseconds,
        timing.totalSpan.inMicroseconds,
      );
    }
    _framesSinceReport += timings.length;
    if (_framesSinceReport >= _reportEveryFrames) {
      _emitSummary();
      _framesSinceReport = 0;
    }
  }

  void _record(int buildUs, int rasterUs, int totalUs) {
    _push(_buildMicros, buildUs);
    _push(_rasterMicros, rasterUs);
    _push(_totalMicros, totalUs);
  }

  void _push(List<int> buffer, int value) {
    buffer.add(value);
    if (buffer.length > _maxSamples) {
      buffer.removeAt(0);
    }
  }

  void _emitSummary({String label = 'window'}) {
    if (_totalMicros.isEmpty) return;
    final build = _stats(_buildMicros);
    final raster = _stats(_rasterMicros);
    final total = _stats(_totalMicros);
    developer.log(
      '[$label] run="${AnimationTimingsRecorder.runLabel}" '
      'mode=${AnimationTimingsRecorder.buildMode} '
      'frames=${total.count} '
      'build_us p50=${build.p50} p95=${build.p95} max=${build.max} '
      'raster_us p50=${raster.p50} p95=${raster.p95} max=${raster.max} '
      'totalSpan_us p50=${total.p50} p95=${total.p95} max=${total.max}',
      name: 'mpvson.anim',
    );
  }
}

final class _TimingStats {
  const _TimingStats({
    required this.count,
    required this.p50,
    required this.p95,
    required this.max,
  });

  final int count;
  final int p50;
  final int p95;
  final int max;
}

_TimingStats _stats(List<int> samples) {
  if (samples.isEmpty) {
    return const _TimingStats(count: 0, p50: 0, p95: 0, max: 0);
  }
  final sorted = List<int>.from(samples)..sort();
  return _TimingStats(
    count: sorted.length,
    p50: _percentile(sorted, 0.50),
    p95: _percentile(sorted, 0.95),
    max: sorted.last,
  );
}

int _percentile(List<int> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final index = (p * (sorted.length - 1)).round().clamp(0, sorted.length - 1);
  return sorted[index];
}
