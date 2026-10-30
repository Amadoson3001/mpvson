import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../player/player_controller.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/media_row.dart';
import '../../core/components/empty_state.dart';
import '../widgets/add_to_playlist_dialog.dart';

enum VideoViewMode { grid, list }

/// Videos library view displaying video files in grid or list layout with
/// duration, file size, thumbnail, and playback actions.
class VideosView extends StatefulWidget {
  const VideosView({
    super.key,
    required this.repository,
    required this.controller,
    this.searchQuery,
    this.onAddFolders,
    this.onShowInFolder,
  });

  final MediaLibraryRepository repository;
  final PlayerController controller;
  final String? searchQuery;
  final VoidCallback? onAddFolders;
  final ValueChanged<String>? onShowInFolder;

  @override
  State<VideosView> createState() => _VideosViewState();
}

class _VideosViewState extends State<VideosView> {
  VideoViewMode _viewMode = VideoViewMode.grid;
  String? _selectedVideo;
  String _sortBy = 'addedAt';
  bool _ascending = false;
  List<MediaItemRecord>? _videos;
  bool _isLoading = false;
  Future<void>? _reloadFuture;
  bool _reloadAgain = false;
  Timer? _reloadThrottle;
  Timer? _searchReload;

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_onRepoChanged);
    _reload();
  }

  @override
  void didUpdateWidget(VideosView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_onRepoChanged);
      widget.repository.addListener(_onRepoChanged);
      _reload();
    } else if (oldWidget.searchQuery != widget.searchQuery) {
      _searchReload?.cancel();
      _searchReload = Timer(const Duration(milliseconds: 150), () {
        _searchReload = null;
        if (mounted) _reload();
      });
    }
  }

  @override
  void dispose() {
    _reloadThrottle?.cancel();
    _searchReload?.cancel();
    widget.repository.removeListener(_onRepoChanged);
    super.dispose();
  }

  void _onRepoChanged() {
    // Scan progress notifies frequently; coalesce those into one refresh.
    if (_reloadThrottle?.isActive ?? false) {
      _reloadAgain = true;
      return;
    }
    _reloadThrottle = Timer(const Duration(milliseconds: 200), () {
      _reloadThrottle = null;
      if (mounted) _reload();
    });
  }

  Future<void> _reload() {
    if (!mounted) return Future<void>.value();
    _reloadAgain = true;
    final active = _reloadFuture;
    if (active != null) return active;
    final future = _drainReloads();
    final tracked = future.whenComplete(() {
      _reloadFuture = null;
      if (_reloadAgain && mounted) unawaited(_reload());
    });
    _reloadFuture = tracked;
    return tracked;
  }

  Future<void> _drainReloads() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      do {
        _reloadAgain = false;
        final videos = await widget.repository.queryMedia(
          kind: MediaKind.video,
          searchQuery: widget.searchQuery,
          sortBy: _sortBy,
          ascending: _ascending,
        );
        if (!mounted) return;
        if (_reloadAgain) continue;
        setState(() => _videos = videos);
      } while (_reloadAgain && mounted);
    } catch (error) {
      debugPrint('Videos view could not refresh: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static String _formatFileSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  void _showInFolder(String path) {
    if (widget.onShowInFolder != null) {
      widget.onShowInFolder!(path);
      return;
    }
    try {
      if (Platform.isWindows) {
        Process.run('explorer.exe', ['/select,', path.replaceAll('/', '\\')]);
      } else if (Platform.isLinux) {
        Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (_) {}
  }

  Future<void> _playVideo(MediaItemRecord video) async {
    if (!video.isAvailable) return;
    await widget.controller.openPaths(
      [video.path],
      append: false,
      initialIndex: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasVideos = (_videos ?? const <MediaItemRecord>[]).isNotEmpty;
    return Material(
      color: context.palette.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Controls / View toggle bar (only shown when videos exist)
          if (hasVideos) ...[
            _buildToolbar(),
            Divider(height: 1, color: context.palette.border),
          ],
          // Video Stage
          Expanded(
            child: _isLoading && _videos == null
                ? Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  )
                : !hasVideos
                ? EmptyState(
                    title: 'No videos found',
                    message:
                        widget.searchQuery != null &&
                            widget.searchQuery!.isNotEmpty
                        ? 'No video files matched "${widget.searchQuery}".'
                        : 'Add your video folders to browse your movies, clips, and recorded videos.',
                    actionLabel: 'Add folder',
                    icon: Icons.video_library_rounded,
                    onAction: widget.searchQuery?.trim().isNotEmpty ?? false
                        ? null
                        : widget.onAddFolders,
                  )
                : _viewMode == VideoViewMode.grid
                ? _buildVideoGrid(_videos!)
                : _buildVideoList(_videos!),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final accent = Theme.of(context).colorScheme.primary;
    final count = _videos?.length ?? 0;
    return Container(
      color: context.palette.surface,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: 8),
      child: Row(
        children: [
          if (count > 0)
            Text(
              '$count ${count == 1 ? 'video' : 'videos'}',
              style: context.palette.metadata,
            ),
          const Spacer(),
          // Sort dropdown
          Text('Sort by: ', style: context.palette.metadata),
          const SizedBox(width: 6),
          DropdownButton<String>(
            value: _sortBy,
            underline: const SizedBox.shrink(),
            dropdownColor: context.palette.surface,
            style: context.palette.rowPrimary.copyWith(fontSize: AppType.small),
            icon: Icon(
              Icons.arrow_drop_down,
              color: context.palette.secondaryText,
              size: 18,
            ),
            items: const [
              DropdownMenuItem(value: 'title', child: Text('Title')),
              DropdownMenuItem(value: 'addedAt', child: Text('Date added')),
              DropdownMenuItem(value: 'duration', child: Text('Duration')),
              DropdownMenuItem(value: 'fileSize', child: Text('File size')),
            ],
            onChanged: (val) {
              if (val != null) {
                setState(() => _sortBy = val);
                _reload();
              }
            },
          ),
          IconButton(
            icon: Icon(
              _ascending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              size: 16,
              color: context.palette.secondaryText,
            ),
            tooltip: _ascending ? 'Ascending' : 'Descending',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() => _ascending = !_ascending);
              _reload();
            },
          ),
          const SizedBox(width: 12),
          VerticalDivider(
            width: 1,
            indent: 6,
            endIndent: 6,
            color: context.palette.border,
          ),
          const SizedBox(width: 12),
          // Grid / List toggle
          IconButton(
            icon: Icon(
              Icons.grid_view_rounded,
              size: 18,
              color: _viewMode == VideoViewMode.grid
                  ? accent
                  : context.palette.mutedText,
            ),
            tooltip: 'Grid view',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _viewMode = VideoViewMode.grid),
          ),
          IconButton(
            icon: Icon(
              Icons.view_list_rounded,
              size: 20,
              color: _viewMode == VideoViewMode.list
                  ? accent
                  : context.palette.mutedText,
            ),
            tooltip: 'List view',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _viewMode = VideoViewMode.list),
          ),
        ],
      ),
    );
  }

  // --- Grid View ---

  Widget _buildVideoGrid(List<MediaItemRecord> videos) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth - 48 + 20) / 280).ceil().clamp(
          1,
          12,
        );
        final width =
            (constraints.maxWidth - 48 - (columns - 1) * 20) / columns;
        return GridView.builder(
          addAutomaticKeepAlives: false,
          padding: const EdgeInsets.all(AppSpace.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 24,
            crossAxisSpacing: 20,
            mainAxisExtent: width * 9 / 16 + 68,
          ),
          itemCount: videos.length,
          itemBuilder: (context, index) {
            final video = videos[index];
            final isUnavailable = !video.isAvailable;
            return _VideoGridCard(
              key: ValueKey(video.id),
              video: video,
              isSelected: _selectedVideo == video.id,
              controller: widget.controller,
              onSelect: () {
                if (_selectedVideo != video.id) {
                  setState(() => _selectedVideo = video.id);
                }
              },
              onPlay: isUnavailable ? null : () => _playVideo(video),
              actionMenu: _buildVideoItemActionMenu(video),
            );
          },
        );
      },
    );
  }

  // --- List View ---

  Widget _buildVideoList(List<MediaItemRecord> videos) {
    final accent = Theme.of(context).colorScheme.primary;
    return ListView.separated(
      addAutomaticKeepAlives: false,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.md,
      ),
      itemCount: videos.length + 1,
      separatorBuilder: (_, index) => index == 0
          ? Divider(height: 16, thickness: 1, color: context.palette.border)
          : Divider(height: 1, color: context.palette.surface),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm,
              vertical: AppSpace.xs,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Text('#', style: context.palette.metadata),
                ),
                Expanded(
                  flex: 5,
                  child: Text('Title', style: context.palette.metadata),
                ),
                Expanded(
                  flex: 2,
                  child: Text('Size', style: context.palette.metadata),
                ),
                SizedBox(
                  width: 90,
                  child: Text(
                    'Duration',
                    style: context.palette.metadata,
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 48), // Favorite icon space
                const SizedBox(width: 40), // More menu space
              ],
            ),
          );
        }

        final videoIndex = index - 1;
        final video = videos[videoIndex];
        final isUnavailable = !video.isAvailable;

        return MediaRow(
          key: ValueKey(video.id),
          onSelect: () {
            if (_selectedVideo != video.id) {
              setState(() => _selectedVideo = video.id);
            }
          },
          onPlay: isUnavailable ? null : () => _playVideo(video),
          builder: (context, rowFocus) => InkWell(
            canRequestFocus: false,
            onTap: () {
              rowFocus.requestFocus();
              setState(() => _selectedVideo = video.id);
            },
            onDoubleTap: isUnavailable ? null : () => _playVideo(video),
            borderRadius: BorderRadius.circular(AppRadii.control),
            hoverColor: context.palette.hover,
            child: Container(
              color: _selectedVideo == video.id
                  ? context.palette.hover
                  : Colors.transparent,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: 10,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Text('${videoIndex + 1}', style: context.palette.metadata),
                  ),
                  Expanded(
                    flex: 5,
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            video.title,
                            style: context.palette.rowPrimary.copyWith(
                              color: isUnavailable
                                  ? context.palette.mutedText
                                  : context.palette.primaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isUnavailable) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: context.palette.danger.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                            ),
                            child: Text(
                              'Missing',
                              style: context.palette.badge.copyWith(
                                fontSize: AppType.caption,
                                color: context.palette.danger,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      _formatFileSize(video.fileSize),
                      style: context.palette.rowSecondary,
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      _formatDuration(video.metadata.duration),
                      style: context.palette.metadata,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: IconButton(
                      icon: Icon(
                        video.isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 18,
                        color: video.isFavorite ? accent : context.palette.mutedText,
                      ),
                      tooltip: video.isFavorite
                          ? 'Remove favorite'
                          : 'Add to favorites',
                      onPressed: () => widget.repository.toggleFavorite(
                        video.id,
                        !video.isFavorite,
                      ),
                    ),
                  ),
                  SizedBox(width: 40, child: _buildVideoItemActionMenu(video)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideoItemActionMenu(MediaItemRecord video) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert_rounded,
        size: 18,
        color: context.palette.mutedText,
      ),
      tooltip: 'Actions',
      color: context.palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        side: BorderSide(color: context.palette.border),
      ),
      onSelected: (action) async {
        switch (action) {
          case 'play_now':
            await _playVideo(video);
            break;
          case 'play_next':
            await widget.controller.openPaths(
              [video.path],
              append: true,
              playNext: true,
            );
            break;
          case 'add_queue':
            await widget.controller.openPaths(
              [video.path],
              append: true,
              playNext: false,
            );
            break;
          case 'toggle_favorite':
            await widget.repository.toggleFavorite(video.id, !video.isFavorite);
            break;
          case 'add_playlist':
            final added = await AddToPlaylistDialog.show(
              context,
              widget.repository,
              video.id,
            );
            if (added && mounted) {
              AppToast.show(
                context,
                'Added to playlist',
                tone: AppToastTone.success,
                duration: const Duration(seconds: 3),
              );
            }
            break;
          case 'show_folder':
            _showInFolder(video.path);
            break;
        }
      },
      itemBuilder: (context) {
        final accent = Theme.of(context).colorScheme.primary;
        return [
          PopupMenuItem(
            value: 'play_now',
            enabled: video.isAvailable,
            child: Row(
              children: [
                Icon(Icons.play_arrow_rounded, size: 18, color: accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Play now', style: context.palette.rowPrimary),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'play_next',
            enabled: video.isAvailable,
            child: Row(
              children: [
                Icon(
                  Icons.playlist_play_rounded,
                  size: 18,
                  color: context.palette.secondaryText,
                ),
                SizedBox(width: 10),
                Expanded(child: Text('Play next', style: context.palette.rowPrimary)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'add_queue',
            enabled: video.isAvailable,
            child: Row(
              children: [
                Icon(
                  Icons.queue_music_rounded,
                  size: 18,
                  color: context.palette.secondaryText,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Add to queue', style: context.palette.rowPrimary),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'add_playlist',
            child: Row(
              children: [
                Icon(
                  Icons.playlist_add_rounded,
                  size: 18,
                  color: context.palette.secondaryText,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Add to playlist', style: context.palette.rowPrimary),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'toggle_favorite',
            child: Row(
              children: [
                Icon(
                  video.isFavorite
                      ? Icons.favorite_border_rounded
                      : Icons.favorite_rounded,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    video.isFavorite ? 'Remove favorite' : 'Favorite',
                    style: context.palette.rowPrimary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(height: 1),
          PopupMenuItem(
            value: 'show_folder',
            child: Row(
              children: [
                Icon(
                  Icons.folder_open_rounded,
                  size: 18,
                  color: context.palette.secondaryText,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Show in folder', style: context.palette.rowPrimary),
                ),
              ],
            ),
          ),
        ];
      },
    );
  }
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.video, required this.controller});

  final MediaItemRecord video;
  final PlayerController controller;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  late Future<MediaThumbnail?> _thumbnail;
  ThumbnailRequestHandle? _request;

  @override
  void initState() {
    super.initState();
    _thumbnail = _load();
  }

  @override
  void didUpdateWidget(_VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.path != widget.video.path ||
        oldWidget.video.modifiedAt != widget.video.modifiedAt ||
        oldWidget.video.isAvailable != widget.video.isAvailable ||
        oldWidget.controller != widget.controller) {
      _request?.release();
      _request = null;
      _thumbnail = _load();
    }
  }

  @override
  void dispose() {
    _request?.release();
    super.dispose();
  }

  Future<MediaThumbnail?> _load() async {
    if (!widget.video.isAvailable) return null;
    try {
      _request = widget.controller.requestThumbnail(
        MediaEntry.fromPath(widget.video.path, id: widget.video.id),
      );
      return await _request?.thumbnail;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback() => ColoredBox(
      color: context.palette.raisedSurface,
      child: Center(
        child: Icon(
          Icons.movie_creation_rounded,
          size: 40,
          color: context.palette.mutedText,
        ),
      ),
    );
    return FutureBuilder<MediaThumbnail?>(
      future: _thumbnail,
      builder: (context, snapshot) {
        final bytes = snapshot.data?.bytes;
        return bytes == null
            ? fallback()
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                cacheWidth: 512,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback(),
              );
      },
    );
  }
}

class _VideoGridCard extends StatefulWidget {
  const _VideoGridCard({
    super.key,
    required this.video,
    required this.isSelected,
    required this.controller,
    required this.onSelect,
    required this.onPlay,
    required this.actionMenu,
  });

  final MediaItemRecord video;
  final bool isSelected;
  final PlayerController controller;
  final VoidCallback onSelect;
  final VoidCallback? onPlay;
  final Widget actionMenu;

  @override
  State<_VideoGridCard> createState() => _VideoGridCardState();
}

class _VideoGridCardState extends State<_VideoGridCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final isUnavailable = !video.isAvailable;
    final accent = Theme.of(context).colorScheme.primary;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: MediaRow(
        key: ValueKey(video.id),
        onSelect: widget.onSelect,
        onPlay: widget.onPlay,
        builder: (context, rowFocus) {
          final showPlayOverlay =
              !isUnavailable &&
              (_isHovered || widget.isSelected || rowFocus.hasFocus);
          return InkWell(
            canRequestFocus: false,
            onTap: () {
              rowFocus.requestFocus();
              widget.onSelect();
            },
            onDoubleTap: widget.onPlay,
            borderRadius: BorderRadius.circular(AppRadii.artwork),
            child: Container(
              decoration: BoxDecoration(
                color: widget.isSelected
                    ? context.palette.hover
                    : context.palette.background,
                borderRadius: BorderRadius.circular(AppRadii.artwork),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Video Thumbnail Stage
                  RepaintBoundary(
                    child: AnimatedScale(
                      scale: (AppMotion.lowPower(context) || !showPlayOverlay)
                          ? 1.0
                          : 1.02,
                      duration: AppMotion.duration(context, AppMotion.hover),
                      curve: AppMotion.enter,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadii.artwork),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _VideoPreview(
                                video: video,
                                controller: widget.controller,
                              ),
                              if (widget.controller.recent.any(
                                (entry) =>
                                    entry.path == video.path &&
                                    entry.position > Duration.zero &&
                                    entry.duration > Duration.zero,
                              ))
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: Builder(
                                    builder: (context) {
                                      final entry = widget.controller.recent
                                          .firstWhere(
                                            (entry) => entry.path == video.path,
                                          );
                                      return LinearProgressIndicator(
                                        minHeight: 2,
                                        value:
                                            (entry.position.inMilliseconds /
                                                    entry
                                                        .duration
                                                        .inMilliseconds)
                                                .clamp(0.0, 1.0),
                                        color: accent,
                                        backgroundColor: Colors.transparent,
                                      );
                                    },
                                  ),
                                ),
                              // Duration badge
                              if (video.metadata.duration > Duration.zero)
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.75,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        AppRadii.control,
                                      ),
                                    ),
                                    child: Text(
                                      _VideosViewState._formatDuration(
                                        video.metadata.duration,
                                      ),
                                      style: context.palette.badge.copyWith(
                                        fontSize: AppType.caption,
                                      ),
                                    ),
                                  ),
                                ),
                              // Missing file indicator badge
                              if (isUnavailable)
                                Positioned(
                                  left: 8,
                                  top: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: context.palette.danger.withValues(
                                        alpha: 0.85,
                                      ),
                                      borderRadius: BorderRadius.circular(
                                        AppRadii.control,
                                      ),
                                    ),
                                    child: Text(
                                      'File missing',
                                      style: context.palette.badge.copyWith(
                                        fontSize: AppType.caption,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              // Subtle play button overlay on hover or focus
                              if (showPlayOverlay)
                                Center(
                                  child: IconButton.filled(
                                    onPressed: widget.onPlay,
                                    tooltip: 'Play video',
                                    style: IconButton.styleFrom(
                                      backgroundColor: Colors.black.withValues(
                                        alpha: 0.65,
                                      ),
                                      foregroundColor: accent,
                                      minimumSize: const Size(40, 40),
                                    ),
                                    icon: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 22,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Card Bottom Details
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.sm,
                      10,
                      AppSpace.xs,
                      10,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                video.title,
                                style: context.palette.rowPrimary.copyWith(
                                  color: isUnavailable
                                      ? context.palette.mutedText
                                      : context.palette.primaryText,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _VideosViewState._formatFileSize(video.fileSize),
                                style: context.palette.metadata,
                              ),
                            ],
                          ),
                        ),
                        widget.actionMenu,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
