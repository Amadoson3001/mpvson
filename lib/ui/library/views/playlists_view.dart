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
import '../../core/components/app_dialog.dart';
import '../../core/components/hover_builder.dart';
import '../../core/components/media_tile.dart';
import '../../core/components/media_row.dart';
import '../../core/components/page_header.dart';
import '../widgets/library_artwork.dart';
import '../../core/components/empty_state.dart';
import '../widgets/media_context_menu.dart';
import '../widgets/playlist_create_dialog.dart';
import '../library_browse_constants.dart';
import '../library_reload_coordinator.dart';
import '../paged_media_loader.dart';

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
                final availableWidth = (constraints.maxWidth - 2 * gutter)
                    .clamp(0.0, double.infinity);
                final columns = ((availableWidth + 20) / 220).ceil().clamp(
                  1,
                  12,
                );
                final tileWidth =
                    (availableWidth - (columns - 1) * 20) / columns;
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
                      child: GridView.builder(
                        addAutomaticKeepAlives: false,
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          AppSpace.lg,
                          gutter,
                          AppSpace.xl,
                        ),
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
                                onReorder: (oldIndex, newIndex) =>
                                    _reorderEntries(pl, oldIndex, newIndex),
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
  final List<MediaItemRecord> _items = <MediaItemRecord>[];
  final ScrollController _scrollController = ScrollController();
  Set<String> _existingIds = <String>{};
  int _browseOffset = 0;
  int _browseEpoch = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  String _activeSearch = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadingMore || !_hasMore) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels <
        kLibraryBrowseScrollPrefetch) {
      unawaited(_loadMore());
    }
  }

  Future<void> _bootstrap() async {
    try {
      final currentEntries = await widget.repository.getPlaylistEntries(
        widget.playlist.id,
      );
      _existingIds = currentEntries.map((e) => e.mediaId).toSet();
      await _reload(reset: true);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reload({required bool reset}) async {
    final epoch = reset ? ++_browseEpoch : _browseEpoch;
    if (reset) {
      if (mounted) {
        setState(() {
          _loading = true;
          _loadingMore = false;
          _browseOffset = 0;
          _hasMore = true;
          _items.clear();
        });
      }
    }
    try {
      final batch = await fetchMediaPage(
        widget.repository,
        offset: _browseOffset,
        searchQuery: _activeSearch.isEmpty ? null : _activeSearch,
        sortBy: 'title',
      );
      if (!mounted || epoch != _browseEpoch) return;
      final page = batch.items
          .where((item) => !_existingIds.contains(item.id))
          .toList();
      setState(() {
        _items.addAll(page);
        _browseOffset += batch.items.length;
        _hasMore = batch.hasMore;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted && epoch == _browseEpoch) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    await _reload(reset: false);
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(kLibrarySearchDebounce, () {
      if (!mounted) return;
      final trimmed = value.trim();
      if (trimmed == _activeSearch) return;
      _activeSearch = trimmed;
      unawaited(_reload(reset: true));
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = (screenSize.width - 64).clamp(260.0, 500.0);
    final dialogHeight = (screenSize.height - 220).clamp(240.0, 420.0);
    return AppDialog(
      maxWidth: 540,
      title: const Text('Add from library'),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search tracks...',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                isDense: true,
              ),
              onChanged: _onSearchChanged,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _items.isEmpty
                  ? Center(
                      child: Text(
                        _activeSearch.isNotEmpty
                            ? 'No matching tracks found.'
                            : 'All library tracks are already in this playlist.',
                        style: context.palette.metadata,
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _items.length + (_loadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= _items.length) {
                          return const Padding(
                            padding: EdgeInsets.all(AppSpace.md),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        final item = _items[index];
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
    required this.width,
    required this.height,
    required this.repository,
    required this.controller,
    this.onPlay,
  });

  final List<PlaylistEntryRecord> entries;
  final double width;
  final double height;
  final MediaLibraryRepository repository;
  final PlayerController controller;
  final VoidCallback? onPlay;

  @override
  State<_PlaylistHeroCover> createState() => _PlaylistHeroCoverState();
}

class _PlaylistHeroCoverState extends State<_PlaylistHeroCover> {
  ThumbnailRequestHandle? _request;
  MediaThumbnail? _videoThumb;
  bool _hovered = false;

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
    final item = widget.entries.firstOrNull?.mediaItem;
    final isVideo =
        item != null &&
        (item.kind == MediaKind.video ||
            MediaCatalog.kindFromExtension(item.path) == MediaKind.video);
    final iconSize = widget.height < 90 ? 36.0 : 48.0;

    Widget artwork;
    if (widget.entries.isEmpty) {
      artwork = Container(
        color: context.palette.raisedSurface,
        child: Center(
          child: Icon(
            Icons.queue_music_rounded,
            size: iconSize,
            color: context.palette.mutedText,
          ),
        ),
      );
    } else if (isVideo) {
      final bytes = _videoThumb?.bytes;
      final fallback = Container(
        color: context.palette.raisedSurface,
        child: Center(
          child: Icon(
            Icons.movie_creation_outlined,
            size: iconSize,
            color: context.palette.mutedText,
          ),
        ),
      );
      artwork = (bytes != null && bytes.isNotEmpty)
          ? RepaintBoundary(
              child: Image.memory(
                bytes,
                width: widget.width,
                height: widget.height,
                cacheWidth: (widget.width * 2).round(),
                cacheHeight: (widget.height * 2).round(),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback,
              ),
            )
          : fallback;
    } else {
      artwork = LibraryArtwork(
        path: item?.metadata.artworkUri,
        mediaPath: item?.path,
        repository: widget.repository,
        icon: Icons.queue_music_rounded,
        iconSize: iconSize,
      );
    }

    final accent = Theme.of(context).colorScheme.primary;
    final lowPower = AppMotion.lowPower(context);
    final canPlay = widget.onPlay != null;

    return MouseRegion(
      cursor: canPlay ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: canPlay ? (_) => setState(() => _hovered = true) : null,
      onExit: canPlay ? (_) => setState(() => _hovered = false) : null,
      child: GestureDetector(
        onTap: widget.onPlay,
        child: Container(
          width: widget.width,
          height: widget.height,
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.artwork),
            border: Border.all(
              color: context.palette.borderStrong.withValues(alpha: 0.65),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.artwork),
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedScale(
                  scale: (!lowPower && _hovered && canPlay) ? 1.03 : 1.0,
                  duration: AppMotion.duration(context, AppMotion.hover),
                  curve: AppMotion.enter,
                  child: artwork,
                ),
                if (canPlay && _hovered)
                  ColoredBox(
                    color: Colors.black.withValues(alpha: 0.36),
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: accent,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistTrackRow extends StatefulWidget {
  const _PlaylistTrackRow({
    super.key,
    required this.index,
    required this.entry,
    required this.isCurrent,
    required this.compact,
    required this.narrow,
    required this.thumbWidth,
    required this.thumbHeight,
    required this.selectedEntryId,
    required this.controller,
    required this.repository,
    required this.onSelect,
    required this.onPlay,
    required this.onRemove,
  });

  final int index;
  final PlaylistEntryRecord entry;
  final bool isCurrent;
  final bool compact;
  final bool narrow;
  final double thumbWidth;
  final double thumbHeight;
  final ValueListenable<String?> selectedEntryId;
  final PlayerController controller;
  final MediaLibraryRepository repository;
  final VoidCallback onSelect;
  final VoidCallback? onPlay;
  final VoidCallback onRemove;

  @override
  State<_PlaylistTrackRow> createState() => _PlaylistTrackRowState();
}

class _PlaylistTrackRowState extends State<_PlaylistTrackRow> {
  Duration _discoveredDuration = Duration.zero;

  @override
  void didUpdateWidget(_PlaylistTrackRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.mediaItem?.path != widget.entry.mediaItem?.path) {
      _discoveredDuration = Duration.zero;
    }
  }

  Future<void> _showInFolder(String path) async {
    final ok = await showInFolder(path);
    if (!ok && mounted) {
      AppToast.show(
        context,
        'Could not open File Explorer',
        tone: AppToastTone.danger,
      );
    }
  }

  Future<void> _showContextMenu(
    BuildContext rowContext,
    Offset globalPosition, {
    required bool isSelected,
  }) async {
    final item = widget.entry.mediaItem;
    if (item == null) return;
    widget.onSelect();
    await showMediaContextMenu(
      context: rowContext,
      globalPosition: globalPosition,
      target: MediaContextMenuTarget.fromRecord(item),
      repository: widget.repository,
      controller: widget.controller,
      onPlay: widget.onPlay,
      onRemove: widget.onRemove,
      isSelected: isSelected,
      onSelect: widget.onSelect,
      onShowInFolder: (path) => unawaited(_showInFolder(path)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final entry = widget.entry;
    final item = entry.mediaItem;
    final isAvailable = item?.isAvailable ?? false;
    final (displayTitle, displaySubtitle) = _resolveDisplayTitleAndSubtitle(
      item,
    );
    final rawDuration = item?.metadata.duration ?? Duration.zero;
    final effectiveDuration = rawDuration > Duration.zero
        ? rawDuration
        : _discoveredDuration;
    final subtitleText = item != null && !item.isAvailable
        ? (displaySubtitle.isNotEmpty
              ? '$displaySubtitle • Missing'
              : 'Missing')
        : displaySubtitle;

    return RepaintBoundary(
      child: HoverListenable(
        builder: (context, hoveredListenable) => MediaRow(
          onSelect: widget.onSelect,
          onPlay: widget.onPlay,
          builder: (context, rowFocus, handleTap) =>
              ValueListenableBuilder<String?>(
                valueListenable: widget.selectedEntryId,
                builder: (context, selectedId, _) {
                  final isSelected = selectedId == entry.id;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                      child: InkWell(
                        canRequestFocus: false,
                        onTap: handleTap,
                        onSecondaryTapDown: item != null
                            ? (details) => unawaited(
                                _showContextMenu(
                                  context,
                                  details.globalPosition,
                                  isSelected: isSelected,
                                ),
                              )
                            : null,
                        borderRadius: BorderRadius.circular(AppRadii.control),
                        hoverColor: context.palette.hover,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: widget.compact ? 8 : 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? context.palette.hover
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                            border: isSelected
                                ? Border.all(
                                    color: accent.withValues(alpha: 0.45),
                                  )
                                : null,
                          ),
                          child: ValueListenableBuilder<bool>(
                            valueListenable: hoveredListenable,
                            builder: (context, isHovered, _) {
                              final showActionAccent =
                                  isHovered || isSelected || widget.compact;
                              final showPlayThumb =
                                  isAvailable &&
                                  widget.onPlay != null &&
                                  (isHovered ||
                                      isSelected ||
                                      rowFocus.hasFocus);
                              return Row(
                                children: [
                                  ReorderableDragStartListener(
                                    index: widget.index,
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.grab,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 6,
                                        ),
                                        child: Icon(
                                          Icons.drag_indicator_rounded,
                                          size: widget.compact ? 18 : 20,
                                          color: showActionAccent
                                              ? context.palette.secondaryText
                                              : context.palette.mutedText
                                                    .withValues(alpha: 0.55),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: widget.compact ? 4 : 6),
                                  SizedBox(
                                    width: 26,
                                    child: widget.isCurrent
                                        ? Icon(
                                            Icons.graphic_eq_rounded,
                                            size: 16,
                                            color: accent,
                                          )
                                        : Text(
                                            '${widget.index + 1}',
                                            style: context.palette.metadata
                                                .copyWith(
                                                  fontFeatures: const [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                  color: isSelected
                                                      ? context
                                                            .palette
                                                            .primaryText
                                                      : context
                                                            .palette
                                                            .mutedText,
                                                ),
                                            textAlign: TextAlign.center,
                                          ),
                                  ),
                                  SizedBox(width: widget.compact ? 8 : 10),
                                  _PlaylistTrackThumbnail(
                                    item: item,
                                    width: widget.thumbWidth,
                                    height: widget.thumbHeight,
                                    controller: widget.controller,
                                    repository: widget.repository,
                                    showPlayOverlay: showPlayThumb,
                                    onPlay: widget.onPlay,
                                    onDurationDiscovered: (discovered) {
                                      if (mounted &&
                                          rawDuration == Duration.zero &&
                                          _discoveredDuration != discovered) {
                                        setState(
                                          () =>
                                              _discoveredDuration = discovered,
                                        );
                                      }
                                    },
                                  ),
                                  SizedBox(width: widget.compact ? 10 : 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          displayTitle,
                                          style: context.palette.rowPrimary
                                              .copyWith(
                                                color: !isAvailable
                                                    ? context.palette.mutedText
                                                    : widget.isCurrent
                                                    ? accent
                                                    : context
                                                          .palette
                                                          .primaryText,
                                                fontWeight: widget.isCurrent
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (subtitleText.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            subtitleText,
                                            style: context.palette.rowSecondary,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (!widget.narrow) ...[
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 56,
                                      child: Text(
                                        formatDuration(effectiveDuration),
                                        style: context.palette.metadata
                                            .copyWith(
                                              fontFeatures: const [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                        textAlign: TextAlign.right,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 4),
                                  SizedBox(
                                    width: 32,
                                    height: 32,
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 16,
                                      ),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      tooltip: 'Remove from playlist',
                                      color: showActionAccent
                                          ? context.palette.secondaryText
                                          : context.palette.mutedText
                                                .withValues(alpha: 0.5),
                                      visualDensity: VisualDensity.compact,
                                      onPressed: widget.onRemove,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
        ),
      ),
    );
  }
}

class _PlaylistTrackThumbnail extends StatefulWidget {
  const _PlaylistTrackThumbnail({
    required this.item,
    required this.width,
    required this.height,
    required this.controller,
    required this.repository,
    this.showPlayOverlay = false,
    this.onPlay,
    this.onDurationDiscovered,
  });

  final MediaItemRecord? item;
  final double width;
  final double height;
  final PlayerController controller;
  final MediaLibraryRepository repository;
  final bool showPlayOverlay;
  final VoidCallback? onPlay;
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
    final accent = Theme.of(context).colorScheme.primary;
    final radius = BorderRadius.circular(AppRadii.control - 2);

    Widget fallback() => Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: context.palette.raisedSurface,
        borderRadius: radius,
      ),
      child: Center(
        child: Icon(
          isVideo ? Icons.movie_outlined : Icons.music_note_rounded,
          size: 16,
          color: context.palette.mutedText,
        ),
      ),
    );

    Widget content;
    if (item == null) {
      content = fallback();
    } else if (isVideo) {
      final bytes = _cachedThumbnail?.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        content = Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          cacheWidth: (widget.width * 2).round(),
          cacheHeight: (widget.height * 2).round(),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => fallback(),
        );
      } else {
        content = fallback();
      }
    } else {
      content = ColoredBox(
        color: context.palette.raisedSurface,
        child: Center(
          child: SizedBox(
            width: widget.height,
            height: widget.height,
            child: LibraryArtwork(
              path: item.metadata.artworkUri,
              mediaPath: item.path,
              repository: widget.repository,
              icon: Icons.music_note_rounded,
              iconSize: 16,
            ),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              content,
              if (widget.showPlayOverlay && widget.onPlay != null)
                Material(
                  color: Colors.black.withValues(alpha: 0.52),
                  child: InkWell(
                    onTap: widget.onPlay,
                    child: Center(
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 20,
                        color: accent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
