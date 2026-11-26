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
import '../../../domain/models/player_hotkeys.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/toast_layout.dart';
import '../../library/views/mini_player_bar.dart';
import '../player_controller.dart';
import '../widgets/queue_panel.dart';
import 'player_chrome_controller.dart';
import 'player_drag_drop.dart';
import 'player_embedded_library.dart';
import 'player_layout_manager.dart';
import 'player_media_coordinator.dart';
import 'player_stage.dart';

/// Where the in-app dock transition is committed to heading.
///
/// The dock controller is driven from two directions: screen state (is the
/// library showing?) and user intent (expand the mini player back to the
/// stage). Playback publishes structure changes at any moment — a queue edit,
/// a metadata refresh, a new track — and each one re-runs the screen-state
/// sync. Without an explicit destination that sync calls `forward()` while the
/// user's reverse is still running, which cancels the reverse's
/// `TickerFuture`: the completion callback never fires and the user is stranded
/// on the library with a mini player that re-docks itself.
///
/// [InAppDockDestination.player] is set by the return action and holds until
/// the parent confirms the player is showing again, so no playback update can
/// redirect it.
enum InAppDockDestination {
  /// Undocking: the stage expands back to the full player.
  player,

  /// Docking: the stage shrinks into the transport bar's artwork slot.
  miniPlayer,
}

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
  final Object _dockTransitionToken = Object();
  final Object _queueTransitionToken = Object();

  late final SpringMotionController _dockMotion = SpringMotionController(
    vsync: this,
    initialForward:
        widget.isShowingLibrary &&
        widget.controller.hasMedia &&
        widget.controller.isVideo,
    forwardSpring: AppMotion.dockSpring,
    reverseSpring: AppMotion.dockExpandSpring,
    tolerance: const Tolerance(distance: 0.0025, velocity: 0.015),
    onAnimatingChanged: (active) => widget.layoutManager
        .setLayoutTransitionActive(_dockTransitionToken, active),
  );

  bool _miniPlayerDismissed = false;
  late bool _libraryMounted =
      widget.isShowingLibrary || _dockMotion.value > 0.001;
  String? _lastVideoId;

  /// Destination the dock transition is committed to. See
  /// [InAppDockDestination] for why playback updates must not steer it.
  InAppDockDestination _dockDestination = InAppDockDestination.miniPlayer;

  Widget? _queuePanelCache;
  PlayerController? _queuePanelCacheController;
  Timer? _wheelResetTimer;
  double _wheelRemainder = 0;

  PlayerHotkeys get _hotkeys =>
      widget.appPreferences?.preferences.hotkeys ?? PlayerHotkeys.defaults;

  bool get _canInAppDockVideo =>
      widget.controller.hasMedia &&
      widget.controller.isVideo &&
      !_miniPlayerDismissed;

  /// A return to the player the user asked for is still animating.
  bool get _dockReturnInFlight =>
      _dockDestination == InAppDockDestination.player;

  void _syncInAppDockController() {
    // The user's return owns the transition until the parent confirms the
    // player is showing again. Re-docking here would cancel the reverse.
    if (_dockReturnInFlight) return;
    if (_canInAppDockVideo && widget.isShowingLibrary) {
      if (_dockMotion.value < 1.0 &&
          (!_dockMotion.targetForward || !_dockMotion.isAnimating)) {
        unawaited(_dockMotion.drive(true));
      }
      return;
    }
    if (_dockMotion.value != 0.0 || _dockMotion.isAnimating) {
      _dockMotion.snap(false);
    }
  }

  @override
  void initState() {
    super.initState();
    _lastVideoId = widget.controller.current?.id;
    widget.controller.structureListenable.addListener(_handlePlaybackChanges);
    widget.layoutManager.isInAppMiniPlayerActive = () => _canInAppDockVideo;
  }

  void _handlePlaybackChanges() {
    if (!mounted) return;
    final currentId = widget.controller.current?.id;
    final trackChanged = currentId != _lastVideoId;
    if (trackChanged) {
      _lastVideoId = currentId;
      final resetDismissed = _miniPlayerDismissed;
      _miniPlayerDismissed = false;
      if (resetDismissed) setState(() {});
    }
    final dockBefore = _dockMotion.value;
    _syncInAppDockController();
    widget.layoutManager.syncVideoVisibilityForLibrary();
    if (trackChanged || dockBefore != _dockMotion.value) {
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dockMotion.applyMotion(context);
    _syncInAppDockController();
  }

  @override
  void didUpdateWidget(covariant PlayerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.structureListenable.removeListener(
        _handlePlaybackChanges,
      );
      widget.controller.structureListenable.addListener(_handlePlaybackChanges);
      _miniPlayerDismissed = false;
    }
    if (oldWidget.layoutManager != widget.layoutManager) {
      oldWidget.layoutManager.setLayoutTransitionActive(
        _dockTransitionToken,
        false,
      );
      oldWidget.layoutManager.setLayoutTransitionActive(
        _queueTransitionToken,
        false,
      );
      if (_dockMotion.isAnimating) {
        widget.layoutManager.setLayoutTransitionActive(
          _dockTransitionToken,
          true,
        );
      }
    }
    widget.layoutManager.isInAppMiniPlayerActive = () => _canInAppDockVideo;

    if (widget.isShowingLibrary != oldWidget.isShowingLibrary) {
      // The screen-level destination moved, so whatever transition was in
      // flight has been superseded: re-dock for a fresh library, or let the
      // player-stage branch below run the expand.
      _dockDestination = InAppDockDestination.miniPlayer;
      if (widget.isShowingLibrary) {
        _syncInAppDockController();
      } else if (_canInAppDockVideo) {
        unawaited(_dockMotion.drive(false));
      } else {
        _dockMotion.snap(false);
      }
    }
  }

  @override
  void dispose() {
    widget.layoutManager.setLayoutTransitionActive(_dockTransitionToken, false);
    widget.layoutManager.setLayoutTransitionActive(
      _queueTransitionToken,
      false,
    );
    _dockMotion.dispose();
    widget.controller.structureListenable.removeListener(
      _handlePlaybackChanges,
    );
    _wheelResetTimer?.cancel();
    super.dispose();
  }

  void _returnToPlayerAnimated() {
    _miniPlayerDismissed = false;
    widget.layoutManager.syncVideoVisibilityForLibrary();
    final reduced = AppMotion.reduce(context);
    final atRest = !_dockMotion.isAnimating && _dockMotion.value <= 0.0;
    if (reduced || atRest) {
      _dockDestination = InAppDockDestination.miniPlayer;
      _dockMotion.snap(false);
      widget.onReturnToPlayer();
      return;
    }
    // Commit the destination before starting the reverse so a structure update
    // arriving mid-transition cannot re-dock the stage and cancel it.
    _dockDestination = InAppDockDestination.player;
    if (_dockMotion.isAnimating && !_dockMotion.targetForward) return;
    _dockMotion.drive(false).then((_) {
      if (!mounted || !_dockReturnInFlight || _dockMotion.targetForward) return;
      _dockDestination = InAppDockDestination.miniPlayer;
      widget.onReturnToPlayer();
    });
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
          onAddUrl: widget.media.addQueueUrl,
          enableNativeDrop: widget.enableNativeDrop,
          onFilesDropped: (paths) =>
              unawaited(widget.media.handleDroppedPaths(paths, append: true)),
        ),
      ),
    );
  }

  Widget _buildLibrary(MediaLibraryRepository repository) {
    return PlayerEmbeddedLibrary(
      repository: repository,
      controller: widget.controller,
      media: widget.media,
      chrome: widget.chrome,
      updates: widget.updates,
      engineUpdates: widget.engineUpdates,
      appPreferences: widget.appPreferences,
      libraryRepository: widget.libraryRepository,
      desktopIntegration: widget.desktopIntegration,
      draggingFiles: widget.draggingFiles,
      settingsOpen: widget.settingsOpen,
      onSettingsOpened: widget.onSettingsOpened,
      onSettingsClosed: widget.onSettingsClosed,
      onReturnToPlayerAnimated: _returnToPlayerAnimated,
    );
  }

  Widget _buildStage({
    double miniProgress = 0.0,
    Animation<double>? miniProgressAnimation,
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
      miniProgressAnimation: miniProgressAnimation,
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
      videoSettingsMounted: chrome.videoSettingsMounted,
      holdSpeedActive: chrome.holdSpeedActive,
      onCloseVideoSettings: chrome.closeVideoSettings,
      onVideoSettingsExitEnd: chrome.handleVideoSettingsExitEnd,
      onOpenFullSettings: widget.onSettingsOpened,
      appPreferences: widget.appPreferences,
      onPickSubtitle: widget.media.pickSubtitle,
      onSaveScreenshot: () => unawaited(widget.media.saveScreenshot()),
      onCopyUrl: () => unawaited(widget.media.copyCurrentUrl()),
      onShowInFolder: () => unawaited(widget.media.showCurrentInFolder()),
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

  Widget _buildLibraryDepthLayer({
    required Widget library,
    required double progress,
    required bool inFlight,
    required bool lowPower,
  }) {
    final depthScale = (inFlight && !lowPower)
        ? (0.988 + 0.012 * progress)
        : 1.0;
    final scrimAlpha = (inFlight && !lowPower)
        ? (0.22 * (1.0 - progress)).clamp(0.0, 0.22)
        : 0.0;

    return Transform.scale(
      scale: depthScale,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: const ValueKey('dock-library-content'),
            child: library,
          ),
          if (scrimAlpha > 0.001)
            Positioned.fill(
              key: const ValueKey('dock-library-scrim'),
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: scrimAlpha),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repository = widget.libraryRepository;
    if (widget.isShowingLibrary ||
        (_canInAppDockVideo && _dockMotion.value > 0.001)) {
      _libraryMounted = true;
    }
    final library = _libraryMounted && repository != null
        ? _buildLibrary(repository)
        : null;
    final lowPower = AppMotion.lowPower(context);

    // Built here, outside the queue slot's LayoutBuilder: the queue widens
    // its slot on every animation tick, which re-runs that builder with new
    // constraints. Building the stage inside it rebuilt the whole stage — video
    // surface, controls, top bar — on each of those ticks. Hoisting it leaves
    // the stage as a stable child that is only relaid out, not recomposed.
    final stage = _buildStage(
      miniProgressAnimation: _canInAppDockVideo ? _dockMotion.progress : null,
      onExpandFromMini: _returnToPlayerAnimated,
      onDismissMini: _dismissMiniPlayer,
    );
    final stageSurface = RepaintBoundary(child: stage);

    return PlayerQueueLayout(
      playerArea: PlayerDragDrop(
        enabled: widget.enableNativeDrop,
        onDragStateChanged: widget.onDragStateChanged,
        onFilesDropped: (paths) =>
            unawaited(widget.media.handleDroppedPaths(paths)),
        // Accent theming is applied once at the app root. A second scope
        // here rebuilt the whole stage on artwork extraction.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth = constraints.maxWidth;
            final totalHeight = constraints.maxHeight;

            // While the library is showing, the stage is mini or hidden and
            // these full-area constraints do not describe the video
            // viewport; the layout manager's own policy handles that case.
            if (!widget.isShowingLibrary) {
              widget.layoutManager.updateViewportDimensions(
                context,
                constraints,
              );
            }

            // Docked mini video seats in the transport bar's artwork slot so
            // the live video reads as part of the bar instead of overlapping
            // it.
            final fullRect = Rect.fromLTWH(0, 0, totalWidth, totalHeight);
            final miniRect = MiniPlayerBar.dockedVideoRect(
              totalHeight,
              MediaQuery.textScalerOf(context),
              dense: MediaQuery.sizeOf(context).height < 600,
            );

            return AnimatedBuilder(
              animation: Listenable.merge(<Listenable>[
                _dockMotion.progress,
                widget.controller.structureListenable,
              ]),
              child: stageSurface,
              builder: (context, cachedStage) {
                final t = _canInAppDockVideo
                    ? _dockMotion.value.clamp(0.0, 1.0)
                    : 0.0;
                final inFlight = _canInAppDockVideo && t > 0.0005 && t < 0.9995;
                final settledDocked = _canInAppDockVideo && t >= 0.9995;
                final currentRect = Rect.lerp(fullRect, miniRect, t)!;

                final showLibraryUnderneath =
                    library != null &&
                    (widget.isShowingLibrary ||
                        (_canInAppDockVideo && t > 0.001));
                final showVideoStage = _canInAppDockVideo
                    ? (!_miniPlayerDismissed || t < 0.999)
                    : !widget.isShowingLibrary;

                if (library == null) return cachedStage!;

                // Keep the Positioned box at fullRect across the entire flight
                // so the video stage and its children undergo zero layout passes
                // per frame; only the GPU matrix & rounded clip animate until
                // settling into miniRect once.
                final boxRect = settledDocked ? miniRect : fullRect;
                final double scale;
                final Offset translation;
                if (inFlight && totalWidth > 0 && totalHeight > 0) {
                  final aspect =
                      widget.controller.videoAspectRatio ?? (16.0 / 9.0);
                  final fullVideoH = math.min(totalHeight, totalWidth / aspect);
                  final curVideoH = math.min(
                    currentRect.height,
                    currentRect.width / aspect,
                  );
                  scale = fullVideoH > 0
                      ? (curVideoH / fullVideoH).clamp(0.01, 1.0)
                      : 1.0;
                  translation = currentRect.center - fullRect.center;
                } else {
                  scale = 1.0;
                  translation = Offset.zero;
                }
                final transform = inFlight
                    ? (Matrix4.identity()
                        ..setEntry(0, 0, scale)
                        ..setEntry(1, 1, scale)
                        ..setEntry(0, 3, translation.dx)
                        ..setEntry(1, 3, translation.dy))
                    : Matrix4.identity();
                final flightRadius = inFlight
                    ? math.sin(math.pi * t) * 10.0
                    : 0.0;

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    KeyedSubtree(
                      key: const ValueKey('dock-library-layer'),
                      child: Offstage(
                        offstage: !showLibraryUnderneath,
                        child: TickerMode(
                          enabled: showLibraryUnderneath,
                          child: _buildLibraryDepthLayer(
                            library: library,
                            progress: t,
                            inFlight: inFlight,
                            lowPower: lowPower,
                          ),
                        ),
                      ),
                    ),
                    if (showVideoStage && inFlight && !lowPower)
                      Positioned.fromRect(
                        key: const ValueKey('dock-video-shadow'),
                        rect: currentRect,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(flightRadius),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: 0.42 * math.sin(math.pi * t),
                                  ),
                                  blurRadius: 24,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (showVideoStage)
                      Positioned(
                        key: const ValueKey('dock-video-stage'),
                        left: boxRect.left,
                        top: boxRect.top,
                        width: boxRect.width,
                        height: boxRect.height,
                        child: ClipRRect(
                          clipper: inFlight
                              ? _DockRRectClipper(
                                  rect: currentRect,
                                  radius: flightRadius,
                                )
                              : null,
                          clipBehavior: inFlight ? Clip.antiAlias : Clip.none,
                          child: ColoredBox(
                            color: inFlight
                                ? AppTheme.stage
                                : Colors.transparent,
                            child: Transform(
                              alignment: Alignment.center,
                              transform: transform,
                              child: cachedStage,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
      queuePanel: _queuePanel(),
      showPlayerQueue: widget.chrome.queueOpen && !widget.isShowingLibrary,
      queueMounted: widget.chrome.queueMounted,
      onToggleQueue: widget.chrome.toggleQueue,
      onCloseQueue: widget.chrome.closeQueue,
      onQueueExitEnd: widget.chrome.handleQueueExitEnd,
      onMotionActiveChanged: (active) => widget.layoutManager
          .setLayoutTransitionActive(_queueTransitionToken, active),
    );
  }
}

class _DockRRectClipper extends CustomClipper<RRect> {
  const _DockRRectClipper({required this.rect, required this.radius});

  final Rect rect;
  final double radius;

  @override
  RRect getClip(Size size) =>
      RRect.fromRectAndRadius(rect, Radius.circular(radius));

  @override
  bool shouldReclip(covariant _DockRRectClipper oldClipper) =>
      oldClipper.rect != rect || oldClipper.radius != radius;
}
