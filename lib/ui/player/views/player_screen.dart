import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/open_request.dart';
import '../../../domain/models/player_hotkeys.dart';
import '../../../data/services/open_request_coordinator.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../../data/services/playback_statistics.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/toast/toast_layout.dart';
import '../../core/components/media_accent_scope.dart';
import '../player_controller.dart';
import '../widgets/empty_library.dart';
import '../widgets/media_ready.dart';
import '../widgets/open_url_dialog.dart';
import '../widgets/player_controls.dart';
import '../widgets/player_actions.dart';
import '../widgets/player_context_menu.dart';
import '../widgets/playback_feedback.dart';
import '../widgets/queue_panel.dart';
import 'settings_dialog.dart';
import 'playback_info_dialog.dart';
import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../library/views/library_shell.dart';
import '../../library/views/home_view.dart';

typedef PlayerVideoBuilder =
    Widget Function(BuildContext context, PlayerController controller);
typedef MediaFilePicker = Future<List<String>> Function();
typedef SubtitleFilePicker = Future<String?> Function();
typedef UrlPrompt = Future<String?> Function(BuildContext context);
typedef FullscreenSetter = Future<void> Function(bool fullscreen);

const double _wideQueuePanelWidth = 352;
const Size _miniPlayerSize = Size(600, 338);
const Size _miniPlayerMinimumSize = Size(560, 315);
const Size _windowMinimumSize = Size(720, 480);

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.desktopWindow,
    required this.videoBuilder,
    this.mediaPicker,
    this.subtitlePicker,
    this.urlPrompt,
    this.enableNativeDrop = true,
    this.fullscreenSetter,
    this.appPreferences,
    this.libraryRepository,
    this.desktopIntegration,
    this.openCoordinator,
  });

  final OpenRequestCoordinator? openCoordinator;
  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final bool desktopWindow;
  final PlayerVideoBuilder videoBuilder;
  final MediaFilePicker? mediaPicker;
  final SubtitleFilePicker? subtitlePicker;
  final UrlPrompt? urlPrompt;
  final bool enableNativeDrop;
  final FullscreenSetter? fullscreenSetter;
  final AppPreferencesRepository? appPreferences;
  final MediaLibraryRepository? libraryRepository;
  final DesktopIntegrationService? desktopIntegration;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver, WindowListener {
  static const _spaceHoldDelay = Duration(milliseconds: 180);
  static const _controlHideDelay = Duration(milliseconds: 2800);

  final FocusScopeNode _controlsFocusScope = FocusScopeNode(
    debugLabel: 'Player controls',
  );
  final FocusScopeNode _queueFocusScope = FocusScopeNode(debugLabel: 'Queue');
  final FocusNode _playerFocus = FocusNode(debugLabel: 'Video player');
  final MenuController _contextMenu = MenuController();
  final GlobalKey _videoSurfaceKey = GlobalKey();
  Timer? _spaceTimer;
  Timer? _controlsTimer;
  Timer? _feedbackTimer;
  Timer? _wheelResetTimer;
  Timer? _fullscreenResyncTimer;
  bool _spaceHeld = false;
  bool _longSpacePress = false;
  double _rateBeforeHold = 1;
  bool _controlsVisible = true;
  bool _pointerInControls = false;
  bool _controlMenuOpen = false;
  bool _controlInteraction = false;
  bool _keyboardControlsFocus = false;
  int _openDialogs = 0;
  bool _draggingFiles = false;
  bool _queueOpen = false;
  bool _queueMounted = false;
  final GlobalKey _queuePanelKey = GlobalKey();
  Widget? _queuePanelCache;
  PlayerController? _queuePanelCacheController;
  bool _isFullscreen = false;
  bool _wasMaximizedBeforeFullscreen = false;
  bool _fullscreenReadInFlight = false;
  bool _fullscreenReadRequested = false;
  String? _focusedQueueEntryId;
  Offset? _lastPointerPosition;
  double _wheelRemainder = 0;
  String? _feedbackLabel;
  IconData _feedbackIcon = Icons.volume_up_rounded;
  double? _feedbackProgress;
  bool _feedbackCentered = false;
  bool _dismissedContextMenuOnPointerDown = false;
  bool _minimized = false;
  bool _animationsSuspended = false;
  bool _showLibrary = false;
  int _homeNavigationRequest = 0;
  bool _backButtonFocused = false;
  bool _settingsOpen = false;
  bool _miniPlayer = false;
  Rect? _miniPlayerRestoreBounds;
  bool _miniRestoreMaximized = false;
  bool _showPlayerView = false;
  String? _playerViewEntryId;
  String? _lastVideoEntryId;
  String? _preparedPausedVideoId;

  bool get _nativeWindow =>
      widget.desktopWindow && widget.fullscreenSetter == null;

  bool get _isShowingLibrary {
    final current = widget.controller.current;
    // A restored audio entry has no engine source yet, so its media kind is
    // not detected. Extension-based classification keeps the library visible
    // immediately instead of showing the video-style resume stage.
    final isAudioMedia =
        (widget.controller.isAudio && widget.controller.hasMedia) ||
        (current != null &&
            MediaCatalog.kindFromExtension(current.path).isAudio);
    final showPlayerForCurrent =
        _showPlayerView && _playerViewEntryId == current?.id;
    return (_showLibrary ||
            ((isAudioMedia || current == null) && !showPlayerForCurrent)) &&
        widget.libraryRepository != null;
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller.isVideo) {
      _lastVideoEntryId = widget.controller.current?.id;
    }
    widget.controller.addListener(_handleControllerChange);
    _controlsFocusScope.addListener(_handleControlFocusChange);
    _queueFocusScope.addListener(_handleQueueFocusChange);
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_handlePrimaryFocusChange);
    HardwareKeyboard.instance.addHandler(_recordKeyboardInput);
    if (_nativeWindow) windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showControls();
        _preparePausedVideo();
      }
    });
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      widget.controller.addListener(_handleControllerChange);
      _queuePanelCache = null;
      _queuePanelCacheController = null;
    }
    final wasNative =
        oldWidget.desktopWindow && oldWidget.fullscreenSetter == null;
    if (wasNative != _nativeWindow) {
      if (_nativeWindow) {
        windowManager.addListener(this);
      } else {
        windowManager.removeListener(this);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_handlePrimaryFocusChange);
    HardwareKeyboard.instance.removeHandler(_recordKeyboardInput);
    if (_nativeWindow) windowManager.removeListener(this);
    widget.controller.removeListener(_handleControllerChange);
    _controlsFocusScope.removeListener(_handleControlFocusChange);
    _queueFocusScope.removeListener(_handleQueueFocusChange);
    _controlsFocusScope.dispose();
    _queueFocusScope.dispose();
    _playerFocus.dispose();
    _spaceTimer?.cancel();
    _controlsTimer?.cancel();
    _feedbackTimer?.cancel();
    _wheelResetTimer?.cancel();
    _fullscreenResyncTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _cancelHeldSpeed();
      if (_contextMenu.isOpen) _contextMenu.close();
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _handleMinimize();
    } else if (state == AppLifecycleState.resumed) {
      _handleRestore();
    }
  }

  @override
  void didHaveMemoryPressure() {
    widget.controller.trimMemory();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  void _handlePrimaryFocusChange() {
    if (!_spaceHeld) return;
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (_textInputFocused ||
        focusedContext == null ||
        focusedContext.findAncestorWidgetOfExactType<PlayerScreen>() == null) {
      _cancelHeldSpeed();
    }
  }

  void _cancelHeldSpeed() {
    _spaceTimer?.cancel();
    _spaceHeld = false;
    if (_longSpacePress) {
      _longSpacePress = false;
      unawaited(widget.controller.setRate(_rateBeforeHold));
    }
  }

  bool get _hideBlocked =>
      !widget.controller.hasMedia ||
      !widget.controller.isPlaying ||
      widget.controller.isBuffering ||
      _controlMenuOpen ||
      _openDialogs > 0 ||
      _controlInteraction ||
      _backButtonFocused ||
      _draggingFiles ||
      (_controlsFocusScope.hasFocus && _keyboardControlsFocus) ||
      (_pointerInControls && !_isFullscreen);

  bool _recordKeyboardInput(KeyEvent event) {
    if (event is KeyDownEvent && mounted) {
      _keyboardControlsFocus = true;
      if (!_textInputFocused) _showControls();
    }
    return false;
  }

  void _markPointerInput(PointerDownEvent event) {
    _keyboardControlsFocus = false;
    if (_contextMenu.isOpen) {
      if (event.buttons != kSecondaryMouseButton) {
        _dismissedContextMenuOnPointerDown = true;
      }
      _contextMenu.close();
    }
    if (!_hideBlocked) _scheduleControlsHide(restart: true);
  }

  void _markPointerUp(PointerUpEvent event) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _dismissedContextMenuOnPointerDown = false;
    });
  }

  void _markPointerCancel(PointerCancelEvent event) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _dismissedContextMenuOnPointerDown = false;
    });
  }

  void _handleControllerChange() {
    if (!mounted) return;
    final current = widget.controller.current;
    if (current != null &&
        widget.controller.hasMedia &&
        widget.controller.isVideo &&
        current.id != _lastVideoEntryId) {
      _lastVideoEntryId = current.id;
      if (_showLibrary) setState(() => _showLibrary = false);
    }
    if (_miniPlayer) {
      final audioEntry =
          current == null ||
          widget.controller.isAudio ||
          MediaCatalog.kindFromExtension(current.path).isAudio;
      if (audioEntry) unawaited(_exitMiniPlayer());
    }
    if (_hideBlocked) {
      _controlsTimer?.cancel();
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    } else {
      _scheduleControlsHide();
    }
    _preparePausedVideo();
    _syncVideoVisibilityForLibrary();
  }

  /// Restored videos open in the stage paused instead of showing a resume card.
  void _preparePausedVideo() {
    if (!mounted || _isShowingLibrary) return;
    final controller = widget.controller;
    final current = controller.current;
    if (current == null || controller.hasMedia || controller.isLoading) return;
    if (!MediaCatalog.kindFromExtension(current.path).isVideo) return;
    if (_preparedPausedVideoId == current.id) return;
    _preparedPausedVideoId = current.id;
    unawaited(controller.prepareCurrentPaused());
  }

  void _openLibrary() {
    if (_miniPlayer) unawaited(_exitMiniPlayer());
    setState(() {
      _showLibrary = true;
      _showPlayerView = false;
    });
    _syncVideoVisibilityForLibrary();
  }

  void _backToHome() {
    if (_contextMenu.isOpen) _contextMenu.close();
    final wasFullscreen = _isFullscreen;
    setState(() {
      _showLibrary = true;
      _showPlayerView = false;
      _settingsOpen = false;
      _homeNavigationRequest++;
      _queueOpen = false;
      _queueMounted = false;
      _backButtonFocused = false;
    });
    _syncVideoVisibilityForLibrary();
    if (wasFullscreen) unawaited(_setFullscreen(false));
  }

  void _returnToPlayer() {
    setState(() {
      _showLibrary = false;
      _showPlayerView = true;
      _playerViewEntryId = widget.controller.current?.id;
    });
    _syncVideoVisibilityForLibrary();
    _preparePausedVideo();
  }

  void _handleQueueFocusChange() {
    if (!_queueFocusScope.hasFocus) _focusedQueueEntryId = null;
  }

  void _handleControlFocusChange() {
    if (_controlsFocusScope.hasFocus && _keyboardControlsFocus) {
      _showControls();
    } else if (!_hideBlocked) {
      _scheduleControlsHide(restart: true);
    }
  }

  void _showControls() {
    if (!mounted) return;
    _controlsTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    if (!_hideBlocked) _scheduleControlsHide(restart: true);
  }

  void _pointerActivity(PointerEvent event) {
    final last = _lastPointerPosition;
    if (event is PointerHoverEvent &&
        last != null &&
        (event.position - last).distance < 3) {
      return;
    }
    _lastPointerPosition = event.position;
    _showControls();
  }

  void _pointerLeft(PointerEvent event) {
    _lastPointerPosition = null;
    if (!_hideBlocked) _scheduleControlsHide(restart: true);
  }

  void _controlsPointerEntered(PointerEvent event) {
    _pointerInControls = true;
    _showControls();
  }

  void _controlsPointerExited(PointerEvent event) {
    _pointerInControls = false;
    if (!_hideBlocked) _scheduleControlsHide(restart: true);
  }

  void _scheduleControlsHide({bool restart = false}) {
    if (_hideBlocked || !_controlsVisible) return;
    if (_controlsTimer?.isActive == true && !restart) return;
    _controlsTimer?.cancel();
    _controlsTimer = Timer(
      _isFullscreen ? const Duration(seconds: 2) : _controlHideDelay,
      () {
        if (mounted && !_hideBlocked) setState(() => _controlsVisible = false);
      },
    );
  }

  void _handleMenuVisibility(bool open) {
    if (!mounted) return;
    final wasOpen = _controlMenuOpen;
    _controlMenuOpen = open;
    if (wasOpen && !open) {
      _dismissedContextMenuOnPointerDown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dismissedContextMenuOnPointerDown = false;
      });
    }
    _showControls();
  }

  void _handleControlInteraction(bool active) {
    if (!mounted) return;
    _controlInteraction = active;
    _showControls();
  }

  Future<T> _withControlsVisible<T>(Future<T> Function() action) async {
    _openDialogs++;
    _showControls();
    try {
      return await action();
    } finally {
      _openDialogs--;
      if (mounted) _showControls();
    }
  }

  void _showFeedback(
    IconData icon,
    String label, {
    double? progress,
    bool centered = false,
  }) {
    if (!mounted) return;
    _feedbackTimer?.cancel();
    setState(() {
      _feedbackIcon = icon;
      _feedbackLabel = label;
      _feedbackProgress = progress;
      _feedbackCentered = centered;
    });
    _feedbackTimer = Timer(Duration(milliseconds: centered ? 700 : 1100), () {
      if (mounted) setState(() => _feedbackLabel = null);
    });
  }

  void _showVolumeFeedback(double value) => _showFeedback(
    value <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
    value <= 0 ? 'Muted' : 'Volume ${value.round()}%',
    progress: value / 100,
  );

  void _adjustVolume(double delta) {
    unawaited(widget.controller.adjustVolume(delta));
    _showVolumeFeedback(widget.controller.volume);
  }

  void _toggleMute() {
    unawaited(widget.controller.toggleMute());
    _showVolumeFeedback(widget.controller.volume);
  }

  /// Nudges the persisted audio or subtitle delay and reports the new value.
  Future<void> _adjustPlaybackDelay({
    required bool audio,
    required bool later,
  }) async {
    final settings = widget.controller.playbackSettings;
    final stepMs = widget.appPreferences?.preferences.syncStepMs ?? 50;
    final step = later ? stepMs : -stepMs;
    final current = audio
        ? settings.audioDelaySeconds
        : settings.subtitleDelaySeconds;
    final boundedMs = ((current * 1000).round() + step).clamp(-10000, 10000);
    final next = boundedMs / 1000;
    final updated = audio
        ? settings.copyWith(audioDelaySeconds: next)
        : settings.copyWith(subtitleDelaySeconds: next);
    final suffix = boundedMs > 0 ? '+' : '';
    _showFeedback(
      audio ? Icons.graphic_eq_rounded : Icons.closed_caption_rounded,
      '${audio ? 'Audio' : 'Subtitle'} delay $suffix$boundedMs ms',
      centered: true,
    );
    await widget.controller.setPlaybackSettings(updated);
    if (mounted && widget.controller.playbackSettingsError != null) {
      _showMessage('The playback engine did not accept the delay change.');
    }
  }

  Future<void> _toggleMiniPlayer() =>
      _miniPlayer ? _exitMiniPlayer() : _enterMiniPlayer();

  Future<void> _enterMiniPlayer() async {
    if (_miniPlayer || !_nativeWindow) return;
    final current = widget.controller.current;
    final isVideoEntry =
        current != null && MediaCatalog.kindFromExtension(current.path).isVideo;
    if (!isVideoEntry || _isShowingLibrary) {
      _showMessage('Mini player is available while a video is playing.');
      return;
    }
    var wasMaximized = false;
    try {
      if (_contextMenu.isOpen) _contextMenu.close();
      if (_isFullscreen) await _setFullscreen(false);
      wasMaximized = await _leaveMaximizedState();
      final bounds = await windowManager.getBounds();
      await windowManager.setMinimumSize(_miniPlayerMinimumSize);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setBounds(
        Rect.fromLTWH(
          bounds.right - _miniPlayerSize.width,
          bounds.top,
          _miniPlayerSize.width,
          _miniPlayerSize.height,
        ),
      );
      if (!mounted) return;
      setState(() {
        _miniPlayer = true;
        _miniPlayerRestoreBounds = bounds;
        _miniRestoreMaximized = wasMaximized;
        _controlsVisible = true;
      });
      _showFeedback(
        Icons.picture_in_picture_alt_rounded,
        'Mini player on',
        centered: true,
      );
    } catch (_) {
      try {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMinimumSize(_windowMinimumSize);
        if (wasMaximized) await windowManager.maximize();
      } on Object {
        // Best effort while the window manager is unavailable.
      }
      _showMessage('Mini player could not be enabled.');
    }
  }

  Future<void> _exitMiniPlayer() async {
    if (!_miniPlayer) return;
    final restoreBounds = _miniPlayerRestoreBounds;
    final restoreMaximized = _miniRestoreMaximized;
    if (mounted) {
      setState(() {
        _miniPlayer = false;
        _miniPlayerRestoreBounds = null;
        _miniRestoreMaximized = false;
      });
    }
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(_windowMinimumSize);
      if (restoreBounds != null) await windowManager.setBounds(restoreBounds);
      if (restoreMaximized) await windowManager.maximize();
    } catch (_) {
      // The window may already be closing.
    }
    _showFeedback(
      Icons.open_in_full_rounded,
      'Mini player off',
      centered: true,
    );
  }

  void _onVideoPointerSignal(PointerSignalEvent event) {
    if (_contextMenu.isOpen) _contextMenu.close();
    if (event is! PointerScrollEvent ||
        !widget.controller.hasMedia ||
        event.scrollDelta.dy == 0 ||
        event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      // Flutter wheel deltas are logical pixels. Coalesce small touchpad
      // deltas, while treating a large wheel packet as one deliberate step.
      _wheelRemainder += event.scrollDelta.dy.clamp(-20.0, 20.0);
      final steps = (_wheelRemainder / 20).truncate();
      _wheelResetTimer?.cancel();
      _wheelResetTimer = Timer(
        const Duration(milliseconds: 250),
        () => _wheelRemainder = 0,
      );
      if (steps == 0) return;
      _wheelRemainder -= steps * 20;
      _adjustVolume(-steps * 5);
    });
  }

  void _toggleVideoPlayback() {
    if (_dismissedContextMenuOnPointerDown || _contextMenu.isOpen) {
      _dismissedContextMenuOnPointerDown = false;
      if (_contextMenu.isOpen) _contextMenu.close();
      return;
    }
    if (widget.controller.current == null) return;
    _playerFocus.requestFocus();
    final wasPlaying = widget.controller.isPlaying;
    unawaited(widget.controller.togglePlayPause());
    _showFeedback(
      wasPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      wasPlaying ? 'Paused' : 'Playing',
      centered: true,
    );
    _showControls();
  }

  void _openKeyboardContextMenu() {
    final box = _videoSurfaceKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    _contextMenu.open(position: box.size.center(Offset.zero));
  }

  Future<void> _loadSubtitle() async {
    final path = await _pickSubtitle();
    if (path == null || !mounted) return;
    await widget.controller.loadSubtitle(path);
  }

  @override
  void onWindowEnterFullScreen() => _syncFullscreen(true);

  @override
  void onWindowLeaveFullScreen() => _syncFullscreen(false);

  @override
  void onWindowMinimize() {
    _handleMinimize();
  }

  @override
  void onWindowRestore() {
    _handleRestore();
  }

  void _handleMinimize() {
    if (_minimized) return;
    _minimized = true;
    _animationsSuspended = true;
    widget.controller.addThumbnailSuspension(
      ThumbnailSuspensionReason.windowMinimized,
    );
    widget.controller.seekPreview.suspend();
    widget.controller.setDisplayUpdatesSuspended(true);
    widget.controller.trimMemory();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _updateVideoOutputPolicy(visible: false);
    if (mounted) setState(() {});
  }

  void _handleRestore() {
    if (!_minimized) return;
    _minimized = false;
    _animationsSuspended = false;
    widget.controller.removeThumbnailSuspension(
      ThumbnailSuspensionReason.windowMinimized,
    );
    widget.controller.seekPreview.resume();
    widget.controller.setDisplayUpdatesSuspended(false);
    _syncVideoVisibilityForLibrary();
    if (mounted) setState(() {});
  }

  void _updateVideoOutputPolicy({
    bool? visible,
    int? physicalWidth,
    int? physicalHeight,
  }) {
    final current = widget.controller.videoOutputPolicy;
    final next = current.copyWith(
      visible: visible ?? (_minimized ? false : current.visible),
      physicalWidth: physicalWidth ?? current.physicalWidth,
      physicalHeight: physicalHeight ?? current.physicalHeight,
    );
    if (next != current) {
      widget.controller.applyVideoOutputPolicy(next);
    }
  }

  /// Video frames are not presented while the library covers the stage or
  /// when the current source is audio. Audio keeps playing and the video
  /// output resumes on return to the stage.
  void _syncVideoVisibilityForLibrary() {
    final visible =
        !_isShowingLibrary &&
        !_minimized &&
        widget.controller.hasMedia &&
        widget.controller.isVideo;
    _updateVideoOutputPolicy(visible: visible);
  }

  void _updateViewportDimensions(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final pw = (constraints.maxWidth * dpr).round();
    final ph = (constraints.maxHeight * dpr).round();
    _updateVideoOutputPolicy(physicalWidth: pw, physicalHeight: ph);
  }

  @override
  void onWindowBlur() {
    widget.controller.setDisplayUpdatesLowPower(true);
    _cancelHeldSpeed();
    if (_contextMenu.isOpen) _contextMenu.close();
  }

  @override
  void onWindowFocus() {
    widget.controller.setDisplayUpdatesLowPower(false);
  }

  @override
  void didChangeMetrics() {
    if (_contextMenu.isOpen) _contextMenu.close();
    if (_nativeWindow) {
      unawaited(_readNativeFullscreen());
      // The resize notification can precede the native fullscreen flag. Read
      // once more after the transition settles, even without playback ticks.
      _fullscreenResyncTimer?.cancel();
      _fullscreenResyncTimer = Timer(const Duration(milliseconds: 150), () {
        if (mounted) unawaited(_readNativeFullscreen());
      });
    }
  }

  Future<void> _readNativeFullscreen() async {
    if (!mounted) return;
    _fullscreenReadRequested = true;
    if (_fullscreenReadInFlight) return;
    _fullscreenReadInFlight = true;
    try {
      do {
        _fullscreenReadRequested = false;
        try {
          // Preserve a metrics notification received during the native call.
          final fullscreen = await windowManager.isFullScreen();
          if (mounted && fullscreen != _isFullscreen) {
            _syncFullscreen(fullscreen);
          }
        } on Object {
          // Explicit fullscreen actions still report their native failures.
        }
      } while (mounted && _fullscreenReadRequested);
    } finally {
      _fullscreenReadInFlight = false;
    }
  }

  void _syncFullscreen(bool value) {
    if (!mounted) return;
    if (value && _queueOpen) {
      _playerFocus.requestFocus();
    }
    setState(() {
      _isFullscreen = value;
      if (value) {
        _queueOpen = false;
        if (AppMotion.reduce(context)) _queueMounted = false;
      }
    });
    _showControls();
  }

  bool get _textInputFocused {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool get _sliderFocused {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is Slider ||
        context.findAncestorWidgetOfExactType<Slider>() != null;
  }

  PlayerHotkeys get _hotkeys =>
      widget.appPreferences?.preferences.hotkeys ?? PlayerHotkeys.defaults;

  PlayerAction? _actionFor(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed) return null;
    return _hotkeys.actionFor(
      event.logicalKey,
      ctrl: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final action = _actionFor(event);
    // A held playback shortcut must unwind even if the focus changed before
    // the release. Fresh typing inside a text field remains untouched.
    if (action == PlayerAction.playPause && event is KeyUpEvent && _spaceHeld) {
      final togglePlayback = !_longSpacePress && !_textInputFocused;
      _cancelHeldSpeed();
      if (togglePlayback) unawaited(widget.controller.togglePlayPause());
      return _textInputFocused
          ? KeyEventResult.ignored
          : KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape && _contextMenu.isOpen) {
      if (event is KeyDownEvent) _contextMenu.close();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape && _queueOpen) {
      if (event is KeyDownEvent) {
        _closeQueuePanel();
      }
      return KeyEventResult.handled;
    }

    if (_textInputFocused) return KeyEventResult.ignored;
    if (action == PlayerAction.playPause && _controlsFocusScope.hasFocus) {
      return KeyEventResult.ignored;
    }

    if (action == PlayerAction.playPause) {
      if (event is KeyDownEvent && !_spaceHeld) {
        _spaceHeld = true;
        _longSpacePress = false;
        _spaceTimer?.cancel();
        _spaceTimer = Timer(_spaceHoldDelay, () {
          if (!mounted || !_spaceHeld) return;
          _longSpacePress = true;
          _rateBeforeHold = widget.controller.rate;
          if (!widget.controller.isPlaying) {
            unawaited(widget.controller.togglePlayPause());
          }
          unawaited(widget.controller.setRate(2));
        });
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent && _spaceHeld) return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final queueOwnsFocus = _queueFocusScope.hasFocus;
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyO) {
      unawaited(_openFiles());
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyL) {
      unawaited(_openUrl());
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyM &&
        widget.libraryRepository != null) {
      _openLibrary();
      return KeyEventResult.handled;
    }

    switch (key) {
      case LogicalKeyboardKey.contextMenu:
        _openKeyboardContextMenu();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.f10:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _openKeyboardContextMenu();
          return KeyEventResult.handled;
        }
        break;
      case LogicalKeyboardKey.delete:
        if (_focusedQueueEntryId case final entryId?
            when _queueFocusScope.hasFocus) {
          unawaited(_removeQueueEntryById(entryId));
          return KeyEventResult.handled;
        }
        break;
      case LogicalKeyboardKey.f11:
        if (widget.desktopWindow) {
          unawaited(_toggleFullscreen());
          return KeyEventResult.handled;
        }
        break;
      case LogicalKeyboardKey.escape:
        if (_isFullscreen) {
          unawaited(_setFullscreen(false));
          return KeyEventResult.handled;
        }
        break;
      default:
        break;
    }

    if (action == null) return KeyEventResult.ignored;
    switch (action) {
      case PlayerAction.playPause:
        // Held-state handling above owns the play/pause shortcut.
        return KeyEventResult.ignored;
      case PlayerAction.seekBackward:
      case PlayerAction.seekForward:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        final stepSeconds =
            widget.appPreferences?.preferences.seekStepSeconds ?? 5;
        final step = action == PlayerAction.seekForward
            ? stepSeconds
            : -stepSeconds;
        unawaited(widget.controller.seekRelative(Duration(seconds: step)));
        _showControls();
        return KeyEventResult.handled;
      case PlayerAction.volumeUp:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        _adjustVolume(5);
        _showControls();
        return KeyEventResult.handled;
      case PlayerAction.volumeDown:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        _adjustVolume(-5);
        _showControls();
        return KeyEventResult.handled;
      case PlayerAction.mute:
        _toggleMute();
        return KeyEventResult.handled;
      case PlayerAction.queue:
        _toggleQueue();
        return KeyEventResult.handled;
      case PlayerAction.playbackInfo:
        unawaited(_showPlaybackInfo());
        return KeyEventResult.handled;
      case PlayerAction.fullscreen:
        if (!widget.desktopWindow) return KeyEventResult.ignored;
        unawaited(_toggleFullscreen());
        return KeyEventResult.handled;
      case PlayerAction.miniPlayer:
        if (!_nativeWindow) return KeyEventResult.ignored;
        unawaited(_toggleMiniPlayer());
        return KeyEventResult.handled;
      case PlayerAction.subtitleEarlier:
        unawaited(_adjustPlaybackDelay(audio: false, later: false));
        return KeyEventResult.handled;
      case PlayerAction.subtitleLater:
        unawaited(_adjustPlaybackDelay(audio: false, later: true));
        return KeyEventResult.handled;
      case PlayerAction.audioEarlier:
        unawaited(_adjustPlaybackDelay(audio: true, later: false));
        return KeyEventResult.handled;
      case PlayerAction.audioLater:
        unawaited(_adjustPlaybackDelay(audio: true, later: true));
        return KeyEventResult.handled;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TickerMode(
        enabled: !_animationsSuspended,
        child: SafeArea(
          top: false,
          child: Focus(
            focusNode: _playerFocus,
            autofocus: true,
            onKeyEvent: _handleKey,
            child: Listener(
              onPointerDown: _markPointerInput,
              onPointerUp: _markPointerUp,
              onPointerCancel: _markPointerCancel,
              child: MouseRegion(
                onEnter: _pointerActivity,
                onHover: _pointerActivity,
                onExit: _pointerLeft,
                child: AnimatedBuilder(
                  animation: widget.controller.structureListenable,
                  builder: (context, _) => Column(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final showPlayerQueue =
                                _queueOpen && !_isShowingLibrary;
                            final queueMounted =
                                _queueMounted && !_isShowingLibrary;
                            final inlineQueue =
                                constraints.maxWidth >= 1100 && showPlayerQueue;
                            final narrowDrawer =
                                constraints.maxWidth < 1100 && showPlayerQueue;
                            return Stack(
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: _buildPlayerArea()),
                                    if (constraints.maxWidth >= 1100)
                                      SizedBox(
                                        width: inlineQueue || queueMounted
                                            ? _wideQueuePanelWidth
                                            : 0,
                                        child: queueMounted || inlineQueue
                                            ? ClipRect(
                                                child: TweenAnimationBuilder<double>(
                                                  tween: Tween<double>(
                                                    begin: 0,
                                                    end: inlineQueue ? 1 : 0,
                                                  ),
                                                  duration: AppMotion.duration(
                                                    context,
                                                    AppMotion.standard,
                                                  ),
                                                  curve: inlineQueue
                                                      ? AppMotion.enter
                                                      : AppMotion.exit,
                                                  onEnd: _handleQueueExitEnd,
                                                  builder:
                                                      (
                                                        context,
                                                        progress,
                                                        child,
                                                      ) {
                                                        if (AppMotion.reduce(
                                                          context,
                                                        )) {
                                                          return child!;
                                                        }
                                                        return Transform.translate(
                                                          offset: Offset(
                                                            (1 - progress) * 24,
                                                            0,
                                                          ),
                                                          child: child,
                                                        );
                                                      },
                                                  child: IgnorePointer(
                                                    ignoring: !inlineQueue,
                                                    child: ExcludeSemantics(
                                                      excluding: !inlineQueue,
                                                      child: RepaintBoundary(
                                                        child: SizedBox(
                                                          width:
                                                              _wideQueuePanelWidth,
                                                          child: _queuePanel(
                                                            onClose:
                                                                _toggleQueue,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : const SizedBox.shrink(),
                                      ),
                                  ],
                                ),
                                if (constraints.maxWidth < 1100 &&
                                    (queueMounted || narrowDrawer)) ...[
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      ignoring: !narrowDrawer,
                                      child: TweenAnimationBuilder<double>(
                                        tween: Tween<double>(
                                          begin: 0,
                                          end: narrowDrawer ? 1 : 0,
                                        ),
                                        duration: AppMotion.duration(
                                          context,
                                          AppMotion.quick,
                                        ),
                                        curve: narrowDrawer
                                            ? AppMotion.enter
                                            : AppMotion.exit,
                                        builder: (context, opacity, child) =>
                                            Opacity(
                                              opacity: opacity,
                                              child: child,
                                            ),
                                        child: GestureDetector(
                                          onTap: _toggleQueue,
                                          child: ColoredBox(
                                            color: context.palette.background
                                                .withValues(alpha: 0.6),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    bottom: 0,
                                    right: 0,
                                    width: constraints.maxWidth
                                        .clamp(290, 360)
                                        .toDouble(),
                                    child: TweenAnimationBuilder<double>(
                                      tween: Tween<double>(
                                        begin: 0,
                                        end: narrowDrawer ? 1 : 0,
                                      ),
                                      duration: AppMotion.duration(
                                        context,
                                        AppMotion.standard,
                                      ),
                                      curve: AppMotion.standardCurve,
                                      onEnd: _handleQueueExitEnd,
                                      builder: (context, progress, child) {
                                        if (AppMotion.reduce(context)) {
                                          return child!;
                                        }
                                        return Transform.translate(
                                          offset: Offset(
                                            (1 - progress) *
                                                constraints.maxWidth
                                                    .clamp(290, 360)
                                                    .toDouble(),
                                            0,
                                          ),
                                          child: child,
                                        );
                                      },
                                      child: IgnorePointer(
                                        ignoring: !narrowDrawer,
                                        child: ExcludeSemantics(
                                          excluding: !narrowDrawer,
                                          child: CallbackShortcuts(
                                            bindings: {
                                              const SingleActivator(
                                                LogicalKeyboardKey.escape,
                                              ): _closeQueuePanel,
                                            },
                                            child: _queuePanel(
                                              onClose: _toggleQueue,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                      if (widget.controller.error case final error?)
                        _ErrorBanner(message: error),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerArea() {
    final current = widget.controller.current;
    final showLibrary = _isShowingLibrary;
    // Track classification can briefly describe the previous source, so the
    // extension keeps known audio from attaching a video output.
    final audioEntry =
        widget.controller.isAudio ||
        (current != null &&
            MediaCatalog.kindFromExtension(current.path).isAudio);
    Widget? library;
    if (widget.libraryRepository != null) {
      library = LibraryShell(
        repository: widget.libraryRepository!,
        controller: widget.controller,
        initialSection: LibrarySection.home,
        homeNavigationRequest: _homeNavigationRequest,
        queueOpen: _queueOpen,
        onQueueOpenChanged: (open) => setState(() {
          _queueOpen = open;
          if (open) _queueMounted = true;
        }),
        home: HomeView(
          repository: widget.libraryRepository!,
          controller: widget.controller,
          recent: widget.controller.recent,
          onOpenFiles: _openFiles,
          onOpenUrl: _openUrl,
          onOpenRecent: _playRecent,
          isDragging: _draggingFiles,
        ),
        onOpenFiles: _openFiles,
        onOpenUrl: _openUrl,
        onAddQueueFiles: _addQueueFiles,
        onBackToPlayer: widget.controller.hasMedia && widget.controller.isVideo
            ? _returnToPlayer
            : null,
        onAddFolders: _addLibraryFolder,
        showSettings: _settingsOpen,
        onSettings: () => setState(() => _settingsOpen = true),
        onCloseSettings: () => setState(() => _settingsOpen = false),
        folders: LibraryFoldersView(repository: widget.libraryRepository!),
        settings: SettingsDialog(
          controller: widget.controller,
          updates: widget.updates,
          engineUpdates: widget.engineUpdates,
          pickSubtitle: _pickSubtitle,
          appPreferences: widget.appPreferences,
          libraryRepository: widget.libraryRepository,
          desktopIntegration: widget.desktopIntegration,
          embedded: true,
          onClose: () => setState(() => _settingsOpen = false),
        ),
      );
    }
    final Widget content;
    final String contentState;
    if (current == null) {
      contentState = 'empty';
      content = Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: EmptyLibrary(
          recent: widget.controller.recent,
          onOpenFiles: _openFiles,
          onOpenUrl: _openUrl,
          onOpenRecent: _playRecent,
          isDragging: _draggingFiles,
          onOpenLibrary: widget.libraryRepository != null ? _openLibrary : null,
        ),
      );
    } else if (!widget.controller.hasMedia) {
      contentState = 'ready';
      content = Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            widget.controller.displayPositionListenable,
            widget.controller.durationListenable,
            widget.controller.bufferingListenable,
          ]),
          builder: (context, _) => MediaReady(
            entry: widget.controller.current ?? current,
            position: widget.controller.displayPosition,
            duration: widget.controller.duration,
            isOpening: widget.controller.isBuffering,
            onPlay: () => unawaited(widget.controller.togglePlayPause()),
          ),
        ),
      );
    } else if (audioEntry) {
      // Audio is presented by the library; the hidden stage must not attach a
      // video output just to stay offstage.
      contentState = 'audio';
      content = const ColoredBox(color: AppTheme.stage);
    } else {
      contentState = 'video';
      content = ColoredBox(
        color: AppTheme.stage,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _updateViewportDimensions(context, constraints);
            return widget.videoBuilder(context, widget.controller);
          },
        ),
      );
    }
    final Widget stage;
    if (showLibrary && (audioEntry || current == null)) {
      // The library covers the stage, and these states keep no video surface
      // alive; building the hidden player chrome only costs memory and frames.
      stage = const SizedBox.expand();
    } else {
      stage = Stack(
        fit: StackFit.expand,
        children: [
          PlayerContextMenu(
            playerController: widget.controller,
            menuController: _contextMenu,
            onOpenFiles: _openFiles,
            onOpenUrl: _openUrl,
            onToggleQueue: _toggleQueue,
            onSettings: _showSettings,
            onLoadSubtitle: _loadSubtitle,
            onToggleMute: _toggleMute,
            onAdjustVolume: _adjustVolume,
            onMenuVisibilityChanged: _handleMenuVisibility,
            onFullscreen: widget.desktopWindow ? _toggleFullscreen : null,
            onToggleMiniPlayer: _nativeWindow
                ? () => unawaited(_toggleMiniPlayer())
                : null,
            isFullscreen: _isFullscreen,
            isMiniPlayer: _miniPlayer,
            queueOpen: _queueOpen,
            shortcutLabel: (action) => _hotkeys.bindingFor(action).label,
            child: MouseRegion(
              key: const ValueKey('video-surface'),
              cursor: _isFullscreen && !_controlsVisible && !_controlMenuOpen
                  ? SystemMouseCursors.none
                  : MouseCursor.defer,
              child: Listener(
                onPointerSignal: _onVideoPointerSignal,
                child: GestureDetector(
                  key: _videoSurfaceKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.controller.hasMedia
                      ? _toggleVideoPlayback
                      : null,
                  onDoubleTap: widget.desktopWindow
                      ? () {
                          if (_miniPlayer) {
                            unawaited(_exitMiniPlayer());
                          } else {
                            unawaited(_toggleFullscreen());
                          }
                        }
                      : null,
                  child: AnimatedSwitcher(
                    duration: AppMotion.duration(context, AppMotion.reveal),
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      fit: StackFit.expand,
                      children: [...previousChildren, ?currentChild],
                    ),
                    transitionBuilder: (child, animation) {
                      if (AppMotion.reduce(context)) {
                        return FadeTransition(opacity: animation, child: child);
                      }
                      final transition = CurvedAnimation(
                        parent: animation,
                        curve: AppMotion.enter,
                        reverseCurve: AppMotion.exit,
                      );
                      return FadeTransition(opacity: transition, child: child);
                    },
                    child: KeyedSubtree(
                      key: ValueKey<String>('player-content-$contentState'),
                      child: RepaintBoundary(child: content),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.controller.hasMedia &&
              widget.controller.isVideo &&
              current != null)
            Positioned(
              left: 16,
              top: 12,
              right: 24,
              child: MouseRegion(
                onEnter: _controlsPointerEntered,
                onExit: _controlsPointerExited,
                child: AnimatedOpacity(
                  duration: AppMotion.duration(context, AppMotion.quick),
                  opacity: _controlsVisible ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Row(
                      children: [
                        if (!_miniPlayer &&
                            widget.libraryRepository != null) ...[
                          Focus(
                            onFocusChange: (focused) {
                              _backButtonFocused = focused;
                              if (focused) {
                                _showControls();
                              } else if (!_hideBlocked) {
                                _scheduleControlsHide(restart: true);
                              }
                            },
                            child: TextButton.icon(
                              onPressed: _backToHome,
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                size: 20,
                              ),
                              label: const Text('Home'),
                              style: TextButton.styleFrom(
                                foregroundColor: AppTheme.onStage,
                                backgroundColor: AppTheme.stage.withValues(
                                  alpha: 0.65,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Text(
                            current.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: AppTheme.onStage,
                                  shadows: const [
                                    Shadow(
                                      color: AppTheme.stage,
                                      blurRadius: 5,
                                    ),
                                  ],
                                ),
                          ),
                        ),
                        if (_miniPlayer) ...[
                          const SizedBox(width: 12),
                          TextButton.icon(
                            key: const ValueKey('exit-mini-player'),
                            onPressed: () => unawaited(_exitMiniPlayer()),
                            icon: const Icon(
                              Icons.open_in_full_rounded,
                              size: 20,
                            ),
                            label: const Text('Exit mini player'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppTheme.onStage,
                              backgroundColor: AppTheme.stage.withValues(
                                alpha: 0.65,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: _feedbackCentered
                    ? Alignment.center
                    : Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: AnimatedSwitcher(
                    duration: AppMotion.duration(context, AppMotion.quick),
                    child: _feedbackLabel == null
                        ? const SizedBox.shrink()
                        : PlaybackFeedback(
                            key: const ValueKey('playback-feedback'),
                            icon: _feedbackIcon,
                            label: _feedbackLabel!,
                            progress: _feedbackProgress,
                          ),
                  ),
                ),
              ),
            ),
          ),
          if (_draggingFiles && current != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: context.palette.background.withValues(alpha: 0.6),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    widget.controller.hasMedia
                        ? 'Drop videos to add them to the queue'
                        : 'Drop a video to start playback',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ),
          // While the library covers the stage, its transport strip cannot be
          // seen; leaving it mounted made a second seek bar repaint on the
          // playback cadence even during audio-only use.
          if (!showLibrary)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FocusScope(
                node: _controlsFocusScope,
                child: MouseRegion(
                  onEnter: _controlsPointerEntered,
                  onExit: _controlsPointerExited,
                  opaque: _controlsVisible,
                  hitTestBehavior: _controlsVisible
                      ? HitTestBehavior.opaque
                      : HitTestBehavior.deferToChild,
                  child: AnimatedOpacity(
                    key: const ValueKey('player-controls-visibility'),
                    duration: AppMotion.duration(context, AppMotion.quick),
                    opacity: _controlsVisible ? 1 : 0,
                    child: AnimatedSlide(
                      offset: !AppMotion.reduce(context) && !_controlsVisible
                          ? const Offset(0, 0.1)
                          : Offset.zero,
                      duration: AppMotion.duration(context, AppMotion.quick),
                      curve: AppMotion.standardCurve,
                      child: IgnorePointer(
                        ignoring: !_controlsVisible,
                        child: ToastRegion(
                          child: AnimatedBuilder(
                            animation: widget.controller,
                            builder: (context, _) => PlayerControls(
                              controller: widget.controller,
                              onMenuVisibilityChanged: _handleMenuVisibility,
                              onInteractionChanged: _handleControlInteraction,
                              onVolumeChanged: _showVolumeFeedback,
                              showPlaybackControls: widget.controller.hasMedia,
                              actions: _miniPlayer
                                  ? null
                                  : PlayerActions(
                                      controller: widget.controller,
                                      onOpenFiles: _openFiles,
                                      onOpenUrl: _openUrl,
                                      onOpenRecent: _playRecent,
                                      onToggleQueue: _toggleQueue,
                                      onSettings: _showSettings,
                                      onPlaybackInfo: _showPlaybackInfo,
                                      onOpenLibrary:
                                          widget.libraryRepository != null
                                          ? _openLibrary
                                          : null,
                                      onMenuVisibilityChanged:
                                          _handleMenuVisibility,
                                      queueOpen: _queueOpen,
                                      isFullscreen: _isFullscreen,
                                      onFullscreen: widget.desktopWindow
                                          ? _toggleFullscreen
                                          : null,
                                      onToggleMiniPlayer: _nativeWindow
                                          ? () => unawaited(_toggleMiniPlayer())
                                          : null,
                                      isMiniPlayer: _miniPlayer,
                                      miniPlayerShortcut: _hotkeys
                                          .bindingFor(PlayerAction.miniPlayer)
                                          .label,
                                      playbackInfoShortcut: _hotkeys
                                          .bindingFor(PlayerAction.playbackInfo)
                                          .label,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    final contentArea = MediaAccentScope(
      controller: widget.controller,
      child: library == null
          ? stage
          : Stack(
              fit: StackFit.expand,
              children: [
                Offstage(
                  offstage: showLibrary,
                  child: TickerMode(enabled: !showLibrary, child: stage),
                ),
                Offstage(
                  offstage: !showLibrary,
                  child: TickerMode(enabled: showLibrary, child: library),
                ),
              ],
            ),
    );
    if (!widget.enableNativeDrop) return contentArea;
    return DropTarget(
      onDragEntered: (_) => setState(() => _draggingFiles = true),
      onDragExited: (_) => setState(() => _draggingFiles = false),
      onDragDone: (details) {
        setState(() => _draggingFiles = false);
        final paths = details.files
            .map((file) => file.path)
            .where((path) => path.isNotEmpty)
            .toList();
        unawaited(_openPaths(paths, origin: OpenOrigin.dragAndDrop));
      },
      child: contentArea,
    );
  }

  Widget _queuePanel({required VoidCallback onClose}) {
    if (_queuePanelCacheController == widget.controller &&
        _queuePanelCache != null) {
      return _queuePanelCache!;
    }
    _queuePanelCacheController = widget.controller;
    return _queuePanelCache = ToastRegion(
      child: FocusScope(
        node: _queueFocusScope,
        child: QueuePanel(
          // One key for the one logical panel, so search text, focus and scroll
          // survive presentation changes and unrelated screen rebuilds.
          key: _queuePanelKey,
          controller: widget.controller,
          onClose: onClose,
          onQueueFocus: (entryId) => _focusedQueueEntryId = entryId,
          onAddFiles: _addQueueFiles,
        ),
      ),
    );
  }

  Future<void> _addQueueFiles() async {
    if (_contextMenu.isOpen) _contextMenu.close();
    try {
      await _withControlsVisible(() async {
        final paths = await (widget.mediaPicker == null
            ? _pickMediaFiles()
            : widget.mediaPicker!());
        if (paths.isEmpty) return;
        await _openPaths(paths, append: true);
      });
    } catch (_) {
      _showMessage('The file picker could not be opened.');
    }
  }

  Future<void> _openFiles() async {
    if (_contextMenu.isOpen) _contextMenu.close();
    try {
      final paths = await _withControlsVisible(
        () => widget.mediaPicker == null
            ? _pickMediaFiles()
            : widget.mediaPicker!(),
      );
      if (paths.isEmpty) return;
      await _openPaths(paths);
    } catch (_) {
      _showMessage('The file picker could not be opened.');
    }
  }

  Future<List<String>> _pickMediaFiles() async {
    final mediaTypes = XTypeGroup(
      label: 'Media files',
      extensions: MediaCatalog.filePickerExtensions,
    );
    final audioVideoTypes = XTypeGroup(
      label: 'Audio and video files',
      extensions: MediaCatalog.filePickerExtensions,
    );
    final files = await openFiles(
      acceptedTypeGroups: [mediaTypes, audioVideoTypes],
    );
    return files
        .map((file) => file.path)
        .where((path) => path.isNotEmpty)
        .toList();
  }

  Future<void> _openPaths(
    List<String> paths, {
    bool append = false,
    OpenOrigin origin = OpenOrigin.filePicker,
    bool playNow = false,
  }) async {
    if (paths.isEmpty) return;
    try {
      final coordinator = widget.openCoordinator;
      if (coordinator == null) {
        await widget.controller.openPaths(paths, append: append);
        return;
      }
      final result = await coordinator.handleOpenRequest(
        OpenRequest(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          sources: paths,
          origin: origin,
          intent: append
              ? OpenIntent.enqueue
              : playNow
              ? OpenIntent.playNow
              : OpenIntent.normal,
        ),
      );
      if (result.status == OpenStatus.rejected) {
        _showMessage(
          'Could not open the selected media. Check the source and try again.',
        );
      } else if (result.rejectedCount > 0) {
        _showMessage('Some selected sources could not be opened.');
      }
    } catch (_) {
      _showMessage('Mpvson could not open that media.');
    }
  }

  Future<void> _openUrl() async {
    if (_contextMenu.isOpen) _contextMenu.close();
    final url = await _withControlsVisible(
      () => widget.urlPrompt == null
          ? showDialog<String>(
              context: context,
              builder: (_) => const OpenUrlDialog(),
            )
          : widget.urlPrompt!(context),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    await _openPaths([url.trim()]);
  }

  Future<void> _playRecent(MediaEntry entry) =>
      _openPaths([entry.path], playNow: true);

  Future<String?> _pickSubtitle() => _withControlsVisible(() async {
    if (widget.subtitlePicker != null) return widget.subtitlePicker!();
    const subtitleTypes = XTypeGroup(
      label: 'Subtitle files',
      extensions: ['ass', 'idx', 'srt', 'ssa', 'sub', 'vtt'],
    );
    final file = await openFile(acceptedTypeGroups: [subtitleTypes]);
    return file?.path;
  });

  Future<void> _removeQueueEntryById(String id) async {
    final index = widget.controller.queue.indexWhere((e) => e.id == id);
    if (index == -1) {
      _focusedQueueEntryId = null;
      return;
    }
    await _removeQueueIndex(index);
  }

  Future<void> _removeQueueIndex(int index) async {
    try {
      await widget.controller.removeAt(index);
      if (!mounted) return;
      _focusedQueueEntryId = null;
      AppToast.show(
        context,
        'Removed from queue',
        actionLabel: 'Undo',
        onAction: () => unawaited(widget.controller.undoRemove()),
      );
    } catch (_) {
      _showMessage('Could not remove this item from the queue.');
    }
  }

  void _toggleQueue() {
    if (_contextMenu.isOpen) _contextMenu.close();
    final closing = _queueOpen;
    setState(() {
      _queueOpen = !_queueOpen;
      if (_queueOpen) {
        _queueMounted = true;
      } else if (AppMotion.reduce(context)) {
        _queueMounted = false;
      }
    });
    if (closing) _playerFocus.requestFocus();
  }

  void _closeQueuePanel() {
    if (!_queueOpen) return;
    setState(() {
      _queueOpen = false;
      if (AppMotion.reduce(context)) _queueMounted = false;
    });
    _playerFocus.requestFocus();
  }

  /// Unmounts the single queue panel once its exit animation has finished.
  void _handleQueueExitEnd() {
    if (_queueOpen || !_queueMounted || !mounted) return;
    setState(() => _queueMounted = false);
  }

  Future<void> _addLibraryFolder() async {
    final repository = widget.libraryRepository;
    if (repository == null) return;
    try {
      final path = await getDirectoryPath();
      if (path != null) await repository.addFolder(path);
    } catch (_) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not add the folder. Try again.',
        tone: AppToastTone.danger,
      );
    }
  }

  Future<void> _showSettings({bool showMediaLibrary = false}) async {
    if (_contextMenu.isOpen) _contextMenu.close();
    if (widget.libraryRepository != null) {
      setState(() {
        _showLibrary = true;
        _settingsOpen = true;
      });
      return;
    }
    await _withControlsVisible(
      () => showDialog<void>(
        context: context,
        builder: (_) => SettingsDialog(
          controller: widget.controller,
          updates: widget.updates,
          engineUpdates: widget.engineUpdates,
          pickSubtitle: _pickSubtitle,
          appPreferences: widget.appPreferences,
          libraryRepository: widget.libraryRepository,
          desktopIntegration: widget.desktopIntegration,
          showMediaLibrary: showMediaLibrary,
        ),
      ),
    );
  }

  Future<void> _showPlaybackInfo() async {
    if (_contextMenu.isOpen) _contextMenu.close();
    await _withControlsVisible(
      () => showDialog<void>(
        context: context,
        builder: (_) => PlaybackInfoDialog(
          readStatistics: () =>
              readNativePlaybackStatistics(widget.controller.player),
        ),
      ),
    );
  }

  Future<void> _toggleFullscreen() async {
    if (_miniPlayer) await _exitMiniPlayer();
    await _setFullscreen(!_isFullscreen);
  }

  Future<void> _setFullscreen(bool value) async {
    if (_contextMenu.isOpen) _contextMenu.close();
    if (!widget.desktopWindow) return;
    try {
      _playerFocus.requestFocus();
      if (_nativeWindow && value) {
        _wasMaximizedBeforeFullscreen = await _leaveMaximizedState();
      }
      if (widget.fullscreenSetter case final setter?) {
        await setter(value);
      } else {
        await windowManager.setFullScreen(value);
      }
      if (_nativeWindow && !value && _wasMaximizedBeforeFullscreen) {
        _wasMaximizedBeforeFullscreen = false;
        await windowManager.maximize();
      }
      _syncFullscreen(value);
    } catch (_) {
      if (_nativeWindow && _wasMaximizedBeforeFullscreen) {
        _wasMaximizedBeforeFullscreen = false;
        try {
          await windowManager.maximize();
        } on Object {
          // Leave the window restored if maximizing fails.
        }
      }
      _showMessage('Fullscreen could not be changed.');
    }
  }

  /// window_manager keeps the native title bar when fullscreen starts from a
  /// maximized window, so start restored and re-maximize when fullscreen ends.
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

  void _showMessage(String message) {
    if (!mounted) return;
    AppToast.show(context, message, tone: AppToastTone.danger);
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: AppSpace.xs),
    color: context.palette.danger.withValues(alpha: 0.12),
    child: Row(
      children: [
        Icon(
          Icons.error_outline_rounded,
          color: context.palette.danger,
          size: 18,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: context.palette.secondaryText),
          ),
        ),
      ],
    ),
  );
}
