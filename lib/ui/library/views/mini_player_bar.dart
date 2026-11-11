import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../core/app_theme.dart';
import '../../core/components/playback_pulse.dart';
import '../../core/components/seek_bar.dart';
import '../../player/player_controller.dart';
import '../../player/widgets/player_controls.dart';
import '../widgets/audio_volume_control.dart';
import '../widgets/library_artwork.dart';

/// Persistent transport bar under the library stage.
///
/// The title area opens Now Playing (or the video player), the right side
/// carries transport and volume, and the strip below is the seek bar.
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

  static const double _minRowHeight = 60;
  static const double _titleSize = 14;
  static const double _subtitleSize = 12;
  static const double seekHeight = 28;
  static const double _denseSeekHeight = 22;
  static const double _denseMinRowHeight = 56;
  static const double _audioThumbSize = 44;
  static const double _cardBorder = 1;

  /// Artwork slot: square for audio, a 16:9 frame for video so the docked
  /// in-app mini video can seat exactly here and read as part of the bar.
  static Size thumbnailSizeFor(bool isVideo) => isVideo
      ? const Size(
          AppLayout.dockedMiniVideoWidth,
          AppLayout.dockedMiniVideoHeight,
        )
      : const Size.square(_audioThumbSize);

  /// The bar's video artwork slot, in coordinates of the full content area.
  /// The player content lerps the docked mini video to this rect so the live
  /// video lands in the bar instead of overlapping it.
  static Rect dockedVideoRect(
    double totalHeight,
    TextScaler scaler, {
    bool dense = false,
  }) {
    final size = thumbnailSizeFor(true);
    final rowHeight = rowHeightFor(scaler, dense: dense);
    final top =
        totalHeight -
        heightFor(scaler, dense: dense) +
        (dense ? AppSpace.xxs : AppSpace.xs) +
        _cardBorder +
        (rowHeight - size.height) / 2;
    return Rect.fromLTWH(
      AppSpace.sm + _cardBorder + 2 * AppSpace.xs,
      top < 0 ? 0 : top,
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
    final padding = dense
        ? 2 * AppSpace.xxs + 2 * AppSpace.xxs + 2
        : 2 * AppSpace.xs + 2 * AppSpace.xxs + 2;
    return (text + padding).ceilToDouble().clamp(
      dense ? _denseMinRowHeight : _minRowHeight,
      double.infinity,
    );
  }

  /// Whole bar: floating card (transport row + seek strip) plus the outer
  /// gaps. The shell sizes the bar from this, so it must equal what [build]
  /// lays out.
  static double heightFor(TextScaler scaler, {bool dense = false}) =>
      (dense ? AppSpace.xxs : AppSpace.xs) +
      rowHeightFor(scaler, dense: dense) +
      (dense ? _denseSeekHeight : seekHeight) +
      (dense ? AppSpace.xs : AppSpace.sm);

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
    final rowHeight = rowHeightFor(scaler, dense: dense);
    final seek = dense ? _denseSeekHeight : seekHeight;
    final radius = BorderRadius.circular(AppRadii.card);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpace.sm,
        dense ? AppSpace.xxs : AppSpace.xs,
        AppSpace.sm,
        dense ? AppSpace.xs : AppSpace.sm,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: radius,
          border: Border.all(color: palette.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AudioVolumeWheel(
              controller: controller,
              child: SizedBox(
                height: rowHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: _OpenArea(
                          label: openLabel,
                          onTap: onOpen,
                          child: Row(
                            children: [
                              _Thumbnail(
                                entry: entry,
                                repository: repository,
                                isVideo: isVideo,
                                showEqualizer: controller.isPlaying && !isVideo,
                              ),
                              const SizedBox(width: AppSpace.sm),
                              Expanded(
                                child: _MiniPlayerSubtitle(
                                  key: ValueKey(entry.path),
                                  repository: repository,
                                  path: entry.path,
                                  fallbackTitle: entry.title,
                                  isVideo: isVideo,
                                ),
                              ),
                            ],
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
              ),
            ),
            SizedBox(
              height: seek,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.xxs),
                child: SeekBar(controller: controller),
              ),
            ),
          ],
        ),
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
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(AppRadii.control),
    child: SizedBox.fromSize(
      size: MiniPlayerBar.thumbnailSizeFor(isVideo),
      child: Stack(
        fit: StackFit.expand,
        children: [
          LibraryArtwork(
            mediaPath: entry.path,
            repository: repository,
            iconSize: 20,
          ),
          if (showEqualizer)
            Positioned(
              right: 3,
              bottom: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: PlayingEqualizerGlyph(isPlaying: true, size: 10),
                ),
              ),
            ),
        ],
      ),
    ),
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
    required this.repository,
    required this.path,
    required this.fallbackTitle,
    required this.isVideo,
  });

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
    if (widget.isVideo) {
      return _lines(widget.fallbackTitle, 'Video');
    }
    final record = _record;
    if (record == null) {
      return _lines(widget.fallbackTitle, 'Unknown artist');
    }
    return FutureBuilder<MediaItemRecord?>(
      future: record,
      builder: (context, snapshot) => _lines(
        snapshot.data?.title ?? widget.fallbackTitle,
        snapshot.data?.artist ?? 'Unknown artist',
      ),
    );
  }

  Widget _lines(String title, String subtitle) {
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
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
