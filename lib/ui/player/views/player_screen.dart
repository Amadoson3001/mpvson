import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/open_request_coordinator.dart';
import '../../../data/services/update_service.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/player_hotkeys.dart';
import '../../core/app_motion.dart';
import '../../core/toast/app_toast.dart';
import '../player_controller.dart';
import 'player_chrome_controller.dart';
import 'player_content.dart';
import 'player_error_banner.dart';
import 'player_hotkey_handler.dart';
import 'player_layout_manager.dart';
import 'player_library_navigation.dart';
import 'player_media_coordinator.dart';

export 'player_drag_drop.dart';
export 'player_error_banner.dart';
export 'player_hotkey_handler.dart';
export 'player_layout_manager.dart';
export 'player_queue_layout.dart';
export 'player_stage.dart';
export 'player_top_bar.dart';

typedef PlayerVideoBuilder =
    Widget Function(BuildContext context, PlayerController controller);
typedef MediaFilePicker = Future<List<String>> Function();
typedef SubtitleFilePicker = Future<String?> Function();
typedef UrlPrompt = Future<String?> Function(BuildContext context);

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
    with WidgetsBindingObserver {
  late final PlayerLayoutManager _layoutManager;
  late final PlayerHotkeyHandler _hotkeyHandler;
  late final PlayerChromeController _chrome;
  late final PlayerMediaCoordinator _media;
  late final PlayerLibraryNavigation _navigation;

  final FocusNode _playerFocus = FocusNode(debugLabel: 'Player screen');
  final MenuController _contextMenu = MenuController();
  final GlobalKey _videoSurfaceKey = GlobalKey();
  final GlobalKey _queuePanelKey = GlobalKey();

  bool _draggingFiles = false;
  String? _lastVideoEntryId;
  String? _preparedPausedVideoId;

  bool get _nativeWindow =>
      widget.desktopWindow && widget.fullscreenSetter == null;

  PlayerHotkeys get _hotkeys =>
      widget.appPreferences?.preferences.hotkeys ?? PlayerHotkeys.defaults;

  void _closeContextMenu() {
    if (_contextMenu.isOpen) _contextMenu.close();
  }

  @override
  void initState() {
    super.initState();
    _chrome = PlayerChromeController(
      contextMenu: _contextMenu,
      playerFocus: _playerFocus,
      isFullscreen: () => _layoutManager.isFullscreen,
      reduceMotion: () => AppMotion.reduce(context),
      getAutoHideDelaySeconds: () =>
          widget.appPreferences?.preferences.playerControls.autoHideDelaySeconds ?? 2.8,
    )..addListener(_onVisualStateChanged);

    _navigation = PlayerLibraryNavigation(
      controller: widget.controller,
      hasLibraryRepository: widget.libraryRepository != null,
      onExitMiniPlayer: () {
        if (_layoutManager.isMiniPlayer) {
          unawaited(_layoutManager.exitMiniPlayer());
        }
      },
      onVisibilityChanged: () => _layoutManager.syncVideoVisibilityForLibrary(),
    )..addListener(_onVisualStateChanged);

    _media = PlayerMediaCoordinator(
      getContext: () => context,
      controller: widget.controller,
      updates: widget.updates,
      engineUpdates: widget.engineUpdates,
      openCoordinator: widget.openCoordinator,
      mediaPicker: widget.mediaPicker,
      subtitlePicker: widget.subtitlePicker,
      urlPrompt: widget.urlPrompt,
      libraryRepository: widget.libraryRepository,
      appPreferences: widget.appPreferences,
      desktopIntegration: widget.desktopIntegration,
      showMessage: _showMessage,
      withControlsVisible: _chrome.withControlsVisible,
      onCloseContextMenu: _closeContextMenu,
      onOpenLibrary: _navigation.openLibrary,
      onClearFocusedQueueEntry: _chrome.clearFocusedQueueEntry,
    );

    _layoutManager = PlayerLayoutManager(
      controller: widget.controller,
      desktopWindow: widget.desktopWindow,
      fullscreenSetter: widget.fullscreenSetter,
      isShowingLibrary: () => _navigation.isShowingLibrary,
      showMessage: _showMessage,
      showFeedback: _chrome.showFeedback,
      onControlsNeedsVisibility: _chrome.showControls,
      onCloseContextMenu: _closeContextMenu,
      onCancelHeldSpeed: () => _hotkeyHandler.cancelHeldSpeed(),
      onSyncFullscreen: _handleSyncFullscreen,
      onMiniPlayerChanged: (mini) {
        if (mounted) _chrome.showControls();
      },
      playerFocus: _playerFocus,
      libraryRepository: widget.libraryRepository,
    )..init();
    _layoutManager.addListener(_onLayoutChanged);

    _hotkeyHandler = PlayerHotkeyHandler(
      controller: widget.controller,
      getHotkeys: () => _hotkeys,
      isQueueOpen: () => _chrome.queueOpen,
      isContextMenuOpen: () => _contextMenu.isOpen,
      isFullscreen: () => _layoutManager.isFullscreen,
      isDesktopWindow: widget.desktopWindow,
      isNativeWindow: _nativeWindow,
      hasLibraryRepository: widget.libraryRepository != null,
      getSeekStepSeconds: () =>
          widget.appPreferences?.preferences.seekStepSeconds ?? 5,
      getFocusedQueueEntryId: () => _chrome.focusedQueueEntryId,
      isControlsFocusActive: () => _chrome.controlsFocusScope.hasFocus,
      isQueueFocusActive: () => _chrome.queueFocusScope.hasFocus,
      isInsidePlayer: (context) =>
          context.findAncestorWidgetOfExactType<PlayerScreen>() != null,
      onCloseContextMenu: _closeContextMenu,
      onCloseQueue: _chrome.closeQueue,
      onToggleQueue: _chrome.toggleQueue,
      onOpenContextMenu: _openKeyboardContextMenu,
      onToggleFullscreen: () => unawaited(_layoutManager.toggleFullscreen()),
      onSetFullscreen: _layoutManager.setFullscreen,
      onToggleMiniPlayer: () => unawaited(_layoutManager.toggleMiniPlayer()),
      onOpenFiles: () => unawaited(_media.pickAndOpenFiles()),
      onOpenUrl: () => unawaited(_media.openUrl()),
      onOpenLibrary: _navigation.openLibrary,
      onRemoveQueueEntry: _media.removeQueueEntryById,
      onAdjustVolume: _adjustVolume,
      onToggleMute: _toggleMute,
      onAdjustDelay: _adjustPlaybackDelay,
      onShowPlaybackInfo: () => unawaited(_media.showPlaybackInfo()),
      onShowControls: _chrome.showControls,
    );

    if (widget.controller.isVideo) {
      _lastVideoEntryId = widget.controller.current?.id;
    }
    widget.controller.addListener(_handleControllerChange);
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_hotkeyHandler.handlePrimaryFocusChange);
    HardwareKeyboard.instance.addHandler(_chrome.recordKeyboardInput);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _chrome.showControls();
        _preparePausedVideo();
      }
    });
  }

  void _onVisualStateChanged() {
    if (mounted) setState(() {});
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  void _handleSyncFullscreen(bool isFullscreen) {
    _chrome.handleFullscreen(isFullscreen);
    if (mounted) _chrome.showControls();
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      widget.controller.addListener(_handleControllerChange);
    }
    _media
      ..controller = widget.controller
      ..updates = widget.updates
      ..engineUpdates = widget.engineUpdates
      ..openCoordinator = widget.openCoordinator
      ..mediaPicker = widget.mediaPicker
      ..subtitlePicker = widget.subtitlePicker
      ..urlPrompt = widget.urlPrompt
      ..libraryRepository = widget.libraryRepository
      ..appPreferences = widget.appPreferences
      ..desktopIntegration = widget.desktopIntegration;
    _navigation
      ..controller = widget.controller
      ..hasLibraryRepository = widget.libraryRepository != null;
    _layoutManager.updateDependencies(
      controller: widget.controller,
      desktopWindow: widget.desktopWindow,
      fullscreenSetter: widget.fullscreenSetter,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(
      _hotkeyHandler.handlePrimaryFocusChange,
    );
    HardwareKeyboard.instance.removeHandler(_chrome.recordKeyboardInput);
    widget.controller.removeListener(_handleControllerChange);
    _chrome.removeListener(_onVisualStateChanged);
    _navigation.removeListener(_onVisualStateChanged);
    _navigation.dispose();
    _playerFocus.dispose();
    _layoutManager.removeListener(_onLayoutChanged);
    _layoutManager.dispose();
    _hotkeyHandler.dispose();
    _chrome.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _hotkeyHandler.cancelHeldSpeed();
      _closeContextMenu();
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _layoutManager.handleMinimize();
    } else if (state == AppLifecycleState.resumed) {
      _layoutManager.handleRestore();
    }
  }

  @override
  void didHaveMemoryPressure() {
    widget.controller.trimMemory();
    unawaited(widget.libraryRepository?.shrinkMemory());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  @override
  void didChangeMetrics() {
    _layoutManager.didChangeMetrics();
  }

  void _handleControllerChange() {
    if (!mounted) return;
    final current = widget.controller.current;
    if (current != null &&
        widget.controller.hasMedia &&
        widget.controller.isVideo &&
        current.id != _lastVideoEntryId) {
      _lastVideoEntryId = current.id;
      _preparedPausedVideoId = current.id;
      _navigation.hideLibrary();
    }
    if (_layoutManager.isMiniPlayer) {
      final audioEntry =
          current == null ||
          widget.controller.isAudio ||
          MediaCatalog.kindFromExtension(current.path).isAudio;
      if (audioEntry) unawaited(_layoutManager.exitMiniPlayer());
    }
    if (_chrome.hideBlocked) {
      _chrome.showControls();
    } else {
      _chrome.scheduleHide();
    }
    if (!widget.controller.isStopped) {
      _preparePausedVideo();
    }
    _layoutManager.syncVideoVisibilityForLibrary();
  }

  void _preparePausedVideo() {
    if (!mounted || _navigation.isShowingLibrary) return;
    final controller = widget.controller;
    final current = controller.current;
    if (current == null ||
        controller.hasMedia ||
        controller.isLoading ||
        controller.isStopped) {
      return;
    }
    if (!MediaCatalog.kindFromExtension(current.path).isVideo) return;
    if (_preparedPausedVideoId == current.id) return;
    _preparedPausedVideoId = current.id;
    unawaited(controller.prepareCurrentPaused());
  }

  void _backToHome() {
    _closeContextMenu();
    final wasFullscreen = _layoutManager.isFullscreen;
    _chrome.dismissQueue();
    if (widget.controller.isStopped || !widget.controller.hasMedia) {
      unawaited(widget.controller.closePlayer());
    }
    _navigation.backToHome();
    if (wasFullscreen) unawaited(_layoutManager.setFullscreen(false));
  }

  void _returnToPlayer() {
    _navigation.returnToPlayer(widget.controller.current?.id);
    _preparePausedVideo();
  }

  void _adjustVolume(double delta) {
    unawaited(widget.controller.adjustVolume(delta));
    _chrome.showVolumeFeedback(widget.controller.volume);
  }

  void _toggleMute() {
    unawaited(widget.controller.toggleMute());
    _chrome.showVolumeFeedback(widget.controller.volume);
  }

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
    _chrome.showFeedback(
      audio ? Icons.graphic_eq_rounded : Icons.closed_caption_rounded,
      '${audio ? 'Audio' : 'Subtitle'} delay $suffix$boundedMs ms',
      centered: true,
    );
    await widget.controller.setPlaybackSettings(updated);
    if (mounted && widget.controller.playbackSettingsError != null) {
      _showMessage('The playback engine did not accept the delay change.');
    }
  }

  void _toggleVideoPlayback() {
    if (_chrome.dismissedContextMenuOnPointerDown || _contextMenu.isOpen) {
      _chrome.clearDismissedContextMenu();
      _closeContextMenu();
      return;
    }
    if (widget.controller.current == null) return;
    _playerFocus.requestFocus();
    final wasPlaying = widget.controller.isPlaying;
    unawaited(widget.controller.togglePlayPause());
    _chrome.showFeedback(
      wasPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      wasPlaying ? 'Paused' : 'Playing',
      centered: true,
    );
    _chrome.showControls();
  }

  void _openKeyboardContextMenu() {
    final box = _videoSurfaceKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    _contextMenu.open(position: box.size.center(Offset.zero));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    AppToast.show(context, message, tone: AppToastTone.danger);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TickerMode(
        enabled: !_layoutManager.animationsSuspended,
        child: Focus(
          focusNode: _playerFocus,
          autofocus: true,
          onKeyEvent: _hotkeyHandler.handleKey,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _chrome.markPointerInput,
            onPointerUp: _chrome.markPointerUp,
            onPointerCancel: _chrome.markPointerCancel,
            child: MouseRegion(
              onHover: _chrome.pointerActivity,
              onExit: _chrome.pointerLeft,
              child: AnimatedBuilder(
                animation: widget.controller.structureListenable,
                builder: (context, _) => Column(
                  children: [
                    Expanded(
                      child: PlayerContent(
                        controller: widget.controller,
                        chrome: _chrome,
                        media: _media,
                        layoutManager: _layoutManager,
                        libraryRepository: widget.libraryRepository,
                        updates: widget.updates,
                        engineUpdates: widget.engineUpdates,
                        appPreferences: widget.appPreferences,
                        desktopIntegration: widget.desktopIntegration,
                        videoBuilder: widget.videoBuilder,
                        contextMenu: _contextMenu,
                        videoSurfaceKey: _videoSurfaceKey,
                        queuePanelKey: _queuePanelKey,
                        queueFocusScope: _chrome.queueFocusScope,
                        desktopWindow: widget.desktopWindow,
                        nativeWindow: _nativeWindow,
                        enableNativeDrop: widget.enableNativeDrop,
                        isShowingLibrary: _navigation.isShowingLibrary,
                        settingsOpen: _navigation.settingsOpen,
                        homeNavigationRequest:
                            _navigation.homeNavigationRequest,
                        draggingFiles: _draggingFiles,
                        onVideoTap: _toggleVideoPlayback,
                        onVideoDoubleTap: () {
                          if (_layoutManager.isMiniPlayer) {
                            unawaited(_layoutManager.exitMiniPlayer());
                          } else {
                            unawaited(_layoutManager.toggleFullscreen());
                          }
                        },
                        onBackToHome: _backToHome,
                        onOpenLibrary: _navigation.openLibrary,
                        onReturnToPlayer: _returnToPlayer,
                        onSettingsOpened: _navigation.openSettings,
                        onSettingsClosed: () => _navigation.setSettingsOpen(false),
                        onDragStateChanged: (dragging) => setState(() => _draggingFiles = dragging),
                      ),
                    ),
                    if (widget.controller.error case final error?)
                      PlayerErrorBanner(message: error),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
