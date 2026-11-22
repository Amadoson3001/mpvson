import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../domain/models/media_entry.dart';
import '../../../domain/models/player_hotkeys.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/toast_layout.dart';
import '../player_controller.dart';
import '../widgets/playback_feedback.dart';
import '../widgets/player_actions.dart';
import '../widgets/player_context_menu.dart';
import '../widgets/player_controls.dart';
import '../widgets/player_stage_media.dart';
import 'player_drag_drop.dart';
import 'player_top_bar.dart';
import '../../../../data/repositories/app_preferences_repository.dart';
import 'mini_player_overlay.dart';
import 'player_loading_overlay.dart';
import 'settings/floating_video_settings.dart';

typedef PlayerVideoBuilder =
    Widget Function(BuildContext context, PlayerController controller);

class PlayerStage extends StatelessWidget {
  const PlayerStage({
    super.key,
    required this.controller,
    required this.videoBuilder,
    required this.contextMenu,
    required this.videoSurfaceKey,
    required this.controlsFocusScope,
    required this.controlsVisible,
    required this.controlMenuOpen,
    required this.draggingFiles,
    required this.feedbackLabel,
    required this.feedbackIcon,
    required this.feedbackProgress,
    required this.feedbackCentered,
    required this.isFullscreen,
    required this.isMiniPlayer,
    required this.queueOpen,
    required this.desktopWindow,
    required this.nativeWindow,
    required this.hasLibraryRepository,
    required this.hotkeys,
    required this.onPointerSignal,
    required this.onVideoTap,
    required this.onVideoDoubleTap,
    required this.onControlsPointerEnter,
    required this.onControlsPointerExit,
    required this.onMenuVisibilityChanged,
    required this.onControlInteractionChanged,
    required this.onVolumeChanged,
    required this.onBackToHome,
    required this.onExitMiniPlayer,
    required this.onTopBarFocusChange,
    required this.onOpenFiles,
    required this.onOpenUrl,
    required this.onOpenRecent,
    required this.onToggleQueue,
    required this.onSettings,
    required this.onPlaybackInfo,
    required this.onOpenLibrary,
    required this.onFullscreen,
    required this.onToggleMiniPlayer,
    required this.onLoadSubtitle,
    required this.onToggleMute,
    required this.onAdjustVolume,
    required this.onUpdateViewportDimensions,
    this.videoSettingsOpen = false,
    this.videoSettingsMounted = false,
    this.holdSpeedActive = false,
    this.miniProgress = 0.0,
    this.miniProgressAnimation,
    this.onExpandFromMini,
    this.onDismissMini,
    this.onCloseVideoSettings,
    this.onVideoSettingsExitEnd,
    this.onOpenFullSettings,
    this.appPreferences,
    this.onPickSubtitle,
    this.onSaveScreenshot,
    this.onCopyUrl,
    this.onShowInFolder,
  });

  final PlayerController controller;
  final PlayerVideoBuilder videoBuilder;
  final MenuController contextMenu;
  final GlobalKey videoSurfaceKey;
  final FocusScopeNode controlsFocusScope;
  final bool controlsVisible;
  final bool controlMenuOpen;
  final bool draggingFiles;
  final String? feedbackLabel;
  final IconData feedbackIcon;
  final double? feedbackProgress;
  final bool feedbackCentered;
  final bool isFullscreen;
  final bool isMiniPlayer;
  final bool queueOpen;
  final bool desktopWindow;
  final bool nativeWindow;
  final bool hasLibraryRepository;
  final PlayerHotkeys hotkeys;
  final bool videoSettingsOpen;
  final bool videoSettingsMounted;
  final bool holdSpeedActive;
  final double miniProgress;
  final Animation<double>? miniProgressAnimation;
  final VoidCallback? onExpandFromMini;
  final VoidCallback? onDismissMini;
  final VoidCallback? onCloseVideoSettings;
  final VoidCallback? onVideoSettingsExitEnd;
  final VoidCallback? onOpenFullSettings;
  final AppPreferencesRepository? appPreferences;
  final Future<String?> Function()? onPickSubtitle;
  final VoidCallback? onSaveScreenshot;
  final VoidCallback? onCopyUrl;
  final VoidCallback? onShowInFolder;

  final void Function(PointerSignalEvent event) onPointerSignal;
  final VoidCallback onVideoTap;
  final VoidCallback onVideoDoubleTap;
  final ValueChanged<PointerEvent> onControlsPointerEnter;
  final ValueChanged<PointerEvent> onControlsPointerExit;
  final ValueChanged<bool> onMenuVisibilityChanged;
  final ValueChanged<bool> onControlInteractionChanged;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onBackToHome;
  final VoidCallback onExitMiniPlayer;
  final ValueChanged<bool> onTopBarFocusChange;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenUrl;
  final ValueChanged<MediaEntry> onOpenRecent;
  final VoidCallback onToggleQueue;
  final Future<void> Function({bool showMediaLibrary}) onSettings;
  final Future<void> Function() onPlaybackInfo;
  final VoidCallback? onOpenLibrary;
  final VoidCallback? onFullscreen;
  final VoidCallback? onToggleMiniPlayer;
  final Future<void> Function() onLoadSubtitle;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onAdjustVolume;
  final void Function(BuildContext context, BoxConstraints constraints)
  onUpdateViewportDimensions;

  @override
  Widget build(BuildContext context) {
    final media = _buildMediaContent(context);
    final animation = miniProgressAnimation;
    // One progress source for the whole stage: a caller that passes a plain
    // value gets a frozen animation at that value, while the dock path passes a
    // live one that the thin wrappers below follow.
    final progress = animation ?? AlwaysStoppedAnimation<double>(miniProgress);
    final body = _buildStageBody(
      context,
      contentState: media.state,
      media: media.surface,
      progress: progress,
    );
    if (animation == null) return body;
    return _DockClipBoundary(progress: progress, child: body);
  }

  ({String state, Widget surface}) _buildMediaContent(BuildContext context) =>
      buildPlayerStageMedia(
        context: context,
        controller: controller,
        videoBuilder: videoBuilder,
        onOpenFiles: onOpenFiles,
        onOpenUrl: onOpenUrl,
        onOpenRecent: onOpenRecent,
        draggingFiles: draggingFiles,
        onOpenLibrary: onOpenLibrary,
      );

  /// Everything the stage shows, built without reading the dock progress.
  ///
  /// Progress-dependent presentation lives in the small wrappers at the bottom
  /// of this file ([_DockFade], [_DockMiniOverlay], [_DockTapSurface]) and in
  /// the video's [LayoutBuilder], which reads the live value. Rebuilding the
  /// controls, top bar and video surface on every dock tick was the stage's
  /// dominant per-frame cost; now a tick only re-runs those wrappers.
  Widget _buildStageBody(
    BuildContext context, {
    required String contentState,
    required Widget media,
    required Animation<double> progress,
  }) {
    final current = controller.current;
    final Widget content;
    if (contentState == 'video') {
      content = ColoredBox(
        color: AppTheme.stage,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Read the live value: the dock changes this box every frame, so
            // the builder runs per frame and must not re-assert the full-stage
            // viewport while the video is seated in the mini slot.
            if (progress.value <= 0.001) {
              onUpdateViewportDimensions(context, constraints);
            }
            return RepaintBoundary(child: media);
          },
        ),
      );
    } else {
      content = media;
    }

    final stageBody = Stack(
      fit: StackFit.expand,
      children: [
        PlayerContextMenu(
          playerController: controller,
          menuController: contextMenu,
          onOpenFiles: onOpenFiles,
          onOpenUrl: onOpenUrl,
          onToggleQueue: onToggleQueue,
          onSettings: onSettings,
          onLoadSubtitle: onLoadSubtitle,
          onToggleMute: onToggleMute,
          onAdjustVolume: onAdjustVolume,
          onMenuVisibilityChanged: onMenuVisibilityChanged,
          onFullscreen: desktopWindow ? onFullscreen : null,
          onToggleMiniPlayer: nativeWindow ? onToggleMiniPlayer : null,
          onSaveScreenshot: onSaveScreenshot,
          onCopyUrl: onCopyUrl,
          onShowInFolder: onShowInFolder,
          isFullscreen: isFullscreen,
          isMiniPlayer: isMiniPlayer,
          queueOpen: queueOpen,
          shortcutLabel: (action) => hotkeys.bindingFor(action).label,
          child: MouseRegion(
            key: const ValueKey('video-surface'),
            cursor: isFullscreen && !controlsVisible && !controlMenuOpen
                ? SystemMouseCursors.none
                : MouseCursor.defer,
            child: Listener(
              onPointerSignal: onPointerSignal,
              // Rebuilt per tick, but its child is not: only the tap bindings
              // depend on whether the video is docked.
              child: _DockTapSurface(
                progress: progress,
                key: videoSurfaceKey,
                behavior: HitTestBehavior.opaque,
                onTap: controller.hasMedia
                    ? () {
                        if (_DockTapSurface.isDocked(progress) &&
                            onExpandFromMini != null) {
                          onExpandFromMini!();
                          return;
                        }
                        if (videoSettingsOpen && onCloseVideoSettings != null) {
                          onCloseVideoSettings!();
                          return;
                        }
                        onVideoTap();
                      }
                    : null,
                onDoubleTap: desktopWindow
                    ? () {
                        // Docked video expands instead of going fullscreen.
                        if (_DockTapSurface.isDocked(progress)) return;
                        onVideoDoubleTap();
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
                    // CurveTween keeps this transient: no CurvedAnimation to
                    // outlive the switcher.
                    final transition = animation.drive(
                      CurveTween(curve: AppMotion.enter),
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
        if ((controller.hasMedia ||
                controller.isLoading ||
                contentState == 'ready') &&
            (!controller.hasMedia || controller.isVideo) &&
            current != null)
          Positioned(
            left: 16,
            top: 12,
            right: 24,
            child: _DockFade(
              progress: progress,
              child: PlayerTopBar(
                currentTitle: current.title,
                controlsVisible:
                    (contentState == 'ready' ||
                        !controller.hasMedia ||
                        controller.isStopped)
                    ? true
                    : controlsVisible,
                hasLibraryRepository: hasLibraryRepository,
                isMiniPlayer: isMiniPlayer,
                onPointerEnter: () =>
                    onControlsPointerEnter(const PointerEnterEvent()),
                onPointerExit: () =>
                    onControlsPointerExit(const PointerExitEvent()),
                onBackToHome: onBackToHome,
                onExitMiniPlayer: onExitMiniPlayer,
                onFocusChange: onTopBarFocusChange,
              ),
            ),
          ),
        Positioned.fill(
          child: _DockFade(
            progress: progress,
            fadeWithDock: false,
            child: PlayerStageLoadingOverlay(controller: controller),
          ),
        ),
        Positioned.fill(
          child: _DockFade(
            progress: progress,
            fadeWithDock: false,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpace.lg),
                  child: AnimatedSwitcher(
                    duration: AppMotion.duration(
                      context,
                      AppMotion.effectsDefault,
                    ),
                    reverseDuration: AppMotion.duration(
                      context,
                      AppMotion.effectsFast,
                    ),
                    switchInCurve: AppMotion.enter,
                    switchOutCurve: AppMotion.exit,
                    transitionBuilder: (child, animation) {
                      if (AppMotion.reduce(context)) return child;
                      return FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.94,
                            end: 1.0,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: holdSpeedActive
                        ? const _HoldSpeedPill(key: ValueKey('hold-speed-pill'))
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: _DockFade(
            progress: progress,
            fadeWithDock: false,
            child: IgnorePointer(
              child: Align(
                alignment: feedbackCentered
                    ? Alignment.center
                    : Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: AnimatedSwitcher(
                    duration: AppMotion.duration(
                      context,
                      AppMotion.effectsDefault,
                    ),
                    reverseDuration: AppMotion.duration(
                      context,
                      AppMotion.effectsFast,
                    ),
                    switchInCurve: AppMotion.enter,
                    switchOutCurve: AppMotion.exit,
                    transitionBuilder: (child, animation) {
                      if (AppMotion.reduce(context)) return child;
                      return FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.94,
                            end: 1.0,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: feedbackLabel == null
                        ? const SizedBox.shrink()
                        : PlaybackFeedback(
                            key: const ValueKey('playback-feedback'),
                            icon: feedbackIcon,
                            label: feedbackLabel!,
                            progress: feedbackProgress,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (draggingFiles && current != null)
          _DockFade(
            progress: progress,
            fadeWithDock: false,
            child: PlayerDragOverlay(hasMedia: controller.hasMedia),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          // The dock fade lives here; the chrome's own auto-hide fade stays on
          // the AnimatedOpacity below, so hiding the controls still animates.
          child: _DockFade(
            key: const ValueKey('player-controls-visibility'),
            progress: progress,
            inertWhenHidden: true,
            child: FocusScope(
              node: controlsFocusScope,
              child: MouseRegion(
                onEnter: onControlsPointerEnter,
                onExit: onControlsPointerExit,
                opaque: controlsVisible,
                hitTestBehavior: controlsVisible
                    ? HitTestBehavior.opaque
                    : HitTestBehavior.deferToChild,
                child: AnimatedOpacity(
                  duration: controlsVisible
                      ? AppMotion.duration(context, AppMotion.chromeEnter)
                      : AppMotion.duration(context, AppMotion.chromeExit),
                  curve: controlsVisible ? AppMotion.enter : AppMotion.exit,
                  opacity: controlsVisible ? 1.0 : 0.0,
                  child: AnimatedSlide(
                    offset: !AppMotion.reduce(context) && !controlsVisible
                        ? const Offset(0, 0.12)
                        : Offset.zero,
                    duration: controlsVisible
                        ? AppMotion.duration(context, AppMotion.chromeEnter)
                        : AppMotion.duration(context, AppMotion.chromeExit),
                    curve: controlsVisible ? AppMotion.enter : AppMotion.exit,
                    child: IgnorePointer(
                      // Hidden chrome must not steal focus or reach screen
                      // readers while it fades out.
                      ignoring: !controlsVisible,
                      child: ExcludeFocus(
                        excluding: !controlsVisible,
                        child: ExcludeSemantics(
                          excluding: !controlsVisible,
                          child: RepaintBoundary(
                            child: ToastRegion(
                              child: AnimatedBuilder(
                                animation: Listenable.merge(<Listenable>[
                                  controller.transportListenable,
                                  controller.structureListenable,
                                ]),
                                builder: (context, _) => PlayerControls(
                                  controller: controller,
                                  onMenuVisibilityChanged:
                                      onMenuVisibilityChanged,
                                  onInteractionChanged:
                                      onControlInteractionChanged,
                                  onVolumeChanged: onVolumeChanged,
                                  onLoadSubtitle: () =>
                                      unawaited(onLoadSubtitle()),
                                  showPlaybackControls: controller.hasMedia,
                                  timelineActive: controlsVisible,
                                  actions: isMiniPlayer
                                      ? null
                                      : PlayerActions(
                                          controller: controller,
                                          onOpenFiles: onOpenFiles,
                                          onOpenUrl: onOpenUrl,
                                          onOpenRecent: onOpenRecent,
                                          onToggleQueue: onToggleQueue,
                                          onSettings: onSettings,
                                          onPlaybackInfo: onPlaybackInfo,
                                          onOpenLibrary: onOpenLibrary,
                                          onMenuVisibilityChanged:
                                              onMenuVisibilityChanged,
                                          queueOpen: queueOpen,
                                          isFullscreen: isFullscreen,
                                          onFullscreen: desktopWindow
                                              ? onFullscreen
                                              : null,
                                          onToggleMiniPlayer: nativeWindow
                                              ? onToggleMiniPlayer
                                              : null,
                                          isMiniPlayer: isMiniPlayer,
                                          miniPlayerShortcut: hotkeys
                                              .bindingFor(
                                                PlayerAction.miniPlayer,
                                              )
                                              .label,
                                          playbackInfoShortcut: hotkeys
                                              .bindingFor(
                                                PlayerAction.playbackInfo,
                                              )
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
              ),
            ),
          ),
        ),
        if ((videoSettingsOpen || videoSettingsMounted) &&
            controller.hasMedia &&
            controller.isVideo)
          Positioned.fill(
            child: _DockFade(
              progress: progress,
              fadeWithDock: false,
              child: FloatingVideoSettings(
                key: const ValueKey('floating-video-settings'),
                controller: controller,
                appPreferences: appPreferences,
                pickSubtitle: onPickSubtitle ?? () async => null,
                onClose: onCloseVideoSettings ?? () {},
                onOpenFullSettings: onOpenFullSettings,
                open: videoSettingsOpen,
                onExitSettled: onVideoSettingsExitEnd,
              ),
            ),
          ),
        if (controller.hasMedia && controller.isVideo)
          Positioned.fill(
            child: _DockMiniOverlay(
              progress: progress,
              child: MiniPlayerOverlay(
                controller: controller,
                onExpand: onExpandFromMini ?? () {},
                onDismiss: onDismissMini ?? () {},
              ),
            ),
          ),
      ],
    );

    return stageBody;
  }
}

class _MappedAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _MappedAnimation({required this.parent, required this.mapper});

  @override
  final Animation<double> parent;
  final double Function(double) mapper;

  @override
  double get value => mapper(parent.value);
}

/// Clips the stage only once it leaves the stage rectangle, keeping the
/// [ClipRect] mounted for the whole dock so unkeyed chrome never remounts.
class _DockClipBoundary extends StatefulWidget {
  const _DockClipBoundary({required this.progress, required this.child});

  final Animation<double> progress;
  final Widget child;

  @override
  State<_DockClipBoundary> createState() => _DockClipBoundaryState();
}

class _DockClipBoundaryState extends State<_DockClipBoundary> {
  late bool _clipped = _shouldClip(widget.progress.value);

  static bool _shouldClip(double progress) => progress > 0.01;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onProgressChanged);
  }

  @override
  void didUpdateWidget(covariant _DockClipBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_onProgressChanged);
      widget.progress.addListener(_onProgressChanged);
    }
    _clipped = _shouldClip(widget.progress.value);
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onProgressChanged);
    super.dispose();
  }

  void _onProgressChanged() {
    final next = _shouldClip(widget.progress.value);
    if (next != _clipped && mounted) {
      setState(() => _clipped = next);
    }
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    clipBehavior: _clipped ? Clip.hardEdge : Clip.none,
    child: widget.child,
  );
}

/// Fades a stage slot out as the video docks using a compositor [FadeTransition],
/// only rebuilding when mount or inertness thresholds cross.
class _DockFade extends StatefulWidget {
  const _DockFade({
    super.key,
    required this.progress,
    required this.child,
    this.fadeWithDock = true,
    this.inertWhenHidden = false,
  });

  final Animation<double> progress;
  final Widget child;

  /// Whether the dock fades this slot. Feedback and settings panels stay
  /// fully opaque while shown, but still leave with the rest of the chrome as
  /// the video docks.
  final bool fadeWithDock;

  /// Hidden chrome must not steal focus or reach screen readers.
  final bool inertWhenHidden;

  /// Fully faded early in the dock flight.
  static double opacityFor(double progress) =>
      (1.0 - progress * 4.5).clamp(0.0, 1.0);

  @override
  State<_DockFade> createState() => _DockFadeState();
}

class _DockFadeState extends State<_DockFade> {
  late _MappedAnimation _fadeAnimation = _buildMapped(widget.progress);
  late bool _hidden = _computeHidden(widget.progress.value);
  late bool _inert = _computeInert(widget.progress.value);

  static _MappedAnimation _buildMapped(Animation<double> progress) =>
      _MappedAnimation(parent: progress, mapper: _DockFade.opacityFor);

  static bool _computeHidden(double value) =>
      _DockFade.opacityFor(value) <= 0.01;

  bool _computeInert(double value) =>
      widget.inertWhenHidden && _DockFade.opacityFor(value) < 0.8;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onProgressChanged);
  }

  @override
  void didUpdateWidget(covariant _DockFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_onProgressChanged);
      widget.progress.addListener(_onProgressChanged);
      _fadeAnimation = _buildMapped(widget.progress);
    }
    _hidden = _computeHidden(widget.progress.value);
    _inert = _computeInert(widget.progress.value);
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onProgressChanged);
    super.dispose();
  }

  void _onProgressChanged() {
    final value = widget.progress.value;
    final nextHidden = _computeHidden(value);
    final nextInert = _computeInert(value);
    if ((nextHidden != _hidden || nextInert != _inert) && mounted) {
      setState(() {
        _hidden = nextHidden;
        _inert = nextInert;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final content = widget.fadeWithDock
        ? FadeTransition(
            opacity: _fadeAnimation,
            alwaysIncludeSemantics: !widget.inertWhenHidden,
            child: widget.child,
          )
        : widget.child;
    if (!widget.inertWhenHidden) return content;
    return IgnorePointer(
      ignoring: _inert,
      child: ExcludeFocus(
        excluding: _inert,
        child: ExcludeSemantics(excluding: _inert, child: content),
      ),
    );
  }
}

/// Shows the docked mini video's tap/dismiss overlay once the video has mostly
/// arrived in the transport bar's artwork slot.
class _DockMiniOverlay extends StatefulWidget {
  const _DockMiniOverlay({required this.progress, required this.child});

  final Animation<double> progress;
  final Widget child;

  @override
  State<_DockMiniOverlay> createState() => _DockMiniOverlayState();
}

class _DockMiniOverlayState extends State<_DockMiniOverlay> {
  static double _opacityFor(double value) =>
      ((value - 0.40) * 1.67).clamp(0.0, 1.0);

  late _MappedAnimation _opacity = _buildMapped(widget.progress);
  late bool _visible = widget.progress.value > 0.40;

  static _MappedAnimation _buildMapped(Animation<double> progress) =>
      _MappedAnimation(parent: progress, mapper: _opacityFor);

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onProgressChanged);
  }

  @override
  void didUpdateWidget(covariant _DockMiniOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_onProgressChanged);
      widget.progress.addListener(_onProgressChanged);
      _opacity = _buildMapped(widget.progress);
    }
    _visible = widget.progress.value > 0.40;
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onProgressChanged);
    super.dispose();
  }

  void _onProgressChanged() {
    final nextVisible = widget.progress.value > 0.40;
    if (nextVisible != _visible && mounted) {
      setState(() => _visible = nextVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

/// The video surface's gesture bindings.
///
/// Only the bindings depend on whether the video is docked, so this wrapper
/// updates only when crossing the 1% dock threshold while its child stays intact.
class _DockTapSurface extends StatefulWidget {
  const _DockTapSurface({
    super.key,
    required this.progress,
    required this.behavior,
    required this.onTap,
    required this.onDoubleTap,
    required this.child,
  });

  final Animation<double> progress;
  final HitTestBehavior behavior;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final Widget child;

  /// Whether the video has left the stage rectangle.
  static bool isDocked(Animation<double> progress) => progress.value > 0.01;

  @override
  State<_DockTapSurface> createState() => _DockTapSurfaceState();
}

class _DockTapSurfaceState extends State<_DockTapSurface> {
  late bool _docked = _DockTapSurface.isDocked(widget.progress);

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onProgressChanged);
  }

  @override
  void didUpdateWidget(covariant _DockTapSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_onProgressChanged);
      widget.progress.addListener(_onProgressChanged);
    }
    _docked = _DockTapSurface.isDocked(widget.progress);
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onProgressChanged);
    super.dispose();
  }

  void _onProgressChanged() {
    final next = _DockTapSurface.isDocked(widget.progress);
    if (next != _docked && mounted) {
      setState(() => _docked = next);
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: widget.behavior,
    onTap: widget.onTap,
    // A docked video expands on tap; it must not also arm the fullscreen
    // double-tap, which would delay that tap by the double-tap timer.
    onDoubleTap: _docked ? null : widget.onDoubleTap,
    child: widget.child,
  );
}

class _HoldSpeedPill extends StatelessWidget {
  const _HoldSpeedPill({super.key});

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xD612141A),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.fast_forward_rounded,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Text(
            '2×',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: AppTheme.onStage,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    ),
  );
}
