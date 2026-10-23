import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../player/player_controller.dart';
import '../theme/library_theme.dart';
import '../widgets/empty_library_view.dart';
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
  bool _isLoading = false;
  Future<void>? _reloadFuture;
  bool _reloadAgain = false;

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
      setState(() => _selectedPlaylist = playlist);
    }
  }

  Future<void> _deletePlaylist(PlaylistRecord pl) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: LibraryTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: LibraryTheme.border),
        ),
        title: const Text('Delete Playlist', style: LibraryTheme.sectionTitle),
        content: Text(
          'Are you sure you want to delete "${pl.title}"? The media files themselves will remain in your library.',
          style: LibraryTheme.rowSecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: LibraryTheme.secondaryText),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: LibraryTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.repository.deletePlaylist(pl.id);
      if (_selectedPlaylist?.id == pl.id) {
        setState(() => _selectedPlaylist = null);
      }
    }
  }

  Future<void> _playPlaylist(
    List<PlaylistEntryRecord> entries, {
    bool shuffle = false,
  }) async {
    final paths = entries
        .map((e) => e.mediaItem?.path)
        .whereType<String>()
        .toList();

    if (paths.isEmpty) return;

    if (shuffle) {
      paths.shuffle();
    }

    await widget.controller.openPaths(paths, append: false, initialIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedPlaylist != null) {
      return _buildPlaylistDetailView(_selectedPlaylist!);
    }

    final allPlaylists = _playlists ?? const <PlaylistRecord>[];
    final query = widget.searchQuery?.trim().toLowerCase();
    final playlists = query != null && query.isNotEmpty
        ? allPlaylists
              .where((p) => p.title.toLowerCase().contains(query))
              .toList()
        : allPlaylists;

    return Scaffold(
      backgroundColor: LibraryTheme.background,
      body: _isLoading && _playlists == null
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(LibraryTheme.accent),
              ),
            )
          : playlists.isEmpty
          ? EmptyLibraryView(
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
                  color: LibraryTheme.surface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Playlists (${playlists.length})',
                        style: LibraryTheme.sectionTitle,
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: LibraryTheme.accent,
                          foregroundColor: LibraryTheme.background,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
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
                const Divider(height: 1, color: LibraryTheme.border),
                // Playlists Grid
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(24),
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
    return InkWell(
      onTap: () {
        setState(() {
          _selectedPlaylist = pl;
          _entries = null;
        });
        _reload();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: LibraryTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: LibraryTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: LibraryTheme.raisedSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Icon(
                    Icons.queue_music_rounded,
                    size: 48,
                    color: LibraryTheme.accent,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    pl.title,
                    style: LibraryTheme.rowPrimary.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    size: 16,
                    color: LibraryTheme.mutedText,
                  ),
                  color: LibraryTheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: LibraryTheme.border),
                  ),
                  onSelected: (action) {
                    if (action == 'delete') {
                      _deletePlaylist(pl);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline_rounded,
                            size: 16,
                            color: LibraryTheme.danger,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Delete playlist',
                            style: TextStyle(
                              color: LibraryTheme.danger,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text('${pl.entryCount} items', style: LibraryTheme.metadata),
          ],
        ),
      ),
    );
  }

  // --- Playlist Detail View with Reorderable Tracks ---

  Widget _buildPlaylistDetailView(PlaylistRecord pl) {
    final entries = _entries ?? const <PlaylistEntryRecord>[];
    final totalDuration = entries.fold<Duration>(
      Duration.zero,
      (sum, e) => sum + (e.mediaItem?.metadata.duration ?? Duration.zero),
    );

    return Scaffold(
      backgroundColor: LibraryTheme.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Navigation back breadcrumb
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back to playlists',
                  color: LibraryTheme.secondaryText,
                  onPressed: () {
                    setState(() {
                      _selectedPlaylist = null;
                      _entries = null;
                    });
                    _reload();
                  },
                ),
                const SizedBox(width: 8),
                Text('Playlists', style: LibraryTheme.rowSecondary),
                const SizedBox(width: 6),
                const Text('›', style: LibraryTheme.metadata),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pl.title,
                    style: LibraryTheme.rowPrimary.copyWith(
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
            padding: const EdgeInsets.all(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: LibraryTheme.raisedSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: LibraryTheme.border),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.queue_music_rounded,
                      size: 56,
                      color: LibraryTheme.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(pl.title, style: LibraryTheme.pageTitle),
                      const SizedBox(height: 6),
                      Text(
                        '${entries.length} items • ${_formatDuration(totalDuration)}',
                        style: LibraryTheme.metadata,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: LibraryTheme.accent,
                              foregroundColor: LibraryTheme.background,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: entries.isNotEmpty
                                ? () => _playPlaylist(entries)
                                : null,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text(
                              'Play playlist',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: LibraryTheme.primaryText,
                              side: const BorderSide(
                                color: LibraryTheme.border,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: entries.isNotEmpty
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
          const Divider(height: 1, color: LibraryTheme.border),
          // Reorderable tracks list
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'No tracks in this playlist yet',
                      style: LibraryTheme.metadata,
                    ),
                  )
                : Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(canvasColor: LibraryTheme.surface),
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      itemCount: entries.length,
                      // ignore: deprecated_member_use
                      onReorder: (oldIndex, newIndex) async {
                        await widget.repository.reorderPlaylist(
                          pl.id,
                          oldIndex,
                          newIndex,
                        );
                        setState(() {});
                      },
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final item = entry.mediaItem;
                        final title = item?.title ?? 'Unknown track';
                        final artist = item?.artist ?? 'Unknown artist';
                        final duration =
                            item?.metadata.duration ?? Duration.zero;

                        return Container(
                          key: ValueKey(entry.id),
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          decoration: BoxDecoration(
                            color: LibraryTheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: LibraryTheme.border.withValues(alpha: 0.5),
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onDoubleTap: () async {
                              if (item != null) {
                                final paths = entries
                                    .map((e) => e.mediaItem?.path)
                                    .whereType<String>()
                                    .toList();
                                await widget.controller.openPaths(
                                  paths,
                                  append: false,
                                  initialIndex: index,
                                );
                              }
                            },
                            child: ListTile(
                              dense: true,
                              leading: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.drag_indicator_rounded,
                                    size: 18,
                                    color: LibraryTheme.mutedText,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '${index + 1}',
                                    style: LibraryTheme.metadata,
                                  ),
                                ],
                              ),
                              title: Text(
                                title,
                                style: LibraryTheme.rowPrimary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                artist,
                                style: LibraryTheme.rowSecondary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _formatDuration(duration),
                                    style: LibraryTheme.metadata,
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                    ),
                                    tooltip: 'Remove from playlist',
                                    color: LibraryTheme.mutedText,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () async {
                                      await widget.repository
                                          .removeFromPlaylist(pl.id, entry.id);
                                      setState(() {});
                                    },
                                  ),
                                ],
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
