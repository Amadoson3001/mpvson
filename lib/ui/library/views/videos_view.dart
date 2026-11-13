import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../utils/file_utils.dart';
import '../../../utils/format.dart';
import '../../player/player_controller.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/app_popup_menu_item.dart';
import '../../core/components/media_row.dart';
import '../../core/components/empty_state.dart';
import '../library_browse_constants.dart';
import '../paged_media_loader.dart';
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
  int _browseOffset = 0;
  bool _hasMoreBrowse = false;
  bool _loadingMoreBrowse = false;
  int _browseEpoch = 0;
  final ScrollController _browseScrollController = ScrollController();
  bool _isLoading = false;
  Object? _error;
  Future<void>? _reloadFuture;
  bool _reloadAgain = false;
  Timer? _reloadThrottle;
  Timer? _searchReload;

  @override
  void initState() {
    super.initState();
    _browseScrollController.addListener(_onBrowseScroll);
    widget.repository.addListener(_onRepoChanged);
    _reload();
  }

  void _onBrowseScroll() {
    if (!_browseScrollController.hasClients) return;
    final position = _browseScrollController.position;
    if (position.pixels >=
        position.maxScrollExtent - kLibraryBrowseScrollPrefetch) {
      unawaited(_loadMoreBrowse());
    }
  }

  Future<void> _loadMoreBrowse() async {
    if (!_hasMoreBrowse || _loadingMoreBrowse || _isLoading) return;
    final epoch = _browseEpoch;
    if (mounted) setState(() => _loadingMoreBrowse = true);
    try {
      final batch = await fetchMediaPage(
        widget.repository,
        offset: _browseOffset,
        kind: MediaKind.video,
        searchQuery: widget.searchQuery,
        sortBy: _sortBy,
        ascending: _ascending,
      );
      if (!mounted || epoch != _browseEpoch) return;
      setState(() {
        _videos ??= <MediaItemRecord>[];
        _videos!.addAll(batch.items);
        _browseOffset += batch.items.length;
        _hasMoreBrowse = batch.hasMore;
        _loadingMoreBrowse = false;
      });
    } catch (error) {
      debugPrint('Videos view could not load more: $error');
      if (mounted && epoch == _browseEpoch) {
        setState(() => _loadingMoreBrowse = false);
      }
    }
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
    _browseScrollController.removeListener(_onBrowseScroll);
    _browseScrollController.dispose();
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
    _browseEpoch++;
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
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadingMoreBrowse = false;
      });
    }
    try {
      do {
        _browseEpoch++;
        _reloadAgain = false;
        _browseOffset = 0;
        _hasMoreBrowse = false;
        final batch = await fetchMediaPage(
          widget.repository,
          offset: 0,
          kind: MediaKind.video,
          searchQuery: widget.searchQuery,
          sortBy: _sortBy,
          ascending: _ascending,
        );
        if (!mounted) return;
        if (_reloadAgain) continue;
        setState(() {
          _videos = List<MediaItemRecord>.from(batch.items);
          _browseOffset = batch.items.length;
          _hasMoreBrowse = batch.hasMore;
          _error = null;
        });
      } while (_reloadAgain && mounted);
    } catch (error) {
      debugPrint('Videos view could not refresh: $error');
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showInFolder(String path) {
    if (widget.onShowInFolder != null) {
      widget.onShowInFolder!(path);
      return;
    }
    showInFolder(path);
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
    final queryFailed = _error != null && !hasVideos;
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
                : queryFailed
                ? EmptyState(
                    title: "Couldn't load videos",
                    message:
                        'The library could not be queried. Try again, or check that the library database is available.',
                    icon: Icons.error_outline_rounded,
                    actionLabel: 'Try again',
                    actionIcon: Icons.refresh_rounded,
                    onAction: () => unawaited(_reload()),
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
              DropdownMenuItem(
                value: 'title',
                child: Text(
                  'Title',
                  style: TextStyle(fontFamily: AppType.family),
                ),
              ),
              DropdownMenuItem(
                value: 'addedAt',
                child: Text(
                  'Date added',
                  style: TextStyle(fontFamily: AppType.family),
                ),
              ),
              DropdownMenuItem(
                value: 'duration',
                child: Text(
                  'Duration',
                  style: TextStyle(fontFamily: AppType.family),
                ),
              ),
              DropdownMenuItem(
                value: 'fileSize',
                child: Text(
                  'File size',
                  style: TextStyle(fontFamily: AppType.family),
                ),
              ),
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
    final recentProgressByPath = <String, double>{
      for (final entry in widget.controller.recent)
        if (entry.position > Duration.zero && entry.duration > Duration.zero)
          entry.path:
              (entry.position.inMilliseconds / entry.duration.inMilliseconds)
                  .clamp(0.0, 1.0),
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            ((constraints.maxWidth - 48 + 20) / AppLayout.videoGridMinWidth)
                .ceil()
                .clamp(1, 12);
        final width =
            (constraints.maxWidth - 48 - (columns - 1) * 20) / columns;
        final itemCount = videos.length + (_loadingMoreBrowse ? 1 : 0);
        return GridView.builder(
          controller: _browseScrollController,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          padding: const EdgeInsets.all(AppSpace.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 24,
            crossAxisSpacing: 20,
            mainAxisExtent: width * 9 / 16 + 68,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (index >= videos.length) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              );
            }
            final video = videos[index];
            final isUnavailable = !video.isAvailable;
            return _VideoGridCard(
              key: ValueKey(video.id),
              video: video,
              isSelected: _selectedVideo == video.id,
              controller: widget.controller,
              resumeProgress: recentProgressByPath[video.path],
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
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14.0).clamp(
      1.0,
      2.2,
    );
    final rowExtent = (68.0 * textScale).ceilToDouble();
    final dividerColor = context.palette.surface;
    final headerBorder = context.palette.border;

    return CustomScrollView(
      controller: _browseScrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.md,
            AppSpace.lg,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
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
                ),
                Divider(height: 16, thickness: 1, color: headerBorder),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppSpace.lg,
            0,
            AppSpace.lg,
            _loadingMoreBrowse ? 0 : AppSpace.md,
          ),
          sliver: SliverFixedExtentList(
            itemExtent: rowExtent,
            delegate: SliverChildBuilderDelegate(
              (context, videoIndex) {
                final video = videos[videoIndex];
                final isUnavailable = !video.isAvailable;

                return Column(
                  children: [
                    Expanded(
                      child: MediaRow(
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
                          onDoubleTap: isUnavailable
                              ? null
                              : () => _playVideo(video),
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
                                  child: Text(
                                    '${videoIndex + 1}',
                                    style: context.palette.metadata,
                                  ),
                                ),
                                Expanded(
                                  flex: 5,
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          video.title,
                                          style: context.palette.rowPrimary
                                              .copyWith(
                                                color: isUnavailable
                                                    ? context.palette.mutedText
                                                    : context
                                                          .palette
                                                          .primaryText,
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
                                            color: context.palette.danger
                                                .withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(
                                              AppRadii.control,
                                            ),
                                          ),
                                          child: Text(
                                            'Missing',
                                            style: context.palette.badge
                                                .copyWith(
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
                                    formatFileSize(video.fileSize),
                                    style: context.palette.rowSecondary,
                                  ),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    formatDuration(video.metadata.duration),
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
                                      color: video.isFavorite
                                          ? accent
                                          : context.palette.mutedText,
                                    ),
                                    tooltip: video.isFavorite
                                        ? 'Remove favorite'
                                        : 'Add to favorites',
                                    onPressed: () =>
                                        widget.repository.toggleFavorite(
                                          video.id,
                                          !video.isFavorite,
                                        ),
                                  ),
                                ),
                                SizedBox(
                                  width: 40,
                                  child: _buildVideoItemActionMenu(video),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Divider(height: 1, thickness: 1, color: dividerColor),
                  ],
                );
              },
              childCount: videos.length,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: true,
            ),
          ),
        ),
        if (_loadingMoreBrowse)
          SliverPadding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.lg,
              vertical: AppSpace.lg,
            ),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
            ),
          ),
      ],
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
          AppPopupMenuItem<String>(
            value: 'play_now',
            enabled: video.isAvailable,
            icon: Icons.play_arrow_rounded,
            iconColor: accent,
            text: 'Play now',
          ),
          AppPopupMenuItem<String>(
            value: 'play_next',
            enabled: video.isAvailable,
            icon: Icons.playlist_play_rounded,
            text: 'Play next',
          ),
          AppPopupMenuItem<String>(
            value: 'add_queue',
            enabled: video.isAvailable,
            icon: Icons.queue_music_rounded,
            text: 'Add to queue',
          ),
          AppPopupMenuItem<String>(
            value: 'add_playlist',
            icon: Icons.playlist_add_rounded,
            text: 'Add to playlist',
          ),
          AppPopupMenuItem<String>(
            value: 'toggle_favorite',
            icon: video.isFavorite
                ? Icons.favorite_border_rounded
                : Icons.favorite_rounded,
            iconColor: accent,
            text: video.isFavorite ? 'Remove favorite' : 'Favorite',
          ),
          const PopupMenuDivider(height: 1),
          AppPopupMenuItem<String>(
            value: 'show_folder',
            icon: Icons.folder_open_rounded,
            text: 'Show in folder',
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
  MediaThumbnail? _provisional;
  ThumbnailRequestHandle? _request;

  MediaEntry get _entry =>
      MediaEntry.fromPath(widget.video.path, id: widget.video.id);

  void _syncPreview() {
    _provisional = widget.video.isAvailable
        ? widget.controller.peekThumbnail(_entry)
        : null;
    _thumbnail = _load();
  }

  @override
  void initState() {
    super.initState();
    _syncPreview();
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
      _syncPreview();
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
      _request = widget.controller.requestThumbnail(_entry);
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
        final bytes = snapshot.data?.bytes ?? _provisional?.bytes;
        return bytes == null
            ? fallback()
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                cacheWidth: 480,
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
    this.resumeProgress,
  });

  final MediaItemRecord video;
  final bool isSelected;
  final PlayerController controller;
  final VoidCallback onSelect;
  final VoidCallback? onPlay;
  final Widget actionMenu;
  final double? resumeProgress;

  @override
  State<_VideoGridCard> createState() => _VideoGridCardState();
}

class _VideoGridCardState extends State<_VideoGridCard> {
  final ValueNotifier<bool> _hovered = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final isUnavailable = !video.isAvailable;
    final accent = Theme.of(context).colorScheme.primary;
    final progress = widget.resumeProgress;

    return MouseRegion(
      onEnter: (_) => _hovered.value = true,
      onExit: (_) => _hovered.value = false,
      child: MediaRow(
        key: ValueKey(video.id),
        onSelect: widget.onSelect,
        onPlay: widget.onPlay,
        builder: (context, rowFocus) {
          final semanticsLabel = [
            video.title,
            formatFileSize(video.fileSize),
            if (video.metadata.duration > Duration.zero)
              formatDuration(video.metadata.duration),
            if (isUnavailable) 'File missing',
          ].join(', ');
          final staticStage = Stack(
            fit: StackFit.expand,
            children: [
              _VideoPreview(video: video, controller: widget.controller),
              if (progress != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    value: progress,
                    color: accent,
                    backgroundColor: Colors.transparent,
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
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    child: Text(
                      formatDuration(video.metadata.duration),
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
                      color: context.palette.danger.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(AppRadii.control),
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
            ],
          );
          final lowPower = AppMotion.lowPower(context);
          final hoverDuration = AppMotion.duration(context, AppMotion.hover);

          return Semantics(
            button: true,
            container: true,
            label: semanticsLabel,
            child: InkWell(
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
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _hovered,
                        child: staticStage,
                        builder: (context, isHovered, stageChild) {
                          final showPlayOverlay =
                              !isUnavailable &&
                              (isHovered ||
                                  widget.isSelected ||
                                  rowFocus.hasFocus);
                          return AnimatedScale(
                            scale: (lowPower || !showPlayOverlay) ? 1.0 : 1.02,
                            duration: hoverDuration,
                            curve: AppMotion.enter,
                            child: Container(
                              foregroundDecoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.artwork,
                                ),
                                border: Border.all(
                                  color: context.palette.borderStrong
                                      .withValues(alpha: 0.65),
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.artwork,
                                ),
                                child: AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ?stageChild,
                                      // Subtle play button overlay on hover or focus
                                      if (showPlayOverlay)
                                        Center(
                                          child: IconButton.filled(
                                            onPressed: widget.onPlay,
                                            tooltip: 'Play video',
                                            style: IconButton.styleFrom(
                                              backgroundColor: Colors.black
                                                  .withValues(alpha: 0.65),
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
                          );
                        },
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
                            child: ExcludeSemantics(
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
                                  const SizedBox(height: AppSpace.micro),
                                  Text(
                                    formatFileSize(video.fileSize),
                                    style: context.palette.metadata,
                                  ),
                                ],
                              ),
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
        },
      ),
    );
  }
}
