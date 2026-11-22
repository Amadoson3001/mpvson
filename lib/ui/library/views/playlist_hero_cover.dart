part of 'playlists_view.dart';

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
                  child: RepaintBoundary(child: artwork),
                ),
                if (canPlay)
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _hovered ? 1.0 : 0.0,
                      duration: AppMotion.duration(context, AppMotion.hover),
                      curve: AppMotion.enter,
                      child: ColoredBox(
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
