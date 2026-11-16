import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../data/services/diagnostic_log.dart';
import '../../../utils/file_utils.dart';
import '../../../utils/format.dart';
import '../../player/player_controller.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_dialog.dart';
import '../../core/components/media_row.dart';
import '../../core/components/empty_state.dart';
import '../../core/components/hover_builder.dart';
import '../../core/components/page_header.dart';
import '../../core/toast/app_toast.dart';
import '../library_browse_constants.dart';
import '../library_reload_coordinator.dart';
import '../media_pager.dart';
import '../paged_media_loader.dart';
import '../widgets/media_context_menu.dart';
import '../widgets/library_item_actions.dart';

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
  final FocusNode _viewFocusNode = FocusNode(debugLabel: 'VideosView');
  final ValueNotifier<String?> _selectedVideoId = ValueNotifier<String?>(null);
  final ValueNotifier<Set<String>> _selectedVideoIds =
      ValueNotifier<Set<String>>(<String>{});
  String _sortBy = 'addedAt';
  bool _ascending = false;
  late final MediaPager _pager;
  final ScrollController _browseScrollController = ScrollController();
  Object? _error;
  late final LibraryReloadCoordinator _reloadCoordinator;

  /// Identity of the query the visible rows came from.
  ///
  /// A repository notification re-runs the same query, which refreshes in
  /// place. A change to the search text, the sort field, or the direction is a
  /// new query, which shows the initial-loading state.
  ({
    MediaLibraryRepository repository,
    String? search,
    String sortBy,
    bool ascending,
  })?
  _loadedQuery;

  /// Reload epoch the pager may publish results for.
  ///
  /// [LibraryReloadCoordinator] advances its epoch as soon as it queues a newer
  /// reload, which can be before the pager has finished the one in flight.
  int _activeReloadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _pager = MediaPager(
      fetch: (offset) => fetchMediaPage(
        widget.repository,
        offset: offset,
        kind: MediaKind.video,
        searchQuery: widget.searchQuery,
        sortBy: _sortBy,
        ascending: _ascending,
      ),
      onChanged: () {
        if (mounted) setState(() {});
      },
      onError: (error) {
        diagnosticDebug('videos.page', error: error);
      },
      // The coordinator's epoch moves as soon as it queues a newer reload, so
      // a superseded request has to be discarded where the pager commits,
      // before it can publish rows for a query the view has left behind.
      isCurrent: () =>
          mounted && _activeReloadEpoch == _reloadCoordinator.epoch,
    );
    _reloadCoordinator = LibraryReloadCoordinator(
      onReload: _runReload,
      onError: (error) {
        diagnosticDebug('videos.refresh', error: error);
        if (mounted) setState(() => _error = error);
      },
      onLoadingChanged: (loading) {
        if (mounted && !_pager.hasLoaded) setState(() {});
      },
      isDisposed: () => !mounted,
    );
    _browseScrollController.addListener(_onBrowseScroll);
    widget.repository.addListener(_onRepoChanged);
    _reload();
  }

  void _onBrowseScroll() {
    if (!_browseScrollController.hasClients) return;
    // A reload owns the list while it runs; appending to it would mix queries.
    if (_reloadCoordinator.isLoading) return;
    final position = _browseScrollController.position;
    if (position.pixels >=
        position.maxScrollExtent - kLibraryBrowseScrollPrefetch) {
      unawaited(_pager.loadMore());
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
      // The shell already debounces typing; apply the committed query now.
      _reload();
    }
  }

  @override
  void dispose() {
    _viewFocusNode.dispose();
    _selectedVideoId.dispose();
    _selectedVideoIds.dispose();
    _browseScrollController.removeListener(_onBrowseScroll);
    _browseScrollController.dispose();
    _reloadCoordinator.dispose();
    widget.repository.removeListener(_onRepoChanged);
    super.dispose();
  }

  void _onRepoChanged() {
    _reloadCoordinator.onRepositoryChanged(
      isScanning: widget.repository.scanStatus.isScanning,
    );
  }

  Future<void> _reload() => _reloadCoordinator.reload();

  Future<void> _runReload(int epoch) async {
    _activeReloadEpoch = epoch;
    final query = _query;
    final refresh = query == _loadedQuery && _pager.hasLoaded;
    _loadedQuery = query;
    if (refresh) {
      await _pager.refresh();
    } else {
      await _pager.loadFirst();
    }
    if (!mounted || epoch != _reloadCoordinator.epoch) return;
    setState(() => _error = null);
  }

  /// Identity of the query the visible rows came from.
  ///
  /// A repository notification re-runs the same query, which refreshes in
  /// place. A change to the search text, the sort field, or the direction is a
  /// new query, which shows the initial-loading state.
  ({
    MediaLibraryRepository repository,
    String? search,
    String sortBy,
    bool ascending,
  })
  get _query => (
    repository: widget.repository,
    search: widget.searchQuery,
    sortBy: _sortBy,
    ascending: _ascending,
  );

  Future<void> _showInFolder(String path) async {
    if (widget.onShowInFolder != null) {
      widget.onShowInFolder!(path);
      return;
    }
    final ok = await showInFolder(path);
    if (!ok && mounted) {
      AppToast.show(
        context,
        'Could not open File Explorer',
        tone: AppToastTone.danger,
      );
    }
  }

  Future<void> _playVideo(MediaItemRecord video) async {
    if (!video.isAvailable) return;
    await widget.controller.openPaths(
      [video.path],
      append: false,
      initialIndex: 0,
    );
  }

  void _toggleMultiSelect(String videoId) {
    final next = Set<String>.from(_selectedVideoIds.value);
    if (!next.add(videoId)) {
      next.remove(videoId);
    }
    _selectedVideoIds.value = next;
    if (next.contains(videoId)) {
      _selectedVideoId.value = videoId;
    }
  }

  Future<void> _confirmAndRemoveVideo(MediaItemRecord video) async {
    final confirmed =
        await AppDialog.show<bool>(
          context: context,
          builder: (dialogContext) => AppDialog(
            maxWidth: 420,
            title: const Text('Remove from library?'),
            content: Text(
              '"${video.title}" will be removed from your Videos library index. The file on disk will not be deleted.',
              style: dialogContext.palette.rowSecondary,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Remove'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await widget.repository.deleteMedia(video.id);
    if (!mounted) return;
    final next = Set<String>.from(_selectedVideoIds.value)..remove(video.id);
    _selectedVideoIds.value = next;
    if (_selectedVideoId.value == video.id) {
      _selectedVideoId.value = null;
    }
    AppToast.show(context, 'Removed "${video.title}" from library');
  }

  Future<void> _showVideoContextMenu(
    MediaItemRecord video,
    Offset globalPosition,
  ) async {
    if (_selectedVideoId.value != video.id) {
      _selectedVideoId.value = video.id;
    }
    await showMediaContextMenu(
      context: context,
      globalPosition: globalPosition,
      target: LibraryItemTarget.fromRecord(video),
      repository: widget.repository,
      controller: widget.controller,
      onPlay: video.isAvailable ? () => _playVideo(video) : null,
      onRemove: () => unawaited(_confirmAndRemoveVideo(video)),
      isSelected: _selectedVideoIds.value.contains(video.id),
      onSelect: () => _toggleMultiSelect(video.id),
      onShowInFolder: _showInFolder,
    );
    if (mounted) {
      _viewFocusNode.requestFocus();
    }
  }

  void _handleF3Shortcut() {
    final targetId =
        _selectedVideoId.value ??
        (_selectedVideoIds.value.isNotEmpty
            ? _selectedVideoIds.value.last
            : null);
    if (targetId == null) return;
    final videos = _pager.items;
    for (final v in videos) {
      if (v.id == targetId &&
          v.isAvailable &&
          !MediaEntry.isNetworkUrl(v.path)) {
        _showInFolder(v.path);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasVideos = _pager.items.isNotEmpty;
    final queryFailed = _error != null && !hasVideos;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f3): _handleF3Shortcut,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_selectedVideoIds.value.isNotEmpty) {
            _selectedVideoIds.value = <String>{};
          }
        },
      },
      child: Focus(
        focusNode: _viewFocusNode,
        child: Material(
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
                child: _reloadCoordinator.isLoading && !_pager.hasLoaded
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
                    ? _buildVideoGrid(_pager.items)
                    : _buildVideoList(_pager.items),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final accent = Theme.of(context).colorScheme.primary;
    final count = _pager.items.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gutter = PageHeader.gutterFor(width);
        final compact = width < AppLayout.compactBreakpoint;
        return Container(
          color: context.palette.surface,
          padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 8),
          child: Row(
            children: [
              if (count > 0)
                Flexible(
                  child: ValueListenableBuilder<Set<String>>(
                    valueListenable: _selectedVideoIds,
                    builder: (context, selectedIds, _) {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              '$count ${count == 1 ? 'video' : 'videos'}',
                              style: context.palette.metadata,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (selectedIds.isNotEmpty) ...[
                            const SizedBox(width: AppSpace.sm),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${selectedIds.length} selected',
                                    style: context.palette.metadata.copyWith(
                                      color: accent,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  InkWell(
                                    onTap: () =>
                                        _selectedVideoIds.value = <String>{},
                                    borderRadius: BorderRadius.circular(4),
                                    child: Padding(
                                      padding: const EdgeInsets.all(2),
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 13,
                                        color: accent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              const Spacer(),
              // Sort dropdown
              if (!compact) ...[
                Text('Sort by: ', style: context.palette.metadata),
                const SizedBox(width: 6),
              ],
              DropdownButton<String>(
                value: _sortBy,
                underline: const SizedBox.shrink(),
                isDense: compact,
                dropdownColor: context.palette.surface,
                style: context.palette.rowPrimary.copyWith(
                  fontSize: AppType.small,
                ),
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
              SizedBox(width: compact ? 4 : 12),
              VerticalDivider(
                width: 1,
                indent: 6,
                endIndent: 6,
                color: context.palette.border,
              ),
              SizedBox(width: compact ? 4 : 12),
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
      },
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
        final gutter = PageHeader.gutterFor(constraints.maxWidth);
        final available = (constraints.maxWidth - 2 * gutter).clamp(
          0.0,
          double.infinity,
        );
        final columns = ((available + 20) / AppLayout.videoGridMinWidth)
            .ceil()
            .clamp(1, 12);
        final width = (available - (columns - 1) * 20) / columns;
        final itemCount = videos.length + (_pager.isLoadingMore ? 1 : 0);
        return GridView.builder(
          controller: _browseScrollController,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          padding: EdgeInsets.fromLTRB(
            gutter,
            AppSpace.lg,
            gutter,
            AppSpace.lg,
          ),
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
              selectedVideoId: _selectedVideoId,
              selectedVideoIds: _selectedVideoIds,
              controller: widget.controller,
              resumeProgress: recentProgressByPath[video.path],
              onSelect: () {
                if (_selectedVideoId.value != video.id) {
                  _selectedVideoId.value = video.id;
                }
              },
              onToggleMultiSelect: () => _toggleMultiSelect(video.id),
              onPlay: isUnavailable ? null : () => _playVideo(video),
              onContextMenu: (position) =>
                  _showVideoContextMenu(video, position),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gutter = PageHeader.gutterFor(width);
        final compact = width < AppLayout.compactBreakpoint;
        final indexWidth = compact ? 34.0 : 48.0;
        final durationWidth = compact ? 64.0 : 90.0;

        return CustomScrollView(
          controller: _browseScrollController,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(gutter, AppSpace.md, gutter, 0),
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
                            width: indexWidth,
                            child: Text('#', style: context.palette.metadata),
                          ),
                          Expanded(
                            flex: 5,
                            child: Text(
                              'Title',
                              style: context.palette.metadata,
                            ),
                          ),
                          if (!compact)
                            Expanded(
                              flex: 2,
                              child: Text(
                                'Size',
                                style: context.palette.metadata,
                              ),
                            ),
                          SizedBox(
                            width: durationWidth,
                            child: Text(
                              'Duration',
                              style: context.palette.metadata,
                              textAlign: TextAlign.right,
                            ),
                          ),
                          SizedBox(width: compact ? 40 : 48),
                          const SizedBox(width: 40),
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
                gutter,
                0,
                gutter,
                _pager.isLoadingMore ? 0 : AppSpace.md,
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
                              if (_selectedVideoId.value != video.id) {
                                _selectedVideoId.value = video.id;
                              }
                            },
                            onPlay: isUnavailable
                                ? null
                                : () => _playVideo(video),
                            builder: (context, rowFocus, handleTap) => ValueListenableBuilder<String?>(
                              valueListenable: _selectedVideoId,
                              builder: (context, selectedId, _) => ValueListenableBuilder<Set<String>>(
                                valueListenable: _selectedVideoIds,
                                builder: (context, selectedIds, _) {
                                  final isMultiSelected = selectedIds.contains(
                                    video.id,
                                  );
                                  final isSelected =
                                      selectedId == video.id || isMultiSelected;
                                  return InkWell(
                                    canRequestFocus: false,
                                    onTap: selectedIds.isNotEmpty
                                        ? () => _toggleMultiSelect(video.id)
                                        : handleTap,
                                    onSecondaryTapDown: (details) =>
                                        _showVideoContextMenu(
                                          video,
                                          details.globalPosition,
                                        ),
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.control,
                                    ),
                                    hoverColor: context.palette.hover,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? context.palette.hover
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(
                                          AppRadii.control,
                                        ),
                                        border: isSelected
                                            ? Border.all(
                                                color: accent.withValues(
                                                  alpha: isMultiSelected
                                                      ? 0.75
                                                      : 0.45,
                                                ),
                                              )
                                            : null,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: AppSpace.sm,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width: indexWidth,
                                            child: isMultiSelected
                                                ? Icon(
                                                    Icons.check_circle_rounded,
                                                    size: 16,
                                                    color: accent,
                                                  )
                                                : Text(
                                                    '${videoIndex + 1}',
                                                    style: context
                                                        .palette
                                                        .metadata,
                                                  ),
                                          ),
                                          Expanded(
                                            flex: 5,
                                            child: Row(
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    video.title,
                                                    style: context
                                                        .palette
                                                        .rowPrimary
                                                        .copyWith(
                                                          color: isUnavailable
                                                              ? context
                                                                    .palette
                                                                    .mutedText
                                                              : context
                                                                    .palette
                                                                    .primaryText,
                                                        ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                if (isUnavailable) ...[
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 5,
                                                          vertical: 1,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: context
                                                          .palette
                                                          .danger
                                                          .withValues(
                                                            alpha: 0.2,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            AppRadii.control,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      'Missing',
                                                      style: context
                                                          .palette
                                                          .badge
                                                          .copyWith(
                                                            fontSize:
                                                                AppType.caption,
                                                            color: context
                                                                .palette
                                                                .danger,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          if (!compact)
                                            Expanded(
                                              flex: 2,
                                              child: Text(
                                                formatFileSize(video.fileSize),
                                                style: context
                                                    .palette
                                                    .rowSecondary,
                                              ),
                                            ),
                                          SizedBox(
                                            width: durationWidth,
                                            child: Text(
                                              formatDuration(
                                                video.metadata.duration,
                                              ),
                                              style: context.palette.metadata
                                                  .copyWith(
                                                    fontFeatures: const [
                                                      FontFeature.tabularFigures(),
                                                    ],
                                                  ),
                                              textAlign: TextAlign.right,
                                            ),
                                          ),
                                          SizedBox(
                                            width: compact ? 40 : 48,
                                            child: IconButton(
                                              icon: Icon(
                                                video.isFavorite
                                                    ? Icons.favorite_rounded
                                                    : Icons
                                                          .favorite_border_rounded,
                                                size: 18,
                                                color: video.isFavorite
                                                    ? accent
                                                    : context.palette.mutedText,
                                              ),
                                              tooltip: video.isFavorite
                                                  ? 'Remove favorite'
                                                  : 'Add to favorites',
                                              onPressed: () => widget.repository
                                                  .toggleFavorite(
                                                    video.id,
                                                    !video.isFavorite,
                                                  ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 40,
                                            child: _buildVideoItemActionMenu(
                                              video,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
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
            if (_pager.isLoadingMore)
              SliverPadding(
                padding: EdgeInsets.symmetric(
                  horizontal: gutter,
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
      },
    );
  }

  Widget _buildVideoItemActionMenu(MediaItemRecord video) {
    return Builder(
      builder: (buttonContext) => IconButton(
        icon: Icon(
          Icons.more_vert_rounded,
          size: 18,
          color: buttonContext.palette.mutedText,
        ),
        tooltip: 'More actions',
        visualDensity: VisualDensity.compact,
        onPressed: () {
          final box = buttonContext.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return;
          final anchor = box.localToGlobal(Offset(0, box.size.height));
          _showVideoContextMenu(video, anchor);
        },
      ),
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
    required this.selectedVideoId,
    required this.selectedVideoIds,
    required this.controller,
    required this.onSelect,
    required this.onToggleMultiSelect,
    required this.onPlay,
    required this.onContextMenu,
    required this.actionMenu,
    this.resumeProgress,
  });

  final MediaItemRecord video;
  final ValueListenable<String?> selectedVideoId;
  final ValueListenable<Set<String>> selectedVideoIds;
  final PlayerController controller;
  final VoidCallback onSelect;
  final VoidCallback onToggleMultiSelect;
  final VoidCallback? onPlay;
  final ValueChanged<Offset> onContextMenu;
  final Widget actionMenu;
  final double? resumeProgress;

  @override
  State<_VideoGridCard> createState() => _VideoGridCardState();
}

class _VideoGridCardState extends State<_VideoGridCard> {
  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final isUnavailable = !video.isAvailable;
    final accent = Theme.of(context).colorScheme.primary;
    final progress = widget.resumeProgress;

    return HoverListenable(
      builder: (context, hovered) => MediaRow(
        key: ValueKey(video.id),
        onSelect: widget.onSelect,
        onPlay: widget.onPlay,
        builder: (context, rowFocus, handleTap) {
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
                      color: PlayerColors.scrim,
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

          return ValueListenableBuilder<String?>(
            valueListenable: widget.selectedVideoId,
            builder: (context, selectedId, _) =>
                ValueListenableBuilder<Set<String>>(
                  valueListenable: widget.selectedVideoIds,
                  builder: (context, selectedIds, _) {
                    final isMultiSelected = selectedIds.contains(video.id);
                    final isSelected =
                        selectedId == video.id || isMultiSelected;
                    return Semantics(
                      button: true,
                      container: true,
                      label: semanticsLabel,
                      child: InkWell(
                        canRequestFocus: false,
                        onTap: selectedIds.isNotEmpty
                            ? widget.onToggleMultiSelect
                            : handleTap,
                        onSecondaryTapDown: (details) =>
                            widget.onContextMenu(details.globalPosition),
                        borderRadius: BorderRadius.circular(AppRadii.artwork),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? context.palette.hover
                                : context.palette.background,
                            borderRadius: BorderRadius.circular(
                              AppRadii.artwork,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Video Thumbnail Stage
                              RepaintBoundary(
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: hovered,
                                  child: staticStage,
                                  builder: (context, isHovered, stageChild) {
                                    final showPlayOverlay =
                                        !isUnavailable &&
                                        (isHovered ||
                                            isSelected ||
                                            rowFocus.hasFocus);
                                    return AnimatedScale(
                                      scale: (lowPower || !showPlayOverlay)
                                          ? 1.0
                                          : 1.02,
                                      duration: hoverDuration,
                                      curve: AppMotion.enter,
                                      child: Container(
                                        foregroundDecoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            AppRadii.artwork,
                                          ),
                                          border: Border.all(
                                            color: isSelected
                                                ? accent.withValues(alpha: 0.55)
                                                : context.palette.borderStrong
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
                                                if (isMultiSelected)
                                                  Positioned(
                                                    top: 8,
                                                    left: 8,
                                                    child: Container(
                                                      width: 22,
                                                      height: 22,
                                                      decoration: BoxDecoration(
                                                        color: accent,
                                                        shape: BoxShape.circle,
                                                        boxShadow: const [
                                                          BoxShadow(
                                                            color:
                                                                Colors.black38,
                                                            blurRadius: 4,
                                                          ),
                                                        ],
                                                      ),
                                                      child: const Icon(
                                                        Icons.check_rounded,
                                                        size: 14,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                // Subtle play button overlay on hover or focus
                                                if (showPlayOverlay)
                                                  Center(
                                                    child: IconButton.filled(
                                                      onPressed: widget.onPlay,
                                                      tooltip: 'Play video',
                                                      style:
                                                          IconButton.styleFrom(
                                                            backgroundColor:
                                                                Colors.black
                                                                    .withValues(
                                                                      alpha:
                                                                          0.65,
                                                                    ),
                                                            foregroundColor:
                                                                accent,
                                                            minimumSize:
                                                                const Size(
                                                                  40,
                                                                  40,
                                                                ),
                                                          ),
                                                      icon: const Icon(
                                                        Icons
                                                            .play_arrow_rounded,
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              video.title,
                                              style: context.palette.rowPrimary
                                                  .copyWith(
                                                    color: isUnavailable
                                                        ? context
                                                              .palette
                                                              .mutedText
                                                        : context
                                                              .palette
                                                              .primaryText,
                                                  ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(
                                              height: AppSpace.micro,
                                            ),
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
        },
      ),
    );
  }
}
