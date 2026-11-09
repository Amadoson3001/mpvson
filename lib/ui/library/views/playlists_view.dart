import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../utils/format.dart';
import '../../player/player_controller.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/app_dialog.dart';
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
  bool _isDragging = false;

  /// One in-flight (or completed) preview request per playlist, keyed by id.
  final Map<String, Future<List<PlaylistEntryRecord>>> _previewFutures = {};

  /// The playlist record each cached preview was created from.
  final Map<String, PlaylistRecord> _previewRecords = {};

  /// Tracks probed paths to avoid infinite probe -> reload loops on duration-0 items.
  final Set<String> _probedPaths = <String>{};

  /// Chains asynchronous reorders to ensure serialized database application.
  Future<void> _reorderChain = Future.value();

  Future<List<PlaylistEntryRecord>> _previewEntries(PlaylistRecord pl) {
    final cached = _previewFutures[pl.id];
    final record = _previewRecords[pl.id];
    if (cached != null &&
        record != null &&
        record.entryCount == pl.entryCount &&
        record.updatedAt == pl.updatedAt &&
        record.title == pl.title) {
      return cached;
    }
    _previewRecords[pl.id] = pl;
    final future = widget.repository.getPlaylistEntries(pl.id);
    _previewFutures[pl.id] = future;
    return future;
  }

  void _syncPreviewCache(List<PlaylistRecord> playlists) {
    final liveIds = playlists.map((p) => p.id).toSet();
    _previewFutures.removeWhere((id, _) => !liveIds.contains(id));
    _previewRecords.removeWhere((id, _) => !liveIds.contains(id));
    for (final pl in playlists) {
      final cachedRecord = _previewRecords[pl.id];
      if (cachedRecord != null &&
          (cachedRecord.entryCount != pl.entryCount ||
              cachedRecord.updatedAt != pl.updatedAt ||
              cachedRecord.title != pl.title)) {
        _previewFutures.remove(pl.id);
        _previewRecords.remove(pl.id);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_onRepositoryChanged);
    _reload();
  }

  @override
  void didUpdateWidget(PlaylistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_onRepositoryChanged);
      widget.repository.addListener(_onRepositoryChanged);
      _previewFutures.clear();
      _previewRecords.clear();
      _reload();
    } else if (oldWidget.searchQuery != widget.searchQuery) {
      _searchReload?.cancel();
      _searchReload = Timer(const Duration(milliseconds: 150), () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _searchReload?.cancel();
    _reloadThrottle?.cancel();
    widget.repository.removeListener(_onRepositoryChanged);
    super.dispose();
  }

  void _onRepositoryChanged() {
    if (!mounted) return;
    _scheduleReload();
  }

  void _scheduleReload() {
    if (_reloadThrottle != null) return;
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
          _probeMissingMetadata(entries);
        } else {
          final playlists = await widget.repository.getPlaylists();
          if (!mounted) return;
          if (_reloadAgain) continue;
          _syncPreviewCache(playlists);
          setState(() => _playlists = playlists);
        }
      } while (_reloadAgain && mounted);
    } catch (error) {
      debugPrint('Playlists view could not refresh: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _probeMissingMetadata(List<PlaylistEntryRecord> entries) {
    final missing = entries
        .where(
          (e) =>
              e.mediaItem != null &&
              e.mediaItem!.isAvailable &&
              e.mediaItem!.metadata.duration == Duration.zero &&
              !_probedPaths.contains(e.mediaItem!.path),
        )
        .toList();
    if (missing.isEmpty) return;

    for (final entry in missing) {
      final path = entry.mediaItem?.path;
      if (path != null) {
        _probedPaths.add(path);
      }
    }

    unawaited(
      Future(() async {
        for (final entry in missing) {
          if (!mounted) break;
          final item = entry.mediaItem;
          if (item != null) {
            await widget.repository.probeMedia(item.path);
            await Future<void>.delayed(const Duration(milliseconds: 16));
          }
        }
      }),
    );
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
    final confirmed = await AppDialog.show<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        maxWidth: 420,
        title: const Text('Delete playlist'),
        content: Text(
          'Are you sure you want to delete "${pl.title}"? The media files themselves will remain on your computer.',
          style: ctx.palette.rowSecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.palette.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await widget.repository.deletePlaylist(pl.id);
      _previewFutures.remove(pl.id);
      _previewRecords.remove(pl.id);
      if (mounted && _selectedPlaylist?.id == pl.id) {
        setState(() {
          _selectedPlaylist = null;
          _entries = null;
        });
      }
      if (mounted) {
        _reload();
        AppToast.show(
          context,
          'Playlist "${pl.title}" deleted',
          tone: AppToastTone.neutral,
        );
      }
    }
  }

  Future<void> _renamePlaylist(PlaylistRecord playlist) async {
    final title = await AppDialog.show<String>(
      context: context,
      builder: (_) => _RenamePlaylistDialog(initialTitle: playlist.title),
    );
    if (title != null && title.isNotEmpty && mounted) {
      try {
        await widget.repository.renamePlaylist(playlist.id, title);
        _previewFutures.remove(playlist.id);
        _previewRecords.remove(playlist.id);
        if (mounted && _selectedPlaylist?.id == playlist.id) {
          setState(() {
            _selectedPlaylist = _selectedPlaylist!.copyWith(title: title);
          });
        }
        if (mounted) {
          _reload();
          AppToast.show(
            context,
            'Playlist renamed to "$title"',
            tone: AppToastTone.success,
          );
        }
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

  Future<void> _clearPlaylist(PlaylistRecord pl) async {
    final confirmed = await AppDialog.show<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        maxWidth: 420,
        title: const Text('Clear playlist'),
        content: Text(
          'Are you sure you want to remove all tracks from "${pl.title}"? The media files themselves will remain on your computer.',
          style: ctx.palette.rowSecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.palette.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await widget.repository.clearPlaylist(pl.id);
        _previewFutures.remove(pl.id);
        _previewRecords.remove(pl.id);
        if (!mounted) return;
        setState(() => _entries = <PlaylistEntryRecord>[]);
        _reload();
        AppToast.show(
          context,
          'Cleared all tracks from "${pl.title}"',
          tone: AppToastTone.neutral,
        );
      } catch (_) {
        if (mounted) {
          AppToast.show(
            context,
            'Could not clear tracks from playlist',
            tone: AppToastTone.danger,
          );
        }
      }
    }
  }

  Future<void> _pickAndAddFiles(PlaylistRecord pl) async {
    try {
      final typeGroup = XTypeGroup(
        label: 'Media files',
        extensions: MediaCatalog.filePickerExtensions,
      );
      final files = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (files.isNotEmpty) {
        final paths = files.map((f) => f.path).toList();
        await _addPaths(pl, paths);
      }
    } catch (e) {
      debugPrint('Error picking files for playlist: $e');
    }
  }

  Future<void> _addPaths(PlaylistRecord pl, List<String> paths) async {
    try {
      await widget.repository.addPathsToPlaylist(pl.id, paths);
      _previewFutures.remove(pl.id);
      _previewRecords.remove(pl.id);
      if (mounted) {
        _reload();
        AppToast.show(
          context,
          paths.length == 1
              ? 'Added 1 file to playlist'
              : 'Added ${paths.length} files to playlist',
          tone: AppToastTone.success,
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(
          context,
          'Could not add files to playlist',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  Future<void> _showAddFromLibrary(PlaylistRecord pl) async {
    final selectedMediaIds = await AppDialog.show<List<String>>(
      context: context,
      builder: (_) =>
          _AddFromLibraryDialog(repository: widget.repository, playlist: pl),
    );

    if (selectedMediaIds != null && selectedMediaIds.isNotEmpty && mounted) {
      try {
        await widget.repository.addToPlaylist(pl.id, selectedMediaIds);
        _previewFutures.remove(pl.id);
        _previewRecords.remove(pl.id);
        if (mounted) {
          _reload();
          AppToast.show(
            context,
            selectedMediaIds.length == 1
                ? 'Added 1 item to playlist'
                : 'Added ${selectedMediaIds.length} items to playlist',
            tone: AppToastTone.success,
          );
        }
      } catch (e) {
        if (mounted) {
          AppToast.show(
            context,
            'Could not add items to playlist',
            tone: AppToastTone.danger,
          );
        }
      }
    }
  }

  void _reorderEntries(PlaylistRecord pl, int oldIndex, int newIndex) {
    final current = _entries;
    if (current == null ||
        oldIndex < 0 ||
        oldIndex >= current.length ||
        newIndex < 0 ||
        newIndex > current.length) {
      return;
    }
    final movedItem = current[oldIndex];
    final insertAt = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final reordered = List<PlaylistEntryRecord>.of(current)
      ..removeAt(oldIndex)
      ..insert(insertAt, movedItem);
    setState(() => _entries = reordered);
    _reorderChain = _reorderChain
        .then((_) async {
          await widget.repository.reorderPlaylist(
            pl.id,
            oldIndex,
            newIndex,
            entryId: movedItem.id,
          );
          _previewFutures.remove(pl.id);
          _previewRecords.remove(pl.id);
        })
        .catchError((Object error) {
          debugPrint('Playlist reorder could not persist: $error');
          if (mounted) _reload();
        });
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
      backgroundColor: context.palette.background,
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
                  color: context.palette.surface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.lg,
                    vertical: AppSpace.sm,
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Playlists (${playlists.length})',
                        style: context.palette.sectionTitle,
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: context.palette.accentForeground,
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
                Divider(height: 1, color: context.palette.border),
                // Playlists Grid
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final availableWidth =
                          (constraints.maxWidth - 2 * AppSpace.lg).clamp(
                            0.0,
                            double.infinity,
                          );
                      final columns = ((availableWidth + 20) / 220)
                          .ceil()
                          .clamp(2, 12);
                      final tileWidth =
                          (availableWidth - (columns - 1) * 20) / columns;
                      final textHeight =
                          MediaQuery.textScalerOf(context).scale(13) * 3.8;

                      return GridView.builder(
                        addAutomaticKeepAlives: false,
                        padding: const EdgeInsets.all(AppSpace.lg),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 20,
                          mainAxisExtent: tileWidth + textHeight + 14,
                        ),
                        itemCount: playlists.length,
                        itemBuilder: (context, index) {
                          final pl = playlists[index];
                          return _buildPlaylistCard(pl);
                        },
                      );
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
        future: _previewEntries(pl),
        builder: (context, snapshot) {
          final entries = snapshot.data;
          final media = (entries?.isEmpty ?? true)
              ? null
              : entries!.first.mediaItem;
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
      backgroundColor: context.palette.background,
      body: DropTarget(
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        onDragDone: (details) async {
          setState(() => _isDragging = false);
          final paths = details.files
              .map((f) => f.path)
              .where((p) => p.isNotEmpty)
              .toList();
          if (paths.isNotEmpty) {
            await _addPaths(pl, paths);
          }
        },
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Navigation back breadcrumb & quick actions
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
                        color: context.palette.secondaryText,
                        onPressed: () {
                          setState(() {
                            _selectedPlaylist = null;
                            _entries = null;
                          });
                          _reload();
                        },
                      ),
                      const SizedBox(width: 8),
                      Text('Playlists', style: context.palette.rowSecondary),
                      const SizedBox(width: 6),
                      Text('›', style: context.palette.metadata),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          pl.title,
                          style: context.palette.rowPrimary.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: 'Rename playlist',
                        color: context.palette.secondaryText,
                        onPressed: () => _renamePlaylist(pl),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        tooltip: 'Delete playlist',
                        color: context.palette.secondaryText,
                        hoverColor: context.palette.danger.withValues(
                          alpha: 0.12,
                        ),
                        onPressed: () => _deletePlaylist(pl),
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
                          child: _PlaylistHeroCover(
                            entries: entries,
                            repository: widget.repository,
                            controller: widget.controller,
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
                              style: context.palette.pageTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${entries.length} items • ${formatDuration(totalDuration)}',
                              style: context.palette.metadata,
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: accent,
                                    foregroundColor:
                                        context.palette.accentForeground,
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
                                        (e) =>
                                            e.mediaItem?.isAvailable ?? false,
                                      )
                                      ? () => _playPlaylist(entries)
                                      : null,
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: const Text(
                                    'Play playlist',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor:
                                        context.palette.primaryText,
                                    side: BorderSide(
                                      color: context.palette.border,
                                    ),
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
                                        (e) =>
                                            e.mediaItem?.isAvailable ?? false,
                                      )
                                      ? () => _playPlaylist(
                                          entries,
                                          shuffle: true,
                                        )
                                      : null,
                                  icon: const Icon(
                                    Icons.shuffle_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Shuffle'),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor:
                                        context.palette.primaryText,
                                    side: BorderSide(
                                      color: context.palette.border,
                                    ),
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
                                  onPressed: () => _pickAndAddFiles(pl),
                                  icon: const Icon(Icons.add_rounded, size: 18),
                                  label: const Text('Add files'),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor:
                                        context.palette.primaryText,
                                    side: BorderSide(
                                      color: context.palette.border,
                                    ),
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
                                  onPressed: () => _showAddFromLibrary(pl),
                                  icon: const Icon(
                                    Icons.library_music_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('From library'),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: 'More actions',
                                  icon: const Icon(
                                    Icons.more_horiz_rounded,
                                    size: 20,
                                  ),
                                  onSelected: (val) {
                                    if (val == 'rename') _renamePlaylist(pl);
                                    if (val == 'clear') _clearPlaylist(pl);
                                    if (val == 'delete') _deletePlaylist(pl);
                                  },
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                      value: 'rename',
                                      child: Text('Rename playlist'),
                                    ),
                                    if (entries.isNotEmpty)
                                      const PopupMenuItem(
                                        value: 'clear',
                                        child: Text('Clear all tracks'),
                                      ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text(
                                        'Delete playlist',
                                        style: TextStyle(
                                          color: context.palette.danger,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: context.palette.border),
                // Tracks list or clean empty state
                Expanded(
                  child: entries.isEmpty
                      ? EmptyState(
                          icon: Icons.queue_music_rounded,
                          title: 'This playlist is empty',
                          message:
                              'Add audio or video files from your computer or library, or drop files here.',
                          actionLabel: 'Add files',
                          onAction: () => _pickAndAddFiles(pl),
                        )
                      : Theme(
                          data: Theme.of(
                            context,
                          ).copyWith(canvasColor: context.palette.surface),
                          child: ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.lg,
                              vertical: AppSpace.md,
                            ),
                            itemCount: entries.length,
                            // ignore: deprecated_member_use
                            onReorder: (oldIndex, newIndex) =>
                                _reorderEntries(pl, oldIndex, newIndex),
                            itemBuilder: (context, index) {
                              final entry = entries[index];
                              final item = entry.mediaItem;
                              final (displayTitle, displaySubtitle) =
                                  _resolveDisplayTitleAndSubtitle(item);
                              final rawDuration =
                                  item?.metadata.duration ?? Duration.zero;
                              final peekedDuration =
                                  item != null && rawDuration == Duration.zero
                                  ? (widget.controller
                                            .peekThumbnail(
                                              MediaEntry.fromPath(
                                                item.path,
                                                id: item.id,
                                              ),
                                            )
                                            ?.duration ??
                                        Duration.zero)
                                  : Duration.zero;
                              final effectiveDuration =
                                  rawDuration > Duration.zero
                                  ? rawDuration
                                  : peekedDuration;
                              final isSelected = _selectedEntry == entry.id;
                              final subtitleText =
                                  item != null && !item.isAvailable
                                  ? (displaySubtitle.isNotEmpty
                                        ? '$displaySubtitle • Missing'
                                        : 'Missing')
                                  : displaySubtitle;

                              return MediaRow(
                                key: ValueKey(entry.id),
                                onSelect: () {
                                  if (_selectedEntry != entry.id) {
                                    setState(() => _selectedEntry = entry.id);
                                  }
                                },
                                onPlay: item?.isAvailable == true
                                    ? () => _playPlaylist(
                                        entries,
                                        startIndex: index,
                                      )
                                    : null,
                                builder: (context, rowFocus) => RepaintBoundary(
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? context.palette.hover
                                          : Colors.transparent,
                                      border: isSelected
                                          ? Border(
                                              left: BorderSide(
                                                color: accent,
                                                width: 2,
                                              ),
                                            )
                                          : null,
                                    ),
                                    child: InkWell(
                                      canRequestFocus: false,
                                      onTap: () {
                                        rowFocus.requestFocus();
                                        setState(
                                          () => _selectedEntry = entry.id,
                                        );
                                      },
                                      borderRadius: BorderRadius.circular(
                                        AppRadii.control,
                                      ),
                                      hoverColor: context.palette.hover,
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
                                            ReorderableDragStartListener(
                                              index: index,
                                              child: MouseRegion(
                                                cursor: SystemMouseCursors.grab,
                                                child: Icon(
                                                  Icons.drag_indicator_rounded,
                                                  size: 18,
                                                  color:
                                                      context.palette.mutedText,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            SizedBox(
                                              width: 24,
                                              child: Text(
                                                '${index + 1}',
                                                style: context.palette.metadata,
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            _PlaylistTrackThumbnail(
                                              item: item,
                                              controller: widget.controller,
                                              repository: widget.repository,
                                              onDurationDiscovered:
                                                  (discovered) {
                                                    if (mounted &&
                                                        rawDuration ==
                                                            Duration.zero) {
                                                      WidgetsBinding.instance
                                                          .addPostFrameCallback(
                                                            (_) {
                                                              if (mounted) {
                                                                setState(() {});
                                                              }
                                                            },
                                                          );
                                                    }
                                                  },
                                            ),
                                          ],
                                        ),
                                        title: Text(
                                          displayTitle,
                                          style: context.palette.rowPrimary,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: subtitleText.isNotEmpty
                                            ? Text(
                                                subtitleText,
                                                style: context
                                                    .palette
                                                    .rowSecondary,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              )
                                            : null,
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              formatDuration(effectiveDuration),
                                              style: context.palette.metadata,
                                            ),
                                            const SizedBox(width: 8),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.close_rounded,
                                                size: 16,
                                              ),
                                              tooltip: 'Remove from playlist',
                                              color: context.palette.mutedText,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed: () async {
                                                final previousEntries =
                                                    _entries;
                                                setState(() {
                                                  _entries = _entries
                                                      ?.where(
                                                        (e) => e.id != entry.id,
                                                      )
                                                      .toList();
                                                });
                                                try {
                                                  await widget.repository
                                                      .removeFromPlaylist(
                                                        pl.id,
                                                        entry.id,
                                                      );
                                                  _previewFutures.remove(pl.id);
                                                  _previewRecords.remove(pl.id);
                                                } catch (error) {
                                                  if (!mounted) return;
                                                  setState(
                                                    () => _entries =
                                                        previousEntries,
                                                  );
                                                  if (this.context.mounted) {
                                                    AppToast.show(
                                                      this.context,
                                                      'Could not remove track from playlist',
                                                      tone: AppToastTone.danger,
                                                    );
                                                  }
                                                }
                                              },
                                            ),
                                          ],
                                        ),
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
            if (_isDragging)
              Positioned.fill(
                child: Container(
                  color: context.palette.background.withValues(alpha: 0.85),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.file_download_rounded,
                        size: 48,
                        color: accent,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Drop files to add to playlist',
                        style: context.palette.pageTitle,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
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
  bool _canSubmit = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
    _canSubmit = widget.initialTitle.trim().isNotEmpty;
    _controller.addListener(() {
      final valid = _controller.text.trim().isNotEmpty;
      if (valid != _canSubmit) {
        setState(() => _canSubmit = valid);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      maxWidth: 420,
      title: const Text('Rename playlist'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Playlist title',
          hintText: 'Enter new title',
        ),
        onSubmitted: (_) {
          if (_canSubmit) {
            Navigator.of(context).pop(_controller.text.trim());
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSubmit
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AddFromLibraryDialog extends StatefulWidget {
  const _AddFromLibraryDialog({
    required this.repository,
    required this.playlist,
  });

  final MediaLibraryRepository repository;
  final PlaylistRecord playlist;

  @override
  State<_AddFromLibraryDialog> createState() => _AddFromLibraryDialogState();
}

class _AddFromLibraryDialogState extends State<_AddFromLibraryDialog> {
  final Set<String> _selected = <String>{};
  List<MediaItemRecord>? _allItems;
  bool _loading = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.repository.queryMedia(
        sortBy: 'title',
        ascending: true,
      );
      final currentEntries = await widget.repository.getPlaylistEntries(
        widget.playlist.id,
      );
      final existingIds = currentEntries.map((e) => e.mediaId).toSet();

      if (mounted) {
        setState(() {
          _allItems = items.where((i) => !existingIds.contains(i.id)).toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = (_allItems ?? const <MediaItemRecord>[]).where((item) {
      if (_search.isEmpty) return true;
      final q = _search.toLowerCase();
      return item.title.toLowerCase().contains(q) ||
          item.artist.toLowerCase().contains(q);
    }).toList();

    return AppDialog(
      maxWidth: 540,
      title: const Text('Add from library'),
      content: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search tracks...',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                isDense: true,
              ),
              onChanged: (val) => setState(() => _search = val.trim()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : (_allItems?.isEmpty ?? true)
                  ? Center(
                      child: Text(
                        'All library tracks are already in this playlist.',
                        style: context.palette.metadata,
                      ),
                    )
                  : filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No matching tracks found.',
                        style: context.palette.metadata,
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        final isChecked = _selected.contains(item.id);
                        return CheckboxListTile(
                          value: isChecked,
                          dense: true,
                          onChanged: (val) {
                            setState(() {
                              if (val == true) {
                                _selected.add(item.id);
                              } else {
                                _selected.remove(item.id);
                              }
                            });
                          },
                          title: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.palette.rowPrimary,
                          ),
                          subtitle: Text(
                            item.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.palette.rowSecondary,
                          ),
                          secondary: SizedBox(
                            width: 36,
                            height: 36,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AppRadii.artwork,
                              ),
                              child: LibraryArtwork(
                                path: item.metadata.artworkUri,
                                mediaPath: item.path,
                                repository: widget.repository,
                                icon: item.kind.isVideo
                                    ? Icons.movie_rounded
                                    : Icons.music_note_rounded,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          child: Text(_selected.isEmpty ? 'Add' : 'Add (${_selected.length})'),
        ),
      ],
    );
  }
}

(String, String) _resolveDisplayTitleAndSubtitle(MediaItemRecord? item) {
  if (item == null) return ('Unknown track', '');

  final cleanTitle = MediaCatalog.displayName(item.title);
  final rawArtist = item.metadata.artist?.trim() ?? '';
  final hasKnownArtist =
      rawArtist.isNotEmpty &&
      rawArtist.toLowerCase() != 'unknown artist' &&
      rawArtist.toLowerCase() != 'unknown';

  if (hasKnownArtist) {
    if (cleanTitle.toLowerCase().startsWith('${rawArtist.toLowerCase()} - ')) {
      final subTitle = cleanTitle.substring(rawArtist.length + 3).trim();
      return (subTitle.isNotEmpty ? subTitle : cleanTitle, rawArtist);
    }
    return (cleanTitle, rawArtist);
  }

  if (cleanTitle.contains(' - ')) {
    final separatorIdx = cleanTitle.indexOf(' - ');
    final parsedArtist = cleanTitle.substring(0, separatorIdx).trim();
    final parsedTitle = cleanTitle.substring(separatorIdx + 3).trim();
    if (parsedArtist.isNotEmpty && parsedTitle.isNotEmpty) {
      return (parsedTitle, parsedArtist);
    }
  }

  final isVideo =
      item.kind == MediaKind.video ||
      MediaCatalog.kindFromExtension(item.path) == MediaKind.video;
  return (cleanTitle, isVideo ? 'Video' : '');
}

class _PlaylistHeroCover extends StatefulWidget {
  const _PlaylistHeroCover({
    required this.entries,
    required this.repository,
    required this.controller,
  });

  final List<PlaylistEntryRecord> entries;
  final MediaLibraryRepository repository;
  final PlayerController controller;

  @override
  State<_PlaylistHeroCover> createState() => _PlaylistHeroCoverState();
}

class _PlaylistHeroCoverState extends State<_PlaylistHeroCover> {
  ThumbnailRequestHandle? _request;
  MediaThumbnail? _videoThumb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PlaylistHeroCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldFirst = oldWidget.entries.firstOrNull?.mediaItem?.path;
    final newFirst = widget.entries.firstOrNull?.mediaItem?.path;
    if (oldFirst != newFirst || oldWidget.controller != widget.controller) {
      _request?.release();
      _request = null;
      _videoThumb = null;
      _load();
    }
  }

  @override
  void dispose() {
    _request?.release();
    _request = null;
    super.dispose();
  }

  void _load() {
    if (widget.entries.isEmpty) return;
    final item = widget.entries.first.mediaItem;
    if (item == null || !item.isAvailable) return;
    final isVideo =
        item.kind == MediaKind.video ||
        MediaCatalog.kindFromExtension(item.path) == MediaKind.video;

    if (isVideo) {
      final entry = MediaEntry.fromPath(item.path, id: item.id);
      final peeked = widget.controller.peekThumbnail(entry);
      if (peeked != null) {
        _videoThumb = peeked;
      } else {
        _request = widget.controller.requestThumbnail(entry);
        _request?.thumbnail
            .then((thumb) {
              if (!mounted || thumb == null) return;
              setState(() => _videoThumb = thumb);
            })
            .catchError((_) {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return Container(
        color: context.palette.raisedSurface,
        child: Center(
          child: Icon(
            Icons.queue_music_rounded,
            size: 56,
            color: context.palette.mutedText,
          ),
        ),
      );
    }

    final item = widget.entries.first.mediaItem;
    final isVideo =
        item != null &&
        (item.kind == MediaKind.video ||
            MediaCatalog.kindFromExtension(item.path) == MediaKind.video);

    if (isVideo) {
      final bytes = _videoThumb?.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        return RepaintBoundary(
          child: Image.memory(
            bytes,
            width: 140,
            height: 140,
            cacheWidth: 280,
            cacheHeight: 280,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => Container(
              color: context.palette.raisedSurface,
              child: Center(
                child: Icon(
                  Icons.movie_creation_outlined,
                  size: 56,
                  color: context.palette.mutedText,
                ),
              ),
            ),
          ),
        );
      }
      return Container(
        color: context.palette.raisedSurface,
        child: Center(
          child: Icon(
            Icons.movie_creation_outlined,
            size: 56,
            color: context.palette.mutedText,
          ),
        ),
      );
    }

    return LibraryArtwork(
      path: item?.metadata.artworkUri,
      mediaPath: item?.path,
      repository: widget.repository,
      icon: Icons.queue_music_rounded,
      iconSize: 56,
    );
  }
}

class _PlaylistTrackThumbnail extends StatefulWidget {
  const _PlaylistTrackThumbnail({
    required this.item,
    required this.controller,
    required this.repository,
    this.onDurationDiscovered,
  });

  final MediaItemRecord? item;
  final PlayerController controller;
  final MediaLibraryRepository repository;
  final ValueChanged<Duration>? onDurationDiscovered;

  @override
  State<_PlaylistTrackThumbnail> createState() =>
      _PlaylistTrackThumbnailState();
}

class _PlaylistTrackThumbnailState extends State<_PlaylistTrackThumbnail> {
  ThumbnailRequestHandle? _request;
  MediaThumbnail? _cachedThumbnail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PlaylistTrackThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.path != widget.item?.path ||
        oldWidget.controller != widget.controller) {
      _request?.release();
      _request = null;
      _cachedThumbnail = null;
      _load();
    }
  }

  @override
  void dispose() {
    _request?.release();
    _request = null;
    super.dispose();
  }

  void _load() {
    final item = widget.item;
    if (item == null || !item.isAvailable) return;

    final isVideo =
        item.kind == MediaKind.video ||
        MediaCatalog.kindFromExtension(item.path) == MediaKind.video;

    if (isVideo) {
      final entry = MediaEntry.fromPath(item.path, id: item.id);
      final peeked = widget.controller.peekThumbnail(entry);
      if (peeked != null) {
        _cachedThumbnail = peeked;
        if (peeked.duration > Duration.zero) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              widget.onDurationDiscovered?.call(peeked.duration);
            }
          });
        }
      } else {
        _request = widget.controller.requestThumbnail(entry);
        _request?.thumbnail
            .then((thumb) {
              if (!mounted || thumb == null) return;
              setState(() => _cachedThumbnail = thumb);
              if (thumb.duration > Duration.zero) {
                widget.onDurationDiscovered?.call(thumb.duration);
                unawaited(
                  widget.repository.updateMediaDuration(
                    item.canonicalSource,
                    thumb.duration,
                  ),
                );
              }
            })
            .catchError((_) {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isVideo =
        item != null &&
        (item.kind == MediaKind.video ||
            MediaCatalog.kindFromExtension(item.path) == MediaKind.video);

    Widget fallback() => Container(
      width: 48,
      height: 32,
      decoration: BoxDecoration(
        color: context.palette.raisedSurface,
        borderRadius: BorderRadius.circular(AppRadii.control - 1),
      ),
      child: Center(
        child: Icon(
          isVideo ? Icons.movie_outlined : Icons.music_note_rounded,
          size: 15,
          color: context.palette.mutedText,
        ),
      ),
    );

    if (item == null) return fallback();

    if (isVideo) {
      final bytes = _cachedThumbnail?.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        return RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.control - 1),
            child: SizedBox(
              width: 48,
              height: 32,
              child: Image.memory(
                bytes,
                width: 48,
                height: 32,
                cacheWidth: 96,
                cacheHeight: 64,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback(),
              ),
            ),
          ),
        );
      }
      return fallback();
    }

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control - 1),
        child: SizedBox(
          width: 48,
          height: 32,
          child: ColoredBox(
            color: context.palette.raisedSurface,
            child: Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: LibraryArtwork(
                  path: item.metadata.artworkUri,
                  mediaPath: item.path,
                  repository: widget.repository,
                  icon: Icons.music_note_rounded,
                  iconSize: 16,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
