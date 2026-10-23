import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
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
  MusicSubtab _currentSubtab = MusicSubtab.songs;
  String? _selectedAlbum;
  String? _selectedArtist;
  List<MediaItemRecord>? _items;
  List<MediaItemRecord>? _albumTracks;
  List<MediaItemRecord>? _artistSongs;
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
        final album = _selectedAlbum;
        final artist = _selectedArtist;
        final List<MediaItemRecord> items;
        if (album != null) {
          items = await widget.repository.queryMedia(
            kind: MediaKind.audio,
            album: album,
            sortBy: 'trackNumber',
          );
        } else if (artist != null) {
          items = await widget.repository.queryMedia(
            kind: MediaKind.audio,
            artist: artist,
            sortBy: 'title',
          );
        } else {
          items = await _fetchMediaForSubtab();
        }
        if (!mounted) return;
        if (_reloadAgain) continue;
        setState(() {
          if (album != null) {
            _albumTracks = items;
          } else if (artist != null) {
            _artistSongs = items;
          } else {
            _items = items;
          }
        });
      } while (_reloadAgain && mounted);
    } catch (error) {
      debugPrint('Music view could not refresh: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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

  Future<void> _playSongCollection(
    List<MediaItemRecord> songs,
    int initialIndex,
  ) async {
    final paths = songs.map((s) => s.path).toList();
    if (paths.isEmpty) return;
    await widget.controller.openPaths(
      paths,
      append: false,
      initialIndex: initialIndex,
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

    final paths = sorted.map((s) => s.path).toList();
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
      return _buildAlbumDetailView(_selectedAlbum!);
    }
    if (_selectedArtist != null) {
      return _buildArtistDetailView(_selectedArtist!);
    }

    final items = _items ?? const <MediaItemRecord>[];

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
            child: _isLoading && _items == null
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        LibraryTheme.accent,
                      ),
                    ),
                  )
                : items.isEmpty
                ? _buildEmptyStateForSubtab()
                : switch (_currentSubtab) {
                    MusicSubtab.songs ||
                    MusicSubtab.favorites ||
                    MusicSubtab.recentlyAdded ||
                    MusicSubtab.recentlyPlayed => _buildSongTableView(items),
                    MusicSubtab.albums => _buildAlbumsGridView(items),
                    MusicSubtab.artists => _buildArtistsGridView(items),
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

  Future<List<MediaItemRecord>> _fetchMediaForSubtab() async {
    final query = widget.searchQuery;
    switch (_currentSubtab) {
      case MusicSubtab.songs:
      case MusicSubtab.albums:
      case MusicSubtab.artists:
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
        final all = await widget.repository.queryMedia(
          kind: MediaKind.audio,
          searchQuery: query,
          sortBy: 'lastPlayedAt',
          ascending: false,
        );
        return all.where((item) => item.lastPlayedAt != null).toList();
    }
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
        return EmptyLibraryView(
          title: 'No music found',
          message: widget.searchQuery != null && widget.searchQuery!.isNotEmpty
              ? 'No songs matched "${widget.searchQuery}". Try a different keyword.'
              : 'Add your music folder to index and listen to your songs.',
          actionLabel: 'Add folders',
          onAction: widget.onAddFolders,
        );
    }
  }

  Widget _buildSongTableView(List<MediaItemRecord> songs) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      itemCount: songs.length + 1, // header row + songs
      separatorBuilder: (_, index) => index == 0
          ? const Divider(height: 16, thickness: 1, color: LibraryTheme.border)
          : const Divider(height: 1, color: LibraryTheme.surface),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildTableHeaderRow();
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
          // Clickable content region (double-tap to play)
          Expanded(
            child: InkWell(
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

  Widget _buildAlbumsGridView(List<MediaItemRecord> songs) {
    // Group songs by album
    final Map<String, List<MediaItemRecord>> albumsMap = {};
    for (final song in songs) {
      albumsMap.putIfAbsent(song.album, () => []).add(song);
    }

    final albums = albumsMap.keys.toList()..sort();

    return GridView.builder(
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 24,
        crossAxisSpacing: 20,
        childAspectRatio: 0.76,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final albumName = albums[index];
        final albumSongs = albumsMap[albumName]!;
        final artist = albumSongs.first.artist;
        final trackCount = albumSongs.length;

        return _buildAlbumCard(albumName, artist, trackCount, albumSongs);
      },
    );
  }

  Widget _buildAlbumCard(
    String albumName,
    String artist,
    int trackCount,
    List<MediaItemRecord> albumSongs,
  ) {
    return InkWell(
      onTap: () {
        setState(() {
          _selectedAlbum = albumName;
          _albumTracks = null;
        });
        _reload();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LibraryTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: LibraryTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Square Cover Art with Hover Play Button
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: LibraryTheme.raisedSurface,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.album_rounded,
                        size: 48,
                        color: LibraryTheme.mutedText,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
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
                          size: 24,
                        ),
                        tooltip: 'Play album',
                        onPressed: () => _playAlbum(albumSongs),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              albumName,
              style: LibraryTheme.rowPrimary.copyWith(
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              artist,
              style: LibraryTheme.rowSecondary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text('$trackCount tracks', style: LibraryTheme.metadata),
          ],
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
                Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    color: LibraryTheme.raisedSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: LibraryTheme.border),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.album_rounded,
                      size: 64,
                      color: LibraryTheme.mutedText,
                    ),
                  ),
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
                        '${sortedTracks.length} tracks • ${_formatDuration(totalDuration)}',
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
                            onPressed: () => _playAlbum(sortedTracks),
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
          const Divider(height: 1, color: LibraryTheme.border),
          // Tracklist
          Expanded(child: _buildSongTableView(sortedTracks)),
        ],
      ),
    );
  }

  // --- Artists View ---

  Widget _buildArtistsGridView(List<MediaItemRecord> songs) {
    final Map<String, List<MediaItemRecord>> artistsMap = {};
    for (final song in songs) {
      artistsMap.putIfAbsent(song.artist, () => []).add(song);
    }

    final artists = artistsMap.keys.toList()..sort();

    return GridView.builder(
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
        childAspectRatio: 0.88,
      ),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final artistName = artists[index];
        final artistSongs = artistsMap[artistName]!;
        final albumCount = artistSongs.map((s) => s.album).toSet().length;

        return InkWell(
          onTap: () {
            setState(() {
              _selectedArtist = artistName;
              _artistSongs = null;
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
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: const BoxDecoration(
                    color: LibraryTheme.raisedSurface,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.person_rounded,
                      size: 40,
                      color: LibraryTheme.accent,
                    ),
                  ),
                ),
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
                  '${artistSongs.length} songs • $albumCount albums',
                  style: LibraryTheme.metadata,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
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
                Container(
                  width: 100,
                  height: 100,
                  decoration: const BoxDecoration(
                    color: LibraryTheme.raisedSurface,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.person_rounded,
                      size: 50,
                      color: LibraryTheme.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(artistName, style: LibraryTheme.pageTitle),
                      const SizedBox(height: 6),
                      Text(
                        '${songs.length} songs in library',
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
                        onPressed: () => _playSongCollection(songs, 0),
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
          Expanded(child: _buildSongTableView(songs)),
        ],
      ),
    );
  }
}
