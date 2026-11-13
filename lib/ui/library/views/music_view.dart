import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../../utils/file_utils.dart';
import '../../../utils/format.dart';
import '../../player/player_controller.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/app_popup_menu_item.dart';
import '../../core/components/media_tile.dart';
import '../../core/components/media_row.dart';
import '../../core/components/media_accent_scope.dart';
import '../../core/components/empty_state.dart';
import '../../core/components/playback_pulse.dart';
import '../library_browse_constants.dart';
import '../paged_media_loader.dart';
import '../viewmodels/music_view_model.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/library_artwork.dart';

const int _kGridNamePageSize = 60;

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
  /// Owns the subtab selection (and the per-subtab sorting intent). Re-created
  /// when the repository or player controller the view is bound to changes.
  late MusicViewModel _music;
  MusicSubTab? _lastSubTab;

  String? _selectedSongPath;
  String? _selectedAlbum;
  String? _selectedAlbumArtist;
  String? _selectedArtist;
  final ScrollController _scrollController = ScrollController();
  List<MediaItemRecord> _items = [];
  int _browseOffset = 0;
  bool _hasMoreBrowse = true;
  bool _loadingMoreBrowse = false;
  List<String>? _albumNames;
  List<String>? _artistNames;
  int _albumGridVisible = _kGridNamePageSize;
  int _artistGridVisible = _kGridNamePageSize;
  final Map<String, MediaItemRecord?> _albumPreviewCache = {};
  List<MediaItemRecord>? _albumTracks;
  List<MediaItemRecord>? _artistSongs;
  bool _isLoading = false;
  Object? _error;
  Future<void>? _reloadFuture;
  bool _reloadAgain = false;
  Timer? _reloadThrottle;
  Timer? _searchReload;
  String? _currentRowPath;
  bool _currentRowPlaying = false;
  late Listenable _playbackListenable;

  Listenable _playbackSignals(PlayerController controller) =>
      Listenable.merge(<Listenable>[
        controller.structureListenable,
        controller.transportListenable,
      ]);

  @override
  void initState() {
    super.initState();
    _music = _createMusicModel();
    _lastSubTab = _music.subTab;
    _music.addListener(_onMusicChanged);
    widget.repository.addListener(_onRepoChanged);
    _playbackListenable = _playbackSignals(widget.controller);
    _playbackListenable.addListener(_onPlaybackChanged);
    _currentRowPath = widget.controller.current?.path;
    _currentRowPlaying = widget.controller.isPlaying;
    _scrollController.addListener(_onBrowseScroll);
    _reload();
  }

  MusicViewModel _createMusicModel() => MusicViewModel(
    repository: widget.repository,
    playerController: widget.controller,
  );

  /// The view model owns the subtab selection; a change resets any album or
  /// artist drilldown and refetches the collection for the new subtab.
  void _onMusicChanged() {
    if (!mounted) return;
    if (_music.subTab != _lastSubTab) {
      _lastSubTab = _music.subTab;
      setState(() {
        _selectedAlbum = null;
        _selectedAlbumArtist = null;
        _selectedArtist = null;
        _items = [];
        _browseOffset = 0;
        _hasMoreBrowse = true;
        _loadingMoreBrowse = false;
        _albumNames = null;
        _artistNames = null;
        _albumGridVisible = _kGridNamePageSize;
        _artistGridVisible = _kGridNamePageSize;
      });
      _reload();
    } else {
      if (_selectedAlbum != null) {
        _loadAlbumTracks(_selectedAlbum!);
      } else if (_selectedArtist != null) {
        _loadArtistTracks(_selectedArtist!);
      } else {
        _reload();
      }
    }
  }

  Future<void> _loadAlbumTracks(String album) => _reload();

  Future<void> _loadArtistTracks(String artist) => _reload();

  @override
  void didUpdateWidget(MusicView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.controller != widget.controller) {
      _music.removeListener(_onMusicChanged);
      _music.dispose();
      _music = _createMusicModel();
      _lastSubTab = _music.subTab;
      _music.addListener(_onMusicChanged);
    }
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
      _searchReload?.cancel();
      _searchReload = Timer(const Duration(milliseconds: 150), () {
        _searchReload = null;
        if (mounted) _reload();
      });
    }
    if (oldWidget.controller != widget.controller) {
      _playbackListenable.removeListener(_onPlaybackChanged);
      _playbackListenable = _playbackSignals(widget.controller);
      _playbackListenable.addListener(_onPlaybackChanged);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onBrowseScroll);
    _scrollController.dispose();
    _reloadThrottle?.cancel();
    _searchReload?.cancel();
    _music.removeListener(_onMusicChanged);
    _music.dispose();
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
    // A scan publishes progress frequently. Reloading every collection on each
    // notification staled the visible rows and flooded the database isolate, so
    // coalesce bursts into one refresh per interval.
    if (_reloadThrottle?.isActive ?? false) {
      _reloadAgain = true;
      return;
    }
    _reloadThrottle = Timer(const Duration(milliseconds: 200), () {
      _reloadThrottle = null;
      if (!mounted) return;
      unawaited(_music.refreshLibraryMetadata());
      _reload();
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

  void _patchFavoriteInLoadedLists(String mediaId, bool isFavorite) {
    MediaItemRecord patch(MediaItemRecord item) =>
        item.id == mediaId ? item.copyWith(isFavorite: isFavorite) : item;

    if (_items.isNotEmpty) {
      _items = _items.map(patch).toList();
    }
    if (_albumTracks != null) {
      _albumTracks = _albumTracks!.map(patch).toList();
    }
    if (_artistSongs != null) {
      _artistSongs = _artistSongs!.map(patch).toList();
    }
  }

  Future<void> _drainReloads() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      do {
        _reloadAgain = false;
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
          switch (_music.currentSubtab) {
            case MusicSubtab.albums:
              final names = await widget.repository.getDistinctAlbums();
              if (!mounted) return;
              if (_reloadAgain) continue;
              setState(() {
                _error = null;
                _albumNames = names;
                _artistNames = null;
                _items = [];
                _albumGridVisible = _kGridNamePageSize;
              });
              continue;
            case MusicSubtab.artists:
              final names = await widget.repository.getDistinctArtists(
                kind: MediaKind.audio,
              );
              if (!mounted) return;
              if (_reloadAgain) continue;
              setState(() {
                _error = null;
                _artistNames = names;
                _albumNames = null;
                _items = [];
                _artistGridVisible = _kGridNamePageSize;
              });
              continue;
            case MusicSubtab.songs:
            case MusicSubtab.favorites:
            case MusicSubtab.recentlyAdded:
            case MusicSubtab.recentlyPlayed:
              _browseOffset = 0;
              _hasMoreBrowse = true;
              _loadingMoreBrowse = false;
              final batch = await _fetchMediaPageForSubtab(offset: 0);
              if (!mounted) return;
              if (_reloadAgain) continue;
              setState(() {
                _error = null;
                _albumNames = null;
                _artistNames = null;
                _items = List<MediaItemRecord>.from(batch.items);
                _browseOffset = batch.items.length;
                _hasMoreBrowse = batch.hasMore;
              });
              continue;
          }
        }
        if (!mounted) return;
        if (_reloadAgain) continue;
        setState(() {
          _error = null;
          if (album != null) {
            _albumTracks = items;
          } else if (artist != null) {
            _artistSongs = items;
          }
        });
      } while (_reloadAgain && mounted);
    } catch (error) {
      debugPrint('Music view could not refresh: $error');
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

    final subtab = _music.currentSubtab;
    final isSongSubtab =
        subtab == MusicSubtab.songs ||
        subtab == MusicSubtab.favorites ||
        subtab == MusicSubtab.recentlyAdded ||
        subtab == MusicSubtab.recentlyPlayed;
    final isGridSubtab =
        subtab == MusicSubtab.albums || subtab == MusicSubtab.artists;
    final items = _items;
    final gridEmpty = switch (subtab) {
      MusicSubtab.albums => (_albumNames ?? const []).isEmpty,
      MusicSubtab.artists => (_artistNames ?? const []).isEmpty,
      _ => false,
    };
    final gridNamesLoading =
        isGridSubtab &&
        _isLoading &&
        _albumNames == null &&
        _artistNames == null;
    final showInitialLoader =
        _isLoading && ((isSongSubtab && items.isEmpty) || gridNamesLoading);

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
    // The view model notifies; _onMusicChanged resets the drilldown state and
    // refetches. selectSubtab ignores a redundant selection.
    _music.selectSubtab(tab);
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
    final subtab = _music.currentSubtab;
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
    switch (_music.currentSubtab) {
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
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels <
        kLibraryBrowseScrollPrefetch) {
      unawaited(_loadMoreBrowse());
    }
  }

  Future<void> _loadMoreBrowse() async {
    if (_loadingMoreBrowse || !_hasMoreBrowse) return;
    if (_selectedAlbum != null || _selectedArtist != null) return;
    final subtab = _music.currentSubtab;
    if (subtab != MusicSubtab.songs &&
        subtab != MusicSubtab.favorites &&
        subtab != MusicSubtab.recentlyAdded &&
        subtab != MusicSubtab.recentlyPlayed) {
      return;
    }
    setState(() => _loadingMoreBrowse = true);
    try {
      final batch = await _fetchMediaPageForSubtab(offset: _browseOffset);
      if (!mounted) return;
      setState(() {
        _items.addAll(batch.items);
        _browseOffset += batch.items.length;
        _hasMoreBrowse = batch.hasMore;
        _loadingMoreBrowse = false;
      });
    } catch (error) {
      debugPrint('Music view could not load more: $error');
      if (mounted) setState(() => _loadingMoreBrowse = false);
    }
  }

  List<String> _filteredAlbumNames() {
    final names = _albumNames ?? const <String>[];
    final query = widget.searchQuery?.trim().toLowerCase();
    if (query == null || query.isEmpty) return names;
    return names.where((name) => name.toLowerCase().contains(query)).toList();
  }

  List<String> _filteredArtistNames() {
    final names = _artistNames ?? const <String>[];
    final query = widget.searchQuery?.trim().toLowerCase();
    if (query == null || query.isEmpty) return names;
    return names.where((name) => name.toLowerCase().contains(query)).toList();
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
    final subtab = _music.currentSubtab;
    if (subtab == MusicSubtab.albums) {
      final total = _filteredAlbumNames().length;
      if (_albumGridVisible >= total) return;
      setState(() {
        _albumGridVisible = (_albumGridVisible + _kGridNamePageSize).clamp(
          0,
          total,
        );
      });
    } else if (subtab == MusicSubtab.artists) {
      final total = _filteredArtistNames().length;
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
    switch (_music.currentSubtab) {
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
    final footerCount = enablePaging && _loadingMoreBrowse ? 1 : 0;
    return ListView.separated(
      controller: _scrollController,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.md,
      ),
      itemCount: songs.length + 1 + footerCount,
      separatorBuilder: (_, index) => index == 0
          ? Divider(height: 16, thickness: 1, color: context.palette.border)
          : Divider(height: 1, color: context.palette.surface),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildTableHeaderRow();
        }
        if (footerCount > 0 && index == songs.length + 1) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpace.md),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final songIndex = index - 1;
        final song = songs[songIndex];
        return _buildSongRow(songs, song, songIndex);
      },
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
    final isSelected = _selectedSongPath == song.path;
    return _HoverRegion(
      key: ValueKey(song.id),
      builder: (context, hovered) => MediaRow(
        onSelect: () {
          if (_selectedSongPath != song.path) {
            setState(() => _selectedSongPath = song.path);
          }
        },
        onPlay: isUnavailable
            ? null
            : () => _playSongCollection(collection, index),
        builder: (context, rowFocus) => Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.sm,
            vertical: AppSpace.xxs,
          ),
          decoration: BoxDecoration(
            color: isSelected ? context.palette.hover : Colors.transparent,
            border: isSelected
                ? Border(left: BorderSide(color: accent, width: 2))
                : null,
          ),
          child: Row(
            children: [
              // Clickable content region (double-tap to play)
              Expanded(
                child: InkWell(
                  canRequestFocus: false,
                  onTap: () {
                    rowFocus.requestFocus();
                    setState(() => _selectedSongPath = song.path);
                  },
                  onDoubleTap: isUnavailable
                      ? null
                      : () => _playSongCollection(collection, index),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                  hoverColor: context.palette.hover,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        // Track index or playing indicator
                        SizedBox(
                          width: 36,
                          child: _TrackIndexCell(
                            index: index,
                            isCurrent: isCurrent,
                            isPlaying: widget.controller.isPlaying,
                            isUnavailable: isUnavailable,
                            hovered: hovered,
                            onPlay: () =>
                                _playSongCollection(collection, index),
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
                                                : context.palette.primaryText,
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
                                        style: context.palette.badge.copyWith(
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
                    color: song.isFavorite ? accent : context.palette.mutedText,
                  ),
                  tooltip: song.isFavorite
                      ? 'Remove favorite'
                      : 'Add to favorites',
                  onPressed: () async {
                    final next = !song.isFavorite;
                    await widget.repository.toggleFavorite(song.id, next);
                    if (!mounted) return;
                    setState(() {
                      _patchFavoriteInLoadedLists(song.id, next);
                    });
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
            await widget.controller.openPaths(
              [song.path],
              append: false,
              initialIndex: 0,
            );
            break;
          case 'play_next':
            await _music.playNext(song.path);
            break;
          case 'add_queue':
            await _music.addToQueue(song.path);
            break;
          case 'toggle_favorite':
            await _music.toggleFavorite(song);
            break;
          case 'add_playlist':
            final added = await AddToPlaylistDialog.show(
              context,
              widget.repository,
              song.id,
            );
            // `context` is the State's context, so the State's mounted flag is
            // the matching guard for the async gap.
            if (!mounted) return;
            if (added) {
              AppToast.show(
                context,
                'Added to playlist',
                tone: AppToastTone.success,
                duration: const Duration(seconds: 3),
              );
            }
            break;
          case 'show_folder':
            _showInFolder(song.path);
            break;
        }
      },
      itemBuilder: (context) {
        final accent = Theme.of(context).colorScheme.primary;
        return [
          AppPopupMenuItem<String>(
            value: 'play_now',
            enabled: song.isAvailable,
            icon: Icons.play_arrow_rounded,
            iconColor: accent,
            text: 'Play now',
          ),
          AppPopupMenuItem<String>(
            value: 'play_next',
            enabled: song.isAvailable,
            icon: Icons.playlist_play_rounded,
            text: 'Play next',
          ),
          AppPopupMenuItem<String>(
            value: 'add_queue',
            enabled: song.isAvailable,
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
            icon: song.isFavorite
                ? Icons.favorite_border_rounded
                : Icons.favorite_rounded,
            iconColor: accent,
            text: song.isFavorite ? 'Remove favorite' : 'Favorite',
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

  // --- Albums View ---

  Widget _buildAlbumsGridView() {
    final albums = _filteredAlbumNames();
    final visibleCount = _albumGridVisible.clamp(0, albums.length);
    final visibleAlbums = albums.take(visibleCount).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = (constraints.maxWidth - 2 * AppSpace.lg).clamp(
          0.0,
          double.infinity,
        );
        final columns = ((availableWidth + 20) / 220).ceil().clamp(2, 12);
        final tileWidth = (availableWidth - (columns - 1) * 20) / columns;
        final textHeight = MediaQuery.textScalerOf(context).scale(13) * 3.8;

        return NotificationListener<ScrollNotification>(
          onNotification: _onGridScroll,
          child: GridView.builder(
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            padding: const EdgeInsets.all(AppSpace.lg),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 24,
              crossAxisSpacing: 20,
              mainAxisExtent: tileWidth + textHeight + 14,
            ),
            itemCount: visibleAlbums.length,
            itemBuilder: (context, index) {
              final albumName = visibleAlbums[index];
              return _AlbumGridTile(
                key: ValueKey(albumName),
                albumName: albumName,
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
              );
            },
          ),
        );
      },
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
    final artists = _filteredArtistNames();
    final visibleCount = _artistGridVisible.clamp(0, artists.length);
    final visibleArtists = artists.take(visibleCount).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = (constraints.maxWidth - 2 * AppSpace.lg).clamp(
          0.0,
          double.infinity,
        );
        final columns = ((availableWidth + 20) / 200).ceil().clamp(2, 12);
        final tileWidth = (availableWidth - (columns - 1) * 20) / columns;
        final textHeight = MediaQuery.textScalerOf(context).scale(13) * 3.8;

        return NotificationListener<ScrollNotification>(
          onNotification: _onGridScroll,
          child: GridView.builder(
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            padding: const EdgeInsets.all(AppSpace.lg),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 20,
              crossAxisSpacing: 20,
              mainAxisExtent: tileWidth + textHeight + 14,
            ),
            itemCount: visibleArtists.length,
            itemBuilder: (context, index) {
              final artistName = visibleArtists[index];
              return _ArtistGridTile(
                key: ValueKey(artistName),
                artistName: artistName,
                repository: widget.repository,
                onOpen: () {
                  setState(() {
                    _selectedArtist = artistName;
                    _artistSongs = null;
                  });
                  _reload();
                },
              );
            },
          ),
        );
      },
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

class _AlbumGridTile extends StatefulWidget {
  const _AlbumGridTile({
    super.key,
    required this.albumName,
    required this.repository,
    required this.previewCache,
    required this.onOpen,
    required this.onPlay,
  });

  final String albumName;
  final MediaLibraryRepository repository;
  final Map<String, MediaItemRecord?> previewCache;
  final VoidCallback onOpen;
  final Future<void> Function() onPlay;

  @override
  State<_AlbumGridTile> createState() => _AlbumGridTileState();
}

class _AlbumGridTileState extends State<_AlbumGridTile> {
  MediaItemRecord? _preview;

  @override
  void initState() {
    super.initState();
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
    final preview = _preview;
    final subtitle =
        preview?.metadata.effectiveAlbumArtist ?? preview?.artist ?? '';
    return MediaTile(
      artwork: LibraryArtwork(
        path: preview?.metadata.artworkUri,
        mediaPath: preview?.path,
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
    super.key,
    required this.artistName,
    required this.repository,
    required this.onOpen,
  });

  final String artistName;
  final MediaLibraryRepository repository;
  final VoidCallback onOpen;

  @override
  State<_ArtistGridTile> createState() => _ArtistGridTileState();
}

class _ArtistGridTileState extends State<_ArtistGridTile> {
  MediaItemRecord? _preview;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
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
    final preview = _preview;
    return MediaTile(
      artwork: LibraryArtwork(
        path: preview?.metadata.artworkUri,
        mediaPath: preview?.path,
        repository: widget.repository,
        icon: Icons.person_rounded,
      ),
      title: widget.artistName,
      subtitle: preview == null ? '' : preview.album,
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

/// Tracks hover for one row and rebuilds only that row.
class _HoverRegion extends StatefulWidget {
  const _HoverRegion({super.key, required this.builder});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_HoverRegion> createState() => _HoverRegionState();
}

class _HoverRegionState extends State<_HoverRegion> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) {
      if (!_hovered) setState(() => _hovered = true);
    },
    onExit: (_) {
      if (_hovered) setState(() => _hovered = false);
    },
    child: widget.builder(context, _hovered),
  );
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
