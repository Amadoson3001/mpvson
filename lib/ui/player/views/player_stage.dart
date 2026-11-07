import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/player_hotkeys.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/toast/toast_layout.dart';
import '../player_controller.dart';
import '../widgets/empty_library.dart';
import '../widgets/media_ready.dart';
import '../widgets/playback_feedback.dart';
import '../widgets/player_actions.dart';
import '../widgets/player_context_menu.dart';
import '../widgets/player_controls.dart';
import 'player_drag_drop.dart';
import 'player_top_bar.dart';
import '../../../../data/repositories/app_preferences_repository.dart';
import 'mini_player_overlay.dart';
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
    this.miniProgress = 0.0,
    this.onExpandFromMini,
    this.onDismissMini,
    this.onCloseVideoSettings,
    this.onOpenFullSettings,
    this.appPreferences,
    this.onPickSubtitle,
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
  final double miniProgress;
  final VoidCallback? onExpandFromMini;
  final VoidCallback? onDismissMini;
  final VoidCallback? onCloseVideoSettings;
  final VoidCallback? onOpenFullSettings;
  final AppPreferencesRepository? appPreferences;
  final Future<String?> Function()? onPickSubtitle;

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
    final current = controller.current;
    final audioEntry =
        controller.isAudio ||
        (current != null &&
            MediaCatalog.kindFromExtension(current.path).isAudio);

    final Widget content;
    final String contentState;
    if (current == null) {
      contentState = 'empty';
      content = Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: EmptyLibrary(
          recent: controller.recent,
          onOpenFiles: onOpenFiles,
          onOpenUrl: onOpenUrl,
          onOpenRecent: onOpenRecent,
          onRemoveRecent: (MediaEntry entry) {
            final restored = controller.removeRecent(entry);
            if (restored != null && context.mounted) {
              AppToast.show(
                context,
                'Removed from recently played',
                actionLabel: 'Undo',
                onAction: () =>
                    controller.restoreRecent(restored.$1, restored.$2),
              );
            }
          },
          isDragging: draggingFiles,
          onOpenLibrary: onOpenLibrary,
        ),
      );
    } else if (!controller.hasMedia) {
      contentState = 'ready';
      content = Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            controller.displayPositionListenable,
            controller.durationListenable,
            controller.bufferingListenable,
          ]),
          builder: (context, _) => MediaReady(
            entry: controller.current ?? current,
            position: controller.displayPosition,
            duration: controller.duration,
            isOpening: controller.isBuffering,
            onPlay: () => unawaited(controller.togglePlayPause()),
          ),
        ),
      );
    } else if (audioEntry) {
      contentState = 'audio';
      content = const ColoredBox(color: AppTheme.stage);
    } else {
      contentState = 'video';
      content = ColoredBox(
        color: AppTheme.stage,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (miniProgress <= 0.001) {
              onUpdateViewportDimensions(context, constraints);
            }
            return RepaintBoundary(child: videoBuilder(context, controller));
          },
        ),
      );
    }

    final fullControlsOpacity = (1.0 - miniProgress * 3.5).clamp(0.0, 1.0);
    final showFullControls = fullControlsOpacity > 0.01;

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
              child: GestureDetector(
                key: videoSurfaceKey,
                behavior: HitTestBehavior.opaque,
                onTap: controller.hasMedia
                    ? () {
                        if (miniProgress > 0.8 && onExpandFromMini != null) {
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
                onDoubleTap: desktopWindow ? onVideoDoubleTap : null,
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
        if (showFullControls &&
            controller.hasMedia &&
            controller.isVideo &&
            current != null)
          PlayerTopBar(
            currentTitle: current.title,
            controlsVisible: controlsVisible,
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
        if (showFullControls)
          Positioned.fill(
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
        if (draggingFiles && current != null && showFullControls)
          PlayerDragOverlay(hasMedia: controller.hasMedia),
        if (showFullControls)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
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
                  key: const ValueKey('player-controls-visibility'),
                  duration: AppMotion.duration(context, AppMotion.quick),
                  opacity: controlsVisible ? fullControlsOpacity : 0,
                  child: AnimatedSlide(
                    offset: !AppMotion.reduce(context) && !controlsVisible
                        ? const Offset(0, 0.1)
                        : Offset.zero,
                    duration: AppMotion.duration(context, AppMotion.quick),
                    curve: AppMotion.standardCurve,
                    child: IgnorePointer(
                      ignoring: !controlsVisible || fullControlsOpacity < 0.8,
                      // Hidden chrome must not steal focus or reach screen
                      // readers while it fades out.
                      child: ExcludeFocus(
                        excluding:
                            !controlsVisible || fullControlsOpacity < 0.8,
                        child: ExcludeSemantics(
                          excluding:
                              !controlsVisible || fullControlsOpacity < 0.8,
                          child: ToastRegion(
                            child: AnimatedBuilder(
                              animation: controller,
                              builder: (context, _) => PlayerControls(
                                controller: controller,
                                onMenuVisibilityChanged:
                                    onMenuVisibilityChanged,
                                onInteractionChanged:
                                    onControlInteractionChanged,
                                onVolumeChanged: onVolumeChanged,
                                showPlaybackControls: controller.hasMedia,
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
        if (showFullControls &&
            videoSettingsOpen &&
            controller.hasMedia &&
            controller.isVideo)
          Positioned.fill(
            child: FloatingVideoSettings(
              key: const ValueKey('floating-video-settings'),
              controller: controller,
              appPreferences: appPreferences,
              pickSubtitle: onPickSubtitle ?? () async => null,
              onClose: onCloseVideoSettings ?? () {},
              onOpenFullSettings: onOpenFullSettings,
            ),
          ),
        if (miniProgress > 0.35 && controller.hasMedia && controller.isVideo)
          Positioned.fill(
            child: Opacity(
              opacity: ((miniProgress - 0.35) * 1.54).clamp(0.0, 1.0),
              child: MiniPlayerOverlay(
                controller: controller,
                onExpand: onExpandFromMini ?? () {},
                onDismiss: onDismissMini ?? () {},
              ),
            ),
          ),
      ],
    );

    if (miniProgress > 0.01) {
      final borderRadius = BorderRadius.circular(
        AppLayout.dockedMiniVideoRadius * miniProgress,
      );
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: context.palette.border.withValues(
              alpha: miniProgress.clamp(0.0, 1.0),
            ),
            width: 1,
          ),
          boxShadow: miniProgress > 0.1 && miniProgress < 0.95
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45 * miniProgress),
                    blurRadius: 16 * miniProgress,
                    offset: Offset(0, 4 * miniProgress),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(borderRadius: borderRadius, child: stageBody),
      );
    }

    return stageBody;
  }
}
