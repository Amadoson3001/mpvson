import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../player/player_controller.dart';
import '../theme/library_theme.dart';

/// Now playing view featuring large artwork, track metadata, full transport
/// controls, timeline scrubber, volume, favorite toggle, and queue drawer.
class NowPlayingView extends StatefulWidget {
  const NowPlayingView({
    super.key,
    required this.controller,
    this.repository,
    this.onBack,
  });

  final PlayerController controller;
  final MediaLibraryRepository? repository;
  final VoidCallback? onBack;

  @override
  State<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends State<NowPlayingView> {
  bool _isQueuePanelOpen = false;
  Uint8List? _cachedArtwork;
  String? _cachedArtworkPath;
  MediaItemRecord? _currentMediaRecord;
  double? _dragPositionRatio;
  int _metadataGeneration = 0;

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
      _syncMetadata();
    }
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository?.removeListener(_onRepositoryChanged);
      widget.repository?.addListener(_onRepositoryChanged);
      _syncMetadata();
    }
  }

  @override
  void dispose() {
    _metadataGeneration++;
    widget.controller.removeListener(_onControllerChanged);
    widget.repository?.removeListener(_onRepositoryChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final cur = widget.controller.current;
    if (cur?.path != _cachedArtworkPath) {
      _syncMetadata();
    } else {
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
      if (mounted) {
        setState(() {
          _cachedArtwork = null;
          _cachedArtworkPath = null;
          _currentMediaRecord = null;
        });
      }
      return;
    }

    _cachedArtworkPath = cur.path;

    // Load thumbnail / artwork
    final thumb = await widget.controller.loadThumbnail(cur);
    if (mounted &&
        generation == _metadataGeneration &&
        _cachedArtworkPath == cur.path) {
      setState(() {
        _cachedArtwork = thumb?.bytes;
      });
    }

    // Load media record from repo if available
    if (widget.repository != null) {
      final record = await widget.repository!.getMediaByCanonicalSource(
        cur.path,
      );
      if (mounted &&
          generation == _metadataGeneration &&
          _cachedArtworkPath == cur.path) {
        setState(() {
          _currentMediaRecord = record;
        });
      }
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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
    final isPlaying = widget.controller.isPlaying;
    final duration = widget.controller.duration > Duration.zero
        ? widget.controller.duration
        : (entry?.duration ?? Duration.zero);
    final position = widget.controller.position;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 800;

        final mainStage = SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.onBack != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back_rounded),
                        tooltip: 'Back',
                        color: LibraryTheme.secondaryText,
                        onPressed: widget.onBack,
                      ),
                    ),
                  const SizedBox(height: 12),
                  // Large square artwork
                  _buildArtwork(context, isNarrow ? 260 : 340),
                  const SizedBox(height: 28),
                  // Title & Favorite row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(width: 48), // balance favorite button
                      Expanded(
                        child: Text(
                          _currentMediaRecord?.title ??
                              entry?.title ??
                              'No Track Playing',
                          style: LibraryTheme.pageTitle,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          (_currentMediaRecord?.isFavorite ?? false)
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: (_currentMediaRecord?.isFavorite ?? false)
                              ? LibraryTheme.accent
                              : LibraryTheme.mutedText,
                        ),
                        tooltip: (_currentMediaRecord?.isFavorite ?? false)
                            ? 'Remove from favorites'
                            : 'Add to favorites',
                        onPressed: entry != null ? _toggleFavorite : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Artist
                  Text(
                    _currentMediaRecord?.artist ?? 'Unknown Artist',
                    style: LibraryTheme.sectionTitle.copyWith(
                      color: LibraryTheme.secondaryText,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // Album
                  Text(
                    _currentMediaRecord?.album ?? '',
                    style: LibraryTheme.rowSecondary.copyWith(
                      color: LibraryTheme.mutedText,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 28),
                  // Timeline scrubber
                  _buildTimelineScrubber(position, duration),
                  const SizedBox(height: 20),
                  // Transport controls
                  _buildTransportControls(isPlaying),
                  const SizedBox(height: 24),
                  // Volume & Queue button row
                  _buildVolumeAndQueueRow(),
                ],
              ),
            ),
          ),
        );

        return Material(
          color: LibraryTheme.background,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!isNarrow)
                Row(
                  children: [
                    Expanded(child: mainStage),
                    if (_isQueuePanelOpen) ...[
                      const VerticalDivider(
                        width: 1,
                        color: LibraryTheme.border,
                      ),
                      SizedBox(width: 320, child: _buildQueuePanel()),
                    ],
                  ],
                )
              else ...[
                Positioned.fill(child: mainStage),
                if (_isQueuePanelOpen) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => setState(() => _isQueuePanelOpen = false),
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: (constraints.maxWidth * 0.85).clamp(280.0, 360.0),
                    child: _buildQueuePanel(),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildArtwork(BuildContext context, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: LibraryTheme.raisedSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LibraryTheme.border, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: _cachedArtwork != null
          ? Image.memory(
              _cachedArtwork!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _buildFallbackArtwork(),
            )
          : _buildFallbackArtwork(),
    );
  }

  Widget _buildFallbackArtwork() {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.1),
          radius: 0.9,
          colors: [
            Color(0xFF223052),
            LibraryTheme.surface,
            LibraryTheme.background,
          ],
        ),
      ),
      child: Center(
        child: Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: LibraryTheme.raisedSurface,
            border: Border.all(
              color: LibraryTheme.accent.withValues(alpha: 0.3),
              width: 3,
            ),
          ),
          child: const Icon(
            Icons.music_note_rounded,
            size: 42,
            color: LibraryTheme.accent,
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineScrubber(Duration position, Duration duration) {
    final totalMs = duration.inMilliseconds;
    final currentMs = _dragPositionRatio != null && totalMs > 0
        ? (_dragPositionRatio! * totalMs).round()
        : position.inMilliseconds;
    final currentPos = Duration(milliseconds: currentMs);

    final ratio = totalMs > 0 ? (currentMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return Column(
      children: [
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: LibraryTheme.accent,
            inactiveTrackColor: LibraryTheme.border,
            thumbColor: LibraryTheme.accent,
            overlayColor: LibraryTheme.accent.withValues(alpha: 0.16),
          ),
          child: Slider(
            value: ratio,
            onChanged: totalMs > 0
                ? (val) {
                    setState(() => _dragPositionRatio = val);
                  }
                : null,
            onChangeEnd: totalMs > 0
                ? (val) {
                    final target = Duration(
                      milliseconds: (val * totalMs).round(),
                    );
                    widget.controller.seek(target);
                    setState(() => _dragPositionRatio = null);
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(currentPos), style: LibraryTheme.metadata),
              Text(_formatDuration(duration), style: LibraryTheme.metadata),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTransportControls(bool isPlaying) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Shuffle
        IconButton(
          icon: const Icon(Icons.shuffle_rounded),
          tooltip: 'Shuffle',
          color: widget.controller.shuffle
              ? LibraryTheme.accent
              : LibraryTheme.mutedText,
          onPressed: () => widget.controller.toggleShuffle(),
        ),
        const SizedBox(width: 16),
        // Previous
        IconButton(
          icon: const Icon(Icons.skip_previous_rounded, size: 30),
          tooltip: 'Previous',
          color: LibraryTheme.primaryText,
          onPressed: () => widget.controller.previous(),
        ),
        const SizedBox(width: 20),
        // Play / Pause
        Container(
          width: 58,
          height: 58,
          decoration: const BoxDecoration(
            color: LibraryTheme.accent,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 32,
              color: LibraryTheme.background,
            ),
            tooltip: isPlaying ? 'Pause' : 'Play',
            onPressed: () => widget.controller.togglePlayPause(),
          ),
        ),
        const SizedBox(width: 20),
        // Next
        IconButton(
          icon: const Icon(Icons.skip_next_rounded, size: 30),
          tooltip: 'Next',
          color: LibraryTheme.primaryText,
          onPressed: () => widget.controller.next(),
        ),
        const SizedBox(width: 16),
        // Repeat
        IconButton(
          icon: Icon(
            widget.controller.repeatMode == 'one'
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
          ),
          tooltip: 'Repeat: ${widget.controller.repeatMode}',
          color: widget.controller.repeatMode != 'off'
              ? LibraryTheme.accent
              : LibraryTheme.mutedText,
          onPressed: () => widget.controller.cycleRepeat(),
        ),
      ],
    );
  }

  Widget _buildVolumeAndQueueRow() {
    final vol = widget.controller.volume;
    final IconData volIcon = vol <= 0
        ? Icons.volume_off_rounded
        : vol < 50
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: Icon(volIcon, size: 20),
          tooltip: vol <= 0 ? 'Unmute' : 'Mute',
          color: LibraryTheme.secondaryText,
          onPressed: () => widget.controller.toggleMute(),
        ),
        SizedBox(
          width: 120,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              activeTrackColor: LibraryTheme.secondaryText,
              inactiveTrackColor: LibraryTheme.border,
              thumbColor: LibraryTheme.primaryText,
            ),
            child: Slider(
              value: vol.clamp(0.0, 100.0),
              min: 0,
              max: 100,
              onChanged: (val) => widget.controller.setVolume(val),
            ),
          ),
        ),
        const SizedBox(width: 24),
        IconButton(
          icon: const Icon(Icons.queue_music_rounded, size: 22),
          tooltip: _isQueuePanelOpen ? 'Hide queue' : 'Show queue',
          color: _isQueuePanelOpen
              ? LibraryTheme.accent
              : LibraryTheme.secondaryText,
          onPressed: () {
            setState(() {
              _isQueuePanelOpen = !_isQueuePanelOpen;
            });
          },
        ),
      ],
    );
  }

  Widget _buildQueuePanel() {
    final queue = widget.controller.queue;
    final currentIndex = widget.controller.currentIndex;

    return Material(
      color: LibraryTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Queue (${queue.length})',
                  style: LibraryTheme.sectionTitle,
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: 'Close queue',
                  visualDensity: VisualDensity.compact,
                  color: LibraryTheme.mutedText,
                  onPressed: () => setState(() => _isQueuePanelOpen = false),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: LibraryTheme.border),
          Expanded(
            child: queue.isEmpty
                ? const Center(
                    child: Text('Queue is empty', style: LibraryTheme.metadata),
                  )
                : ListView.separated(
                    itemCount: queue.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: LibraryTheme.border),
                    itemBuilder: (context, index) {
                      final item = queue[index];
                      final isCurrent = index == currentIndex;

                      return ListTile(
                        dense: true,
                        selected: isCurrent,
                        selectedTileColor: LibraryTheme.accent.withValues(
                          alpha: 0.1,
                        ),
                        leading: isCurrent
                            ? const Icon(
                                Icons.volume_up_rounded,
                                size: 16,
                                color: LibraryTheme.accent,
                              )
                            : Text(
                                '${index + 1}',
                                style: LibraryTheme.metadata,
                              ),
                        title: Text(
                          item.title,
                          style: LibraryTheme.rowPrimary.copyWith(
                            color: isCurrent
                                ? LibraryTheme.accent
                                : LibraryTheme.primaryText,
                            fontWeight: isCurrent
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16),
                          tooltip: 'Remove',
                          visualDensity: VisualDensity.compact,
                          color: LibraryTheme.mutedText,
                          onPressed: () => widget.controller.removeAt(index),
                        ),
                        onTap: () => widget.controller.playIndex(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
