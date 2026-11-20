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
    return AnimatedBuilder(
      animation: progress,
      child: body,
      builder: (context, child) => _applyDockProgress(child!, progress.value),
    );
  }

  /// The only work a dock tick does: clip the stage once it leaves the stage
  /// rectangle. The stage body itself is the [AnimatedBuilder] child, so it is
  /// built once per stage rebuild instead of once per frame.
  ///
  /// The [ClipRect] stays mounted for the whole dock and only its
  /// [clipBehavior] changes. Swapping between a bare body and a `ClipRect`
  /// wrapper would put two different widget types at the same tree position, so
  /// the stage's unkeyed chrome would unmount and remount at both ends of the
  /// move — losing control state and restarting the video-surface switcher.
  /// [Clip.none] paints the child directly, so the undocked stage costs
  /// nothing extra.
  Widget _applyDockProgress(Widget body, double progress) => ClipRect(
    clipBehavior: progress > 0.01 ? Clip.hardEdge : Clip.none,
    child: body,
  );

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
                    duration: AppMotion.duration(context, AppMotion.quick),
                    child: holdSpeedActive
                        ? _HoldSpeedPill(key: const ValueKey('hold-speed-pill'))
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
                    duration: AppMotion.duration(context, AppMotion.quick),
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
                  duration: AppMotion.duration(context, AppMotion.quick),
                  opacity: controlsVisible ? 1.0 : 0.0,
                  child: AnimatedSlide(
                    offset: !AppMotion.reduce(context) && !controlsVisible
                        ? const Offset(0, 0.1)
                        : Offset.zero,
                    duration: AppMotion.duration(context, AppMotion.quick),
                    curve: AppMotion.standardCurve,
                    child: IgnorePointer(
                      // Hidden chrome must not steal focus or reach screen
                      // readers while it fades out.
                      ignoring: !controlsVisible,
                      child: ExcludeFocus(
                        excluding: !controlsVisible,
                        child: ExcludeSemantics(
                          excluding: !controlsVisible,
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
                                            .bindingFor(PlayerAction.miniPlayer)
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

/// Fades a stage slot out as the video docks, and drops it from the tree once
/// it is fully faded.
///
/// The stage body is built once per stage rebuild; only these thin wrappers
/// re-run on a dock tick, so the controls, top bar and video surface are not
/// recomposed on every frame while the video moves.
class _DockFade extends StatelessWidget {
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

  /// Fully faded just under a third of the way into the dock.
  static double opacityFor(double progress) =>
      (1.0 - progress * 3.5).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final dockOpacity = opacityFor(progress.value);
        final double opacity;
        if (fadeWithDock) {
          opacity = dockOpacity;
        } else {
          opacity = dockOpacity > 0.01 ? 1.0 : 0.0;
        }
        if (opacity <= 0.01) return const SizedBox.shrink();
        if (opacity >= 0.999) return child!;
        final faded = Opacity(opacity: opacity, child: child);
        if (!inertWhenHidden || opacity >= 0.8) return faded;
        return IgnorePointer(
          ignoring: true,
          child: ExcludeFocus(
            excluding: true,
            child: ExcludeSemantics(excluding: true, child: faded),
          ),
        );
      },
    );
  }
}

/// Shows the docked mini video's tap/dismiss overlay once the video has mostly
/// arrived in the transport bar's artwork slot.
///
/// The overlay paints nothing but its hover/press highlight, so fading the
/// whole widget reproduces the ramp the overlay applies to that highlight
/// without rebuilding it on every dock tick. Hit testing is unaffected.
class _DockMiniOverlay extends StatelessWidget {
  const _DockMiniOverlay({required this.progress, required this.child});

  final Animation<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final value = progress.value;
        if (value <= 0.35) return const SizedBox.shrink();
        final opacity = ((value - 0.35) * 1.54).clamp(0.0, 1.0);
        if (opacity >= 0.999) return child!;
        return Opacity(opacity: opacity, child: child);
      },
    );
  }
}

/// The video surface's gesture bindings.
///
/// Only the bindings depend on whether the video is docked, so this wrapper is
/// rebuilt per dock tick while its child — the whole video surface — is not.
class _DockTapSurface extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final docked = isDocked(progress);
        return GestureDetector(
          behavior: behavior,
          onTap: onTap,
          // A docked video expands on tap; it must not also arm the fullscreen
          // double-tap, which would delay that tap by the double-tap timer.
          onDoubleTap: docked ? null : onDoubleTap,
          child: child,
        );
      },
    );
  }
}

class _HoldSpeedPill extends StatelessWidget {
  const _HoldSpeedPill({super.key});

  @override
  Widget build(BuildContext context) => Container(
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
  );
}
