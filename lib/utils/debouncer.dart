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

/// Runs [action] at most once per [interval]. Optional trailing call fires
/// the last request after the window closes.
class Throttler {
  Throttler({this.interval = const Duration(milliseconds: 100)});

  final Duration interval;
  DateTime? _last;
  Timer? _trailing;
  void Function()? _pending;

  void run(void Function() action, {bool trailing = false}) {
    final now = DateTime.now();
    final last = _last;
    if (last == null || now.difference(last) >= interval) {
      _last = now;
      _trailing?.cancel();
      _trailing = null;
      _pending = null;
      action();
      return;
    }
    if (!trailing) return;
    _pending = action;
    _trailing ??= Timer(interval - now.difference(last), () {
      _trailing = null;
      final pending = _pending;
      _pending = null;
      if (pending == null) return;
      _last = DateTime.now();
      pending();
    });
  }

  void cancel() {
    _trailing?.cancel();
    _trailing = null;
    _pending = null;
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
