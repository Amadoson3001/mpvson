import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../data/services/diagnostic_log.dart';
import '../../../utils/file_utils.dart';
import '../../../utils/format.dart';
import '../../player/player_controller.dart';
import '../../core/app_theme.dart';
import '../../core/components/animated_grid_reflow.dart';
import '../../core/components/app_dialog.dart';
import '../../core/components/media_tile.dart';
import '../../core/components/media_row.dart';
import '../../core/components/media_accent_scope.dart';
import '../../core/components/empty_state.dart';
import '../../core/components/hover_builder.dart';
import '../../core/components/playback_pulse.dart';
import '../../core/toast/app_toast.dart';
import '../library_browse_constants.dart';
import '../library_reload_coordinator.dart';
import '../media_pager.dart';
import '../paged_media_loader.dart';
import '../widgets/library_artwork.dart';
import '../widgets/library_item_action_menu.dart';
import '../widgets/media_context_menu.dart';
import '../widgets/library_item_actions.dart';

const int _kGridNamePageSize = 60;

/// Subtabs within the Music library view.
enum MusicSubtab {
  songs,
  albums,
  artists,
  favorites,
  recentlyAdded,
  recentlyPlayed,
}

/// Comprehensive Music View with subtabs for Songs, Albums, Artists,
/// Favorites, Recently Added, and Recently Played.
class MusicView extends StatefulWidget {
  const MusicView({
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
  State<MusicView> createState() => _MusicViewState();
}

class _MusicViewState extends State<MusicView> {
  MusicSubtab _subtab = MusicSubtab.songs;

  final ValueNotifier<String?> _selectedSongPath = ValueNotifier<String?>(null);
  String? _selectedAlbum;
  String? _selectedAlbumArtist;
  String? _selectedArtist;
  final ScrollController _scrollController = ScrollController();
  late final MediaPager _pager;
  List<MediaCollectionSummary>? _albumSummaries;
  List<MediaCollectionSummary>? _artistSummaries;
  int _albumGridVisible = _kGridNamePageSize;
  int _artistGridVisible = _kGridNamePageSize;
  final Map<String, MediaItemRecord?> _albumPreviewCache = {};
  List<MediaItemRecord>? _albumTracks;
  List<MediaItemRecord>? _artistSongs;
  Object? _error;
  late final LibraryReloadCoordinator _reloadCoordinator;
  String? _currentRowPath;
  bool _currentRowPlaying = false;

  /// Identity of the query the visible song rows came from.
  ///
  /// A repository notification re-runs the same query, which refreshes in
  /// place. A change to the search text or the subtab is a new query, which
  /// shows the initial-loading state.
  ({MediaLibraryRepository repository, String? search, MusicSubtab subtab})?
  _loadedSongsQuery;

  /// Reload epoch the pager may publish results for.
  ///
  /// [LibraryReloadCoordinator] advances its epoch as soon as it queues a newer
  /// reload, which can be before the pager has finished the one in flight.
  int _activeReloadEpoch = 0;
  late Listenable _playbackListenable;

  Listenable _playbackSignals(PlayerController controller) =>
      Listenable.merge(<Listenable>[
        controller.structureListenable,
        controller.transportListenable,
      ]);

  @override
  void initState() {
    super.initState();
    _pager = MediaPager(
      fetch: (offset) => _fetchMediaPageForSubtab(offset: offset),
      onChanged: () {
        if (mounted) setState(() {});
      },
      onError: (error) => diagnosticDebug('music.page', error: error),
      // The coordinator's epoch moves as soon as it queues a newer reload, so
      // a superseded request has to be discarded where the pager commits,
      // before it can publish rows for a query the view has left behind.
      isCurrent: () =>
          mounted && _activeReloadEpoch == _reloadCoordinator.epoch,
    );
    _reloadCoordinator = LibraryReloadCoordinator(
      onReload: _runReload,
      onError: (error) {
        diagnosticDebug('music.refresh', error: error);
        if (mounted) setState(() => _error = error);
      },
      onLoadingChanged: (loading) {
        if (mounted && _shouldShowLoader()) setState(() {});
      },
      isDisposed: () => !mounted,
    );
    widget.repository.addListener(_onRepoChanged);
    _playbackListenable = _playbackSignals(widget.controller);
    _playbackListenable.addListener(_onPlaybackChanged);
    _currentRowPath = widget.controller.current?.path;
    _currentRowPlaying = widget.controller.isPlaying;
    _scrollController.addListener(_onBrowseScroll);
    _reload();
  }

  @override
  void didUpdateWidget(MusicView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.removeListener(_onRepoChanged);
      widget.repository.addListener(_onRepoChanged);
      _reload();
    } else if (oldWidget.searchQuery != widget.searchQuery) {
      if (widget.searchQuery?.trim().isNotEmpty ?? false) {
        _selectedAlbum = null;
        _selectedAlbumArtist = null;
        _selectedArtist = null;
        _albumTracks = null;
        _artistSongs = null;
      }
      // The shell already debounces typing; apply the committed query now.
      _reload();
    }
    if (oldWidget.controller != widget.controller) {
      _playbackListenable.removeListener(_onPlaybackChanged);
      _playbackListenable = _playbackSignals(widget.controller);
      _playbackListenable.addListener(_onPlaybackChanged);
    }
  }

  @override
  void dispose() {
    _selectedSongPath.dispose();
    _scrollController.removeListener(_onBrowseScroll);
    _scrollController.dispose();
    _reloadCoordinator.dispose();
    widget.repository.removeListener(_onRepoChanged);
    _playbackListenable.removeListener(_onPlaybackChanged);
    super.dispose();
  }

  void _onPlaybackChanged() {
    final path = widget.controller.current?.path;
    final playing = widget.controller.isPlaying;
    if (path == _currentRowPath && playing == _currentRowPlaying) return;
    _currentRowPath = path;
    _currentRowPlaying = playing;
    if (mounted) setState(() {});
  }

  void _onRepoChanged() {
    _reloadCoordinator.onRepositoryChanged(
      isScanning: widget.repository.scanStatus.isScanning,
    );
  }

  Future<void> _reload() => _reloadCoordinator.reload();

  bool _shouldShowLoader() =>
      _pager.items.isEmpty &&
      _albumSummaries == null &&
      _artistSummaries == null &&
      _albumTracks == null &&
      _artistSongs == null;

  void _patchFavoriteInLoadedLists(String mediaId, bool isFavorite) {
    MediaItemRecord patch(MediaItemRecord item) =>
        item.id == mediaId ? item.copyWith(isFavorite: isFavorite) : item;
    _pager.patchItems(patch);
    _patchDetailTracks(patch);
  }

  void _removeSongFromLoadedLists(String mediaId) {
    _pager.removeWhere((item) => item.id == mediaId);
    final albumTracks = _albumTracks;
    if (albumTracks != null) {
      _albumTracks = albumTracks.where((item) => item.id != mediaId).toList();
    }
    final artistSongs = _artistSongs;
    if (artistSongs != null) {
      _artistSongs = artistSongs.where((item) => item.id != mediaId).toList();
    }
  }

  /// Applies [patch] to the album and artist detail lists, which are rendered
  /// instead of the paged list while a detail view is open.
  void _patchDetailTracks(MediaItemRecord Function(MediaItemRecord) patch) {
    final albumTracks = _albumTracks;
    if (albumTracks != null) {
      _albumTracks = albumTracks.map(patch).toList();
    }
    final artistSongs = _artistSongs;
    if (artistSongs != null) {
      _artistSongs = artistSongs.map(patch).toList();
    }
  }

  Future<void> _runReload(int epoch) async {
    _activeReloadEpoch = epoch;
    final album = _selectedAlbum;
    final albumArtist = _selectedAlbumArtist;
    final artist = _selectedArtist;
    final List<MediaItemRecord> items;
    if (album != null) {
      final matching = await widget.repository.queryMedia(
        kind: MediaKind.audio,
        album: album,
        sortBy: 'trackNumber',
      );
      items = albumArtist == null
          ? matching
          : matching
                .where(
                  (item) =>
                      item.metadata.effectiveAlbumArtist.toLowerCase() ==
                      albumArtist.toLowerCase(),
                )
                .toList();
    } else if (artist != null) {
      items = await widget.repository.queryMedia(
        kind: MediaKind.audio,
        artist: artist,
        sortBy: 'title',
      );
    } else {
      switch (_subtab) {
        case MusicSubtab.albums:
          _pager.clear();
          final summaries = await widget.repository.getAlbumSummaries();
          if (!mounted || epoch != _reloadCoordinator.epoch) return;
          setState(() {
            _error = null;
            _albumSummaries = summaries;
            _artistSummaries = null;
            _albumGridVisible = _kGridNamePageSize;
          });
          return;
        case MusicSubtab.artists:
          _pager.clear();
          final summaries = await widget.repository.getArtistSummaries(
            kind: MediaKind.audio,
          );
          if (!mounted || epoch != _reloadCoordinator.epoch) return;
          setState(() {
            _error = null;
            _artistSummaries = summaries;
            _albumSummaries = null;
            _artistGridVisible = _kGridNamePageSize;
          });
          return;
        case MusicSubtab.songs:
        case MusicSubtab.favorites:
        case MusicSubtab.recentlyAdded:
        case MusicSubtab.recentlyPlayed:
          await _loadSongsPage(epoch);
          return;
      }
    }
    if (!mounted || epoch != _reloadCoordinator.epoch) return;
    setState(() {
      _error = null;
      if (album != null) {
        _albumTracks = items;
      } else if (artist != null) {
        _artistSongs = items;
      }
    });
  }

  /// Loads the paged song list, refreshing in place when the query is the one
  /// the visible rows came from.
  Future<void> _loadSongsPage(int epoch) async {
    final query = _songsQuery;
    final refresh = query == _loadedSongsQuery && _pager.hasLoaded;
    _loadedSongsQuery = query;
    if (refresh) {
      await _pager.refresh();
    } else {
      await _pager.loadFirst();
    }
    if (!mounted || epoch != _reloadCoordinator.epoch) return;
    setState(() {
      _error = null;
      _albumSummaries = null;
      _artistSummaries = null;
    });
  }

  ({MediaLibraryRepository repository, String? search, MusicSubtab subtab})
  get _songsQuery => (
    repository: widget.repository,
    search: widget.searchQuery,
    subtab: _subtab,
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

  Future<void> _confirmAndRemoveSong(MediaItemRecord song) async {
    if (!mounted || Navigator.maybeOf(context, rootNavigator: true) == null) {
      return;
    }
    final confirmed =
        await AppDialog.show<bool>(
          context: context,
          builder: (dialogContext) => AppDialog(
            maxWidth: 420,
            title: const Text('Remove from library?'),
            content: Text(
              '"${song.title}" will be removed from your Music library index. The file on disk will not be deleted.',
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
    await widget.repository.deleteMedia(song.id);
    if (!mounted) return;
    // The pager notifies the view, so this must not also be wrapped in
    // setState; the selection notifier rebuilds only the row it belongs to.
    _removeSongFromLoadedLists(song.id);
    if (_selectedSongPath.value == song.path) {
      _selectedSongPath.value = null;
    }
    AppToast.show(context, 'Removed "${song.title}" from library');
  }

  Future<void> _showSongContextMenu(
    List<MediaItemRecord> collection,
    MediaItemRecord song,
    int index,
    Offset globalPosition,
  ) async {
    if (_selectedSongPath.value != song.path) {
      _selectedSongPath.value = song.path;
    }
    await showMediaContextMenu(
      context: context,
      globalPosition: globalPosition,
      target: LibraryItemTarget.fromRecord(song),
      repository: widget.repository,
      controller: widget.controller,
      onPlay: song.isAvailable
          ? () => _playSongCollection(collection, index)
          : null,
      onRemove: () => unawaited(_confirmAndRemoveSong(song)),
      isSelected: _selectedSongPath.value == song.path,
      onSelect: () {
        _selectedSongPath.value = _selectedSongPath.value == song.path
            ? null
            : song.path;
      },
      onShowInFolder: (path) => unawaited(_showInFolder(path)),
    );
  }

  Future<void> _playSongCollection(
    List<MediaItemRecord> songs,
    int initialIndex,
  ) async {
    if (initialIndex < 0 ||
        initialIndex >= songs.length ||
        !songs[initialIndex].isAvailable) {
      return;
    }
    final paths = songs.where((s) => s.isAvailable).map((s) => s.path).toList();
    if (paths.isEmpty) return;
    await widget.controller.openPaths(
      paths,
      append: false,
      initialIndex: songs.take(initialIndex).where((s) => s.isAvailable).length,
    );
  }

  Future<void> _playAlbum(
    List<MediaItemRecord> albumTracks, {
    bool shuffle = false,
  }) async {
    final sorted = List<MediaItemRecord>.from(albumTracks)
      ..sort((a, b) {
        final discCompare = (a.metadata.discNumber ?? 1).compareTo(
          b.metadata.discNumber ?? 1,
        );
        if (discCompare != 0) return discCompare;
        return (a.metadata.trackNumber ?? 0).compareTo(
          b.metadata.trackNumber ?? 0,
        );
      });

    final paths = sorted
        .where((s) => s.isAvailable)
        .map((s) => s.path)
        .toList();
    if (paths.isEmpty) return;

    if (shuffle) {
      paths.shuffle();
    }
    await widget.controller.openPaths(paths, append: false, initialIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    // If drilling down into an album or artist, show detail view
    if (_selectedAlbum != null) {
      return _detailAccent(
        _buildAlbumDetailView(_selectedAlbum!),
        _albumTracks,
      );
    }
    if (_selectedArtist != null) {
      return _detailAccent(
        _buildArtistDetailView(_selectedArtist!),
        _artistSongs,
      );
    }

    final subtab = _subtab;
    final isSongSubtab =
        subtab == MusicSubtab.songs ||
        subtab == MusicSubtab.favorites ||
        subtab == MusicSubtab.recentlyAdded ||
        subtab == MusicSubtab.recentlyPlayed;
    final isGridSubtab =
        subtab == MusicSubtab.albums || subtab == MusicSubtab.artists;
    final items = _pager.items;
    final gridEmpty = switch (subtab) {
      MusicSubtab.albums => (_albumSummaries ?? const []).isEmpty,
      MusicSubtab.artists => (_artistSummaries ?? const []).isEmpty,
      _ => false,
    };
    final isLoading = _reloadCoordinator.isLoading;
    final gridNamesLoading =
        isGridSubtab &&
        isLoading &&
        _albumSummaries == null &&
        _artistSummaries == null;
    final showInitialLoader =
        isLoading && ((isSongSubtab && items.isEmpty) || gridNamesLoading);

    return Material(
      color: context.palette.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Subtab Navigation Bar
          _buildSubtabHeader(),
          Divider(height: 1, color: context.palette.border),
          // Content stage
          Expanded(
            child: showInitialLoader
                ? Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  )
                : _error != null && (isSongSubtab ? items.isEmpty : gridEmpty)
                ? _buildLoadErrorState()
                : (isSongSubtab ? items.isEmpty : gridEmpty)
                ? _buildEmptyStateForSubtab()
                : switch (subtab) {
                    MusicSubtab.songs ||
                    MusicSubtab.favorites ||
                    MusicSubtab.recentlyAdded ||
                    MusicSubtab.recentlyPlayed => _buildSongTableView(
                      items,
                      enablePaging: true,
                    ),
                    MusicSubtab.albums => _buildAlbumsGridView(),
                    MusicSubtab.artists => _buildArtistsGridView(),
                  },
          ),
        ],
      ),
    );
  }

  void _changeSubtab(MusicSubtab tab) {
    if (_subtab == tab) return;
    setState(() {
      _subtab = tab;
      _selectedAlbum = null;
      _selectedAlbumArtist = null;
      _selectedArtist = null;
      _albumSummaries = null;
      _artistSummaries = null;
      _albumGridVisible = _kGridNamePageSize;
      _artistGridVisible = _kGridNamePageSize;
    });
    _reload();
  }

  Widget _detailAccent(Widget child, List<MediaItemRecord>? items) {
    if (items == null || items.isEmpty) return child;
    return MediaAccentScope(
      controller: widget.controller,
      entryOverride: MediaEntry.fromPath(items.first.path, id: items.first.id),
      child: child,
    );
  }

  Widget _buildSubtabHeader() {
    final subtab = _subtab;
    final songsSelected =
        subtab != MusicSubtab.albums && subtab != MusicSubtab.artists;
    return Container(
      color: context.palette.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _SubtabPill(
                    label: 'Songs',
                    selected: subtab == MusicSubtab.songs,
                    onSelect: () => _changeSubtab(MusicSubtab.songs),
                  ),
                  _SubtabPill(
                    label: 'Albums',
                    selected: subtab == MusicSubtab.albums,
                    onSelect: () => _changeSubtab(MusicSubtab.albums),
                  ),
                  _SubtabPill(
                    label: 'Artists',
                    selected: subtab == MusicSubtab.artists,
                    onSelect: () => _changeSubtab(MusicSubtab.artists),
                  ),
                ],
              ),
            ),
          ),
          if (songsSelected)
            PopupMenuButton<MusicSubtab>(
              tooltip: 'Filter songs',
              onSelected: _changeSubtab,
              icon: Icon(
                Icons.filter_list_rounded,
                color: subtab == MusicSubtab.songs
                    ? context.palette.secondaryText
                    : Theme.of(context).colorScheme.primary,
              ),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: MusicSubtab.songs,
                  child: Text('All songs'),
                ),
                PopupMenuItem(
                  value: MusicSubtab.favorites,
                  child: Text('Favorites'),
                ),
                PopupMenuItem(
                  value: MusicSubtab.recentlyAdded,
                  child: Text('Recently added'),
                ),
                PopupMenuItem(
                  value: MusicSubtab.recentlyPlayed,
                  child: Text('Recently played'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<PagedMediaBatch> _fetchMediaPageForSubtab({required int offset}) {
    final query = widget.searchQuery;
    final repository = widget.repository;
    switch (_subtab) {
      case MusicSubtab.songs:
        return fetchMediaPage(
          repository,
          offset: offset,
          kind: MediaKind.audio,
          searchQuery: query,
          sortBy: 'title',
        );
      case MusicSubtab.albums:
      case MusicSubtab.artists:
        return Future.value(const PagedMediaBatch(items: [], hasMore: false));
      case MusicSubtab.favorites:
        return fetchMediaPage(
          repository,
          offset: offset,
          kind: MediaKind.audio,
          searchQuery: query,
          onlyFavorites: true,
          sortBy: 'title',
        );
      case MusicSubtab.recentlyAdded:
        return fetchMediaPage(
          repository,
          offset: offset,
          kind: MediaKind.audio,
          searchQuery: query,
          sortBy: 'addedAt',
          ascending: false,
        );
      case MusicSubtab.recentlyPlayed:
        return fetchMediaPage(
          repository,
          offset: offset,
          kind: MediaKind.audio,
          searchQuery: query,
          sortBy: 'lastPlayedAt',
          ascending: false,
        );
    }
  }

  void _onBrowseScroll() {
    if (!_scrollController.hasClients) return;
    // A reload owns the list while it runs; appending to it would mix queries.
    if (_reloadCoordinator.isLoading) return;
    if (_selectedAlbum != null || _selectedArtist != null) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels <
        kLibraryBrowseScrollPrefetch) {
      unawaited(_pager.loadMore());
    }
  }

  List<MediaCollectionSummary> _filteredAlbumSummaries() {
    final summaries = _albumSummaries ?? const <MediaCollectionSummary>[];
    final query = widget.searchQuery?.trim().toLowerCase();
    if (query == null || query.isEmpty) return summaries;
    return summaries
        .where((s) => s.name.toLowerCase().contains(query))
        .toList();
  }

  List<MediaCollectionSummary> _filteredArtistSummaries() {
    final summaries = _artistSummaries ?? const <MediaCollectionSummary>[];
    final query = widget.searchQuery?.trim().toLowerCase();
    if (query == null || query.isEmpty) return summaries;
    return summaries
        .where((s) => s.name.toLowerCase().contains(query))
        .toList();
  }

  bool _onGridScroll(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    final metrics = notification.metrics;
    if (metrics.maxScrollExtent - metrics.pixels <
        kLibraryBrowseScrollPrefetch) {
      _loadMoreGridNames();
    }
    return false;
  }

  void _loadMoreGridNames() {
    final subtab = _subtab;
    if (subtab == MusicSubtab.albums) {
      final total = _filteredAlbumSummaries().length;
      if (_albumGridVisible >= total) return;
      setState(() {
        _albumGridVisible = (_albumGridVisible + _kGridNamePageSize).clamp(
          0,
          total,
        );
      });
    } else if (subtab == MusicSubtab.artists) {
      final total = _filteredArtistSummaries().length;
      if (_artistGridVisible >= total) return;
      setState(() {
        _artistGridVisible = (_artistGridVisible + _kGridNamePageSize).clamp(
          0,
          total,
        );
      });
    }
  }

  Widget _buildLoadErrorState() => EmptyState(
    title: "Couldn't load music",
    message:
        'The library could not be queried. Try again, or check that the library database is available.',
    icon: Icons.error_outline_rounded,
    actionLabel: 'Try again',
    actionIcon: Icons.refresh_rounded,
    onAction: () => unawaited(_reload()),
  );

  Widget _buildEmptyStateForSubtab() {
    final query = widget.searchQuery?.trim();
    if (query != null && query.isNotEmpty) {
      return EmptyState(
        title: 'No music found',
        message: 'No songs matched "$query". Try a different search.',
        icon: Icons.search_off_rounded,
      );
    }
    switch (_subtab) {
      case MusicSubtab.favorites:
        return const EmptyState(
          title: 'No favorite songs yet',
          message:
              'Click the heart icon on any song or track to add it to your favorites.',
          icon: Icons.favorite_border_rounded,
        );
      case MusicSubtab.recentlyPlayed:
        return const EmptyState(
          title: 'No recently played music',
          message:
              'Songs you listen to will appear here in chronological order.',
          icon: Icons.history_rounded,
        );
      default:
        return EmptyState(
          title: 'No music found',
          message: widget.searchQuery != null && widget.searchQuery!.isNotEmpty
              ? 'No songs matched "${widget.searchQuery}". Try a different keyword.'
              : 'Add your music folder to index and listen to your songs.',
          actionLabel: 'Add folder',
          onAction: widget.onAddFolders,
        );
    }
  }

  Widget _buildSongTableView(
    List<MediaItemRecord> songs, {
    bool enablePaging = false,
  }) {
    final showFooter = enablePaging && _pager.isLoadingMore;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14.0).clamp(
      1.0,
      2.2,
    );
    final rowExtent = (66.0 * textScale).ceilToDouble();
    final dividerColor = context.palette.surface;
    final headerBorder = context.palette.border;

    return CustomScrollView(
      controller: _scrollController,
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
                _buildTableHeaderRow(),
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
            showFooter ? 0 : AppSpace.md,
          ),
          sliver: SliverFixedExtentList(
            itemExtent: rowExtent,
            delegate: SliverChildBuilderDelegate(
              (context, songIndex) {
                final song = songs[songIndex];
                return Column(
                  children: [
                    Expanded(child: _buildSongRow(songs, song, songIndex)),
                    Divider(height: 1, thickness: 1, color: dividerColor),
                  ],
                );
              },
              childCount: songs.length,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: true,
            ),
          ),
        ),
        if (showFooter)
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.md,
              AppSpace.lg,
              AppSpace.md,
            ),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTableHeaderRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text('#', style: context.palette.metadata),
          ),
          Expanded(
            flex: 4,
            child: Text('Title', style: context.palette.metadata),
          ),
          Expanded(
            flex: 3,
            child: Text('Album', style: context.palette.metadata),
          ),
          SizedBox(
            width: 70,
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

  Widget _buildSongRow(
    List<MediaItemRecord> collection,
    MediaItemRecord song,
    int index,
  ) {
    final accent = Theme.of(context).colorScheme.primary;
    final isCurrent = widget.controller.current?.path == song.path;
    final isUnavailable = !song.isAvailable;
    return HoverListenable(
      key: ValueKey(song.id),
      builder: (context, hoveredListenable) => MediaRow(
        onSelect: () {
          if (_selectedSongPath.value != song.path) {
            _selectedSongPath.value = song.path;
          }
        },
        onPlay: isUnavailable
            ? null
            : () => _playSongCollection(collection, index),
        builder: (context, rowFocus, handleTap) =>
            ValueListenableBuilder<String?>(
              valueListenable: _selectedSongPath,
              builder: (context, selectedPath, rowChild) {
                final isSelected = selectedPath == song.path;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.sm,
                    vertical: AppSpace.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? context.palette.hover
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    border: isSelected
                        ? Border.all(color: accent.withValues(alpha: 0.45))
                        : null,
                  ),
                  child: rowChild,
                );
              },
              child: Row(
                children: [
                  // Clickable content region (instant select, double-tap to play)
                  Expanded(
                    child: InkWell(
                      canRequestFocus: false,
                      onTap: handleTap,
                      onSecondaryTapDown: (details) => unawaited(
                        _showSongContextMenu(
                          collection,
                          song,
                          index,
                          details.globalPosition,
                        ),
                      ),
                      borderRadius: BorderRadius.circular(AppRadii.control),
                      hoverColor: context.palette.hover,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            // Track index or playing indicator
                            SizedBox(
                              width: 36,
                              child: ValueListenableBuilder<bool>(
                                valueListenable: hoveredListenable,
                                builder: (context, hovered, _) =>
                                    _TrackIndexCell(
                                      index: index,
                                      isCurrent: isCurrent,
                                      isPlaying: widget.controller.isPlaying,
                                      isUnavailable: isUnavailable,
                                      hovered: hovered,
                                      onPlay: () => _playSongCollection(
                                        collection,
                                        index,
                                      ),
                                    ),
                              ),
                            ),
                            // Title & Artist + Missing file indicator
                            Expanded(
                              flex: 4,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          song.title,
                                          style: context.palette.rowPrimary
                                              .copyWith(
                                                color: isUnavailable
                                                    ? context.palette.mutedText
                                                    : isCurrent
                                                    ? accent
                                                    : context
                                                          .palette
                                                          .primaryText,
                                                fontWeight: isCurrent
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (isUnavailable) ...[
                                        const SizedBox(width: 6),
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
                                  const SizedBox(height: 2),
                                  Text(
                                    song.artist,
                                    style: context.palette.rowSecondary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            // Album
                            Expanded(
                              flex: 3,
                              child: Text(
                                song.album,
                                style: context.palette.rowSecondary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            // Duration
                            SizedBox(
                              width: 70,
                              child: Text(
                                formatDuration(song.metadata.duration),
                                style: context.palette.metadata.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                                textAlign: TextAlign.right,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Favorite Button
                  SizedBox(
                    width: 48,
                    child: IconButton(
                      icon: Icon(
                        song.isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 18,
                        color: song.isFavorite
                            ? accent
                            : context.palette.mutedText,
                      ),
                      tooltip: song.isFavorite
                          ? 'Remove favorite'
                          : 'Add to favorites',
                      onPressed: () async {
                        final next = !song.isFavorite;
                        await widget.repository.toggleFavorite(song.id, next);
                        if (!mounted) return;
                        _patchFavoriteInLoadedLists(song.id, next);
                      },
                    ),
                  ),
                  // More actions menu
                  SizedBox(width: 40, child: _buildItemActionMenu(song)),
                ],
              ),
            ),
      ),
    );
  }

  Widget _buildItemActionMenu(MediaItemRecord song) {
    return LibraryItemActionMenu(
      item: song,
      repository: widget.repository,
      controller: widget.controller,
      libraryContext: context,
      onShowInFolder: _showInFolder,
      onFavoriteToggled: (mediaId, isFavorite) {
        if (!mounted) return;
        _patchFavoriteInLoadedLists(mediaId, isFavorite);
      },
    );
  }

  // --- Albums View ---

  Widget _buildAlbumsGridView() {
    final albums = _filteredAlbumSummaries();
    final visibleCount = _albumGridVisible.clamp(0, albums.length);
    final visibleAlbums = albums.take(visibleCount).toList();

    final textHeight = MediaQuery.textScalerOf(context).scale(13) * 3.8;
    return NotificationListener<ScrollNotification>(
      onNotification: _onGridScroll,
      child: StableGridReflowBox(
        metricsBuilder: (width, columnBasisWidth) {
          final availableWidth = (width - 2 * AppSpace.lg).clamp(
            0.0,
            double.infinity,
          );
          final basisWidth = (columnBasisWidth - 2 * AppSpace.lg).clamp(
            0.0,
            double.infinity,
          );
          final columns = ((basisWidth + 20) / 220).ceil().clamp(2, 12);
          final tileWidth = (availableWidth - (columns - 1) * 20) / columns;
          return GridReflowMetrics(
            columns: columns,
            itemWidth: tileWidth,
            itemHeight: tileWidth + textHeight + 14,
            crossAxisSpacing: 20,
            mainAxisSpacing: 24,
            horizontalPadding: AppSpace.lg,
          );
        },
        builder: (context, metrics, isReflowing) => GridView.builder(
          clipBehavior: isReflowing ? Clip.none : Clip.hardEdge,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          padding: const EdgeInsets.all(AppSpace.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: metrics.columns,
            mainAxisSpacing: metrics.mainAxisSpacing,
            crossAxisSpacing: metrics.crossAxisSpacing,
            mainAxisExtent: metrics.itemHeight,
          ),
          itemCount: visibleAlbums.length,
          itemBuilder: (context, index) {
            final album = visibleAlbums[index];
            final albumName = album.name;
            return GridReflowItem(
              key: ValueKey(albumName),
              index: index,
              child: _AlbumGridTile(
                albumName: albumName,
                summary: album,
                repository: widget.repository,
                previewCache: _albumPreviewCache,
                onOpen: () {
                  setState(() {
                    _selectedAlbum = albumName;
                    _selectedAlbumArtist = null;
                    _albumTracks = null;
                  });
                  _reload();
                },
                onPlay: () async {
                  final tracks = await widget.repository.queryMedia(
                    kind: MediaKind.audio,
                    album: albumName,
                    sortBy: 'trackNumber',
                  );
                  if (!mounted) return;
                  await _playAlbum(tracks);
                },
              ),
            );
          },
        ),
      ),
    );
  }

  // --- Album Detail View (Drilldown) ---

  Widget _buildAlbumDetailView(String albumName) {
    final tracks = _albumTracks ?? const <MediaItemRecord>[];
    final sortedTracks = List<MediaItemRecord>.from(tracks)
      ..sort((a, b) {
        final discCompare = (a.metadata.discNumber ?? 1).compareTo(
          b.metadata.discNumber ?? 1,
        );
        if (discCompare != 0) return discCompare;
        return (a.metadata.trackNumber ?? 0).compareTo(
          b.metadata.trackNumber ?? 0,
        );
      });

    final artist = sortedTracks.isNotEmpty
        ? sortedTracks.first.artist
        : 'Unknown Artist';
    final totalDuration = sortedTracks.fold<Duration>(
      Duration.zero,
      (sum, t) => sum + t.metadata.duration,
    );

    return Scaffold(
      backgroundColor: context.palette.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header back navigation
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
                  tooltip: 'Back to albums',
                  color: context.palette.secondaryText,
                  onPressed: () {
                    setState(() {
                      _selectedAlbum = null;
                      _selectedAlbumArtist = null;
                      _albumTracks = null;
                    });
                    _reload();
                  },
                ),
                const SizedBox(width: 8),
                Text('Albums', style: context.palette.rowSecondary),
                const SizedBox(width: 6),
                Text('›', style: context.palette.metadata),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    albumName,
                    style: context.palette.rowPrimary.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // Album hero
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    color: context.palette.raisedSurface,
                    borderRadius: BorderRadius.circular(AppRadii.artwork),
                    border: Border.all(color: context.palette.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: LibraryArtwork(
                    path: sortedTracks.isEmpty
                        ? null
                        : sortedTracks.first.metadata.artworkUri,
                    mediaPath: sortedTracks.isEmpty
                        ? null
                        : sortedTracks.first.path,
                    repository: widget.repository,
                    iconSize: 64,
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        albumName,
                        style: context.palette.albumTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.palette.sectionTitle.copyWith(
                          color: context.palette.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${sortedTracks.length} tracks • ${formatDuration(totalDuration)}',
                        style: context.palette.metadata,
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              foregroundColor: context.palette.accentForeground,
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
                            onPressed: () => _playAlbum(sortedTracks),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text(
                              'Play album',
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
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                              ),
                            ),
                            onPressed: () =>
                                _playAlbum(sortedTracks, shuffle: true),
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
          Divider(height: 1, color: context.palette.border),
          // Tracklist
          Expanded(child: _buildSongTableView(sortedTracks)),
        ],
      ),
    );
  }

  // --- Artists View ---

  Widget _buildArtistsGridView() {
    final artists = _filteredArtistSummaries();
    final visibleCount = _artistGridVisible.clamp(0, artists.length);
    final visibleArtists = artists.take(visibleCount).toList();

    final textHeight = MediaQuery.textScalerOf(context).scale(13) * 3.8;
    return NotificationListener<ScrollNotification>(
      onNotification: _onGridScroll,
      child: StableGridReflowBox(
        metricsBuilder: (width, columnBasisWidth) {
          final availableWidth = (width - 2 * AppSpace.lg).clamp(
            0.0,
            double.infinity,
          );
          final basisWidth = (columnBasisWidth - 2 * AppSpace.lg).clamp(
            0.0,
            double.infinity,
          );
          final columns = ((basisWidth + 20) / 200).ceil().clamp(2, 12);
          final tileWidth = (availableWidth - (columns - 1) * 20) / columns;
          return GridReflowMetrics(
            columns: columns,
            itemWidth: tileWidth,
            itemHeight: tileWidth + textHeight + 14,
            crossAxisSpacing: 20,
            mainAxisSpacing: 20,
            horizontalPadding: AppSpace.lg,
          );
        },
        builder: (context, metrics, isReflowing) => GridView.builder(
          clipBehavior: isReflowing ? Clip.none : Clip.hardEdge,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          padding: const EdgeInsets.all(AppSpace.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: metrics.columns,
            mainAxisSpacing: metrics.mainAxisSpacing,
            crossAxisSpacing: metrics.crossAxisSpacing,
            mainAxisExtent: metrics.itemHeight,
          ),
          itemCount: visibleArtists.length,
          itemBuilder: (context, index) {
            final artist = visibleArtists[index];
            final artistName = artist.name;
            return GridReflowItem(
              key: ValueKey(artistName),
              index: index,
              child: _ArtistGridTile(
                artistName: artistName,
                summary: artist,
                repository: widget.repository,
                onOpen: () {
                  setState(() {
                    _selectedArtist = artistName;
                    _artistSongs = null;
                  });
                  _reload();
                },
              ),
            );
          },
        ),
      ),
    );
  }

  // --- Artist Detail View (Drilldown) ---

  Widget _buildArtistDetailView(String artistName) {
    final songs = _artistSongs ?? const <MediaItemRecord>[];

    return Scaffold(
      backgroundColor: context.palette.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header back navigation
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
                  tooltip: 'Back to artists',
                  color: context.palette.secondaryText,
                  onPressed: () {
                    setState(() {
                      _selectedArtist = null;
                      _artistSongs = null;
                    });
                    _reload();
                  },
                ),
                const SizedBox(width: 8),
                Text('Artists', style: context.palette.rowSecondary),
                const SizedBox(width: 6),
                Text('›', style: context.palette.metadata),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    artistName,
                    style: context.palette.rowPrimary.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.artwork),
                  child: SizedBox(
                    width: 140,
                    height: 140,
                    child: LibraryArtwork(
                      path: songs.isEmpty
                          ? null
                          : songs.first.metadata.artworkUri,
                      mediaPath: songs.isEmpty ? null : songs.first.path,
                      repository: widget.repository,
                      icon: Icons.person_rounded,
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artistName,
                        style: context.palette.pageTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${songs.length} songs in library',
                        style: context.palette.metadata,
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: songs.isEmpty
                                ? null
                                : () => _playAlbum(songs),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Play'),
                          ),
                          OutlinedButton.icon(
                            onPressed: songs.isEmpty
                                ? null
                                : () => _playAlbum(songs, shuffle: true),
                            icon: const Icon(Icons.shuffle_rounded),
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
          Divider(height: 1, color: context.palette.border),
          Expanded(child: _buildSongTableView(songs)),
        ],
      ),
    );
  }
}

bool _hasCollectionBatchSummary(MediaCollectionSummary? summary) =>
    summary != null &&
    (summary.samplePath != null ||
        summary.artworkUri != null ||
        summary.trackCount > 0);

String _pluralize(int count, String singular) =>
    count == 1 ? '1 $singular' : '$count ${singular}s';

String _formatAlbumSubtitle(String artist, int trackCount) {
  final countLabel = trackCount > 0 ? _pluralize(trackCount, 'track') : '';
  if (artist.isNotEmpty && countLabel.isNotEmpty) {
    return '$artist • $countLabel';
  }
  return artist.isNotEmpty ? artist : countLabel;
}

String _formatArtistSubtitle(int trackCount, int albumCount) {
  final songsLabel = _pluralize(trackCount, 'song');
  if (albumCount <= 0) return songsLabel;
  return '$songsLabel • ${_pluralize(albumCount, 'album')}';
}

class _AlbumGridTile extends StatefulWidget {
  const _AlbumGridTile({
    required this.albumName,
    this.summary,
    required this.repository,
    required this.previewCache,
    required this.onOpen,
    required this.onPlay,
  });

  final String albumName;
  final MediaCollectionSummary? summary;
  final MediaLibraryRepository repository;
  final Map<String, MediaItemRecord?> previewCache;
  final VoidCallback onOpen;
  final Future<void> Function() onPlay;

  @override
  State<_AlbumGridTile> createState() => _AlbumGridTileState();
}

class _AlbumGridTileState extends State<_AlbumGridTile> {
  MediaItemRecord? _preview;

  bool get _hasBatchSummary => _hasCollectionBatchSummary(widget.summary);

  @override
  void initState() {
    super.initState();
    if (_hasBatchSummary) {
      return;
    }
    if (widget.previewCache.containsKey(widget.albumName)) {
      _preview = widget.previewCache[widget.albumName];
    } else {
      unawaited(_loadPreview());
    }
  }

  Future<void> _loadPreview() async {
    try {
      final items = await widget.repository.queryMedia(
        kind: MediaKind.audio,
        album: widget.albumName,
        limit: 1,
      );
      final preview = items.isEmpty ? null : items.first;
      widget.previewCache[widget.albumName] = preview;
      if (mounted) setState(() => _preview = preview);
    } catch (_) {
      widget.previewCache[widget.albumName] = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final preview = _preview;
    final artworkUri = _hasBatchSummary
        ? summary!.artworkUri
        : preview?.metadata.artworkUri;
    final samplePath = _hasBatchSummary ? summary!.samplePath : preview?.path;
    final artistLabel = _hasBatchSummary
        ? summary!.subtitle
        : (preview?.metadata.effectiveAlbumArtist ?? preview?.artist ?? '');
    final trackCount = _hasBatchSummary ? summary!.trackCount : 0;
    final subtitle = _formatAlbumSubtitle(artistLabel, trackCount);
    return MediaTile(
      artwork: LibraryArtwork(
        path: artworkUri,
        mediaPath: samplePath,
        repository: widget.repository,
      ),
      title: widget.albumName,
      subtitle: subtitle,
      onTap: widget.onOpen,
      overlay: FilledButton.tonal(
        onPressed: () => unawaited(widget.onPlay()),
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(40, 40),
        ),
        child: const Icon(Icons.play_arrow_rounded),
      ),
    );
  }
}

class _ArtistGridTile extends StatefulWidget {
  const _ArtistGridTile({
    required this.artistName,
    this.summary,
    required this.repository,
    required this.onOpen,
  });

  final String artistName;
  final MediaCollectionSummary? summary;
  final MediaLibraryRepository repository;
  final VoidCallback onOpen;

  @override
  State<_ArtistGridTile> createState() => _ArtistGridTileState();
}

class _ArtistGridTileState extends State<_ArtistGridTile> {
  MediaItemRecord? _preview;

  bool get _hasBatchSummary => _hasCollectionBatchSummary(widget.summary);

  @override
  void initState() {
    super.initState();
    if (!_hasBatchSummary) {
      unawaited(_loadPreview());
    }
  }

  Future<void> _loadPreview() async {
    try {
      final items = await widget.repository.queryMedia(
        kind: MediaKind.audio,
        artist: widget.artistName,
        limit: 1,
      );
      if (!mounted) return;
      setState(() => _preview = items.isEmpty ? null : items.first);
    } catch (_) {
      if (mounted) setState(() => _preview = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final preview = _preview;
    final artworkUri = _hasBatchSummary
        ? summary!.artworkUri
        : preview?.metadata.artworkUri;
    final samplePath = _hasBatchSummary ? summary!.samplePath : preview?.path;
    final subtitle = _hasBatchSummary && summary!.trackCount > 0
        ? _formatArtistSubtitle(summary.trackCount, summary.albumCount)
        : (_hasBatchSummary
              ? summary!.subtitle
              : (preview == null ? '' : preview.album));
    return MediaTile(
      artwork: LibraryArtwork(
        path: artworkUri,
        mediaPath: samplePath,
        repository: widget.repository,
        icon: Icons.person_rounded,
      ),
      title: widget.artistName,
      subtitle: subtitle,
      onTap: widget.onOpen,
    );
  }
}

/// One subtab pill in the Music header. Exposed to assistive tech as a
/// button with a selected state instead of a bare text label.
class _SubtabPill extends StatelessWidget {
  const _SubtabPill({
    required this.label,
    required this.selected,
    required this.onSelect,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Semantics(
        button: true,
        selected: selected,
        child: TextButton(
          onPressed: onSelect,
          style: TextButton.styleFrom(
            foregroundColor: selected ? accent : context.palette.secondaryText,
            backgroundColor: selected
                ? accent.withValues(alpha: 0.10)
                : Colors.transparent,
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
            textStyle: TextStyle(
              fontFamily: AppType.family,
              fontSize: AppType.small,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

/// Track number cell that reveals a play button on hover.
class _TrackIndexCell extends StatelessWidget {
  const _TrackIndexCell({
    required this.index,
    required this.isCurrent,
    required this.isPlaying,
    required this.isUnavailable,
    required this.hovered,
    required this.onPlay,
  });

  final int index;
  final bool isCurrent;
  final bool isPlaying;
  final bool isUnavailable;
  final bool hovered;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    if (hovered && !isUnavailable) {
      return InkWell(
        onTap: onPlay,
        child: Icon(Icons.play_arrow_rounded, size: 20, color: accent),
      );
    }
    if (isCurrent && isPlaying) {
      return PlayingEqualizerGlyph(
        index: index,
        size: 14,
        color: accent,
        semanticLabel: 'Playing',
      );
    }
    return Text(
      '${index + 1}',
      style: context.palette.metadata.copyWith(
        color: isCurrent ? accent : context.palette.mutedText,
      ),
    );
  }
}
