import 'dart:async';

/// Cancels and restarts [delay] on every [run] so only the last call fires.
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 300)});

  final Duration delay;
  Timer? _timer;

  bool get isPending => _timer?.isActive ?? false;

  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Runs [action] immediately and cancels any pending call.
  void runNow(void Function() action) {
    cancel();
    action();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}

/// Schedules [action] once. Further calls during [delay] are ignored until it
/// fires. Used for scan-driven reloads that should coalesce, not reset.
class Coalescer {
  Coalescer({this.delay = const Duration(seconds: 2)});

  final Duration delay;
  Timer? _timer;

  bool get isPending => _timer?.isActive ?? false;

  void schedule(void Function() action) {
    _timer ??= Timer(delay, () {
      _timer = null;
      action();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}
