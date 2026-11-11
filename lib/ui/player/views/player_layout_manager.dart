import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/media_catalog.dart';
import '../../core/app_theme.dart';
import '../player_controller.dart';

export 'player_queue_layout.dart';
export 'player_top_bar.dart';

typedef FullscreenSetter = Future<void> Function(bool fullscreen);

const double wideQueuePanelWidth = AppLayout.queuePanelWidth;
const Size miniPlayerSize = Size(
  AppLayout.miniPlayerWidth,
  AppLayout.miniPlayerHeight,
);
const Size miniPlayerMinimumSize = Size(560, 315);
const Size windowMinimumSize = Size(720, 480);

class PlayerLayoutManager with WindowListener, ChangeNotifier {
  PlayerLayoutManager({
    required this.controller,
    required this.desktopWindow,
    this.fullscreenSetter,
    required this.isShowingLibrary,
    required this.showMessage,
    required this.showFeedback,
    this.onControlsNeedsVisibility,
    this.onCloseContextMenu,
    this.onCancelHeldSpeed,
    this.onSyncFullscreen,
    this.onMiniPlayerChanged,
    this.playerFocus,
    this.libraryRepository,
    this.isInAppMiniPlayerActive,
  });

  PlayerController controller;
  bool desktopWindow;
  FullscreenSetter? fullscreenSetter;
  final bool Function() isShowingLibrary;
  final void Function(String message) showMessage;
  final void Function(IconData icon, String label, {bool centered})
  showFeedback;
  final VoidCallback? onControlsNeedsVisibility;
  final VoidCallback? onCloseContextMenu;
  final VoidCallback? onCancelHeldSpeed;
  final void Function(bool isFullscreen)? onSyncFullscreen;
  final void Function(bool isMiniPlayer)? onMiniPlayerChanged;
  FocusNode? playerFocus;
  final MediaLibraryRepository? libraryRepository;
  bool Function()? isInAppMiniPlayerActive;

  bool _isFullscreen = false;
  bool _miniPlayer = false;
  bool _miniPlayerTransition = false;
  bool _minimized = false;
  bool _animationsSuspended = false;

  Rect? _miniPlayerRestoreBounds;
  bool _miniRestoreMaximized = false;
  bool _wasMaximizedBeforeFullscreen = false;
  bool _fullscreenReadInFlight = false;
  bool _fullscreenReadRequested = false;
  Timer? _fullscreenResyncTimer;
  bool _isDisposed = false;

  bool get isFullscreen => _isFullscreen;
  bool get isMiniPlayer => _miniPlayer;
  bool get isMinimized => _minimized;
  bool get animationsSuspended => _animationsSuspended;
  bool get isNativeWindow => desktopWindow && fullscreenSetter == null;

  void init() {
    if (isNativeWindow) {
      windowManager.addListener(this);
      unawaited(readNativeFullscreen());
    }
  }

  void updateDependencies({
    required PlayerController controller,
    required bool desktopWindow,
    FullscreenSetter? fullscreenSetter,
  }) {
    final wasNative = this.desktopWindow && this.fullscreenSetter == null;
    this.controller = controller;
    this.desktopWindow = desktopWindow;
    this.fullscreenSetter = fullscreenSetter;
    final isNative = this.desktopWindow && this.fullscreenSetter == null;
    if (wasNative != isNative) {
      if (isNative) {
        windowManager.addListener(this);
      } else {
        windowManager.removeListener(this);
      }
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _fullscreenResyncTimer?.cancel();
    if (isNativeWindow) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> toggleMiniPlayer() {
    // A toggle while a mini-player transition is still applying its window
    // changes would capture mid-transition bounds and corrupt the restore
    // state, so it is swallowed until the running transition settles.
    if (_miniPlayerTransition) return Future<void>.value();
    return _miniPlayer ? exitMiniPlayer() : enterMiniPlayer();
  }

  Future<void> enterMiniPlayer() async {
    if (_miniPlayer || _miniPlayerTransition || !isNativeWindow) return;
    final current = controller.current;
    final isVideoEntry =
        current != null && MediaCatalog.kindFromExtension(current.path).isVideo;
    if (!isVideoEntry || isShowingLibrary()) {
      showMessage('Mini player is available while a video is playing.');
      return;
    }
    // Entering is asynchronous: flag the transition synchronously so a rapid
    // double-toggle cannot interleave window calls before the first enter
    // has stored its restore bounds.
    _miniPlayerTransition = true;
    var wasMaximized = false;
    try {
      onCloseContextMenu?.call();
      if (_isFullscreen) await setFullscreen(false);
      wasMaximized = await _leaveMaximizedState();
      final bounds = await windowManager.getBounds();
      await windowManager.setMinimumSize(miniPlayerMinimumSize);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setBounds(
        Rect.fromLTWH(
          bounds.right - miniPlayerSize.width,
          bounds.top,
          miniPlayerSize.width,
          miniPlayerSize.height,
        ),
      );
      if (_isDisposed) return;
      _miniPlayer = true;
      _miniPlayerRestoreBounds = bounds;
      _miniRestoreMaximized = wasMaximized;
      onMiniPlayerChanged?.call(true);
      notifyListeners();
      showFeedback(
        Icons.picture_in_picture_alt_rounded,
        'Mini player on',
        centered: true,
      );
    } catch (_) {
      try {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMinimumSize(windowMinimumSize);
        if (wasMaximized) await windowManager.maximize();
      } on Object {
        // Best effort while the window manager is unavailable.
      }
      showMessage('Mini player could not be enabled.');
    } finally {
      _miniPlayerTransition = false;
    }
  }

  Future<void> exitMiniPlayer() async {
    if (!_miniPlayer || _miniPlayerTransition) return;
    final restoreBounds = _miniPlayerRestoreBounds;
    final restoreMaximized = _miniRestoreMaximized;
    _miniPlayer = false;
    _miniPlayerRestoreBounds = null;
    _miniRestoreMaximized = false;
    // Exiting is asynchronous too: flag the transition synchronously so a
    // rapid re-enter cannot capture the mini bounds as restore bounds while
    // the window is still being restored.
    _miniPlayerTransition = true;
    onMiniPlayerChanged?.call(false);
    notifyListeners();
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(windowMinimumSize);
      if (restoreBounds != null) await windowManager.setBounds(restoreBounds);
      if (restoreMaximized) await windowManager.maximize();
    } catch (_) {
      // The window may already be closing.
    } finally {
      _miniPlayerTransition = false;
    }
    showFeedback(Icons.open_in_full_rounded, 'Mini player off', centered: true);
  }

  @override
  void onWindowEnterFullScreen() => syncFullscreen(true);

  @override
  void onWindowLeaveFullScreen() => syncFullscreen(false);

  @override
  void onWindowMinimize() => handleMinimize();

  @override
  void onWindowRestore() => handleRestore();

  void handleMinimize() {
    if (_minimized) return;
    _minimized = true;
    _animationsSuspended = true;
    controller.addThumbnailSuspension(
      ThumbnailSuspensionReason.windowMinimized,
    );
    controller.seekPreview.suspend();
    controller.setDisplayUpdatesSuspended(true);
    controller.trimMemory(includeVideo: controller.trimOnMinimize);
    unawaited(libraryRepository?.shrinkMemory());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    updateVideoOutputPolicy(visible: false);
    notifyListeners();
  }

  void handleRestore() {
    if (!_minimized) return;
    _minimized = false;
    _animationsSuspended = false;
    controller.removeThumbnailSuspension(
      ThumbnailSuspensionReason.windowMinimized,
    );
    controller.seekPreview.resume();
    controller.setDisplayUpdatesSuspended(false);
    syncVideoVisibilityForLibrary();
    notifyListeners();
  }

  void updateVideoOutputPolicy({
    bool? visible,
    int? physicalWidth,
    int? physicalHeight,
  }) {
    final current = controller.videoOutputPolicy;
    final next = current.copyWith(
      visible: visible ?? (_minimized ? false : current.visible),
      physicalWidth: physicalWidth ?? current.physicalWidth,
      physicalHeight: physicalHeight ?? current.physicalHeight,
    );
    if (next != current) {
      controller.applyVideoOutputPolicy(next);
    }
  }

  void syncVideoVisibilityForLibrary() {
    final miniActive = isInAppMiniPlayerActive?.call() ?? true;
    final inLibraryWithMini = isShowingLibrary() && miniActive;
    final visible =
        (!isShowingLibrary() || inLibraryWithMini) &&
        !_minimized &&
        controller.hasMedia &&
        controller.isVideo;
    updateVideoOutputPolicy(visible: visible);
  }

  void updateViewportDimensions(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final pw = (constraints.maxWidth * dpr).round();
    final ph = (constraints.maxHeight * dpr).round();
    updateVideoOutputPolicy(physicalWidth: pw, physicalHeight: ph);
  }

  @override
  void onWindowBlur() {
    controller.setDisplayUpdatesLowPower(true);
    onCancelHeldSpeed?.call();
    onCloseContextMenu?.call();
  }

  @override
  void onWindowFocus() {
    controller.setDisplayUpdatesLowPower(false);
  }

  void didChangeMetrics() {
    onCloseContextMenu?.call();
    if (isNativeWindow) {
      unawaited(readNativeFullscreen());
      _fullscreenResyncTimer?.cancel();
      _fullscreenResyncTimer = Timer(const Duration(milliseconds: 150), () {
        if (!_isDisposed) unawaited(readNativeFullscreen());
      });
    }
  }

  Future<void> readNativeFullscreen() async {
    if (_isDisposed) return;
    _fullscreenReadRequested = true;
    if (_fullscreenReadInFlight) return;
    _fullscreenReadInFlight = true;
    try {
      do {
        _fullscreenReadRequested = false;
        try {
          final fullscreen = await windowManager.isFullScreen();
          if (!_isDisposed && fullscreen != _isFullscreen) {
            syncFullscreen(fullscreen);
          }
        } on Object {
          // Explicit fullscreen actions still report their native failures.
        }
      } while (!_isDisposed && _fullscreenReadRequested);
    } finally {
      _fullscreenReadInFlight = false;
    }
  }

  void syncFullscreen(bool value) {
    if (_isDisposed) return;
    _isFullscreen = value;
    onSyncFullscreen?.call(value);
    onControlsNeedsVisibility?.call();
    notifyListeners();
  }

  Future<void> toggleFullscreen() async {
    if (_miniPlayer) await exitMiniPlayer();
    await setFullscreen(!_isFullscreen);
  }

  Future<void> setFullscreen(bool value) async {
    onCloseContextMenu?.call();
    if (!desktopWindow) return;
    try {
      playerFocus?.requestFocus();
      if (isNativeWindow && value) {
        _wasMaximizedBeforeFullscreen = await _leaveMaximizedState();
      }
      if (fullscreenSetter != null) {
        await fullscreenSetter!(value);
      } else {
        await windowManager.setFullScreen(value);
      }
      if (isNativeWindow && !value && _wasMaximizedBeforeFullscreen) {
        _wasMaximizedBeforeFullscreen = false;
        await windowManager.maximize();
      }
      syncFullscreen(value);
    } catch (_) {
      if (isNativeWindow && _wasMaximizedBeforeFullscreen) {
        _wasMaximizedBeforeFullscreen = false;
        try {
          await windowManager.maximize();
        } on Object {
          // Leave the window restored if maximizing fails.
        }
      }
      showMessage('Fullscreen could not be changed.');
    }
  }

  Future<bool> _leaveMaximizedState() async {
    try {
      if (!await windowManager.isMaximized()) return false;
      await windowManager.unmaximize();
      for (var attempt = 0; attempt < 30; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!await windowManager.isMaximized()) return true;
      }
    } on Object {
      // Proceed without changing the window state.
    }
    return false;
  }
}
