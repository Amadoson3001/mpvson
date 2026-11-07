import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/open_request.dart';
import '../../../domain/models/player_hotkeys.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/components/media_accent_scope.dart';
import '../../core/toast/toast_layout.dart';
import '../../library/views/home_view.dart';
import '../../library/views/library_shell.dart';
import '../player_controller.dart';
import '../widgets/queue_panel.dart';
import 'player_chrome_controller.dart';
import 'player_drag_drop.dart';
import 'player_layout_manager.dart';
import 'player_media_coordinator.dart';
import 'player_stage.dart';
import 'settings_dialog.dart';

/// Player surface plus the inline/drawer queue, with the library shell layered
/// on top when it is showing.
///
/// Kept apart from `PlayerScreen` so the screen stays a composition root: this
/// widget owns the stage wiring and the cached queue panel, while the screen
/// owns timers, navigation flags and lifecycle.
class PlayerContent extends StatefulWidget {
  const PlayerContent({
    super.key,
    required this.controller,
    required this.chrome,
    required this.media,
    required this.layoutManager,
    required this.libraryRepository,
    required this.updates,
    required this.engineUpdates,
    required this.appPreferences,
    required this.desktopIntegration,
    required this.videoBuilder,
    required this.contextMenu,
    required this.videoSurfaceKey,
    required this.queuePanelKey,
    required this.queueFocusScope,
    required this.desktopWindow,
    required this.nativeWindow,
    required this.enableNativeDrop,
    required this.isShowingLibrary,
    required this.settingsOpen,
    required this.homeNavigationRequest,
    required this.draggingFiles,
    required this.onVideoTap,
    required this.onVideoDoubleTap,
    required this.onBackToHome,
    required this.onOpenLibrary,
    required this.onReturnToPlayer,
    required this.onSettingsOpened,
    required this.onSettingsClosed,
    required this.onDragStateChanged,
  });

  final PlayerController controller;
  final PlayerChromeController chrome;
  final PlayerMediaCoordinator media;
  final PlayerLayoutManager layoutManager;
  final MediaLibraryRepository? libraryRepository;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final AppPreferencesRepository? appPreferences;
  final DesktopIntegrationService? desktopIntegration;
  final PlayerVideoBuilder videoBuilder;
  final MenuController contextMenu;
  final GlobalKey videoSurfaceKey;
  final GlobalKey queuePanelKey;
  final FocusScopeNode queueFocusScope;
  final bool desktopWindow;
  final bool nativeWindow;
  final bool enableNativeDrop;
  final bool isShowingLibrary;
  final bool settingsOpen;
  final int homeNavigationRequest;
  final bool draggingFiles;

  final VoidCallback onVideoTap;
  final VoidCallback onVideoDoubleTap;
  final VoidCallback onBackToHome;
  final VoidCallback onOpenLibrary;
  final VoidCallback onReturnToPlayer;
  final VoidCallback onSettingsOpened;
  final VoidCallback onSettingsClosed;
  final ValueChanged<bool> onDragStateChanged;

  @override
  State<PlayerContent> createState() => _PlayerContentState();
}

class _PlayerContentState extends State<PlayerContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _miniPlayerController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    reverseDuration: const Duration(milliseconds: 260),
    value:
        (widget.isShowingLibrary &&
            widget.controller.hasMedia &&
            widget.controller.isVideo)
        ? 1.0
        : 0.0,
  );

  late final CurvedAnimation _miniPlayerCurved = CurvedAnimation(
    parent: _miniPlayerController,
    curve: Curves.easeInOutCubic,
    reverseCurve: Curves.easeInOutCubic,
  );

  bool _miniPlayerDismissed = false;
  String? _lastVideoId;

  Widget? _queuePanelCache;
  PlayerController? _queuePanelCacheController;
  Timer? _wheelResetTimer;
  double _wheelRemainder = 0;

  PlayerHotkeys get _hotkeys =>
      widget.appPreferences?.preferences.hotkeys ?? PlayerHotkeys.defaults;

  @override
  void initState() {
    super.initState();
    _lastVideoId = widget.controller.current?.id;
    widget.controller.addListener(_handlePlaybackChanges);
    widget.layoutManager.isInAppMiniPlayerActive = () =>
        !_miniPlayerDismissed &&
        widget.controller.hasMedia &&
        widget.controller.isVideo;
  }

  void _handlePlaybackChanges() {
    if (!mounted) return;
    final current = widget.controller.current;
    if (current?.id != _lastVideoId) {
      _lastVideoId = current?.id;
      _miniPlayerDismissed = false;
      widget.layoutManager.syncVideoVisibilityForLibrary();
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant PlayerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handlePlaybackChanges);
      widget.controller.addListener(_handlePlaybackChanges);
      _miniPlayerDismissed = false;
    }
    widget.layoutManager.isInAppMiniPlayerActive = () =>
        !_miniPlayerDismissed &&
        widget.controller.hasMedia &&
        widget.controller.isVideo;

    final isVideo = widget.controller.hasMedia && widget.controller.isVideo;
    if (widget.isShowingLibrary != oldWidget.isShowingLibrary) {
      if (widget.isShowingLibrary) {
        if (isVideo && !_miniPlayerDismissed) {
          if (AppMotion.reduce(context)) {
            _miniPlayerController.value = 1.0;
          } else {
            _miniPlayerController.forward();
          }
        } else {
          _miniPlayerController.value = 1.0;
        }
      } else {
        if (isVideo) {
          if (AppMotion.reduce(context)) {
            _miniPlayerController.value = 0.0;
          } else {
            _miniPlayerController.reverse();
          }
        } else {
          _miniPlayerController.value = 0.0;
        }
      }
    }
  }

  @override
  void dispose() {
    _miniPlayerCurved.dispose();
    _miniPlayerController.dispose();
    widget.controller.removeListener(_handlePlaybackChanges);
    _wheelResetTimer?.cancel();
    super.dispose();
  }

  void _returnToPlayerAnimated() {
    _miniPlayerDismissed = false;
    widget.layoutManager.syncVideoVisibilityForLibrary();
    if (AppMotion.reduce(context)) {
      _miniPlayerController.value = 0.0;
      widget.onReturnToPlayer();
    } else {
      _miniPlayerController.reverse().then((_) {
        if (mounted) {
          widget.onReturnToPlayer();
        }
      });
    }
  }

  void _dismissMiniPlayer() {
    setState(() {
      _miniPlayerDismissed = true;
    });
    widget.layoutManager.syncVideoVisibilityForLibrary();
  }

  Widget _queuePanel() {
    if (_queuePanelCacheController == widget.controller &&
        _queuePanelCache != null) {
      return _queuePanelCache!;
    }
    _queuePanelCacheController = widget.controller;
    return _queuePanelCache = ToastRegion(
      child: FocusScope(
        node: widget.queueFocusScope,
        child: QueuePanel(
          // One key for the one logical panel, so search text, focus and scroll
          // survive presentation changes and unrelated screen rebuilds.
          key: widget.queuePanelKey,
          controller: widget.controller,
          onClose: widget.chrome.toggleQueue,
          onQueueFocus: widget.chrome.setFocusedQueueEntry,
          onAddFiles: widget.media.addQueueFiles,
        ),
      ),
    );
  }

  Widget _buildLibrary(MediaLibraryRepository repository) {
    return LibraryShell(
      repository: repository,
      controller: widget.controller,
      initialSection: LibrarySection.home,
      homeNavigationRequest: widget.homeNavigationRequest,
      queueOpen: widget.chrome.queueOpen,
      onQueueOpenChanged: widget.chrome.setQueueOpen,
      home: HomeView(
        repository: repository,
        controller: widget.controller,
        recent: widget.controller.recent,
        onOpenFiles: widget.media.pickAndOpenFiles,
        onOpenUrl: widget.media.openUrl,
        onOpenRecent: widget.media.playRecent,
        onRemoveRecent: widget.media.removeRecent,
        onClearRecent: widget.media.clearRecent,
        isDragging: widget.draggingFiles,
      ),
      onOpenFiles: widget.media.pickAndOpenFiles,
      onOpenUrl: widget.media.openUrl,
      onAddQueueFiles: widget.media.addQueueFiles,
      onBackToPlayer: widget.controller.hasMedia && widget.controller.isVideo
          ? _returnToPlayerAnimated
          : null,
      onAddFolders: widget.media.addLibraryFolder,
      showSettings: widget.settingsOpen,
      onSettings: widget.onSettingsOpened,
      onCloseSettings: widget.onSettingsClosed,
      folders: LibraryFoldersView(repository: repository),
      settings: SettingsDialog(
        controller: widget.controller,
        updates: widget.updates,
        engineUpdates: widget.engineUpdates,
        pickSubtitle: widget.media.pickSubtitle,
        appPreferences: widget.appPreferences,
        libraryRepository: widget.libraryRepository,
        desktopIntegration: widget.desktopIntegration,
        embedded: true,
        onClose: widget.onSettingsClosed,
      ),
    );
  }

  Widget _buildStage({
    double miniProgress = 0.0,
    VoidCallback? onExpandFromMini,
    VoidCallback? onDismissMini,
  }) {
    final layout = widget.layoutManager;
    final chrome = widget.chrome;
    return PlayerStage(
      controller: widget.controller,
      videoBuilder: widget.videoBuilder,
      contextMenu: widget.contextMenu,
      videoSurfaceKey: widget.videoSurfaceKey,
      controlsFocusScope: chrome.controlsFocusScope,
      controlsVisible: chrome.controlsVisible,
      controlMenuOpen: chrome.controlMenuOpen,
      draggingFiles: widget.draggingFiles,
      feedbackLabel: chrome.feedbackLabel,
      feedbackIcon: chrome.feedbackIcon,
      feedbackProgress: chrome.feedbackProgress,
      feedbackCentered: chrome.feedbackCentered,
      isFullscreen: layout.isFullscreen,
      isMiniPlayer: layout.isMiniPlayer,
      queueOpen: chrome.queueOpen,
      desktopWindow: widget.desktopWindow,
      nativeWindow: widget.nativeWindow,
      hasLibraryRepository: widget.libraryRepository != null,
      hotkeys: _hotkeys,
      miniProgress: miniProgress,
      onExpandFromMini: onExpandFromMini,
      onDismissMini: onDismissMini,
      onPointerSignal: _handlePointerSignal,
      onVideoTap: widget.onVideoTap,
      onVideoDoubleTap: widget.onVideoDoubleTap,
      onControlsPointerEnter: chrome.controlsPointerEntered,
      onControlsPointerExit: chrome.controlsPointerExited,
      onMenuVisibilityChanged: chrome.handleMenuVisibility,
      onControlInteractionChanged: chrome.handleControlInteraction,
      onVolumeChanged: chrome.showVolumeFeedback,
      onBackToHome: widget.onBackToHome,
      onExitMiniPlayer: () => unawaited(layout.exitMiniPlayer()),
      onTopBarFocusChange: chrome.setBackButtonFocused,
      onOpenFiles: widget.media.pickAndOpenFiles,
      onOpenUrl: widget.media.openUrl,
      onOpenRecent: (MediaEntry entry) => widget.media.playRecent(entry),
      onToggleQueue: chrome.toggleQueue,
      onSettings: ({bool showMediaLibrary = false}) =>
          widget.media.showSettings(
            showMediaLibrary: showMediaLibrary,
            onOpenSettingsView: widget.onSettingsOpened,
            onToggleVideoSettings: chrome.toggleVideoSettings,
          ),
      onPlaybackInfo: widget.media.showPlaybackInfo,
      onOpenLibrary: widget.libraryRepository != null
          ? widget.onOpenLibrary
          : null,
      onFullscreen: widget.desktopWindow
          ? () => unawaited(layout.toggleFullscreen())
          : null,
      onToggleMiniPlayer: widget.nativeWindow
          ? () => unawaited(layout.toggleMiniPlayer())
          : null,
      onLoadSubtitle: widget.media.loadSubtitle,
      onToggleMute: _toggleMute,
      onAdjustVolume: _adjustVolume,
      onUpdateViewportDimensions: layout.updateViewportDimensions,
      videoSettingsOpen: chrome.videoSettingsOpen,
      onCloseVideoSettings: chrome.closeVideoSettings,
      onOpenFullSettings: widget.onSettingsOpened,
      appPreferences: widget.appPreferences,
      onPickSubtitle: widget.media.pickSubtitle,
    );
  }

  void _adjustVolume(double delta) {
    unawaited(widget.controller.adjustVolume(delta));
    widget.chrome.showVolumeFeedback(widget.controller.volume);
  }

  void _toggleMute() {
    unawaited(widget.controller.toggleMute());
    widget.chrome.showVolumeFeedback(widget.controller.volume);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    final chrome = widget.chrome;
    if (chrome.contextMenu.isOpen) chrome.contextMenu.close();
    final controller = widget.controller;
    if (event is! PointerScrollEvent ||
        !controller.hasMedia ||
        event.scrollDelta.dy == 0 ||
        event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs()) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
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

  @override
  Widget build(BuildContext context) {
    final repository = widget.libraryRepository;
    final library = repository == null ? null : _buildLibrary(repository);
    final isVideo = widget.controller.hasMedia && widget.controller.isVideo;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final totalHeight = constraints.maxHeight;

        // While the library is showing, the stage is mini or hidden and these
        // full-area constraints do not describe the video viewport; the
        // layout manager's own policy handles that case.
        if (!widget.isShowingLibrary) {
          widget.layoutManager.updateViewportDimensions(context, constraints);
        }

        // Docked mini player rect: seated in the bottom bar next to the track name
        const miniWidth = AppLayout.dockedMiniVideoWidth;
        const miniHeight = AppLayout.dockedMiniVideoHeight;
        const miniLeft = 16.0;
        final miniTop = math.max(0.0, totalHeight - 79.0);

        final fullRect = Rect.fromLTWH(0, 0, totalWidth, totalHeight);
        final miniRect = Rect.fromLTWH(
          miniLeft,
          miniTop,
          miniWidth,
          miniHeight,
        );

        return AnimatedBuilder(
          animation: _miniPlayerCurved,
          builder: (context, _) {
            final t = _miniPlayerCurved.value;
            final currentRect = Rect.lerp(fullRect, miniRect, t)!;

            final showLibraryUnderneath =
                library != null && (widget.isShowingLibrary || t > 0.001);
            final showVideoStage = isVideo
                ? (!_miniPlayerDismissed || t < 0.999)
                : !widget.isShowingLibrary;

            final Widget stage = _buildStage(
              miniProgress: t,
              onExpandFromMini: _returnToPlayerAnimated,
              onDismissMini: _dismissMiniPlayer,
            );

            Widget mainStack;
            if (library == null) {
              mainStack = stage;
            } else {
              mainStack = Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: !showLibraryUnderneath,
                    child: TickerMode(
                      enabled: showLibraryUnderneath,
                      child: library,
                    ),
                  ),
                  if (showVideoStage)
                    Positioned(
                      left: currentRect.left,
                      top: currentRect.top,
                      width: currentRect.width,
                      height: currentRect.height,
                      child: RepaintBoundary(child: stage),
                    ),
                ],
              );
            }

            final contentArea = MediaAccentScope(
              controller: widget.controller,
              child: mainStack,
            );

            return PlayerQueueLayout(
              playerArea: PlayerDragDrop(
                enabled: widget.enableNativeDrop,
                onDragStateChanged: widget.onDragStateChanged,
                onFilesDropped: (paths) => unawaited(
                  widget.media.openPaths(paths, origin: OpenOrigin.dragAndDrop),
                ),
                child: contentArea,
              ),
              queuePanel: _queuePanel(),
              showPlayerQueue:
                  widget.chrome.queueOpen && !widget.isShowingLibrary,
              queueMounted: widget.chrome.queueMounted,
              onToggleQueue: widget.chrome.toggleQueue,
              onCloseQueue: widget.chrome.closeQueue,
              onQueueExitEnd: widget.chrome.handleQueueExitEnd,
            );
          },
        );
      },
    );
  }
}
