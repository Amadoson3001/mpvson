import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/stream_playback_state.dart';
import '../../core/app_theme.dart';
import '../../core/components/playback_pulse.dart';
import '../../core/components/seek_bar.dart';
import '../../player/player_controller.dart';
import '../../player/views/player_loading_overlay.dart';
import '../../player/widgets/player_controls.dart';
import '../widgets/audio_volume_control.dart';
import '../widgets/library_artwork.dart';

/// Persistent full-width transport bar under the library stage.
///
/// The left area stacks track info, transport + volume controls, and the seek
/// bar; the right edge holds the full-height, frameless mini player / artwork
/// slot flush from top to bottom.
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({
    super.key,
    required this.controller,
    required this.repository,
    required this.entry,
    required this.isVideo,
    required this.compact,
    required this.openLabel,
    required this.onOpen,
    required this.onShowQueue,
    this.dense = false,
  });

  static const double _minBarHeight = AppLayout.dockedMiniVideoHeight;
  static const double _denseMinBarHeight = 84;
  static const double _minRowHeight = 52;
  static const double _denseMinRowHeight = 44;
  static const double _titleSize = 14;
  static const double _subtitleSize = 12;
  static const double seekHeight = 28;
  static const double _denseSeekHeight = 24;
  static const double _topBorder = 1;

  /// Artwork slot: square at full bar height for audio, or a 16:9 frame at
  /// full bar height for video so the docked in-app mini video sits flush on
  /// the left edge, top to bottom, without any frame.
  static Size thumbnailSizeFor(bool isVideo, {double? barHeight}) {
    final height = barHeight ?? _minBarHeight;
    return isVideo
        ? Size((height * 16 / 9).roundToDouble(), height)
        : Size.square(height);
  }

  /// The bar's video artwork slot, in coordinates of the full content area.
  /// The player content lerps the docked mini video to this rect so the live
  /// video lands flush on the left edge from top to bottom of the bar.
  static Rect dockedVideoRect(
    double totalHeight,
    TextScaler scaler, {
    bool dense = false,
  }) {
    final barHeight = heightFor(scaler, dense: dense);
    final size = thumbnailSizeFor(true, barHeight: barHeight);
    return Rect.fromLTWH(
      0,
      (totalHeight - barHeight).clamp(0.0, double.infinity),
      size.width,
      size.height,
    );
  }

  /// Transport row height. Grows with the text scale so two lines of text
  /// never overflow the title area. [dense] trims the vertical padding for
  /// short windows where the stage needs every pixel.
  static double rowHeightFor(TextScaler scaler, {bool dense = false}) {
    final text =
        scaler.scale(_titleSize) * 1.3 +
        AppSpace.micro +
        scaler.scale(_subtitleSize) * 1.3;
    return (text + 8).ceilToDouble().clamp(
      dense ? _denseMinRowHeight : _minRowHeight,
      double.infinity,
    );
  }

  /// Whole bar height: top hairline + controls column + seek strip. The shell
  /// and docked video rect both measure from this so they stay locked together.
  static double heightFor(TextScaler scaler, {bool dense = false}) {
    final topPad = dense ? 6.0 : 10.0;
    final gap = dense ? 2.0 : 4.0;
    final bottomPad = dense ? 4.0 : 8.0;
    final seek = dense ? _denseSeekHeight : seekHeight;
    final contentHeight =
        _topBorder +
        topPad +
        rowHeightFor(scaler, dense: dense) +
        gap +
        seek +
        bottomPad;
    return math.max(dense ? _denseMinBarHeight : _minBarHeight, contentHeight);
  }

  final PlayerController controller;
  final MediaLibraryRepository repository;
  final MediaEntry entry;
  final bool isVideo;
  final bool compact;
  final String openLabel;
  final VoidCallback onOpen;
  final VoidCallback onShowQueue;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scaler = MediaQuery.textScalerOf(context);
    final barHeight = heightFor(scaler, dense: dense);
    final rowHeight = rowHeightFor(scaler, dense: dense);
    final seek = dense ? _denseSeekHeight : seekHeight;
    final topPad = dense ? 6.0 : 10.0;
    final bottomPad = dense ? 4.0 : 8.0;
    final thumbSize = thumbnailSizeFor(isVideo, barHeight: barHeight);

    return SizedBox(
      height: barHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox.fromSize(
            size: thumbSize,
            child: Semantics(
              button: true,
              label: openLabel,
              excludeSemantics: true,
              child: Tooltip(
                message: openLabel,
                waitDuration: const Duration(milliseconds: 600),
                child: Material(
                  color: isVideo ? AppTheme.stage : palette.card,
                  child: InkWell(
                    onTap: onOpen,
                    hoverColor: Colors.white.withValues(alpha: 0.08),
                    child: _Thumbnail(
                      entry: entry,
                      repository: repository,
                      isVideo: isVideo,
                      showEqualizer: controller.isPlaying && !isVideo,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.card,
                border: Border(
                  top: BorderSide(color: palette.border, width: _topBorder),
                ),
              ),
              child: AudioVolumeWheel(
                controller: controller,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpace.sm,
                    topPad,
                    AppSpace.sm,
                    bottomPad,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      SizedBox(
                        height: rowHeight,
                        child: Row(
                          children: [
                            Expanded(
                              child: _OpenArea(
                                label: openLabel,
                                onTap: onOpen,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: _MiniPlayerSubtitle(
                                    key: ValueKey(entry.path),
                                    controller: controller,
                                    repository: repository,
                                    path: entry.path,
                                    fallbackTitle: entry.title,
                                    isVideo: isVideo,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpace.sm),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TransportButtons(
                                  controller: controller,
                                  compact: compact,
                                ),
                                const SizedBox(width: AppSpace.xs),
                                AudioVolumeControl(
                                  controller: controller,
                                  compact: true,
                                  showPercent: !compact,
                                ),
                                if (compact)
                                  IconButton(
                                    icon: const Icon(Icons.queue_music_rounded),
                                    tooltip: 'Queue',
                                    color: palette.secondaryText,
                                    onPressed: onShowQueue,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: seek,
                        child: Padding(
                          padding: const EdgeInsets.only(left: AppSpace.xxs),
                          child: SeekBar(controller: controller),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.entry,
    required this.repository,
    required this.isVideo,
    required this.showEqualizer,
  });

  final MediaEntry entry;
  final MediaLibraryRepository repository;
  final bool isVideo;
  final bool showEqualizer;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      LibraryArtwork(
        mediaPath: entry.path,
        repository: repository,
        iconSize: 32,
      ),
      if (showEqualizer)
        Positioned(
          right: 8,
          bottom: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Padding(
              padding: EdgeInsets.all(3),
              child: PlayingEqualizerGlyph(isPlaying: true, size: 12),
            ),
          ),
        ),
    ],
  );
}

/// Hover, focus and pressed feedback around the title area.
class _OpenArea extends StatefulWidget {
  const _OpenArea({
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_OpenArea> createState() => _OpenAreaState();
}

class _OpenAreaState extends State<_OpenArea> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = BorderRadius.circular(AppRadii.control);
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: widget.onTap,
          onFocusChange: (value) => setState(() => _focused = value),
          borderRadius: radius,
          hoverColor: palette.hover,
          focusColor: Colors.transparent,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: _focused
                  ? Border.all(color: palette.accent, width: 2)
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Title and subtitle for the bottom transport bar.
///
/// The controller notifies for many transport changes; resolving the library
/// record once per track instead of once per rebuild keeps those notifications
/// from issuing a database query each time. Both lines prefer the record so the
/// bar and the Now Playing screen show the same title and artist.
class _MiniPlayerSubtitle extends StatefulWidget {
  const _MiniPlayerSubtitle({
    super.key,
    required this.controller,
    required this.repository,
    required this.path,
    required this.fallbackTitle,
    required this.isVideo,
  });

  final PlayerController controller;
  final MediaLibraryRepository repository;
  final String path;
  final String fallbackTitle;
  final bool isVideo;

  @override
  State<_MiniPlayerSubtitle> createState() => _MiniPlayerSubtitleState();
}

class _MiniPlayerSubtitleState extends State<_MiniPlayerSubtitle> {
  Future<MediaItemRecord?>? _record;

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_onRepositoryChanged);
    _resolve();
  }

  @override
  void didUpdateWidget(_MiniPlayerSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_onRepositoryChanged);
      widget.repository.addListener(_onRepositoryChanged);
    }
    if (oldWidget.path != widget.path ||
        oldWidget.repository != widget.repository ||
        oldWidget.isVideo != widget.isVideo) {
      _resolve();
    }
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onRepositoryChanged);
    super.dispose();
  }

  void _onRepositoryChanged() {
    if (!widget.isVideo && _record == null && widget.repository.isReady) {
      setState(_resolve);
    }
  }

  void _resolve() {
    if (widget.isVideo || !widget.repository.isReady) {
      _record = null;
      return;
    }
    _record = widget.repository
        .getMediaByCanonicalSource(widget.path)
        .catchError((Object _) => null);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TransportState>(
      valueListenable: widget.controller.transportListenable,
      builder: (context, transport, _) {
        final stage = transport.streamStage;
        final activeStatus =
            (transport.isLoading ||
                transport.isBuffering ||
                stage == StreamStage.reconnecting ||
                stage == StreamStage.switchingQuality)
            ? resolveLoadingStageLabel(
                transport: transport,
                entry: widget.controller.current,
              )
            : null;
        final currentTitle = widget.controller.current?.path == widget.path
            ? widget.controller.current!.title
            : widget.fallbackTitle;

        if (widget.isVideo) {
          return _lines(
            currentTitle,
            activeStatus ?? 'Video',
            isStatus: activeStatus != null,
          );
        }
        final record = _record;
        if (record == null) {
          return _lines(
            currentTitle,
            activeStatus ?? 'Unknown artist',
            isStatus: activeStatus != null,
          );
        }
        return FutureBuilder<MediaItemRecord?>(
          future: record,
          builder: (context, snapshot) => _lines(
            snapshot.data?.title ?? currentTitle,
            activeStatus ?? snapshot.data?.artist ?? 'Unknown artist',
            isStatus: activeStatus != null,
          ),
        );
      },
    );
  }

  Widget _lines(String title, String subtitle, {bool isStatus = false}) {
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: palette.sectionTitle.copyWith(
            fontSize: MiniPlayerBar._titleSize,
            height: 1.3,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpace.micro),
        Text(
          subtitle,
          style: palette.rowSecondary.copyWith(
            fontSize: MiniPlayerBar._subtitleSize,
            height: 1.3,
            color: isStatus ? palette.accent : palette.secondaryText,
            fontWeight: isStatus ? FontWeight.w500 : FontWeight.normal,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
