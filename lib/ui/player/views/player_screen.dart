import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../../domain/models/media_entry.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../../data/services/playback_statistics.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
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

typedef PlayerVideoBuilder =
    Widget Function(BuildContext context, PlayerController controller);
typedef MediaFilePicker = Future<List<String>> Function();
typedef SubtitleFilePicker = Future<String?> Function();
typedef UrlPrompt = Future<String?> Function(BuildContext context);
typedef FullscreenSetter = Future<void> Function(bool fullscreen);

const double _wideQueuePanelWidth = 352;

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
  });

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

  bool get _nativeWindow =>
      widget.desktopWindow && widget.fullscreenSetter == null;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChange);
    _controlsFocusScope.addListener(_handleControlFocusChange);
    _queueFocusScope.addListener(_handleQueueFocusChange);
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_handlePrimaryFocusChange);
    HardwareKeyboard.instance.addHandler(_recordKeyboardInput);
    if (_nativeWindow) windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showControls();
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
    if (_hideBlocked) {
      _controlsTimer?.cancel();
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    } else {
      _scheduleControlsHide();
    }
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
    widget.controller.thumbnails?.suspend();
    _updateVideoOutputPolicy(visible: false);
    if (mounted) setState(() {});
  }

  void _handleRestore() {
    if (!_minimized) return;
    _minimized = false;
    _animationsSuspended = false;
    widget.controller.thumbnails?.resume();
    _updateVideoOutputPolicy(visible: true);
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
    _cancelHeldSpeed();
    if (_contextMenu.isOpen) _contextMenu.close();
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

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    // A held playback shortcut must unwind even if the focus changed before
    // the release. Fresh typing inside a text field remains untouched.
    if (key == LogicalKeyboardKey.space && event is KeyUpEvent && _spaceHeld) {
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
    if (key == LogicalKeyboardKey.space && _controlsFocusScope.hasFocus) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.space) {
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

    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        unawaited(widget.controller.seekRelative(const Duration(seconds: -5)));
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        unawaited(widget.controller.seekRelative(const Duration(seconds: 5)));
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        _adjustVolume(5);
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (_sliderFocused || queueOwnsFocus) return KeyEventResult.ignored;
        _adjustVolume(-5);
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyP:
        _toggleQueue();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyI:
        if (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        unawaited(_showPlaybackInfo());
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        if (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        _toggleMute();
        return KeyEventResult.handled;
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
      case LogicalKeyboardKey.keyF:
        if (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        if (widget.desktopWindow) {
          unawaited(_toggleFullscreen());
          return KeyEventResult.handled;
        }
        break;
      case LogicalKeyboardKey.escape:
        if (_contextMenu.isOpen) {
          _contextMenu.close();
          return KeyEventResult.handled;
        }
        if (_queueOpen) {
          _closeQueuePanel();
          return KeyEventResult.handled;
        }
        if (_isFullscreen) {
          unawaited(_setFullscreen(false));
          return KeyEventResult.handled;
        }
        break;
      default:
        break;
    }
    return KeyEventResult.ignored;
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
                  animation: widget.controller,
                  builder: (context, _) => Column(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final inlineQueue =
                                constraints.maxWidth >= 1100 && _queueOpen;
                            final narrowDrawer =
                                constraints.maxWidth < 1100 && _queueOpen;
                            return Stack(
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: _buildPlayerArea()),
                                    if (constraints.maxWidth >= 1100)
                                      AnimatedContainer(
                                        width: inlineQueue
                                            ? _wideQueuePanelWidth
                                            : 0,
                                        decoration: const BoxDecoration(),
                                        duration: AppMotion.duration(
                                          context,
                                          AppMotion.standard,
                                        ),
                                        curve: AppMotion.standardCurve,
                                        clipBehavior: Clip.hardEdge,
                                        onEnd: _handleQueueExitEnd,
                                        child: _queueMounted || inlineQueue
                                            ? ClipRect(
                                                child: OverflowBox(
                                                  alignment:
                                                      Alignment.centerRight,
                                                  minWidth:
                                                      _wideQueuePanelWidth,
                                                  maxWidth:
                                                      _wideQueuePanelWidth,
                                                  child: TweenAnimationBuilder<double>(
                                                    tween: Tween<double>(
                                                      begin: 0,
                                                      end: inlineQueue ? 1 : 0,
                                                    ),
                                                    duration:
                                                        AppMotion.duration(
                                                          context,
                                                          AppMotion.standard,
                                                        ),
                                                    curve:
                                                        AppMotion.standardCurve,
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
                                                              (1 - progress) *
                                                                  16,
                                                              0,
                                                            ),
                                                            child: child,
                                                          );
                                                        },
                                                    child: IgnorePointer(
                                                      ignoring: !inlineQueue,
                                                      child: ExcludeSemantics(
                                                        excluding: !inlineQueue,
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
                                    (_queueMounted || narrowDrawer)) ...[
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
                                            color: AppTheme.background
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
        ),
      );
    } else if (!widget.controller.hasMedia) {
      contentState = 'ready';
      content = Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            widget.controller.positionListenable,
            widget.controller.durationListenable,
            widget.controller.bufferingListenable,
          ]),
          builder: (context, _) => MediaReady(
            entry: widget.controller.current ?? current,
            position: widget.controller.position,
            duration: widget.controller.duration,
            isOpening: widget.controller.isBuffering,
            onPlay: () => unawaited(widget.controller.togglePlayPause()),
          ),
        ),
      );
    } else {
      contentState = 'video';
      content = ColoredBox(
        color: AppTheme.background,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _updateViewportDimensions(context, constraints);
            return widget.videoBuilder(context, widget.controller);
          },
        ),
      );
    }
    final stage = Stack(
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
          isFullscreen: _isFullscreen,
          queueOpen: _queueOpen,
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
                onTap: widget.controller.hasMedia ? _toggleVideoPlayback : null,
                onDoubleTap: widget.desktopWindow ? _toggleFullscreen : null,
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
                    return FadeTransition(
                      opacity: transition,
                      child: ScaleTransition(
                        scale: Tween<double>(
                          begin: 0.985,
                          end: 1,
                        ).animate(transition),
                        child: child,
                      ),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey<String>('player-content-$contentState'),
                    child: content,
                  ),
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
                padding: const EdgeInsets.all(24),
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
                  color: AppTheme.background.withValues(alpha: 0.6),
                  border: Border.all(color: AppTheme.accent, width: 2),
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
                    child: PlayerControls(
                      controller: widget.controller,
                      onMenuVisibilityChanged: _handleMenuVisibility,
                      onInteractionChanged: _handleControlInteraction,
                      onVolumeChanged: _showVolumeFeedback,
                      showPlaybackControls: widget.controller.hasMedia,
                      actions: PlayerActions(
                        controller: widget.controller,
                        onOpenFiles: _openFiles,
                        onOpenUrl: _openUrl,
                        onOpenRecent: _playRecent,
                        onToggleQueue: _toggleQueue,
                        onSettings: _showSettings,
                        onPlaybackInfo: _showPlaybackInfo,
                        onMenuVisibilityChanged: _handleMenuVisibility,
                        queueOpen: _queueOpen,
                        isFullscreen: _isFullscreen,
                        onFullscreen: widget.desktopWindow
                            ? _toggleFullscreen
                            : null,
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
    if (!widget.enableNativeDrop) return stage;
    return DropTarget(
      onDragEntered: (_) => setState(() => _draggingFiles = true),
      onDragExited: (_) => setState(() => _draggingFiles = false),
      onDragDone: (details) {
        setState(() => _draggingFiles = false);
        final paths = details.files
            .map((file) => file.path)
            .where((path) => path.isNotEmpty)
            .toList();
        unawaited(_openPaths(paths, append: widget.controller.hasMedia));
      },
      child: stage,
    );
  }

  Widget _queuePanel({required VoidCallback onClose}) {
    if (_queuePanelCacheController == widget.controller &&
        _queuePanelCache != null) {
      return _queuePanelCache!;
    }
    _queuePanelCacheController = widget.controller;
    return _queuePanelCache = FocusScope(
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
    const videoTypes = XTypeGroup(
      label: 'Video files',
      extensions: [
        '3gp',
        'avi',
        'flv',
        'm2ts',
        'm4v',
        'mkv',
        'mov',
        'mp4',
        'mpeg',
        'mpg',
        'mts',
        'ogg',
        'ogv',
        'ts',
        'webm',
        'wmv',
      ],
    );
    final files = await openFiles(acceptedTypeGroups: [videoTypes]);
    return files
        .map((file) => file.path)
        .where((path) => path.isNotEmpty)
        .toList();
  }

  Future<void> _openPaths(List<String> paths, {bool append = false}) async {
    if (paths.isEmpty) return;
    try {
      await widget.controller.openPaths(paths, append: append);
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

  Future<void> _playRecent(MediaEntry entry) => _openPaths([entry.path]);

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
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Removed from queue'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: widget.controller.undoRemove,
            ),
          ),
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

  Future<void> _showSettings() async {
    if (_contextMenu.isOpen) _contextMenu.close();
    await _withControlsVisible(
      () => showDialog<void>(
        context: context,
        builder: (_) => SettingsDialog(
          controller: widget.controller,
          updates: widget.updates,
          engineUpdates: widget.engineUpdates,
          pickSubtitle: _pickSubtitle,
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

  Future<void> _toggleFullscreen() => _setFullscreen(!_isFullscreen);

  Future<void> _setFullscreen(bool value) async {
    if (_contextMenu.isOpen) _contextMenu.close();
    if (!widget.desktopWindow) return;
    try {
      _playerFocus.requestFocus();
      if (widget.fullscreenSetter case final setter?) {
        await setter(value);
      } else {
        await windowManager.setFullScreen(value);
      }
      _syncFullscreen(value);
    } catch (_) {
      _showMessage('Fullscreen could not be changed.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
    color: AppTheme.danger.withValues(alpha: 0.12),
    child: Row(
      children: [
        const Icon(
          Icons.error_outline_rounded,
          color: AppTheme.danger,
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
            ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
          ),
        ),
      ],
    ),
  );
}
