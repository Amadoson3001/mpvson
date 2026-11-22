import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../data/services/diagnostic_log.dart';
import '../../../utils/file_utils.dart';
import '../../../utils/format.dart';
import '../../player/player_controller.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/animated_grid_reflow.dart';
import '../../core/components/app_dialog.dart';
import '../../core/components/hover_builder.dart';
import '../../core/components/media_tile.dart';
import '../../core/components/media_row.dart';
import '../../core/components/page_header.dart';
import '../widgets/library_artwork.dart';
import '../../core/components/empty_state.dart';
import '../widgets/media_context_menu.dart';
import '../widgets/library_item_actions.dart';
import '../widgets/playlist_create_dialog.dart';
import '../library_browse_constants.dart';
import '../library_reload_coordinator.dart';
import '../media_pager.dart';
import '../paged_media_loader.dart';

part 'playlist_dialogs.dart';
part 'playlist_hero_cover.dart';
part 'playlist_track_row.dart';

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
  final ValueNotifier<String?> _selectedEntryId = ValueNotifier<String?>(null);
  String? _currentPlayingPath;
  Object? _error;
  late final LibraryReloadCoordinator _reloadCoordinator;
  bool _isDragging = false;
  int _probeGeneration = 0;
  DateTime? _lastPlayTriggerAt;
  String? _lastPlayTriggerKey;

  /// One cached preview request per playlist, pairing its snapshot record with
  /// its future so cached data and invalidation stay together.
  final Map<
    String,
    ({PlaylistRecord record, Future<List<PlaylistEntryRecord>> future})
  >
  _previews = {};

  /// Tracks probed paths to avoid infinite probe -> reload loops on duration-0 items.
  final Set<String> _probedPaths = <String>{};

  /// Chains asynchronous reorders to ensure serialized database application.
  Future<void> _reorderChain = Future.value();

  static bool _previewMatches(PlaylistRecord cached, PlaylistRecord current) =>
      cached.entryCount == current.entryCount &&
      cached.updatedAt == current.updatedAt &&
      cached.title == current.title;

  Future<List<PlaylistEntryRecord>> _previewEntries(PlaylistRecord pl) {
    final cached = _previews[pl.id];
    if (cached != null && _previewMatches(cached.record, pl)) {
      return cached.future;
    }
    final future = widget.repository.getPlaylistEntries(pl.id);
    _previews[pl.id] = (record: pl, future: future);
    return future;
  }

  void _syncPreviewCache(List<PlaylistRecord> playlists) {
    final byId = {for (final pl in playlists) pl.id: pl};
    _previews.removeWhere((id, entry) {
      final current = byId[id];
      return current == null || !_previewMatches(entry.record, current);
    });
  }

  @override
  void initState() {
    super.initState();
    _reloadCoordinator = LibraryReloadCoordinator(
      onReload: _runReload,
      onError: (error) {
        diagnosticDebug('playlists.refresh', error: error);
        if (mounted) setState(() => _error = error);
      },
      onLoadingChanged: (loading) {
        if (mounted && _playlists == null && _entries == null) setState(() {});
      },
      isDisposed: () => !mounted,
    );
    widget.repository.addListener(_onRepositoryChanged);
    widget.controller.structureListenable.addListener(_onPlaybackChanged);
    _currentPlayingPath = widget.controller.current?.path;
    _reload();
  }

  @override
  void didUpdateWidget(PlaylistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.structureListenable.removeListener(
        _onPlaybackChanged,
      );
      widget.controller.structureListenable.addListener(_onPlaybackChanged);
      _currentPlayingPath = widget.controller.current?.path;
    }
    if (oldWidget.repository != widget.repository) {
      _probeGeneration++;
      oldWidget.repository.removeListener(_onRepositoryChanged);
      widget.repository.addListener(_onRepositoryChanged);
      _previews.clear();
      _reload();
    } else if (oldWidget.searchQuery != widget.searchQuery) {
      // The shell already debounces typing; refilter immediately.
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _probeGeneration++;
    _selectedEntryId.dispose();
    _reloadCoordinator.dispose();
    widget.repository.removeListener(_onRepositoryChanged);
    widget.controller.structureListenable.removeListener(_onPlaybackChanged);
    super.dispose();
  }

  void _onPlaybackChanged() {
    final nextPath = widget.controller.current?.path;
    if (nextPath == _currentPlayingPath) return;
    if (mounted) {
      setState(() => _currentPlayingPath = nextPath);
    }
  }

  void _onRepositoryChanged() {
    _reloadCoordinator.onRepositoryChanged(
      isScanning: widget.repository.scanStatus.isScanning,
    );
  }

  Future<void> _reload() => _reloadCoordinator.reload();

  Future<void> _runReload(int epoch) async {
    final selectedId = _selectedPlaylist?.id;
    if (selectedId != null) {
      final entries = await widget.repository.getPlaylistEntries(selectedId);
      if (!mounted || epoch != _reloadCoordinator.epoch) return;
      setState(() {
        _entries = entries;
        _error = null;
      });
      _probeMissingMetadata(entries);
    } else {
      final playlists = await widget.repository.getPlaylists();
      if (!mounted || epoch != _reloadCoordinator.epoch) return;
      _syncPreviewCache(playlists);
      setState(() {
        _playlists = playlists;
        _error = null;
      });
    }
  }

  void _probeMissingMetadata(List<PlaylistEntryRecord> entries) {
    final currentPlaylistId = _selectedPlaylist?.id;
    if (currentPlaylistId == null) return;

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

    final currentGen = ++_probeGeneration;

    unawaited(
      Future(() async {
        for (final entry in missing) {
          if (!mounted ||
              _probeGeneration != currentGen ||
              _selectedPlaylist?.id != currentPlaylistId) {
            break;
          }
          final item = entry.mediaItem;
          if (item != null) {
            if (_probedPaths.contains(item.path)) continue;
            _probedPaths.add(item.path);
            await widget.repository.probeMedia(item.path);
            if (!mounted ||
                _probeGeneration != currentGen ||
                _selectedPlaylist?.id != currentPlaylistId) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 16));
          }
        }
      }),
    );
  }

  void _selectPlaylist(PlaylistRecord? playlist) {
    _probeGeneration++;
    _selectedEntryId.value = null;
    setState(() {
      _selectedPlaylist = playlist;
      _entries = null;
    });
    _reload();
  }

  Future<void> _createPlaylist() async {
    final playlist = await PlaylistCreateDialog.show(
      context,
      widget.repository,
    );
    if (playlist != null && mounted) {
      _selectPlaylist(playlist);
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
      _previews.remove(pl.id);
      if (mounted && _selectedPlaylist?.id == pl.id) {
        _selectPlaylist(null);
      } else if (mounted) {
        _reload();
      }
      if (mounted) {
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
        _previews.remove(playlist.id);
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
        _previews.remove(pl.id);
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
      diagnosticDebug('playlists.pickFiles', error: e);
    }
  }

  Future<void> _addPaths(PlaylistRecord pl, List<String> paths) async {
    try {
      await widget.repository.addPathsToPlaylist(pl.id, paths);
      _previews.remove(pl.id);
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
        _previews.remove(pl.id);
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
          _previews.remove(pl.id);
        })
        .catchError((Object error) {
          diagnosticDebug('playlists.reorder', error: error);
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

    final now = DateTime.now();
    final key = '${_selectedPlaylist?.id}:$shuffle:$startIndex:${paths.length}';
    if (_lastPlayTriggerKey == key &&
        _lastPlayTriggerAt != null &&
        now.difference(_lastPlayTriggerAt!) <
            const Duration(milliseconds: 350)) {
      return;
    }
    _lastPlayTriggerAt = now;
    _lastPlayTriggerKey = key;

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

  Future<void> _removeEntry(
    PlaylistRecord pl,
    PlaylistEntryRecord entry,
  ) async {
    final previousEntries = _entries;
    setState(() {
      _entries = _entries?.where((e) => e.id != entry.id).toList();
    });
    if (_selectedEntryId.value == entry.id) {
      _selectedEntryId.value = null;
    }
    try {
      await widget.repository.removeFromPlaylist(pl.id, entry.id);
      _previews.remove(pl.id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _entries = previousEntries);
      AppToast.show(
        context,
        'Could not remove track from playlist',
        tone: AppToastTone.danger,
      );
    }
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
      body: _reloadCoordinator.isLoading && _playlists == null
          ? Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            )
          : _error != null && playlists.isEmpty
          ? EmptyState(
              title: "Couldn't load playlists",
              message:
                  'The library could not be queried. Try again, or check that the library database is available.',
              icon: Icons.error_outline_rounded,
              actionLabel: 'Try again',
              actionIcon: Icons.refresh_rounded,
              onAction: () => unawaited(_reload()),
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
          : LayoutBuilder(
              builder: (context, constraints) {
                final gutter = PageHeader.gutterFor(constraints.maxWidth);
                final textHeight =
                    MediaQuery.textScalerOf(context).scale(13) * 3.8;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header bar
                    Container(
                      color: context.palette.surface,
                      padding: EdgeInsets.symmetric(
                        horizontal: gutter,
                        vertical: AppSpace.sm,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Playlists (${playlists.length})',
                              style: context.palette.sectionTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: AppSpace.sm),
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
                      child: StableGridReflowBox(
                        metricsBuilder: (width, columnBasisWidth) {
                          final g = PageHeader.gutterFor(width);
                          final avail = (width - 2 * g).clamp(
                            0.0,
                            double.infinity,
                          );
                          final basisG = PageHeader.gutterFor(columnBasisWidth);
                          final basisAvail = (columnBasisWidth - 2 * basisG)
                              .clamp(0.0, double.infinity);
                          final cols = ((basisAvail + 20) / 220).ceil().clamp(
                            2,
                            12,
                          );
                          final tw = (avail - (cols - 1) * 20) / cols;
                          return GridReflowMetrics(
                            columns: cols,
                            itemWidth: tw,
                            itemHeight: tw + textHeight + 14,
                            crossAxisSpacing: 20,
                            mainAxisSpacing: 20,
                            horizontalPadding: g,
                          );
                        },
                        builder: (context, metrics, isReflowing) =>
                            GridView.builder(
                              clipBehavior: isReflowing
                                  ? Clip.none
                                  : Clip.hardEdge,
                              addAutomaticKeepAlives: false,
                              padding: EdgeInsets.fromLTRB(
                                metrics.horizontalPadding,
                                AppSpace.lg,
                                metrics.horizontalPadding,
                                AppSpace.xl,
                              ),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: metrics.columns,
                                    mainAxisSpacing: metrics.mainAxisSpacing,
                                    crossAxisSpacing: metrics.crossAxisSpacing,
                                    mainAxisExtent: metrics.itemHeight,
                                  ),
                              itemCount: playlists.length,
                              itemBuilder: (context, index) {
                                final pl = playlists[index];
                                return GridReflowItem(
                                  key: ValueKey(pl.id),
                                  index: index,
                                  child: _buildPlaylistCard(pl),
                                );
                              },
                            ),
                      ),
                    ),
                  ],
                );
              },
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
      subtitle: '${pl.entryCount} ${pl.entryCount == 1 ? 'item' : 'items'}',
      onTap: () => _selectPlaylist(pl),
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
    final isInitialLoading = _entries == null && _reloadCoordinator.isLoading;
    final hasPlayable = entries.any((e) => e.mediaItem?.isAvailable ?? false);
    final totalDuration = entries.fold<Duration>(
      Duration.zero,
      (sum, e) => sum + (e.mediaItem?.metadata.duration ?? Duration.zero),
    );
    final firstItem = entries.firstOrNull?.mediaItem;
    final isVideoCover =
        firstItem != null &&
        (firstItem.kind == MediaKind.video ||
            MediaCatalog.kindFromExtension(firstItem.path) == MediaKind.video);

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final gutter = PageHeader.gutterFor(width);
            final compact = width < AppLayout.compactBreakpoint;
            final narrow = width < 440;
            final thumbWidth = compact ? 52.0 : 64.0;
            final thumbHeight = compact ? 30.0 : 36.0;

            return Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Pinned navigation breadcrumb & quick actions
                    Container(
                      color: context.palette.surface,
                      padding: EdgeInsets.symmetric(
                        horizontal: gutter,
                        vertical: AppSpace.xs,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              size: 20,
                            ),
                            tooltip: 'Back to playlists',
                            visualDensity: VisualDensity.compact,
                            color: context.palette.secondaryText,
                            onPressed: () => _selectPlaylist(null),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: () => _selectPlaylist(null),
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: Text(
                                'Playlists',
                                style: context.palette.rowSecondary.copyWith(
                                  fontSize: AppType.small,
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text('›', style: context.palette.metadata),
                          ),
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
                            visualDensity: VisualDensity.compact,
                            color: context.palette.secondaryText,
                            onPressed: () => _renamePlaylist(pl),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                            tooltip: 'Delete playlist',
                            visualDensity: VisualDensity.compact,
                            color: context.palette.secondaryText,
                            hoverColor: context.palette.danger.withValues(
                              alpha: 0.12,
                            ),
                            onPressed: () => _deletePlaylist(pl),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: context.palette.border),
                    // Unified scroll area: Hero + Column Header + Track List
                    Expanded(
                      child: CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              gutter,
                              compact ? AppSpace.md : AppSpace.lg,
                              gutter,
                              AppSpace.md,
                            ),
                            sliver: SliverToBoxAdapter(
                              child: _buildPlaylistHeroCard(
                                pl: pl,
                                entries: entries,
                                totalDuration: totalDuration,
                                hasPlayable: hasPlayable,
                                isVideoCover: isVideoCover,
                                compact: compact,
                                accent: accent,
                              ),
                            ),
                          ),
                          if (isInitialLoading)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    accent,
                                  ),
                                ),
                              ),
                            )
                          else if (entries.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: EmptyState(
                                icon: Icons.queue_music_rounded,
                                title: 'This playlist is empty',
                                message:
                                    'Add audio or video files from your computer or library, or drop files here.',
                                actionLabel: 'Add files',
                                onAction: () => _pickAndAddFiles(pl),
                              ),
                            )
                          else ...[
                            // Column header
                            SliverPadding(
                              padding: EdgeInsets.fromLTRB(
                                gutter,
                                AppSpace.xs,
                                gutter,
                                0,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: compact ? 8 : 12,
                                        vertical: AppSpace.xs,
                                      ),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                            width:
                                                (compact ? 18 : 22) +
                                                (compact ? 4 : 6) +
                                                26 +
                                                (compact ? 8 : 10) +
                                                thumbWidth +
                                                (compact ? 10 : 12),
                                            child: Padding(
                                              padding: EdgeInsets.only(
                                                left:
                                                    (compact ? 18 : 22) +
                                                    (compact ? 4 : 6),
                                              ),
                                              child: SizedBox(
                                                width: 26,
                                                child: Text(
                                                  '#',
                                                  style:
                                                      context.palette.metadata,
                                                  textAlign: TextAlign.center,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Text(
                                              'Title',
                                              style: context.palette.metadata,
                                            ),
                                          ),
                                          if (!narrow)
                                            SizedBox(
                                              width: 56,
                                              child: Text(
                                                'Duration',
                                                style: context.palette.metadata,
                                                textAlign: TextAlign.right,
                                              ),
                                            ),
                                          const SizedBox(width: 36),
                                        ],
                                      ),
                                    ),
                                    Divider(
                                      height: 1,
                                      color: context.palette.border,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Reorderable tracks list
                            SliverPadding(
                              padding: EdgeInsets.fromLTRB(
                                gutter,
                                AppSpace.xs,
                                gutter,
                                AppSpace.xl,
                              ),
                              sliver: SliverReorderableList(
                                itemCount: entries.length,
                                onReorderItem: (oldIndex, targetIndex) =>
                                    _reorderEntries(
                                      pl,
                                      oldIndex,
                                      targetIndex > oldIndex
                                          ? targetIndex + 1
                                          : targetIndex,
                                    ),
                                proxyDecorator: (child, index, animation) {
                                  return Material(
                                    color: Colors.transparent,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: context.palette.raisedSurface,
                                        borderRadius: BorderRadius.circular(
                                          AppRadii.control,
                                        ),
                                        border: Border.all(
                                          color: accent.withValues(alpha: 0.6),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.35,
                                            ),
                                            blurRadius: 16,
                                            offset: const Offset(0, 6),
                                          ),
                                        ],
                                      ),
                                      child: child,
                                    ),
                                  );
                                },
                                itemBuilder: (context, index) {
                                  final entry = entries[index];
                                  final item = entry.mediaItem;
                                  final isCurrent =
                                      item != null &&
                                      _currentPlayingPath != null &&
                                      _currentPlayingPath == item.path;
                                  return _PlaylistTrackRow(
                                    key: ValueKey(entry.id),
                                    index: index,
                                    entry: entry,
                                    isCurrent: isCurrent,
                                    compact: compact,
                                    narrow: narrow,
                                    thumbWidth: thumbWidth,
                                    thumbHeight: thumbHeight,
                                    selectedEntryId: _selectedEntryId,
                                    controller: widget.controller,
                                    repository: widget.repository,
                                    onSelect: () {
                                      if (_selectedEntryId.value != entry.id) {
                                        _selectedEntryId.value = entry.id;
                                      }
                                    },
                                    onPlay: item?.isAvailable == true
                                        ? () {
                                            if (_selectedEntryId.value !=
                                                entry.id) {
                                              _selectedEntryId.value = entry.id;
                                            }
                                            _playPlaylist(
                                              entries,
                                              startIndex: index,
                                            );
                                          }
                                        : null,
                                    onRemove: () => _removeEntry(pl, entry),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (_isDragging)
                  Positioned.fill(
                    child: Container(
                      color: context.palette.background.withValues(alpha: 0.88),
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.xl,
                          vertical: AppSpace.lg,
                        ),
                        decoration: BoxDecoration(
                          color: context.palette.surface,
                          borderRadius: BorderRadius.circular(AppRadii.card),
                          border: Border.all(color: accent, width: 1.5),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.file_download_rounded,
                              size: 44,
                              color: accent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Drop files to add to playlist',
                              style: context.palette.albumTitle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildPlaylistHeroCard({
    required PlaylistRecord pl,
    required List<PlaylistEntryRecord> entries,
    required Duration totalDuration,
    required bool hasPlayable,
    required bool isVideoCover,
    required bool compact,
    required Color accent,
  }) {
    final coverWidth = compact
        ? (isVideoCover ? 124.0 : 84.0)
        : (isVideoCover ? 192.0 : 124.0);
    final coverHeight = compact
        ? (isVideoCover ? 70.0 : 84.0)
        : (isVideoCover ? 108.0 : 124.0);

    final coverWidget = _PlaylistHeroCover(
      entries: entries,
      width: coverWidth,
      height: coverHeight,
      repository: widget.repository,
      controller: widget.controller,
      onPlay: hasPlayable ? () => _playPlaylist(entries) : null,
    );

    final countLabel =
        '${entries.length} ${entries.length == 1 ? 'item' : 'items'}';
    final durationLabel = totalDuration > Duration.zero
        ? ' • ${formatDuration(totalDuration)}'
        : '';

    final titleAndMeta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          pl.title,
          style: compact
              ? context.palette.pageTitle.copyWith(fontSize: 22)
              : context.palette.pageTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          '$countLabel$durationLabel',
          style: context.palette.rowSecondary.copyWith(
            fontSize: AppType.small,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );

    final actionButtons = Wrap(
      spacing: AppSpace.xs,
      runSpacing: AppSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: context.palette.accentForeground,
            padding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: AppSpace.sm,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: hasPlayable ? () => _playPlaylist(entries) : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          label: const Text(
            'Play playlist',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: context.palette.primaryText,
            side: BorderSide(color: context.palette.border),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: hasPlayable
              ? () => _playPlaylist(entries, shuffle: true)
              : null,
          icon: const Icon(Icons.shuffle_rounded, size: 18),
          label: const Text('Shuffle'),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: context.palette.primaryText,
            side: BorderSide(color: context.palette.border),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: () => _pickAndAddFiles(pl),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add files'),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: context.palette.primaryText,
            side: BorderSide(color: context.palette.border),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: () => _showAddFromLibrary(pl),
          icon: const Icon(Icons.library_music_outlined, size: 18),
          label: const Text('From library'),
        ),
        PopupMenuButton<String>(
          tooltip: 'More actions',
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
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
                style: TextStyle(color: context.palette.danger),
              ),
            ),
          ],
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.all(compact ? AppSpace.md : AppSpace.lg),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: context.palette.border),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    coverWidget,
                    const SizedBox(width: AppSpace.md),
                    Expanded(child: titleAndMeta),
                  ],
                ),
                const SizedBox(height: AppSpace.md),
                actionButtons,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                coverWidget,
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      titleAndMeta,
                      const SizedBox(height: AppSpace.md),
                      actionButtons,
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
