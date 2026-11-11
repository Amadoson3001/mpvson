import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Transient chrome state for [PlayerScreen]: auto-hiding controls, pointer and
/// keyboard bookkeeping that keeps them visible, the feedback pill, and the
/// queue panel's open/mounted state.
///
/// Kept out of the screen's [State] so the screen only orchestrates playback,
/// navigation and layout while these purely presentational timers live here.
class PlayerChromeController extends ChangeNotifier {
  PlayerChromeController({
    required this.contextMenu,
    required this.playerFocus,
    required this.isFullscreen,
    required this.reduceMotion,
    this.getAutoHideDelaySeconds,
    FocusScopeNode? controlsFocusScope,
    FocusScopeNode? queueFocusScope,
  }) : controlsFocusScope =
           controlsFocusScope ?? FocusScopeNode(debugLabel: 'Player controls'),
       queueFocusScope =
           queueFocusScope ?? FocusScopeNode(debugLabel: 'Player queue') {
    this.controlsFocusScope.addListener(_handleControlFocusChange);
    this.queueFocusScope.addListener(_handleQueueFocusChange);
  }

  static const controlHideDelay = Duration(milliseconds: 2800);
  static const fullscreenHideDelay = Duration(seconds: 2);

  final MenuController contextMenu;
  final FocusNode playerFocus;
  final bool Function() isFullscreen;
  final bool Function() reduceMotion;
  final double Function()? getAutoHideDelaySeconds;
  final FocusScopeNode controlsFocusScope;
  final FocusScopeNode queueFocusScope;

  Timer? _controlsTimer;
  Timer? _feedbackTimer;

  bool _controlsVisible = true;
  bool _pointerInControls = false;
  bool _controlMenuOpen = false;
  bool _controlInteraction = false;
  bool _keyboardControlsFocus = false;
  int _openDialogs = 0;
  bool _backButtonFocused = false;
  bool _dismissedContextMenuOnPointerDown = false;
  Offset? _lastPointerPosition;

  String? _feedbackLabel;
  IconData _feedbackIcon = Icons.volume_up_rounded;
  double? _feedbackProgress;
  bool _feedbackCentered = false;

  bool _queueOpen = false;
  bool _queueMounted = false;
  String? _focusedQueueEntryId;
  bool _videoSettingsOpen = false;

  bool get queueOpen => _queueOpen;
  bool get queueMounted => _queueMounted;
  String? get focusedQueueEntryId => _focusedQueueEntryId;
  bool get videoSettingsOpen => _videoSettingsOpen;

  void setFocusedQueueEntry(String? entryId) => _focusedQueueEntryId = entryId;

  void clearFocusedQueueEntry() => _focusedQueueEntryId = null;

  void setQueueOpen(bool open) {
    if (_queueOpen == open) return;
    _queueOpen = open;
    if (open) {
      _queueMounted = true;
      _videoSettingsOpen = false;
    }
    notifyListeners();
  }

  void toggleQueue() {
    if (contextMenu.isOpen) contextMenu.close();
    final closing = _queueOpen;
    _queueOpen = !_queueOpen;
    if (_queueOpen) {
      _queueMounted = true;
      _videoSettingsOpen = false;
    } else if (reduceMotion()) {
      _queueMounted = false;
    }
    notifyListeners();
    if (closing) playerFocus.requestFocus();
  }

  void closeQueue() {
    if (!_queueOpen) return;
    _queueOpen = false;
    if (reduceMotion()) _queueMounted = false;
    notifyListeners();
    playerFocus.requestFocus();
  }

  void toggleVideoSettings() {
    if (contextMenu.isOpen) contextMenu.close();
    final closing = _videoSettingsOpen;
    _videoSettingsOpen = !_videoSettingsOpen;
    if (_videoSettingsOpen) {
      _queueOpen = false;
      if (reduceMotion()) _queueMounted = false;
    }
    notifyListeners();
    if (closing) playerFocus.requestFocus();
  }

  void closeVideoSettings() {
    if (!_videoSettingsOpen) return;
    _videoSettingsOpen = false;
    notifyListeners();
    playerFocus.requestFocus();
  }

  void handleQueueExitEnd() {
    if (_queueOpen || !_queueMounted) return;
    _queueMounted = false;
    notifyListeners();
  }

  /// Immediate dismissal used when leaving the stage for the library.
  void dismissQueue() {
    _videoSettingsOpen = false;
    if (!_queueOpen && !_queueMounted) return;
    _queueOpen = false;
    _queueMounted = false;
    notifyListeners();
  }

  /// Fullscreen hides the queue: the drawer would cover the video otherwise.
  void handleFullscreen(bool isFullscreen) {
    if (!isFullscreen || !_queueOpen) return;
    playerFocus.requestFocus();
    _queueOpen = false;
    if (reduceMotion()) _queueMounted = false;
    notifyListeners();
  }

  bool get controlsVisible => _controlsVisible;
  bool get controlMenuOpen => _controlMenuOpen;
  String? get feedbackLabel => _feedbackLabel;
  IconData get feedbackIcon => _feedbackIcon;
  double? get feedbackProgress => _feedbackProgress;
  bool get feedbackCentered => _feedbackCentered;

  /// True when the last pointer press dismissed the context menu, so the same
  /// gesture does not also toggle playback.
  bool get dismissedContextMenuOnPointerDown =>
      _dismissedContextMenuOnPointerDown;

  void clearDismissedContextMenu() =>
      _dismissedContextMenuOnPointerDown = false;

  bool get hideBlocked =>
      _pointerInControls ||
      _controlMenuOpen ||
      _controlInteraction ||
      _openDialogs > 0 ||
      _backButtonFocused ||
      _videoSettingsOpen ||
      (controlsFocusScope.hasFocus && _keyboardControlsFocus);

  bool recordKeyboardInput(KeyEvent event) {
    if (event is KeyDownEvent) {
      _keyboardControlsFocus =
          event.logicalKey != LogicalKeyboardKey.space &&
          controlsFocusScope.hasFocus;
    }
    return false;
  }

  void markPointerInput(PointerDownEvent event) {
    _keyboardControlsFocus = false;
    if (contextMenu.isOpen) {
      _dismissedContextMenuOnPointerDown = true;
      contextMenu.close();
    }
    showControls();
  }

  void markPointerUp(PointerUpEvent event) {
    _dismissedContextMenuOnPointerDown = false;
  }

  void markPointerCancel(PointerCancelEvent event) {
    _dismissedContextMenuOnPointerDown = false;
  }

  void pointerActivity(PointerEvent event) {
    final last = _lastPointerPosition;
    if (event is PointerHoverEvent &&
        last != null &&
        (event.position - last).distance < 3) {
      return;
    }
    _lastPointerPosition = event.position;
    showControls();
  }

  void pointerLeft(PointerEvent event) {
    _lastPointerPosition = null;
    if (!hideBlocked) scheduleHide(restart: true);
  }

  void controlsPointerEntered(PointerEvent event) {
    _pointerInControls = true;
    showControls();
  }

  void controlsPointerExited(PointerEvent event) {
    _pointerInControls = false;
    if (!hideBlocked) scheduleHide(restart: true);
  }

  void setBackButtonFocused(bool focused) {
    _backButtonFocused = focused;
    if (focused) {
      showControls();
    } else if (!hideBlocked) {
      scheduleHide(restart: true);
    }
  }

  void showControls() {
    _controlsTimer?.cancel();
    if (!_controlsVisible) {
      _controlsVisible = true;
      notifyListeners();
    }
    if (!hideBlocked) scheduleHide(restart: true);
  }

  void scheduleHide({bool restart = false}) {
    final delaySeconds = getAutoHideDelaySeconds?.call() ?? 2.8;
    if (delaySeconds <= 0) {
      _controlsTimer?.cancel();
      _controlsTimer = null;
      return;
    }
    if (hideBlocked || !_controlsVisible) return;
    if (_controlsTimer?.isActive == true && !restart) return;
    _controlsTimer?.cancel();
    final delay = isFullscreen()
        ? fullscreenHideDelay
        : Duration(milliseconds: (delaySeconds * 1000).round());
    _controlsTimer = Timer(delay, () {
      if (!hideBlocked && _controlsVisible) {
        _controlsVisible = false;
        notifyListeners();
      }
    });
  }

  void handleMenuVisibility(bool open) {
    final wasOpen = _controlMenuOpen;
    _controlMenuOpen = open;
    if (wasOpen && !open) {
      _dismissedContextMenuOnPointerDown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _dismissedContextMenuOnPointerDown = false;
      });
    }
    showControls();
  }

  void handleControlInteraction(bool active) {
    _controlInteraction = active;
    showControls();
  }

  Future<T> withControlsVisible<T>(Future<T> Function() action) async {
    _openDialogs++;
    showControls();
    try {
      return await action();
    } finally {
      _openDialogs--;
      showControls();
    }
  }

  void showFeedback(
    IconData icon,
    String label, {
    double? progress,
    bool centered = false,
  }) {
    _feedbackTimer?.cancel();
    _feedbackIcon = icon;
    _feedbackLabel = label;
    _feedbackProgress = progress;
    _feedbackCentered = centered;
    notifyListeners();
    _feedbackTimer = Timer(Duration(milliseconds: centered ? 700 : 1100), () {
      _feedbackLabel = null;
      notifyListeners();
    });
  }

  void showVolumeFeedback(double value) => showFeedback(
    value <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
    value <= 0 ? 'Muted' : 'Volume ${value.round()}%',
    progress: value / 100,
  );

  void _handleControlFocusChange() {
    if (controlsFocusScope.hasFocus && _keyboardControlsFocus) {
      showControls();
    } else if (!hideBlocked) {
      scheduleHide(restart: true);
    }
  }

  void _handleQueueFocusChange() {
    if (!queueFocusScope.hasFocus) _focusedQueueEntryId = null;
  }

  @override
  void dispose() {
    controlsFocusScope.removeListener(_handleControlFocusChange);
    queueFocusScope.removeListener(_handleQueueFocusChange);
    _controlsTimer?.cancel();
    _feedbackTimer?.cancel();
    controlsFocusScope.dispose();
    queueFocusScope.dispose();
    super.dispose();
  }
}
