part of 'playlists_view.dart';

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
      target: LibraryItemTarget.fromRecord(item),
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
