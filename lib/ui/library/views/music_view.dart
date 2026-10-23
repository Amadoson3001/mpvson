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
  static const int _pageSize = 80;

  MusicSubtab _currentSubtab = MusicSubtab.songs;
  String? _selectedAlbum;
  String? _selectedArtist;
  List<MediaItemRecord>? _items;
  List<MediaItemRecord>? _albumTracks;
  List<MediaItemRecord>? _artistSongs;
  List<LibraryAlbumSummary>? _albums;
  List<LibraryArtistSummary>? _artists;
  LibraryAlbumSummary? _selectedAlbumSummary;
  LibraryArtistSummary? _selectedArtistSummary;
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
  void didUpdateWidget(MusicView oldWidget) {
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
    _queryGeneration++;
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
      _items = null;
      _albumTracks = null;
      _artistSongs = null;
      _albums = null;
      _artists = null;
      _selectedAlbumSummary = null;
      _selectedArtistSummary = null;
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
      final repository = widget.repository;
      final album = _selectedAlbum;
      final artist = _selectedArtist;
      final tab = _currentSubtab;

      if (album != null) {
        final tracks = await repository.queryMedia(
          kind: MediaKind.audio,
          album: album,
          limit: _pageSize,
          offset: offset,
          sortBy: 'trackNumber',
        );
        if (!mounted || generation != _queryGeneration) return;
        final summaries = offset == 0
            ? await repository.queryAlbums(album: album, limit: 1)
            : const <LibraryAlbumSummary>[];
        if (!mounted || generation != _queryGeneration) return;
        setState(() {
          _albumTracks = offset == 0
              ? tracks
              : <MediaItemRecord>[...?_albumTracks, ...tracks];
          if (summaries.isNotEmpty) {
            _selectedAlbumSummary = summaries.first;
          }
          _nextOffset = offset + tracks.length;
          _hasMore = tracks.length == _pageSize;
          _isLoading = false;
          _isLoadingMore = false;
          _pageLoadFailed = false;
        });
      } else if (artist != null) {
        final tracks = await repository.queryMedia(
          kind: MediaKind.audio,
          artist: artist,
          limit: _pageSize,
          offset: offset,
          sortBy: 'title',
        );
        if (!mounted || generation != _queryGeneration) return;
        final summaries = offset == 0
            ? await repository.queryArtists(artist: artist, limit: 1)
            : const <LibraryArtistSummary>[];
        if (!mounted || generation != _queryGeneration) return;
        setState(() {
          _artistSongs = offset == 0
              ? tracks
              : <MediaItemRecord>[...?_artistSongs, ...tracks];
          if (summaries.isNotEmpty) {
            _selectedArtistSummary = summaries.first;
          }
          _nextOffset = offset + tracks.length;
          _hasMore = tracks.length == _pageSize;
          _isLoading = false;
          _isLoadingMore = false;
          _pageLoadFailed = false;
        });
      } else if (tab == MusicSubtab.albums) {
        final albums = await repository.queryAlbums(
          searchQuery: widget.searchQuery,
          limit: _pageSize,
          offset: offset,
        );
        if (!mounted || generation != _queryGeneration) return;
        setState(() {
          _albums = offset == 0
              ? albums
              : <LibraryAlbumSummary>[...?_albums, ...albums];
          _nextOffset = offset + albums.length;
          _hasMore = albums.length == _pageSize;
          _isLoading = false;
          _isLoadingMore = false;
          _pageLoadFailed = false;
        });
      } else if (tab == MusicSubtab.artists) {
        final artists = await repository.queryArtists(
          searchQuery: widget.searchQuery,
          limit: _pageSize,
          offset: offset,
        );
        if (!mounted || generation != _queryGeneration) return;
        setState(() {
          _artists = offset == 0
              ? artists
              : <LibraryArtistSummary>[...?_artists, ...artists];
          _nextOffset = offset + artists.length;
          _hasMore = artists.length == _pageSize;
          _isLoading = false;
          _isLoadingMore = false;
          _pageLoadFailed = false;
        });
      } else {
        final items = await _fetchMediaForSubtab(offset: offset);
        if (!mounted || generation != _queryGeneration) return;
        setState(() {
          _items = offset == 0
              ? items
              : <MediaItemRecord>[...?_items, ...items];
          _nextOffset = offset + items.length;
          _hasMore = items.length == _pageSize;
          _isLoading = false;
          _isLoadingMore = false;
          _pageLoadFailed = false;
        });
      }
    } catch (error) {
      debugPrint('Music view could not refresh: $error');
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
    if (!mounted || !_hasMore || _isLoading || _isLoadingMore) return;
    final offset = _nextOffset;
    setState(() => _isLoadingMore = true);
    _queuePage(offset);
  }

  bool get _currentListIsNull {
    if (_selectedAlbum != null) return _albumTracks == null;
    if (_selectedArtist != null) return _artistSongs == null;
    return switch (_currentSubtab) {
      MusicSubtab.albums => _albums == null,
      MusicSubtab.artists => _artists == null,
      _ => _items == null,
    };
  }

  void _retryPage() {
    if (!mounted || !_pageLoadFailed) return;
    final offset = _currentListIsNull ? 0 : _nextOffset;
    setState(() {
      _pageLoadFailed = false;
      _isLoading = _currentListIsNull;
      _isLoadingMore = !_currentListIsNull;
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

  Future<List<MediaItemRecord>> _fetchMediaForSubtab({
    required int offset,
  }) async {
    final query = widget.searchQuery;
    switch (_currentSubtab) {
      case MusicSubtab.songs:
        return widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          limit: _pageSize,
          offset: offset,
          sortBy: 'title',
        );
      case MusicSubtab.favorites:
        return widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          onlyFavorites: true,
          limit: _pageSize,
          offset: offset,
          sortBy: 'title',
        );
      case MusicSubtab.recentlyAdded:
        return widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          limit: _pageSize,
          offset: offset,
          sortBy: 'addedAt',
          ascending: false,
        );
      case MusicSubtab.recentlyPlayed:
        return widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          onlyPlayed: true,
          limit: _pageSize,
          offset: offset,
          sortBy: 'lastPlayedAt',
          ascending: false,
        );
      case MusicSubtab.albums:
      case MusicSubtab.artists:
        return const <MediaItemRecord>[];
    }
  }

  Future<List<MediaItemRecord>> _fetchFullSongCollection() {
    if (_selectedAlbum != null) {
      return widget.repository.queryMedia(
        kind: MediaKind.audio,
        album: _selectedAlbum,
        sortBy: 'trackNumber',
      );
    }
    if (_selectedArtist != null) {
      return widget.repository.queryMedia(
        kind: MediaKind.audio,
        artist: _selectedArtist,
        sortBy: 'title',
      );
    }
    final query = widget.searchQuery;
    switch (_currentSubtab) {
      case MusicSubtab.songs:
        return widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          sortBy: 'title',
        );
      case MusicSubtab.favorites:
        return widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          onlyFavorites: true,
          sortBy: 'title',
        );
      case MusicSubtab.recentlyAdded:
        return widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          sortBy: 'addedAt',
          ascending: false,
        );
      case MusicSubtab.recentlyPlayed:
        return widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          onlyPlayed: true,
          sortBy: 'lastPlayedAt',
          ascending: false,
        );
      case MusicSubtab.albums:
      case MusicSubtab.artists:
        return Future<List<MediaItemRecord>>.value(const <MediaItemRecord>[]);
    }
  }

  Future<void> _playSongCollection(
    List<MediaItemRecord> loadedSongs,
    int initialIndex,
  ) async {
    if (initialIndex < 0 || initialIndex >= loadedSongs.length) return;
    final selectedSong = loadedSongs[initialIndex];
    final songs = await _fetchFullSongCollection();
    final selectedIndex = songs.indexWhere(
      (song) => song.id == selectedSong.id,
    );
    if (songs.isEmpty) return;
    await widget.controller.openPaths(
      songs.map((song) => song.path).toList(),
      append: false,
      initialIndex: selectedIndex < 0 ? 0 : selectedIndex,
    );
  }

  Future<void> _playAlbum(String albumName, {bool shuffle = false}) async {
    final albumTracks = await widget.repository.queryMedia(
      kind: MediaKind.audio,
      album: albumName,
      sortBy: 'trackNumber',
    );
    final sorted = List<MediaItemRecord>.from(albumTracks)
      ..sort(_compareAlbumTracks);

    final paths = sorted.map((s) => s.path).toList();
    if (paths.isEmpty) return;
    if (shuffle) paths.shuffle();
    await widget.controller.openPaths(paths, append: false, initialIndex: 0);
  }

  int _compareAlbumTracks(MediaItemRecord a, MediaItemRecord b) {
    final discCompare = (a.metadata.discNumber ?? 1).compareTo(
      b.metadata.discNumber ?? 1,
    );
    if (discCompare != 0) return discCompare;
    final trackCompare = (a.metadata.trackNumber ?? 0).compareTo(
      b.metadata.trackNumber ?? 0,
    );
    if (trackCompare != 0) return trackCompare;
    final titleCompare = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    if (titleCompare != 0) return titleCompare;
    final sourceCompare = a.canonicalSource.toLowerCase().compareTo(
      b.canonicalSource.toLowerCase(),
    );
    return sourceCompare != 0
        ? sourceCompare
        : a.canonicalSource.compareTo(b.canonicalSource);
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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

  @override
  Widget build(BuildContext context) {
    // If drilling down into an album or artist, show detail view
    if (_selectedAlbum != null) {
      return _buildAlbumDetailView(_selectedAlbum!);
    }
    if (_selectedArtist != null) {
      return _buildArtistDetailView(_selectedArtist!);
    }

    final isInitialLoading =
        _isLoading &&
        switch (_currentSubtab) {
          MusicSubtab.albums => _albums == null,
          MusicSubtab.artists => _artists == null,
          _ => _items == null,
        };
    final isEmpty = switch (_currentSubtab) {
      MusicSubtab.albums => (_albums ?? const <LibraryAlbumSummary>[]).isEmpty,
      MusicSubtab.artists =>
        (_artists ?? const <LibraryArtistSummary>[]).isEmpty,
      _ => (_items ?? const <MediaItemRecord>[]).isEmpty,
    };

    return Material(
      color: LibraryTheme.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Subtab Navigation Bar
          _buildSubtabHeader(),
          const Divider(height: 1, color: LibraryTheme.border),
          // Content stage
          Expanded(
            child: isInitialLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        LibraryTheme.accent,
                      ),
                    ),
                  )
                : _pageLoadFailed && _currentListIsNull
                ? _buildLoadError()
                : isEmpty
                ? _buildEmptyStateForSubtab()
                : switch (_currentSubtab) {
                    MusicSubtab.songs ||
                    MusicSubtab.favorites ||
                    MusicSubtab.recentlyAdded ||
                    MusicSubtab.recentlyPlayed => _buildSongTableView(
                      _items!,
                      hasMore: _hasMore,
                    ),
                    MusicSubtab.albums => _buildAlbumsGridView(_albums!),
                    MusicSubtab.artists => _buildArtistsGridView(_artists!),
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildSubtabHeader() {
    return Container(
      color: LibraryTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _subtabButton('Songs', MusicSubtab.songs, Icons.music_note_rounded),
            const SizedBox(width: 6),
            _subtabButton('Albums', MusicSubtab.albums, Icons.album_rounded),
            const SizedBox(width: 6),
            _subtabButton('Artists', MusicSubtab.artists, Icons.person_rounded),
            const SizedBox(width: 6),
            _subtabButton(
              'Favorites',
              MusicSubtab.favorites,
              Icons.favorite_rounded,
            ),
            const SizedBox(width: 6),
            _subtabButton(
              'Recently Added',
              MusicSubtab.recentlyAdded,
              Icons.access_time_rounded,
            ),
            const SizedBox(width: 6),
            _subtabButton(
              'Recently Played',
              MusicSubtab.recentlyPlayed,
              Icons.history_rounded,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadError() {
    return Center(
      child: TextButton.icon(
        onPressed: _retryPage,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Could not load music. Retry'),
      ),
    );
  }

  Widget _subtabButton(String title, MusicSubtab tab, IconData icon) {
    final isSelected = _currentSubtab == tab;
    return InkWell(
      onTap: () {
        setState(() {
          _currentSubtab = tab;
          _selectedAlbum = null;
          _selectedArtist = null;
          _items = null;
        });
        _reload();
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? LibraryTheme.raisedSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? LibraryTheme.accent.withValues(alpha: 0.6)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected
                  ? LibraryTheme.accent
                  : LibraryTheme.secondaryText,
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected
                    ? LibraryTheme.primaryText
                    : LibraryTheme.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStateForSubtab() {
    switch (_currentSubtab) {
      case MusicSubtab.favorites:
        return const EmptyLibraryView(
          title: 'No favorite songs yet',
          message:
              'Click the heart icon on any song or track to add it to your favorites.',
          actionLabel: '',
          icon: Icons.favorite_border_rounded,
        );
      case MusicSubtab.recentlyPlayed:
        return const EmptyLibraryView(
          title: 'No recently played music',
          message:
              'Songs you listen to will appear here in chronological order.',
          actionLabel: '',
          icon: Icons.history_rounded,
        );
      default:
        final hasQuery =
            widget.searchQuery != null && widget.searchQuery!.isNotEmpty;
        return EmptyLibraryView(
          title: 'No music found',
          message: hasQuery
              ? 'No songs matched "${widget.searchQuery}". Try a different keyword.'
              : 'Add your music folder to index and listen to your songs.',
          actionLabel: hasQuery ? '' : 'Add folders',
          onAction: hasQuery ? null : widget.onAddFolders,
        );
    }
  }

  Widget _buildSongTableView(
    List<MediaItemRecord> songs, {
    required bool hasMore,
  }) {
    return ListView.separated(
      key: ValueKey<int>(_queryGeneration),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      itemCount: songs.length + 1 + (hasMore ? 1 : 0),
      separatorBuilder: (_, index) => index == 0
          ? const Divider(height: 16, thickness: 1, color: LibraryTheme.border)
          : const Divider(height: 1, color: LibraryTheme.surface),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildTableHeaderRow();
        }
        if (hasMore && index == songs.length + 1) {
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
        final songIndex = index - 1;
        final song = songs[songIndex];
        return _buildSongRow(songs, song, songIndex);
      },
    );
  }

  Widget _buildTableHeaderRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 36,
            child: Text('#', style: LibraryTheme.metadata),
          ),
          const Expanded(
            flex: 4,
            child: Text('Title & Artist', style: LibraryTheme.metadata),
          ),
          const Expanded(
            flex: 3,
            child: Text('Album', style: LibraryTheme.metadata),
          ),
          const SizedBox(
            width: 70,
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

  Widget _buildSongRow(
    List<MediaItemRecord> collection,
    MediaItemRecord song,
    int index,
  ) {
    final isCurrent = widget.controller.current?.path == song.path;
    final isUnavailable = !song.isAvailable;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: isCurrent
            ? LibraryTheme.accent.withValues(alpha: 0.1)
            : Colors.transparent,
      ),
      child: Row(
        children: [
          // Clickable content region (tap or double-tap to play)
          Expanded(
            child: InkWell(
              onTap: () => _playSongCollection(collection, index),
              onDoubleTap: () => _playSongCollection(collection, index),
              borderRadius: BorderRadius.circular(8),
              hoverColor: LibraryTheme.hover,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    // Track index or playing indicator
                    SizedBox(
                      width: 36,
                      child: isCurrent && widget.controller.isPlaying
                          ? const Icon(
                              Icons.volume_up_rounded,
                              size: 16,
                              color: LibraryTheme.accent,
                            )
                          : Text(
                              '${index + 1}',
                              style: LibraryTheme.metadata.copyWith(
                                color: isCurrent
                                    ? LibraryTheme.accent
                                    : LibraryTheme.mutedText,
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
                                  style: LibraryTheme.rowPrimary.copyWith(
                                    color: isUnavailable
                                        ? LibraryTheme.mutedText
                                        : isCurrent
                                        ? LibraryTheme.accent
                                        : LibraryTheme.primaryText,
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
                                    color: LibraryTheme.danger.withValues(
                                      alpha: 0.2,
                                    ),
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
                          const SizedBox(height: 2),
                          Text(
                            song.artist,
                            style: LibraryTheme.rowSecondary,
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
                        style: LibraryTheme.rowSecondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Duration
                    SizedBox(
                      width: 70,
                      child: Text(
                        _formatDuration(song.metadata.duration),
                        style: LibraryTheme.metadata,
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
                    ? LibraryTheme.accent
                    : LibraryTheme.mutedText,
              ),
              tooltip: song.isFavorite ? 'Remove favorite' : 'Add to favorites',
              onPressed: () =>
                  widget.repository.toggleFavorite(song.id, !song.isFavorite),
            ),
          ),
          // More actions menu
          SizedBox(width: 40, child: _buildItemActionMenu(song)),
        ],
      ),
    );
  }

  Widget _buildItemActionMenu(MediaItemRecord song) {
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
            await widget.controller.openPaths(
              [song.path],
              append: false,
              initialIndex: 0,
            );
            break;
          case 'play_next':
            await widget.controller.openPaths(
              [song.path],
              append: true,
              playNext: true,
            );
            break;
          case 'add_queue':
            await widget.controller.openPaths(
              [song.path],
              append: true,
              playNext: false,
            );
            break;
          case 'toggle_favorite':
            await widget.repository.toggleFavorite(song.id, !song.isFavorite);
            break;
          case 'show_folder':
            _showInFolder(song.path);
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
                song.isFavorite
                    ? Icons.favorite_border_rounded
                    : Icons.favorite_rounded,
                size: 18,
                color: LibraryTheme.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  song.isFavorite ? 'Remove favorite' : 'Favorite',
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

  // --- Albums View ---

  Widget _buildAlbumsGridView(List<LibraryAlbumSummary> albums) {
    return GridView.builder(
      key: ValueKey<int>(_queryGeneration),
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 24,
        crossAxisSpacing: 20,
        childAspectRatio: 0.76,
      ),
      itemCount: albums.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == albums.length) {
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
        return _buildAlbumCard(albums[index]);
      },
    );
  }

  Widget _buildAlbumCard(LibraryAlbumSummary album) {
    return _AlbumCard(
      album: album,
      onTap: () {
        setState(() {
          _selectedAlbum = album.album;
          _selectedAlbumSummary = album;
        });
        _reload();
      },
      onPlay: () => _playAlbum(album.album),
    );
  }

  // --- Album Detail View (Drilldown) ---

  Widget _buildAlbumDetailView(String albumName) {
    final tracks = _albumTracks ?? const <MediaItemRecord>[];
    final sortedTracks = List<MediaItemRecord>.from(tracks)
      ..sort(_compareAlbumTracks);

    final artist =
        _selectedAlbumSummary?.artist ??
        (sortedTracks.isNotEmpty
            ? sortedTracks.first.artist
            : 'Unknown Artist');
    final totalDuration =
        _selectedAlbumSummary?.totalDuration ??
        sortedTracks.fold<Duration>(
          Duration.zero,
          (sum, t) => sum + t.metadata.duration,
        );
    final trackCount = _selectedAlbumSummary?.trackCount ?? sortedTracks.length;

    return Scaffold(
      backgroundColor: LibraryTheme.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header back navigation
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back to albums',
                  color: LibraryTheme.secondaryText,
                  onPressed: () {
                    setState(() {
                      _selectedAlbum = null;
                      _albumTracks = null;
                    });
                    _reload();
                  },
                ),
                const SizedBox(width: 8),
                Text('Albums', style: LibraryTheme.rowSecondary),
                const SizedBox(width: 6),
                const Text('›', style: LibraryTheme.metadata),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    albumName,
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
          // Album hero
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _albumTracks != null && _albumTracks!.isNotEmpty
                    ? _MusicCover(
                        song: _albumTracks!.first,
                        controller: widget.controller,
                        size: 160,
                      )
                    : Container(
                        width: 160,
                        height: 160,
                        decoration: BoxDecoration(
                          color: LibraryTheme.raisedSurface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: LibraryTheme.border),
                        ),
                        child: _buildVinylCover(size: 160),
                      ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(albumName, style: LibraryTheme.albumTitle),
                      const SizedBox(height: 6),
                      Text(
                        artist,
                        style: LibraryTheme.sectionTitle.copyWith(
                          color: LibraryTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$trackCount tracks, ${_formatDuration(totalDuration)}',
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
                            onPressed: () => _playAlbum(albumName),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text(
                              'Play album',
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
                            onPressed: () =>
                                _playAlbum(albumName, shuffle: true),
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
          // Tracklist
          Expanded(
            child: _pageLoadFailed && _albumTracks == null
                ? _buildLoadError()
                : _isLoading && _albumTracks == null
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        LibraryTheme.accent,
                      ),
                    ),
                  )
                : _buildSongTableView(sortedTracks, hasMore: _hasMore),
          ),
        ],
      ),
    );
  }

  // --- Artists View ---

  Widget _buildArtistsGridView(List<LibraryArtistSummary> artists) {
    return GridView.builder(
      key: ValueKey<int>(_queryGeneration),
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
        childAspectRatio: 0.88,
      ),
      itemCount: artists.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == artists.length) {
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
        final artist = artists[index];
        final artistName = artist.artist;

        return _ArtistCard(
          artist: artist,
          onTap: () {
            setState(() {
              _selectedArtist = artistName;
              _selectedArtistSummary = artist;
            });
            _reload();
          },
        );
      },
    );
  }

  // --- Artist Detail View (Drilldown) ---

  Widget _buildArtistDetailView(String artistName) {
    final songs = _artistSongs ?? const <MediaItemRecord>[];

    return Scaffold(
      backgroundColor: LibraryTheme.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header back navigation
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back to artists',
                  color: LibraryTheme.secondaryText,
                  onPressed: () {
                    setState(() {
                      _selectedArtist = null;
                      _artistSongs = null;
                    });
                    _reload();
                  },
                ),
                const SizedBox(width: 8),
                Text('Artists', style: LibraryTheme.rowSecondary),
                const SizedBox(width: 6),
                const Text('›', style: LibraryTheme.metadata),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    artistName,
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
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                _buildArtistAvatar(artistName, size: 100),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(artistName, style: LibraryTheme.pageTitle),
                      const SizedBox(height: 6),
                      Text(
                        '${_selectedArtistSummary?.songCount ?? songs.length} songs in library',
                        style: LibraryTheme.metadata,
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: LibraryTheme.accent,
                          foregroundColor: LibraryTheme.background,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: songs.isEmpty
                            ? null
                            : () => _playSongCollection(songs, 0),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text(
                          'Play all songs',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: LibraryTheme.border),
          Expanded(
            child: _pageLoadFailed && _artistSongs == null
                ? _buildLoadError()
                : _isLoading && _artistSongs == null
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        LibraryTheme.accent,
                      ),
                    ),
                  )
                : _buildSongTableView(songs, hasMore: _hasMore),
          ),
        ],
      ),
    );
  }
}

Widget _buildVinylCover({double size = 100, double iconSize = 44}) {
  return Container(
    decoration: BoxDecoration(
      gradient: const RadialGradient(
        center: Alignment(-0.2, -0.2),
        radius: 0.95,
        colors: [Color(0xFF262D3D), Color(0xFF161922), Color(0xFF0F1117)],
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Center(
      child: Container(
        width: size * 0.65,
        height: size * 0.65,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: LibraryTheme.accent.withValues(alpha: 0.18),
            width: 1.5,
          ),
          color: LibraryTheme.raisedSurface,
        ),
        child: Center(
          child: Container(
            width: size * 0.28,
            height: size * 0.28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: LibraryTheme.surface,
              border: Border.all(
                color: LibraryTheme.accent.withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Icon(
                Icons.music_note_rounded,
                size: iconSize * 0.45,
                color: LibraryTheme.accent,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _buildArtistAvatar(String artistName, {double size = 80}) {
  final initial = artistName.trim().isNotEmpty
      ? artistName.trim().characters.first.toUpperCase()
      : '';
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const RadialGradient(
        center: Alignment(-0.2, -0.3),
        radius: 0.85,
        colors: [Color(0xFF2B3A5A), Color(0xFF182033)],
      ),
      border: Border.all(
        color: LibraryTheme.accent.withValues(alpha: 0.25),
        width: 1.5,
      ),
    ),
    child: Center(
      child: initial.isNotEmpty
          ? Text(
              initial,
              style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w700,
                color: LibraryTheme.accent,
                letterSpacing: -0.5,
              ),
            )
          : Icon(
              Icons.person_rounded,
              size: size * 0.45,
              color: LibraryTheme.accent,
            ),
    ),
  );
}

class _AlbumCard extends StatefulWidget {
  const _AlbumCard({
    required this.album,
    required this.onTap,
    required this.onPlay,
  });

  final LibraryAlbumSummary album;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: LibraryTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isHovered
                  ? LibraryTheme.accent.withValues(alpha: 0.5)
                  : LibraryTheme.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Square Cover Art with Hover Play Button
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildVinylCover(size: 140),
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
                            decoration: const BoxDecoration(
                              color: LibraryTheme.accent,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black45,
                                  blurRadius: 8,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                color: LibraryTheme.background,
                                size: 26,
                              ),
                              tooltip: 'Play album',
                              onPressed: widget.onPlay,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                album.album,
                style: LibraryTheme.rowPrimary.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                album.artist,
                style: LibraryTheme.rowSecondary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text('${album.trackCount} tracks', style: LibraryTheme.metadata),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistCard extends StatefulWidget {
  const _ArtistCard({required this.artist, required this.onTap});

  final LibraryArtistSummary artist;
  final VoidCallback onTap;

  @override
  State<_ArtistCard> createState() => _ArtistCardState();
}

class _ArtistCardState extends State<_ArtistCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    final artistName = artist.artist;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: LibraryTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isHovered
                  ? LibraryTheme.accent.withValues(alpha: 0.5)
                  : LibraryTheme.border,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildArtistAvatar(artistName, size: 80),
              const SizedBox(height: 14),
              Text(
                artistName,
                style: LibraryTheme.rowPrimary.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                '${artist.songCount} songs, ${artist.albumCount} albums',
                style: LibraryTheme.metadata,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MusicCover extends StatefulWidget {
  const _MusicCover({
    required this.song,
    required this.controller,
    this.size = 160,
  });

  final MediaItemRecord song;
  final PlayerController controller;
  final double size;

  @override
  State<_MusicCover> createState() => _MusicCoverState();
}

class _MusicCoverState extends State<_MusicCover> {
  ThumbnailRequestHandle? _handle;
  MediaThumbnail? _thumbnail;
  late MediaEntry _entry;

  @override
  void initState() {
    super.initState();
    _entry = MediaEntry(
      id: widget.song.id,
      path: widget.song.path,
      title: widget.song.title,
      duration: widget.song.metadata.duration,
      lastPlayed: widget.song.lastPlayedAt ?? widget.song.addedAt,
    );
    _initThumbnail();
  }

  @override
  void didUpdateWidget(covariant _MusicCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id ||
        oldWidget.song.path != widget.song.path) {
      _handle?.release();
      _handle = null;
      _thumbnail = null;
      _entry = MediaEntry(
        id: widget.song.id,
        path: widget.song.path,
        title: widget.song.title,
        duration: widget.song.metadata.duration,
        lastPlayed: widget.song.lastPlayedAt ?? widget.song.addedAt,
      );
      _initThumbnail();
    }
  }

  @override
  void dispose() {
    _handle?.release();
    _handle = null;
    super.dispose();
  }

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
      // Safely ignore test fakes without thumbnail service
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbnail != null && _thumbnail!.bytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image(
          image: ResizeImage(
            MemoryImage(_thumbnail!.bytes),
            width: (widget.size * 2).round(),
            policy: ResizeImagePolicy.fit,
          ),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _buildVinylCover(size: widget.size),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _buildVinylCover(size: widget.size),
      ),
    );
  }
}
