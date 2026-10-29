import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../player/player_controller.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/media_tile.dart';
import '../../core/components/media_row.dart';
import '../widgets/library_artwork.dart';
import '../../core/components/empty_state.dart';
import '../widgets/playlist_create_dialog.dart';

/// Playlists view featuring playlist management, detail tracklist view,
/// drag-and-drop reordering, and playback actions.
class PlaylistsView extends StatefulWidget {
  const PlaylistsView({
    super.key,
    required this.repository,
    required this.controller,
    this.searchQuery,
  });

  final MediaLibraryRepository repository;
  final PlayerController controller;
  final String? searchQuery;

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView> {
  PlaylistRecord? _selectedPlaylist;
  List<PlaylistRecord>? _playlists;
  List<PlaylistEntryRecord>? _entries;
  String? _selectedEntry;
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
  void didUpdateWidget(PlaylistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_onRepoChanged);
      widget.repository.addListener(_onRepoChanged);
      _reload();
    } else if (oldWidget.searchQuery != widget.searchQuery) {
      if (widget.searchQuery?.trim().isNotEmpty ?? false) {
        _selectedPlaylist = null;
        _entries = null;
      }
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
        final selectedId = _selectedPlaylist?.id;
        if (selectedId != null) {
          final entries = await widget.repository.getPlaylistEntries(
            selectedId,
          );
          if (!mounted) return;
          if (_reloadAgain) continue;
          setState(() => _entries = entries);
        } else {
          final playlists = await widget.repository.getPlaylists();
          if (!mounted) return;
          if (_reloadAgain) continue;
          setState(() => _playlists = playlists);
        }
      } while (_reloadAgain && mounted);
    } catch (error) {
      debugPrint('Playlists view could not refresh: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _createPlaylist() async {
    final playlist = await PlaylistCreateDialog.show(
      context,
      widget.repository,
    );
    if (playlist != null && mounted) {
      setState(() {
        _selectedPlaylist = playlist;
        _entries = null;
      });
      _reload();
    }
  }

  Future<void> _deletePlaylist(PlaylistRecord pl) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          side: const BorderSide(color: AppTheme.border),
        ),
        title: const Text('Delete playlist', style: AppTheme.sectionTitle),
        content: Text(
          'Are you sure you want to delete "${pl.title}"? The media files themselves will remain in your library.',
          style: AppTheme.rowSecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppTheme.secondaryText),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await widget.repository.deletePlaylist(pl.id);
      if (mounted && _selectedPlaylist?.id == pl.id) {
        setState(() => _selectedPlaylist = null);
      }
    }
  }

  Future<void> _renamePlaylist(PlaylistRecord playlist) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenamePlaylistDialog(initialTitle: playlist.title),
    );
    if (title != null && title.isNotEmpty && mounted) {
      try {
        await widget.repository.renamePlaylist(playlist.id, title);
      } catch (_) {
        if (mounted) {
          AppToast.show(
            context,
            'Could not rename the playlist. Try again.',
            tone: AppToastTone.danger,
          );
        }
      }
    }
  }

  Future<void> _playPlaylist(
    List<PlaylistEntryRecord> entries, {
    bool shuffle = false,
    int startIndex = 0,
  }) async {
    final paths = entries
        .where((e) => e.mediaItem?.isAvailable ?? false)
        .map((e) => e.mediaItem?.path)
        .whereType<String>()
        .toList();

    if (paths.isEmpty) return;

    if (shuffle) {
      paths.shuffle();
    }

    final initialIndex = shuffle
        ? 0
        : entries
              .take(startIndex)
              .where((e) => e.mediaItem?.isAvailable ?? false)
              .length;
    await widget.controller.openPaths(
      paths,
      append: false,
      initialIndex: initialIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedPlaylist != null) {
      return _buildPlaylistDetailView(_selectedPlaylist!);
    }

    final accent = Theme.of(context).colorScheme.primary;
    final allPlaylists = _playlists ?? const <PlaylistRecord>[];
    final query = widget.searchQuery?.trim().toLowerCase();
    final playlists = query != null && query.isNotEmpty
        ? allPlaylists
              .where((p) => p.title.toLowerCase().contains(query))
              .toList()
        : allPlaylists;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: _isLoading && _playlists == null
          ? Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            )
          : playlists.isEmpty
          ? EmptyState(
              title: query != null && query.isNotEmpty
                  ? 'No playlists found'
                  : 'No playlists created yet',
              message: query != null && query.isNotEmpty
                  ? 'No playlists match "$query".'
                  : 'Create custom playlists to group and sequence your favorite tracks and videos.',
              actionLabel: 'Create playlist',
              icon: Icons.playlist_add_rounded,
              onAction: _createPlaylist,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header bar
                Container(
                  color: AppTheme.surface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.lg,
                    vertical: AppSpace.sm,
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Playlists (${playlists.length})',
                        style: AppTheme.sectionTitle,
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: AppTheme.accentForeground,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.md,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                          ),
                        ),
                        onPressed: _createPlaylist,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text(
                          'New playlist',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppTheme.border),
                // Playlists Grid
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 240,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 20,
                          childAspectRatio: 0.9,
                        ),
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final pl = playlists[index];
                      return _buildPlaylistCard(pl);
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildPlaylistCard(PlaylistRecord pl) {
    return MediaTile(
      artwork: FutureBuilder<List<PlaylistEntryRecord>>(
        future: widget.repository.getPlaylistEntries(pl.id),
        builder: (context, snapshot) {
          final entries = snapshot.data;
          final media = entries == null || entries.isEmpty
              ? null
              : entries.first.mediaItem;
          return LibraryArtwork(
            path: media?.metadata.artworkUri,
            mediaPath: media?.path,
            repository: widget.repository,
            icon: Icons.queue_music_rounded,
          );
        },
      ),
      title: pl.title,
      subtitle: '${pl.entryCount} items',
      onTap: () {
        setState(() {
          _selectedPlaylist = pl;
          _entries = null;
        });
        _reload();
      },
      trailing: PopupMenuButton<String>(
        tooltip: 'Playlist actions',
        icon: const Icon(Icons.more_vert_rounded, size: 18),
        onSelected: (action) {
          if (action == 'delete') _deletePlaylist(pl);
          if (action == 'rename') _renamePlaylist(pl);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename playlist')),
          PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
        ],
      ),
    );
  }

  Widget _buildPlaylistDetailView(PlaylistRecord pl) {
    final accent = Theme.of(context).colorScheme.primary;
    final entries = _entries ?? const <PlaylistEntryRecord>[];
    final totalDuration = entries.fold<Duration>(
      Duration.zero,
      (sum, e) => sum + (e.mediaItem?.metadata.duration ?? Duration.zero),
    );

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Navigation back breadcrumb
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              AppSpace.md,
              AppSpace.md,
              0,
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back to playlists',
                  color: AppTheme.secondaryText,
                  onPressed: () {
                    setState(() {
                      _selectedPlaylist = null;
                      _entries = null;
                    });
                    _reload();
                  },
                ),
                const SizedBox(width: 8),
                Text('Playlists', style: AppTheme.rowSecondary),
                const SizedBox(width: 6),
                const Text('›', style: AppTheme.metadata),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pl.title,
                    style: AppTheme.rowPrimary.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // Playlist hero banner
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.artwork),
                  child: SizedBox(
                    width: 140,
                    height: 140,
                    child: LibraryArtwork(
                      path: entries.isEmpty
                          ? null
                          : entries.first.mediaItem?.metadata.artworkUri,
                      mediaPath: entries.isEmpty
                          ? null
                          : entries.first.mediaItem?.path,
                      repository: widget.repository,
                      icon: Icons.queue_music_rounded,
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pl.title,
                        style: AppTheme.pageTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${entries.length} items • ${_formatDuration(totalDuration)}',
                        style: AppTheme.metadata,
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: AppTheme.accentForeground,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: AppSpace.sm,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                              ),
                            ),
                            onPressed:
                                entries.any(
                                  (e) => e.mediaItem?.isAvailable ?? false,
                                )
                                ? () => _playPlaylist(entries)
                                : null,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text(
                              'Play playlist',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primaryText,
                              side: const BorderSide(color: AppTheme.border),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpace.md,
                                vertical: AppSpace.sm,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                              ),
                            ),
                            onPressed:
                                entries.any(
                                  (e) => e.mediaItem?.isAvailable ?? false,
                                )
                                ? () => _playPlaylist(entries, shuffle: true)
                                : null,
                            icon: const Icon(Icons.shuffle_rounded, size: 18),
                            label: const Text('Shuffle'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.border),
          // Reorderable tracks list
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'No tracks in this playlist yet',
                      style: AppTheme.metadata,
                    ),
                  )
                : Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(canvasColor: AppTheme.surface),
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.lg,
                        vertical: AppSpace.md,
                      ),
                      itemCount: entries.length,
                      // ignore: deprecated_member_use
                      onReorder: (oldIndex, newIndex) async {
                        await widget.repository.reorderPlaylist(
                          pl.id,
                          oldIndex,
                          newIndex,
                        );
                      },
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final item = entry.mediaItem;
                        final title = item?.title ?? 'Unknown track';
                        final artist = item?.artist ?? 'Unknown artist';
                        final duration =
                            item?.metadata.duration ?? Duration.zero;
                        final isSelected = _selectedEntry == entry.id;

                        return MediaRow(
                          key: ValueKey(entry.id),
                          onSelect: () {
                            if (_selectedEntry != entry.id) {
                              setState(() => _selectedEntry = entry.id);
                            }
                          },
                          onPlay: item?.isAvailable == true
                              ? () => _playPlaylist(entries, startIndex: index)
                              : null,
                          builder: (context, rowFocus) => Container(
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppTheme.hover
                                  : Colors.transparent,
                              border: isSelected
                                  ? Border(
                                      left: BorderSide(color: accent, width: 2),
                                    )
                                  : null,
                            ),
                            child: InkWell(
                              canRequestFocus: false,
                              onTap: () {
                                rowFocus.requestFocus();
                                setState(() => _selectedEntry = entry.id);
                              },
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              hoverColor: AppTheme.hover,
                              onDoubleTap: item?.isAvailable == true
                                  ? () => _playPlaylist(
                                      entries,
                                      startIndex: index,
                                    )
                                  : null,
                              child: ListTile(
                                dense: true,
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.drag_indicator_rounded,
                                      size: 18,
                                      color: AppTheme.mutedText,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '${index + 1}',
                                      style: AppTheme.metadata,
                                    ),
                                  ],
                                ),
                                title: Text(
                                  title,
                                  style: AppTheme.rowPrimary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  item != null && !item.isAvailable
                                      ? '$artist • Missing'
                                      : artist,
                                  style: AppTheme.rowSecondary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _formatDuration(duration),
                                      style: AppTheme.metadata,
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 16,
                                      ),
                                      tooltip: 'Remove from playlist',
                                      color: AppTheme.mutedText,
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () async {
                                        await widget.repository
                                            .removeFromPlaylist(
                                              pl.id,
                                              entry.id,
                                            );
                                      },
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
          ),
        ],
      ),
    );
  }
}

class _RenamePlaylistDialog extends StatefulWidget {
  const _RenamePlaylistDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenamePlaylistDialog> createState() => _RenamePlaylistDialogState();
}

class _RenamePlaylistDialogState extends State<_RenamePlaylistDialog> {
  late final TextEditingController _controller;
  bool _empty = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final title = _controller.text.trim();
    if (title.isEmpty) {
      setState(() => _empty = true);
      return;
    }
    Navigator.pop(context, title);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: AppTheme.surface,
    title: const Text('Rename playlist', style: AppTheme.sectionTitle),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(
        labelText: 'Playlist name',
        errorText: _empty ? 'Enter a name' : null,
      ),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
