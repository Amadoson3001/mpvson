import 'package:flutter/material.dart';

import 'toast_layout.dart';

/// Severity tint for a toast.
enum AppToastTone { neutral, success, warning, danger }

/// The message a toast carries, plus its optional inline action.
@immutable
class AppToastRequest {
  const AppToastRequest({
    required this.message,
    this.actionLabel,
    this.onAction,
    this.tone = AppToastTone.neutral,
    this.duration = const Duration(seconds: 4),
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final AppToastTone tone;
  final Duration duration;
}

/// A live toast: the request plus the state its card needs to animate.
class AppToastEntry {
  AppToastEntry(this.id, this.request);

  final int id;
  final AppToastRequest request;

  /// Bumped when an identical message arrives again, which restarts the
  /// countdown instead of stacking a duplicate card.
  final ValueNotifier<int> pulse = ValueNotifier<int>(0);

  /// True once the card is playing its exit animation.
  bool dismissing = false;

  void dispose() => pulse.dispose();
}

/// Owns the toasts currently on screen.
class AppToastController extends ChangeNotifier {
  final List<AppToastEntry> _entries = <AppToastEntry>[];
  int _nextId = 0;

  /// At most this many toasts stay readable at once.
  static const int maxVisible = 3;

  List<AppToastEntry> get entries => List<AppToastEntry>.unmodifiable(_entries);

  void show(AppToastRequest request) {
    for (final entry in _entries) {
      if (entry.dismissing) continue;
      if (entry.request.message == request.message &&
          entry.request.tone == request.tone &&
          entry.request.actionLabel == request.actionLabel) {
        entry.pulse.value++;
        return;
      }
    }

    _entries.add(AppToastEntry(_nextId++, request));
    var oldest = _firstVisibleIndex;
    while (_visibleCount > maxVisible && oldest >= 0) {
      _entries[oldest].dismissing = true;
      oldest = _firstVisibleIndex;
    }
    notifyListeners();
  }

  /// Starts a toast's exit animation; the card removes itself when it ends.
  void requestDismiss(int id) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || _entries[index].dismissing) return;
    _entries[index].dismissing = true;
    notifyListeners();
  }

  /// Drops a toast whose exit animation has finished.
  void completeDismiss(int id) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    _entries.removeAt(index).dispose();
    notifyListeners();
  }

  /// Dismisses every toast, newest first.
  void dismissVisible() {
    for (final entry in _entries.toList(growable: false)) {
      requestDismiss(entry.id);
    }
  }

  int get _visibleCount => _entries.where((entry) => !entry.dismissing).length;

  int get _firstVisibleIndex =>
      _entries.indexWhere((entry) => !entry.dismissing);

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.dispose();
    }
    _entries.clear();
    super.dispose();
  }
}

/// Publishes the toast controller and the occupied-space registry to the app.
class AppToastScope extends InheritedWidget {
  const AppToastScope({
    super.key,
    required this.controller,
    required this.layout,
    required super.child,
  });

  final AppToastController controller;
  final ToastLayoutState layout;

  static AppToastScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppToastScope>();

  @override
  bool updateShouldNotify(AppToastScope oldWidget) =>
      controller != oldWidget.controller || layout != oldWidget.layout;
}

/// Shows transient, non-blocking messages.
///
/// Toasts never take focus, never cover the whole screen, and only intercept
/// pointer events on their own card, so the rest of the interface stays
/// usable while a message is on screen.
abstract final class AppToast {
  /// Default lifetime of a toast without an action.
  static const Duration defaultDuration = Duration(seconds: 4);

  /// Shows a toast, or falls back to a snack bar outside a toast host.
  static void show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    AppToastTone tone = AppToastTone.neutral,
    Duration? duration,
  }) {
    final scope = AppToastScope.maybeOf(context);
    if (scope == null) {
      _showFallbackSnackBar(
        context,
        message,
        actionLabel: actionLabel,
        onAction: onAction,
      );
      return;
    }
    scope.controller.show(
      AppToastRequest(
        message: message,
        actionLabel: actionLabel,
        onAction: onAction,
        tone: tone,
        duration: duration ?? defaultDuration,
      ),
    );
  }

  /// Dismisses the toasts that are currently visible.
  static void dismissVisible(BuildContext context) {
    AppToastScope.maybeOf(context)?.controller.dismissVisible();
  }

  static void _showFallbackSnackBar(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final hasAction = actionLabel != null && onAction != null;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: hasAction
              ? SnackBarAction(label: actionLabel, onPressed: onAction)
              : null,
        ),
      );
  }
}
