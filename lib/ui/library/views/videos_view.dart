import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../player/player_controller.dart';
import '../theme/library_theme.dart';
import '../widgets/empty_library_view.dart';

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
    this.onSwitchToVideo,
  });

  final MediaLibraryRepository repository;
  final PlayerController controller;
  final String? searchQuery;
  final VoidCallback? onAddFolders;
  final ValueChanged<String>? onShowInFolder;
  final VoidCallback? onSwitchToVideo;

  @override
  State<VideosView> createState() => _VideosViewState();
}

class _VideosViewState extends State<VideosView> {
  static const int _pageSize = 80;

  VideoViewMode _viewMode = VideoViewMode.grid;
  String _sortBy = 'addedAt';
  bool _ascending = false;
  List<MediaItemRecord>? _videos;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _pageLoadFailed = false;
  bool _hasMore = true;
  bool _loadMoreScheduled = false;
  bool _requestRunning = false;
  int? _pendingOffset;
  int _nextOffset = 0;
  int _queryGeneration = 0;

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
      _reload();
    }
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onRepoChanged);
    super.dispose();
  }

  void _onRepoChanged() {
    _reload();
  }

  void _reload() {
    if (!mounted) return;
    _queryGeneration++;
    setState(() {
      _videos = null;
      _isLoading = true;
      _isLoadingMore = false;
      _pageLoadFailed = false;
      _hasMore = true;
      _nextOffset = 0;
    });
    _queuePage(0);
  }

  void _queuePage(int offset) {
    _pendingOffset = offset;
    _pumpPages();
  }

  void _pumpPages() {
    if (!mounted || _requestRunning || _pendingOffset == null) return;
    final offset = _pendingOffset!;
    final generation = _queryGeneration;
    _pendingOffset = null;
    _requestRunning = true;
    unawaited(
      _loadPage(generation, offset).whenComplete(() {
        _requestRunning = false;
        _pumpPages();
      }),
    );
  }

  Future<void> _loadPage(int generation, int offset) async {
    try {
      final videos = await widget.repository.queryMedia(
        kind: MediaKind.video,
        searchQuery: widget.searchQuery,
        limit: _pageSize,
        offset: offset,
        sortBy: _sortBy,
        ascending: _ascending,
      );
      if (!mounted || generation != _queryGeneration) return;
      setState(() {
        _videos = offset == 0
            ? videos
            : <MediaItemRecord>[...?_videos, ...videos];
        _nextOffset = offset + videos.length;
        _hasMore = videos.length == _pageSize;
        _isLoading = false;
        _isLoadingMore = false;
        _pageLoadFailed = false;
      });
    } catch (error) {
      debugPrint('Videos view could not refresh: $error');
      if (mounted && generation == _queryGeneration) {
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
          _pageLoadFailed = true;
        });
      }
    }
  }

  void _loadMore() {
    if (!mounted ||
        _videos == null ||
        !_hasMore ||
        _isLoading ||
        _isLoadingMore) {
      return;
    }
    final offset = _nextOffset;
    setState(() => _isLoadingMore = true);
    _queuePage(offset);
  }

  void _retryPage() {
    if (!mounted || !_pageLoadFailed) return;
    final offset = _videos == null ? 0 : _nextOffset;
    setState(() {
      _pageLoadFailed = false;
      _isLoading = _videos == null;
      _isLoadingMore = _videos != null;
    });
    _queuePage(offset);
  }

  void _scheduleLoadMore() {
    if (_loadMoreScheduled ||
        !_hasMore ||
        _pageLoadFailed ||
        _isLoadingMore ||
        _isLoading) {
      return;
    }
    _loadMoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreScheduled = false;
      if (mounted) _loadMore();
    });
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
    await widget.controller.openPaths(
      [video.path],
      append: false,
      initialIndex: 0,
    );
    widget.onSwitchToVideo?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: LibraryTheme.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Controls / View toggle bar
          _buildToolbar(),
          const Divider(height: 1, color: LibraryTheme.border),
          // Video Stage
          Expanded(
            child: _isLoading && _videos == null
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        LibraryTheme.accent,
                      ),
                    ),
                  )
                : _pageLoadFailed && _videos == null
                ? _buildLoadError()
                : (_videos ?? const <MediaItemRecord>[]).isEmpty
                ? EmptyLibraryView(
                    title: 'No videos found',
                    message:
                        widget.searchQuery != null &&
                            widget.searchQuery!.isNotEmpty
                        ? 'No video files matched "${widget.searchQuery}".'
                        : 'Add your video folders to browse your movies, clips, and recorded videos.',
                    actionLabel:
                        widget.searchQuery != null &&
                            widget.searchQuery!.isNotEmpty
                        ? ''
                        : 'Add folders',
                    icon: Icons.video_library_rounded,
                    onAction:
                        widget.searchQuery != null &&
                            widget.searchQuery!.isNotEmpty
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

  Widget _buildLoadError() {
    return Center(
      child: TextButton.icon(
        onPressed: _retryPage,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Could not load videos. Retry'),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: LibraryTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(
        children: [
          Text('Videos', style: LibraryTheme.sectionTitle),
          const Spacer(),
          // Sort dropdown
          Text('Sort by: ', style: LibraryTheme.metadata),
          const SizedBox(width: 6),
          DropdownButton<String>(
            value: _sortBy,
            underline: const SizedBox.shrink(),
            dropdownColor: LibraryTheme.surface,
            style: LibraryTheme.rowPrimary.copyWith(fontSize: 12.5),
            icon: const Icon(
              Icons.arrow_drop_down,
              color: LibraryTheme.secondaryText,
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
              color: LibraryTheme.secondaryText,
            ),
            tooltip: _ascending ? 'Ascending' : 'Descending',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() => _ascending = !_ascending);
              _reload();
            },
          ),
          const SizedBox(width: 12),
          const VerticalDivider(
            width: 1,
            indent: 6,
            endIndent: 6,
            color: LibraryTheme.border,
          ),
          const SizedBox(width: 12),
          // Grid / List toggle
          IconButton(
            icon: Icon(
              Icons.grid_view_rounded,
              size: 18,
              color: _viewMode == VideoViewMode.grid
                  ? LibraryTheme.accent
                  : LibraryTheme.mutedText,
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
                  ? LibraryTheme.accent
                  : LibraryTheme.mutedText,
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
    return GridView.builder(
      key: ValueKey<int>(_queryGeneration),
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisSpacing: 24,
        crossAxisSpacing: 20,
        childAspectRatio: 1.15,
      ),
      itemCount: videos.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == videos.length) {
          _scheduleLoadMore();
          return Center(
            child: _pageLoadFailed
                ? TextButton(onPressed: _retryPage, child: const Text('Retry'))
                : _isLoadingMore
                ? const CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      LibraryTheme.accent,
                    ),
                  )
                : const SizedBox.shrink(),
          );
        }
        final video = videos[index];
        return _VideoGridCard(
          video: video,
          controller: widget.controller,
          onPlay: () => _playVideo(video),
          actionMenu: _buildVideoItemActionMenu(video),
        );
      },
    );
  }

  // --- List View ---

  Widget _buildVideoList(List<MediaItemRecord> videos) {
    return ListView.separated(
      key: ValueKey<int>(_queryGeneration),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      itemCount: videos.length + 1 + (_hasMore ? 1 : 0),
      separatorBuilder: (_, index) => index == 0
          ? const Divider(height: 16, thickness: 1, color: LibraryTheme.border)
          : const Divider(height: 1, color: LibraryTheme.surface),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 36,
                  child: Text('#', style: LibraryTheme.metadata),
                ),
                const SizedBox(width: 48), // Preview column
                const SizedBox(width: 12),
                const Expanded(
                  flex: 5,
                  child: Text('Title', style: LibraryTheme.metadata),
                ),
                const Expanded(
                  flex: 2,
                  child: Text('Size', style: LibraryTheme.metadata),
                ),
                const SizedBox(
                  width: 90,
                  child: Text(
                    'Duration',
                    style: LibraryTheme.metadata,
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 48), // Favorite icon space
                const SizedBox(width: 40), // More menu space
              ],
            ),
          );
        }

        if (index == videos.length + 1) {
          _scheduleLoadMore();
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: _pageLoadFailed
                  ? TextButton(
                      onPressed: _retryPage,
                      child: const Text('Could not load more. Retry'),
                    )
                  : _isLoadingMore
                  ? const CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        LibraryTheme.accent,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          );
        }

        final videoIndex = index - 1;
        final video = videos[videoIndex];
        final isUnavailable = !video.isAvailable;

        return InkWell(
          onTap: () => _playVideo(video),
          onDoubleTap: () => _playVideo(video),
          borderRadius: BorderRadius.circular(8),
          hoverColor: LibraryTheme.hover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    '${videoIndex + 1}',
                    style: LibraryTheme.metadata,
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 48,
                    height: 30,
                    child: _VideoThumbnailStage(
                      video: video,
                      controller: widget.controller,
                      iconSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          video.title,
                          style: LibraryTheme.rowPrimary.copyWith(
                            color: isUnavailable
                                ? LibraryTheme.mutedText
                                : LibraryTheme.primaryText,
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
                            color: LibraryTheme.danger.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Missing',
                            style: LibraryTheme.badge.copyWith(
                              fontSize: 10,
                              color: LibraryTheme.danger,
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
                    style: LibraryTheme.rowSecondary,
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: Text(
                    _formatDuration(video.metadata.duration),
                    style: LibraryTheme.metadata,
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
                      color: video.isFavorite
                          ? LibraryTheme.accent
                          : LibraryTheme.mutedText,
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
        );
      },
    );
  }

  Widget _buildVideoItemActionMenu(MediaItemRecord video) {
    return PopupMenuButton<String>(
      icon: const Icon(
        Icons.more_vert_rounded,
        size: 18,
        color: LibraryTheme.mutedText,
      ),
      tooltip: 'Actions',
      color: LibraryTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: LibraryTheme.border),
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
          case 'show_folder':
            _showInFolder(video.path);
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'play_now',
          child: Row(
            children: [
              Icon(
                Icons.play_arrow_rounded,
                size: 18,
                color: LibraryTheme.accent,
              ),
              SizedBox(width: 10),
              Expanded(child: Text('Play now', style: LibraryTheme.rowPrimary)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'play_next',
          child: Row(
            children: [
              Icon(
                Icons.playlist_play_rounded,
                size: 18,
                color: LibraryTheme.secondaryText,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text('Play next', style: LibraryTheme.rowPrimary),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'add_queue',
          child: Row(
            children: [
              Icon(
                Icons.queue_music_rounded,
                size: 18,
                color: LibraryTheme.secondaryText,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text('Add to queue', style: LibraryTheme.rowPrimary),
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
                color: LibraryTheme.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  video.isFavorite ? 'Remove favorite' : 'Favorite',
                  style: LibraryTheme.rowPrimary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: 'show_folder',
          child: Row(
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 18,
                color: LibraryTheme.secondaryText,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text('Show in folder', style: LibraryTheme.rowPrimary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VideoGridCard extends StatefulWidget {
  const _VideoGridCard({
    required this.video,
    required this.controller,
    required this.onPlay,
    required this.actionMenu,
  });

  final MediaItemRecord video;
  final PlayerController controller;
  final VoidCallback onPlay;
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

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onPlay,
        onDoubleTap: widget.onPlay,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: LibraryTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isHovered
                  ? LibraryTheme.accent.withValues(alpha: 0.5)
                  : LibraryTheme.border,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Video Thumbnail Stage
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _VideoThumbnailStage(
                      video: video,
                      controller: widget.controller,
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
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _VideosViewState._formatDuration(
                              video.metadata.duration,
                            ),
                            style: LibraryTheme.badge.copyWith(fontSize: 10),
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
                            color: LibraryTheme.danger.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'File missing',
                            style: LibraryTheme.badge.copyWith(
                              fontSize: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    // Animated Play Button on Hover
                    AnimatedOpacity(
                      opacity: _isHovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: Center(
                        child: AnimatedScale(
                          scale: _isHovered ? 1.0 : 0.8,
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOutCubic,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: LibraryTheme.accent,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Card Bottom Details
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            video.title,
                            style: LibraryTheme.rowPrimary.copyWith(
                              color: isUnavailable
                                  ? LibraryTheme.mutedText
                                  : LibraryTheme.primaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _VideosViewState._formatFileSize(video.fileSize),
                            style: LibraryTheme.metadata,
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
      ),
    );
  }
}

class _VideoThumbnailStage extends StatefulWidget {
  const _VideoThumbnailStage({
    required this.video,
    required this.controller,
    this.iconSize = 40,
  });

  final MediaItemRecord video;
  final PlayerController controller;
  final double iconSize;

  @override
  State<_VideoThumbnailStage> createState() => _VideoThumbnailStageState();
}

class _VideoThumbnailStageState extends State<_VideoThumbnailStage> {
  ThumbnailRequestHandle? _handle;
  MediaThumbnail? _thumbnail;
  late MediaEntry _entry;

  @override
  void initState() {
    super.initState();
    _entry = _createEntry(widget.video);
    _initThumbnail();
  }

  @override
  void didUpdateWidget(covariant _VideoThumbnailStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id ||
        oldWidget.video.path != widget.video.path) {
      _handle?.release();
      _handle = null;
      _thumbnail = null;
      _entry = _createEntry(widget.video);
      _initThumbnail();
    }
  }

  @override
  void dispose() {
    _handle?.release();
    _handle = null;
    super.dispose();
  }

  MediaEntry _createEntry(MediaItemRecord v) => MediaEntry(
    id: v.id,
    path: v.path,
    title: v.title,
    duration: v.metadata.duration,
    lastPlayed: v.lastPlayedAt ?? v.addedAt,
  );

  void _initThumbnail() {
    try {
      final peek = widget.controller.peekThumbnail(_entry);
      if (peek != null && peek.bytes.isNotEmpty) {
        _thumbnail = peek;
        return;
      }
      final handle = widget.controller.requestThumbnail(
        _entry,
        priority: ThumbnailPriority.normal,
      );
      _handle = handle;
      handle?.thumbnail.then((thumb) {
        if (mounted && thumb != null && thumb.bytes.isNotEmpty) {
          setState(() => _thumbnail = thumb);
        }
      });
    } catch (_) {
      // Safely ignore if controller is a test mock or has no thumbnail service
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbnail != null && _thumbnail!.bytes.isNotEmpty) {
      return Image(
        image: ResizeImage(
          MemoryImage(_thumbnail!.bytes),
          width: 320,
          policy: ResizeImagePolicy.fit,
        ),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildFallback(),
      );
    }
    return _buildFallback();
  }

  Widget _buildFallback() {
    return Container(
      color: LibraryTheme.raisedSurface,
      child: Center(
        child: Icon(
          Icons.movie_creation_rounded,
          size: widget.iconSize,
          color: LibraryTheme.mutedText,
        ),
      ),
    );
  }
}
