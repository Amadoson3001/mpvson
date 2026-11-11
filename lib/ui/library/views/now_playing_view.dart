import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../player/player_controller.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/components/seek_bar.dart';
import '../../core/toast/app_toast.dart';
import '../../core/toast/toast_layout.dart';
import '../../player/widgets/player_controls.dart';
import '../../player/widgets/player_control_style.dart';
import '../../player/widgets/queue_panel.dart';
import '../widgets/audio_volume_control.dart';
import '../widgets/library_artwork.dart';
import 'now_playing_layout.dart';

/// Now playing view featuring large artwork, track metadata, full transport
/// controls, timeline scrubber, volume, favorite toggle, and queue access.
class NowPlayingView extends StatefulWidget {
  const NowPlayingView({
    super.key,
    required this.controller,
    this.repository,
    this.onBack,
    this.onOpenQueue,
    this.onAddQueueFiles,
  });

  final PlayerController controller;
  final MediaLibraryRepository? repository;
  final VoidCallback? onBack;
  final VoidCallback? onOpenQueue;
  final VoidCallback? onAddQueueFiles;

  @override
  State<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends State<NowPlayingView> {
  /// Minimum interactive edge for the top-bar controls. The theme already
  /// enforces a 44px minimum, but pinning the constraints keeps the back,
  /// queue, and close buttons at an exact 44×44 hit target.
  static const BoxConstraints _hitTargetConstraints = BoxConstraints(
    minWidth: 44,
    minHeight: 44,
    maxWidth: 44,
    maxHeight: 44,
  );

  Uint8List? _cachedArtwork;
  String? _cachedArtworkPath;
  String? _lastEntryTitle;
  MediaItemRecord? _currentMediaRecord;
  int _metadataGeneration = 0;
  int _artworkGeneration = 0;
  bool _sideQueueHidden = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    widget.repository?.addListener(_onRepositoryChanged);
    _syncMetadata();
  }

  @override
  void didUpdateWidget(NowPlayingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _cachedArtworkPath = null;
      _syncMetadata();
    }
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository?.removeListener(_onRepositoryChanged);
      widget.repository?.addListener(_onRepositoryChanged);
      _currentMediaRecord = null;
      _syncMetadata();
    }
  }

  @override
  void dispose() {
    _metadataGeneration++;
    _artworkGeneration++;
    widget.controller.removeListener(_onControllerChanged);
    widget.repository?.removeListener(_onRepositoryChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final cur = widget.controller.current;
    if (cur?.path != _cachedArtworkPath) {
      _syncMetadata();
      return;
    }
    if (cur?.title != _lastEntryTitle) {
      _lastEntryTitle = cur?.title;
      if (mounted) setState(() {});
    }
  }

  void _onRepositoryChanged() {
    _syncMetadata();
  }

  Future<void> _syncMetadata() async {
    final generation = ++_metadataGeneration;
    final cur = widget.controller.current;
    if (cur == null) {
      _artworkGeneration++;
      if (mounted) {
        setState(() {
          _cachedArtwork = null;
          _cachedArtworkPath = null;
          _currentMediaRecord = null;
        });
      }
      return;
    }

    if (_cachedArtworkPath != cur.path) {
      final artworkGeneration = ++_artworkGeneration;
      setState(() {
        _cachedArtworkPath = cur.path;
        _cachedArtwork = null;
        _currentMediaRecord = null;
      });
      unawaited(_loadArtwork(cur, artworkGeneration));
    }

    // Load media record from repo if available
    final repository = widget.repository;
    if (repository != null && repository.isReady) {
      MediaItemRecord? record;
      try {
        record = await repository.getMediaByCanonicalSource(cur.path);
      } catch (_) {
        return;
      }
      if (mounted &&
          generation == _metadataGeneration &&
          _cachedArtworkPath == cur.path) {
        setState(() {
          _currentMediaRecord = record;
        });
      }
    }
  }

  Future<void> _loadArtwork(MediaEntry entry, int generation) async {
    final thumb = await widget.controller
        .loadThumbnail(entry)
        .catchError((Object _) => null);
    if (mounted &&
        generation == _artworkGeneration &&
        _cachedArtworkPath == entry.path) {
      setState(() => _cachedArtwork = thumb?.bytes);
    }
  }

  Future<void> _closePlayer() async {
    await widget.controller.closePlayer();
    if (!mounted) return;
    AppToast.show(
      context,
      'Player closed. Your queue is still available.',
      duration: const Duration(seconds: 3),
    );
  }

  /// Height of a single [IconButton] row.
  ///
  /// The app theme sets a 44px minimum, but an icon button keeps the 48px
  /// padded touch target around itself, so the row is the larger of the two —
  /// reading only the theme's minimum undercounts these rows by 4px each.
  double _iconButtonExtent(BuildContext context) {
    final style = Theme.of(context).iconButtonTheme.style;
    final minimum = style?.minimumSize?.resolve(const <WidgetState>{});
    final density = Theme.of(context).visualDensity;
    return math.max(
      kMinInteractiveDimension + density.vertical,
      minimum?.height ?? 0,
    );
  }

  Future<void> _toggleFavorite() async {
    final repo = widget.repository;
    final record = _currentMediaRecord;
    if (repo == null || record == null) return;
    final nextFav = !record.isFavorite;
    await repo.toggleFavorite(record.id, nextFav);
    if (!mounted) return;
    setState(() {
      _currentMediaRecord = record.copyWith(isFavorite: nextFav);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.controller.current;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The artwork is the only flexible element in the column, so it takes
        // the height the rest of the content leaves behind. Measuring that
        // remainder keeps the artwork from overshooting on shorter windows,
        // where it used to stay at its maximum and push the transport row
        // below the fold.
        final isCompactHeight =
            constraints.maxHeight < NowPlayingLayout.compactHeightBreakpoint;
        // Unknown artist and album stay empty until real metadata arrives;
        // inventing names would present fabricated information as fact.
        final artworkSize =
            NowPlayingLayout(
              title:
                  _currentMediaRecord?.title ??
                  entry?.title ??
                  'Nothing playing',
              artist: _currentMediaRecord?.artist ?? '',
              album: _currentMediaRecord?.album ?? '',
            ).artworkSize(
              context: context,
              viewportWidth: constraints.maxWidth,
              viewportHeight: constraints.maxHeight,
              iconButtonExtent: _iconButtonExtent(context),
              textScaler: MediaQuery.textScalerOf(context),
            );

        final verticalPadding = NowPlayingLayout.stageVerticalPadding(
          isCompactHeight: isCompactHeight,
        );
        final queue = widget.controller.queue;
        final showSideQueue =
            constraints.maxWidth >= 920 &&
            queue.length > 1 &&
            !_sideQueueHidden;

        return Scaffold(
          backgroundColor: context.palette.background,
          body: Stack(
            children: [
              if (_cachedArtwork != null)
                Positioned.fill(
                  // The dark tint above this layer supplies the depth; skipping
                  // a full-screen gaussian blur keeps integrated GPUs fluid.
                  child: RepaintBoundary(
                    child: Image.memory(
                      _cachedArtwork!,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.low,
                      cacheWidth: 512,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              Positioned.fill(
                child: ColoredBox(
                  color: Color.alphaBlend(
                    Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.1),
                    context.palette.background,
                  ).withValues(alpha: 0.82),
                ),
              ),
              Positioned.fill(
                child: RepaintBoundary(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, -0.25),
                        radius: 0.85,
                        colors: [
                          (Theme.of(
                                    context,
                                  ).extension<MediaAccentPalette>()?.vibrant ??
                                  Theme.of(context).colorScheme.primary)
                              .withValues(alpha: 0.16),
                          (Theme.of(
                                    context,
                                  ).extension<MediaAccentPalette>()?.muted ??
                                  context.palette.background)
                              .withValues(alpha: 0.04),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  // Main content stage
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppSpace.xl,
                        vertical: verticalPadding,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          // Fill the viewport when the content is shorter, so
                          // the column centers in the stage instead of leaving
                          // the slack at the bottom.
                          constraints: BoxConstraints(
                            minHeight: math.max(
                              0,
                              constraints.maxHeight - 2 * verticalPadding,
                            ),
                            maxWidth: NowPlayingLayout.columnMaxWidth,
                          ),
                          child: Column(
                            mainAxisAlignment: isCompactHeight
                                ? MainAxisAlignment.start
                                : MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  if (widget.onBack != null)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.arrow_back_rounded,
                                        size: 20,
                                      ),
                                      tooltip: 'Back to library',
                                      color: context.palette.secondaryText,
                                      constraints: _hitTargetConstraints,
                                      padding: EdgeInsets.zero,
                                      onPressed: widget.onBack,
                                    )
                                  else
                                    const SizedBox(width: 44),
                                  const Spacer(),
                                  if (!showSideQueue &&
                                      (widget.onOpenQueue != null ||
                                          _sideQueueHidden))
                                    IconButton(
                                      icon: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.queue_music_rounded,
                                            size: 20,
                                          ),
                                          SizedBox(width: 4),
                                          Text('Queue'),
                                        ],
                                      ),
                                      tooltip: 'Open queue',
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      constraints: const BoxConstraints(
                                        minWidth: 44,
                                        minHeight: 44,
                                      ),
                                      color: context.palette.primaryText,
                                      onPressed: () {
                                        if (constraints.maxWidth >= 920 &&
                                            queue.length > 1) {
                                          setState(
                                            () => _sideQueueHidden = false,
                                          );
                                        } else {
                                          widget.onOpenQueue?.call();
                                        }
                                      },
                                    ),
                                  const SizedBox(width: AppSpace.xxs),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 20,
                                    ),
                                    tooltip: 'Close player',
                                    color: context.palette.secondaryText,
                                    constraints: _hitTargetConstraints,
                                    padding: EdgeInsets.zero,
                                    onPressed: _closePlayer,
                                  ),
                                ],
                              ),
                              SizedBox(
                                height: NowPlayingLayout.gapAboveArtwork(
                                  isCompactHeight: isCompactHeight,
                                ),
                              ),
                              // Large square artwork
                              AudioVolumeWheel(
                                controller: widget.controller,
                                child: _buildArtwork(context, artworkSize),
                              ),
                              SizedBox(
                                height: NowPlayingLayout.gapBelowArtwork(
                                  isCompactHeight: isCompactHeight,
                                ),
                              ),
                              // Title & Favorite row
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpace.md,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(
                                      width: NowPlayingLayout.titleBalanceWidth,
                                    ),
                                    Flexible(
                                      child: Text(
                                        _currentMediaRecord?.title ??
                                            entry?.title ??
                                            'Nothing playing',
                                        style: isCompactHeight
                                            ? context.palette.albumTitle
                                            : context.palette.pageTitle,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: AppSpace.xs),
                                    IconButton(
                                      icon: Icon(
                                        (_currentMediaRecord?.isFavorite ??
                                                false)
                                            ? Icons.favorite_rounded
                                            : Icons.favorite_border_rounded,
                                        size: 22,
                                        color:
                                            (_currentMediaRecord?.isFavorite ??
                                                false)
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : context.palette.primaryText
                                                  .withValues(alpha: 0.6),
                                      ),
                                      tooltip:
                                          (_currentMediaRecord?.isFavorite ??
                                              false)
                                          ? 'Remove from favorites'
                                          : 'Add to favorites',
                                      onPressed: _currentMediaRecord != null
                                          ? _toggleFavorite
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                height: NowPlayingLayout.gapBelowTitle(
                                  isCompactHeight: isCompactHeight,
                                ),
                              ),
                              // Artist
                              Text(
                                _currentMediaRecord?.artist ?? '',
                                style: NowPlayingLayout.artistStyle(context),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              SizedBox(
                                height: NowPlayingLayout.gapBelowArtist(
                                  isCompactHeight: isCompactHeight,
                                ),
                              ),
                              // Album
                              Text(
                                _currentMediaRecord?.album ?? '',
                                style: NowPlayingLayout.albumStyle(context),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              SizedBox(
                                height: NowPlayingLayout.gapAboveTransport(
                                  isCompactHeight: isCompactHeight,
                                ),
                              ),
                              // Transport, timeline and volume, so this screen
                              // can drive playback on its own.
                              AudioVolumeWheel(
                                controller: widget.controller,
                                child: PlayerControlStyle(
                                  compact: isCompactHeight,
                                  child: Column(
                                    children: [
                                      SeekBar(controller: widget.controller),
                                      SizedBox(
                                        height:
                                            NowPlayingLayout.gapTimelineTransport(
                                              isCompactHeight: isCompactHeight,
                                            ),
                                      ),
                                      _buildControls(isCompactHeight),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (showSideQueue) ...[
                    VerticalDivider(width: 1, color: context.palette.border),
                    ToastRegion(
                      child: SizedBox(
                        width: AppLayout.queuePanelWidth,
                        child: QueuePanel(
                          controller: widget.controller,
                          onQueueFocus: (_) {},
                          onClose: () =>
                              setState(() => _sideQueueHidden = true),
                          onAddFiles: widget.onAddQueueFiles ?? () {},
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// Perfectly centered, symmetrical transport controls and volume slider.
  Widget _buildControls(bool isCompactHeight) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: TransportButtons(
            controller: widget.controller,
            compact: isCompactHeight,
            showStop: false,
            showShuffleRepeat: true,
          ),
        ),
        const SizedBox(height: NowPlayingLayout.transportVolumeGap),
        Center(
          child: AudioVolumeControl(
            controller: widget.controller,
            compact: isCompactHeight,
            showPercent: true,
          ),
        ),
      ],
    );
  }

  Widget _buildArtwork(BuildContext context, double size) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.palette.raisedSurface,
        gradient: RadialGradient(
          center: const Alignment(0, -0.2),
          radius: 0.9,
          colors: [
            primary.withValues(alpha: 0.32),
            context.palette.raisedSurface,
            context.palette.background,
          ],
          stops: const [0.0, 0.6, 1.0],
        ),
        borderRadius: BorderRadius.circular(AppRadii.artworkHero),
        border: Border.all(color: primary.withValues(alpha: 0.38), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.35),
            blurRadius: 56,
            spreadRadius: 4,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSwitcher(
        duration: AppMotion.duration(context, AppMotion.standard),
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        transitionBuilder: (child, animation) {
          if (AppMotion.reduce(context)) return child;
          return FadeTransition(opacity: animation, child: child);
        },
        child: KeyedSubtree(
          key: ValueKey<String>(_cachedArtworkPath ?? 'no-artwork'),
          child: SizedBox.expand(
            child: _cachedArtwork != null
                ? Image.memory(
                    _cachedArtwork!,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    cacheWidth: 512,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => _buildFallbackArtwork(),
                  )
                : _currentMediaRecord != null
                ? LibraryArtwork(
                    path: _currentMediaRecord!.metadata.artworkUri,
                    mediaPath: _currentMediaRecord!.path,
                    repository: widget.repository,
                    icon: Icons.music_note_rounded,
                    iconSize: 56,
                  )
                : _buildFallbackArtwork(),
          ),
        ),
      ),
    );
  }

  Widget _buildFallbackArtwork() {
    final primary = Theme.of(context).colorScheme.primary;
    final card = context.palette.raisedSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 0.95,
          colors: [primary.withValues(alpha: 0.25), card],
        ),
      ),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: primary.withValues(alpha: 0.12),
                  width: 1.5,
                ),
              ),
            ),
            Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: primary.withValues(alpha: 0.18),
                  width: 1.5,
                ),
              ),
            ),
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primary.withValues(alpha: 0.18),
                border: Border.all(
                  color: primary.withValues(alpha: 0.45),
                  width: 2.0,
                ),
              ),
              child: Center(
                child: Icon(Icons.music_note_rounded, size: 42, color: primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
