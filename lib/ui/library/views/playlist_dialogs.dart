part of 'playlists_view.dart';

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
  final ScrollController _scrollController = ScrollController();
  Set<String> _existingIds = <String>{};
  late final MediaPager _pager;
  String _activeSearch = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _pager = MediaPager(
      // Rows already in the playlist are dropped after the page arrives, so the
      // offset still advances by the unfiltered page length.
      filter: (item) => !_existingIds.contains(item.id),
      fetch: (offset) => fetchMediaPage(
        widget.repository,
        offset: offset,
        searchQuery: _activeSearch.isEmpty ? null : _activeSearch,
        sortBy: 'title',
      ),
      onChanged: () {
        if (mounted) setState(() {});
      },
      onError: (error) =>
          diagnosticDebug('playlists.addFromLibrary', error: error),
    );
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
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels <
        kLibraryBrowseScrollPrefetch) {
      unawaited(_pager.loadMore());
    }
  }

  Future<void> _bootstrap() async {
    try {
      final currentEntries = await widget.repository.getPlaylistEntries(
        widget.playlist.id,
      );
      _existingIds = currentEntries.map((e) => e.mediaId).toSet();
    } catch (error) {
      diagnosticDebug('playlists.addFromLibrary', error: error);
      if (mounted) setState(() {});
      return;
    }
    await _loadFirstPage();
  }

  /// Loads the first page, keeping a failed query from escaping as an unhandled
  /// error.
  ///
  /// The pager reports a first-page failure by throwing, and both entry points
  /// here start one unawaited. Loading settles in the pager's own completion
  /// path, so this only has to record the failure.
  Future<void> _loadFirstPage() async {
    try {
      await _pager.loadFirst();
    } catch (error) {
      diagnosticDebug('playlists.addFromLibrary', error: error);
      if (mounted) setState(() {});
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(kLibrarySearchDebounce, () {
      if (!mounted) return;
      final trimmed = value.trim();
      if (trimmed == _activeSearch) return;
      _activeSearch = trimmed;
      unawaited(_loadFirstPage());
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
              child: _pager.isLoading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _pager.items.isEmpty
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
                      itemCount:
                          _pager.items.length + (_pager.isLoadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= _pager.items.length) {
                          return const Padding(
                            padding: EdgeInsets.all(AppSpace.md),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        final item = _pager.items[index];
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
