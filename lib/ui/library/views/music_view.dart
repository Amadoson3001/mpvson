import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/media_entry.dart';
import '../../player/player_controller.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/media_tile.dart';
import '../../core/components/media_row.dart';
import '../../core/components/media_accent_scope.dart';
import '../../core/components/empty_state.dart';
import '../../core/components/playback_pulse.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/library_artwork.dart';

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
  String? _selectedSongPath;
  String? _selectedAlbum;
  String? _selectedAlbumArtist;
  String? _selectedArtist;
  List<MediaItemRecord>? _items;
  List<MediaItemRecord>? _albumTracks;
  List<MediaItemRecord>? _artistSongs;
  bool _isLoading = false;
  Future<void>? _reloadFuture;
  bool _reloadAgain = false;
  Timer? _reloadThrottle;
  Timer? _searchReload;
  String? _currentRowPath;
  bool _currentRowPlaying = false;

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_onRepoChanged);
    widget.controller.addListener(_onPlaybackChanged);
    _currentRowPath = widget.controller.current?.path;
    _currentRowPlaying = widget.controller.isPlaying;
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
      _searchReload?.cancel();
      _searchReload = Timer(const Duration(milliseconds: 150), () {
        _searchReload = null;
        if (mounted) _reload();
      });
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPlaybackChanged);
      widget.controller.addListener(_onPlaybackChanged);
    }
  }

  @override
  void dispose() {
    _reloadThrottle?.cancel();
    _searchReload?.cancel();
    widget.repository.removeListener(_onRepoChanged);
    widget.controller.removeListener(_onPlaybackChanged);
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

    final items = _items ?? const <MediaItemRecord>[];

    return Material(
      color: AppTheme.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Subtab Navigation Bar
          _buildSubtabHeader(),
          const Divider(height: 1, color: AppTheme.border),
          // Content stage
          Expanded(
            child: _isLoading && _items == null
                ? Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Theme.of(context).colorScheme.primary,
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

  void _changeSubtab(MusicSubtab tab) {
    setState(() {
      _currentSubtab = tab;
      _selectedAlbum = null;
      _selectedAlbumArtist = null;
      _selectedArtist = null;
      _items = null;
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
    final songsSelected =
        _currentSubtab != MusicSubtab.albums &&
        _currentSubtab != MusicSubtab.artists;
    return Container(
      color: AppTheme.surface,
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
                  _subtabButton('Songs', MusicSubtab.songs, songsSelected),
                  _subtabButton(
                    'Albums',
                    MusicSubtab.albums,
                    _currentSubtab == MusicSubtab.albums,
                  ),
                  _subtabButton(
                    'Artists',
                    MusicSubtab.artists,
                    _currentSubtab == MusicSubtab.artists,
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
                color: _currentSubtab == MusicSubtab.songs
                    ? AppTheme.secondaryText
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

  Widget _subtabButton(String title, MusicSubtab tab, bool selected) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: TextButton(
        onPressed: () => _changeSubtab(tab),
        style: TextButton.styleFrom(
          foregroundColor: selected ? accent : AppTheme.secondaryText,
          backgroundColor: selected
              ? accent.withValues(alpha: 0.10)
              : Colors.transparent,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          textStyle: TextStyle(
            fontSize: AppType.small,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
        child: Text(title),
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
    final query = widget.searchQuery?.trim();
    if (query != null && query.isNotEmpty) {
      return EmptyState(
        title: 'No music found',
        message: 'No songs matched "$query". Try a different search.',
        icon: Icons.search_off_rounded,
      );
    }
    switch (_currentSubtab) {
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

  Widget _buildSongTableView(List<MediaItemRecord> songs) {
    return ListView.separated(
      addAutomaticKeepAlives: false,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.md,
      ),
      itemCount: songs.length + 1, // header row + songs
      separatorBuilder: (_, index) => index == 0
          ? const Divider(height: 16, thickness: 1, color: AppTheme.border)
          : const Divider(height: 1, color: AppTheme.surface),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      child: Row(
        children: [
          const SizedBox(width: 36, child: Text('#', style: AppTheme.metadata)),
          const Expanded(
            flex: 4,
            child: Text('Title', style: AppTheme.metadata),
          ),
          const Expanded(
            flex: 3,
            child: Text('Album', style: AppTheme.metadata),
          ),
          const SizedBox(
            width: 70,
            child: Text(
              'Duration',
              style: AppTheme.metadata,
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
            color: isSelected ? AppTheme.hover : Colors.transparent,
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
                  hoverColor: AppTheme.hover,
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
                                      style: AppTheme.rowPrimary.copyWith(
                                        color: isUnavailable
                                            ? AppTheme.mutedText
                                            : isCurrent
                                            ? accent
                                            : AppTheme.primaryText,
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
                                        color: AppTheme.danger.withValues(
                                          alpha: 0.2,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          AppRadii.control,
                                        ),
                                      ),
                                      child: Text(
                                        'Missing',
                                        style: AppTheme.badge.copyWith(
                                          fontSize: AppType.caption,
                                          color: AppTheme.danger,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                song.artist,
                                style: AppTheme.rowSecondary,
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
                            style: AppTheme.rowSecondary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Duration
                        SizedBox(
                          width: 70,
                          child: Text(
                            _formatDuration(song.metadata.duration),
                            style: AppTheme.metadata.copyWith(
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
                    color: song.isFavorite ? accent : AppTheme.mutedText,
                  ),
                  tooltip: song.isFavorite
                      ? 'Remove favorite'
                      : 'Add to favorites',
                  onPressed: () => widget.repository.toggleFavorite(
                    song.id,
                    !song.isFavorite,
                  ),
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
      icon: const Icon(
        Icons.more_vert_rounded,
        size: 18,
        color: AppTheme.mutedText,
      ),
      tooltip: 'Actions',
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        side: const BorderSide(color: AppTheme.border),
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
          case 'add_playlist':
            final added = await AddToPlaylistDialog.show(
              context,
              widget.repository,
              song.id,
            );
            if (added && mounted) {
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
          PopupMenuItem(
            value: 'play_now',
            enabled: song.isAvailable,
            child: Row(
              children: [
                Icon(Icons.play_arrow_rounded, size: 18, color: accent),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Play now', style: AppTheme.rowPrimary),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'play_next',
            enabled: song.isAvailable,
            child: const Row(
              children: [
                Icon(
                  Icons.playlist_play_rounded,
                  size: 18,
                  color: AppTheme.secondaryText,
                ),
                SizedBox(width: 10),
                Expanded(child: Text('Play next', style: AppTheme.rowPrimary)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'add_queue',
            enabled: song.isAvailable,
            child: const Row(
              children: [
                Icon(
                  Icons.queue_music_rounded,
                  size: 18,
                  color: AppTheme.secondaryText,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Add to queue', style: AppTheme.rowPrimary),
                ),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'add_playlist',
            child: Row(
              children: [
                Icon(
                  Icons.playlist_add_rounded,
                  size: 18,
                  color: AppTheme.secondaryText,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Add to playlist', style: AppTheme.rowPrimary),
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
                  color: accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    song.isFavorite ? 'Remove favorite' : 'Favorite',
                    style: AppTheme.rowPrimary,
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
                  color: AppTheme.secondaryText,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Show in folder', style: AppTheme.rowPrimary),
                ),
              ],
            ),
          ),
        ];
      },
    );
  }

  // --- Albums View ---

  Widget _buildAlbumsGridView(List<MediaItemRecord> songs) {
    // Group songs by album
    final Map<(String, String), List<MediaItemRecord>> albumsMap = {};
    for (final song in songs) {
      albumsMap
          .putIfAbsent((
            song.album,
            song.metadata.effectiveAlbumArtist,
          ), () => [])
          .add(song);
    }

    final albums = albumsMap.keys.toList()
      ..sort((a, b) {
        final title = a.$1.toLowerCase().compareTo(b.$1.toLowerCase());
        return title != 0
            ? title
            : a.$2.toLowerCase().compareTo(b.$2.toLowerCase());
      });

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = (constraints.maxWidth - 2 * AppSpace.lg).clamp(
          0.0,
          double.infinity,
        );
        final columns = ((availableWidth + 20) / 220).ceil().clamp(2, 12);
        final tileWidth = (availableWidth - (columns - 1) * 20) / columns;
        final textHeight = MediaQuery.textScalerOf(context).scale(13) * 3.8;

        return GridView.builder(
          addAutomaticKeepAlives: false,
          padding: const EdgeInsets.all(AppSpace.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 24,
            crossAxisSpacing: 20,
            mainAxisExtent: tileWidth + textHeight + 14,
          ),
          itemCount: albums.length,
          itemBuilder: (context, index) {
            final key = albums[index];
            final albumName = key.$1;
            final albumSongs = albumsMap[key]!;
            final artist = key.$2;
            final trackCount = albumSongs.length;

            return _buildAlbumCard(albumName, artist, trackCount, albumSongs);
          },
        );
      },
    );
  }

  Widget _buildAlbumCard(
    String albumName,
    String artist,
    int trackCount,
    List<MediaItemRecord> albumSongs,
  ) {
    return MediaTile(
      artwork: LibraryArtwork(
        path: albumSongs.first.metadata.artworkUri,
        mediaPath: albumSongs.first.path,
        repository: widget.repository,
      ),
      title: albumName,
      subtitle: artist,
      onTap: () {
        setState(() {
          _selectedAlbum = albumName;
          _selectedAlbumArtist = artist;
          _albumTracks = null;
        });
        _reload();
      },
      overlay: FilledButton.tonal(
        onPressed: () => _playAlbum(albumSongs),
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(40, 40),
        ),
        child: const Icon(Icons.play_arrow_rounded),
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
      backgroundColor: AppTheme.background,
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
                  color: AppTheme.secondaryText,
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
                Text('Albums', style: AppTheme.rowSecondary),
                const SizedBox(width: 6),
                const Text('›', style: AppTheme.metadata),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    albumName,
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
                    color: AppTheme.raisedSurface,
                    borderRadius: BorderRadius.circular(AppRadii.artwork),
                    border: Border.all(color: AppTheme.border),
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
                        style: AppTheme.albumTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.sectionTitle.copyWith(
                          color: AppTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${sortedTracks.length} tracks • ${_formatDuration(totalDuration)}',
                        style: AppTheme.metadata,
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
                            onPressed: () => _playAlbum(sortedTracks),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text(
                              'Play album',
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
          const Divider(height: 1, color: AppTheme.border),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = (constraints.maxWidth - 2 * AppSpace.lg).clamp(
          0.0,
          double.infinity,
        );
        final columns = ((availableWidth + 20) / 200).ceil().clamp(2, 12);
        final tileWidth = (availableWidth - (columns - 1) * 20) / columns;
        final textHeight = MediaQuery.textScalerOf(context).scale(13) * 3.8;

        return GridView.builder(
          addAutomaticKeepAlives: false,
          padding: const EdgeInsets.all(AppSpace.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 20,
            crossAxisSpacing: 20,
            mainAxisExtent: tileWidth + textHeight + 14,
          ),
          itemCount: artists.length,
          itemBuilder: (context, index) {
            final artistName = artists[index];
            final artistSongs = artistsMap[artistName]!;
            final albumCount = artistSongs.map((s) => s.album).toSet().length;

            return MediaTile(
              artwork: LibraryArtwork(
                path: artistSongs.first.metadata.artworkUri,
                mediaPath: artistSongs.first.path,
                repository: widget.repository,
                icon: Icons.person_rounded,
              ),
              title: artistName,
              subtitle: '${artistSongs.length} songs, $albumCount albums',
              onTap: () {
                setState(() {
                  _selectedArtist = artistName;
                  _artistSongs = null;
                });
                _reload();
              },
            );
          },
        );
      },
    );
  }

  // --- Artist Detail View (Drilldown) ---

  Widget _buildArtistDetailView(String artistName) {
    final songs = _artistSongs ?? const <MediaItemRecord>[];

    return Scaffold(
      backgroundColor: AppTheme.background,
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
                  color: AppTheme.secondaryText,
                  onPressed: () {
                    setState(() {
                      _selectedArtist = null;
                      _artistSongs = null;
                    });
                    _reload();
                  },
                ),
                const SizedBox(width: 8),
                Text('Artists', style: AppTheme.rowSecondary),
                const SizedBox(width: 6),
                const Text('›', style: AppTheme.metadata),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    artistName,
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
                        style: AppTheme.pageTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${songs.length} songs in library',
                        style: AppTheme.metadata,
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
          const Divider(height: 1, color: AppTheme.border),
          Expanded(child: _buildSongTableView(songs)),
        ],
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
      return PlayingEqualizerGlyph(index: index, size: 14, color: accent);
    }
    return Text(
      '${index + 1}',
      style: AppTheme.metadata.copyWith(
        color: isCurrent ? accent : AppTheme.mutedText,
      ),
    );
  }
}
