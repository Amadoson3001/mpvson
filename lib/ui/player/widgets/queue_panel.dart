import 'dart:async';
import 'package:flutter/material.dart';

import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/playback_pulse.dart';
import '../player_controller.dart';

class QueuePanel extends StatefulWidget {
  const QueuePanel({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onQueueFocus,
    required this.onAddFiles,
  });

  final PlayerController controller;
  final VoidCallback onClose;
  final ValueChanged<String?> onQueueFocus;
  final VoidCallback onAddFiles;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final _searchController = TextEditingController();
  final _isScrollingNotifier = ValueNotifier<bool>(false);
  Timer? _scrollDebounceTimer;
  String _query = '';

  @override
  void dispose() {
    _scrollDebounceTimer?.cancel();
    _isScrollingNotifier.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0) {
      if (notification is ScrollStartNotification ||
          notification is ScrollUpdateNotification) {
        _scrollDebounceTimer?.cancel();
        if (!_isScrollingNotifier.value) {
          _isScrollingNotifier.value = true;
        }
        _scrollDebounceTimer = Timer(const Duration(milliseconds: 100), () {
          _isScrollingNotifier.value = false;
        });
      } else if (notification is ScrollEndNotification) {
        _scrollDebounceTimer?.cancel();
        _scrollDebounceTimer = Timer(const Duration(milliseconds: 100), () {
          _isScrollingNotifier.value = false;
        });
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<QueueSnapshot>(
      valueListenable: widget.controller.queueListenable,
      builder: (context, ignoredSnapshot, ignoredChild) {
        // Progress snapshots are refreshed internally without firing the
        // structural listenable on every tick. Read the latest immutable value
        // whenever this panel builds for a search, transport, or queue change.
        final snapshot = widget.controller.queueSnapshot;
        final queue = snapshot.entries;
        final visible = snapshot.filterIndexed(_query);

        return Container(
          decoration: const BoxDecoration(
            color: AppTheme.surface,
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.md,
                  10,
                  AppSpace.xs,
                  AppSpace.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Text(
                            'Queue',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(width: 9),
                          _QueueCount(count: queue.length),
                        ],
                      ),
                    ),
                    AnimatedBuilder(
                      animation: widget.controller,
                      builder: (context, _) => IconButton(
                        key: const ValueKey('queue-shuffle-toggle'),
                        tooltip: widget.controller.shuffle
                            ? 'Turn shuffle off'
                            : 'Turn shuffle on',
                        isSelected: widget.controller.shuffle,
                        onPressed: () =>
                            unawaited(widget.controller.toggleShuffle()),
                        icon: const Icon(Icons.shuffle_rounded, size: 19),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close queue',
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.sm,
                  0,
                  AppSpace.sm,
                  AppSpace.sm,
                ),
                child: TextField(
                  key: const ValueKey('queue-search'),
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search queue',
                    prefixIcon: const Icon(Icons.search_rounded, size: 19),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: _clearSearch,
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                    isDense: true,
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ValueListenableBuilder<TransportState>(
                  valueListenable: widget.controller.transportListenable,
                  builder: (context, transport, _) =>
                      NotificationListener<ScrollNotification>(
                        onNotification: _onScrollNotification,
                        child: _QueueScrollScope(
                          isScrolling: _isScrollingNotifier,
                          child: visible.isEmpty
                              ? AnimatedSize(
                                  duration: AppMotion.duration(
                                    context,
                                    AppMotion.quick,
                                  ),
                                  curve: AppMotion.standardCurve,
                                  alignment: Alignment.topCenter,
                                  child: AnimatedSwitcher(
                                    duration: AppMotion.duration(
                                      context,
                                      AppMotion.quick,
                                    ),
                                    child: _QueueEmpty(
                                      key: ValueKey<String>(
                                        '${queue.isNotEmpty}:${_query.isNotEmpty}',
                                      ),
                                      hasQueue: queue.isNotEmpty,
                                      onClearSearch: _query.isNotEmpty
                                          ? _clearSearch
                                          : null,
                                    ),
                                  ),
                                )
                              : _query.isNotEmpty
                              ? ListView.builder(
                                  key: const PageStorageKey<String>(
                                    'queue-list-filtered',
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 3,
                                  ),
                                  itemCount: visible.length,
                                  itemBuilder: (context, visibleIndex) {
                                    final (index, entry) =
                                        visible[visibleIndex];
                                    return _QueueEntry(
                                      key: ValueKey('queue-${entry.id}'),
                                      controller: widget.controller,
                                      entry: entry,
                                      index: index,
                                      queueLength: queue.length,
                                      isCurrent: index == snapshot.currentIndex,
                                      isPlaying: transport.isPlaying,
                                      canReorder: false,
                                      onFocusChanged: (focused) =>
                                          widget.onQueueFocus(
                                            focused ? entry.id : null,
                                          ),
                                      onPlay: () =>
                                          widget.controller.playIndex(index),
                                      onRemove: () => _remove(index),
                                    );
                                  },
                                )
                              : ReorderableListView.builder(
                                  key: const PageStorageKey<String>(
                                    'queue-list',
                                  ),
                                  buildDefaultDragHandles: false,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 3,
                                  ),
                                  itemCount: visible.length,
                                  onReorderItem: (oldIndex, newIndex) {
                                    // PlayerController follows the previous callback's destination convention.
                                    final controllerNewIndex =
                                        newIndex > oldIndex
                                        ? newIndex + 1
                                        : newIndex;
                                    unawaited(
                                      widget.controller.reorder(
                                        oldIndex,
                                        controllerNewIndex,
                                      ),
                                    );
                                  },
                                  itemBuilder: (context, visibleIndex) {
                                    final (index, entry) =
                                        visible[visibleIndex];
                                    return _QueueEntry(
                                      key: ValueKey('queue-${entry.id}'),
                                      controller: widget.controller,
                                      entry: entry,
                                      index: index,
                                      queueLength: queue.length,
                                      isCurrent: index == snapshot.currentIndex,
                                      isPlaying: transport.isPlaying,
                                      canReorder: true,
                                      onFocusChanged: (focused) =>
                                          widget.onQueueFocus(
                                            focused ? entry.id : null,
                                          ),
                                      onPlay: () =>
                                          widget.controller.playIndex(index),
                                      onRemove: () => _remove(index),
                                    );
                                  },
                                ),
                        ),
                      ),
                ),
              ),
              AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) => _QueueFooter(
                  canUndo: widget.controller.canUndo,
                  hasItems: queue.isNotEmpty,
                  onAddFiles: widget.onAddFiles,
                  onUndo: () => unawaited(widget.controller.undoRemove()),
                  onClear: () => _confirmClear(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  Future<void> _remove(int index) async {
    try {
      await widget.controller.removeAt(index);
      if (!mounted) return;
      widget.onQueueFocus(null);
      AppToast.show(
        context,
        'Removed from queue',
        actionLabel: 'Undo',
        onAction: () => unawaited(widget.controller.undoRemove()),
      );
    } catch (_) {
      if (mounted) {
        AppToast.show(
          context,
          'Could not remove this item from the queue.',
          tone: AppToastTone.danger,
        );
      }
    }
  }

  Future<void> _confirmClear(BuildContext context) async {
    if (widget.controller.queue.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the queue?'),
        content: const Text(
          'This only clears the playlist. Your video files stay on disk.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear queue'),
          ),
        ],
      ),
    );
    if (!context.mounted || confirmed != true) return;
    try {
      await widget.controller.clearQueue();
    } catch (_) {
      if (context.mounted) {
        AppToast.show(
          context,
          'Could not clear the queue.',
          tone: AppToastTone.danger,
        );
      }
    }
  }
}

class _QueueCount extends StatelessWidget {
  const _QueueCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$count ${count == 1 ? 'video' : 'videos'} in queue',
    container: true,
    excludeSemantics: true,
    child: AnimatedSize(
      duration: AppMotion.duration(context, AppMotion.quick),
      curve: AppMotion.standardCurve,
      child: Container(
        constraints: const BoxConstraints(minHeight: 26, minWidth: 28),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.xs,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: AppTheme.border.withValues(alpha: 0.72)),
        ),
        child: AnimatedSwitcher(
          duration: AppMotion.duration(context, AppMotion.quick),
          child: Text(
            '$count',
            key: ValueKey<int>(count),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    ),
  );
}

class _QueueScrollScope extends InheritedNotifier<ValueNotifier<bool>> {
  const _QueueScrollScope({
    required ValueNotifier<bool> isScrolling,
    required super.child,
  }) : super(notifier: isScrolling);

  static bool isScrolling(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_QueueScrollScope>();
    return scope?.notifier?.value ?? false;
  }
}

class _QueueEntry extends StatefulWidget {
  const _QueueEntry({
    super.key,
    required this.controller,
    required this.entry,
    required this.index,
    required this.queueLength,
    required this.isCurrent,
    required this.isPlaying,
    required this.canReorder,
    required this.onFocusChanged,
    required this.onPlay,
    required this.onRemove,
  });

  final PlayerController controller;
  final MediaEntry entry;
  final int index;
  final int queueLength;
  final bool isCurrent;
  final bool isPlaying;
  final bool canReorder;
  final ValueChanged<bool> onFocusChanged;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  State<_QueueEntry> createState() => _QueueEntryState();
}

class _QueueEntryState extends State<_QueueEntry> with WidgetsBindingObserver {
  ThumbnailRequestHandle? _thumbnailHandle;
  Future<MediaThumbnail?>? _thumbnailFuture;
  MediaThumbnail? _lastResolvedThumbnail;
  int _thumbnailRequestGeneration = 0;
  bool _isDeferred = false;
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_lastResolvedThumbnail == null && mounted) {
        _isDeferred = false;
        _requestThumbnail();
        setState(() {});
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_thumbnailFuture == null) {
      _initThumbnail();
    } else if (_isDeferred && !_QueueScrollScope.isScrolling(context)) {
      _isDeferred = false;
      _requestThumbnail();
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _QueueEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.controller != widget.controller) {
      _thumbnailRequestGeneration++;
      _thumbnailHandle?.release();
      _thumbnailHandle = null;
      _thumbnailFuture = null;
      _lastResolvedThumbnail = widget.controller.peekThumbnail(widget.entry);
      _initThumbnail();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _thumbnailRequestGeneration++;
    _thumbnailHandle?.release();
    _thumbnailHandle = null;
    super.dispose();
  }

  void _initThumbnail() {
    _lastResolvedThumbnail = widget.controller.peekThumbnail(widget.entry);
    if (_QueueScrollScope.isScrolling(context)) {
      _isDeferred = true;
      _thumbnailFuture = null;
    } else {
      _isDeferred = false;
      _requestThumbnail();
    }
  }

  void _requestThumbnail() {
    _thumbnailHandle?.release();
    final generation = ++_thumbnailRequestGeneration;
    final entry = widget.entry;
    final controller = widget.controller;
    _lastResolvedThumbnail ??= controller.peekThumbnail(entry);
    final handle = widget.controller.requestThumbnail(
      entry,
      priority: ThumbnailPriority.high,
    );
    _thumbnailHandle = handle;
    final future =
        (handle?.thumbnail ?? _loadFallbackThumbnail(entry, controller))
            .catchError((_) => null);
    _thumbnailFuture = future.then((thumb) {
      if (!mounted ||
          generation != _thumbnailRequestGeneration ||
          widget.controller != controller ||
          widget.entry.path != entry.path) {
        return null;
      }
      _lastResolvedThumbnail = thumb;
      return thumb;
    });
  }

  Future<MediaThumbnail?> _loadFallbackThumbnail(
    MediaEntry entry,
    PlayerController controller,
  ) async {
    try {
      return await controller.loadThumbnail(
        entry,
        priority: ThumbnailPriority.high,
      );
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final duration = entry.duration > Duration.zero
        ? entry.duration
        : Duration.zero;

    final semanticsLabel =
        '${entry.title}, track ${widget.index + 1} of ${widget.queueLength}'
        '${widget.isCurrent && widget.isPlaying ? ', currently playing' : ''}'
        '${widget.isCurrent && !widget.isPlaying ? ', current item' : ''}'
        '${duration > Duration.zero ? ', ${_formatTime(duration)}' : ''}';

    return Focus(
      onFocusChange: (focused) {
        if (_focused != focused) setState(() => _focused = focused);
        widget.onFocusChanged(focused);
      },
      child: Material(
        color: Colors.transparent,
        child: Semantics(
          selected: widget.isCurrent,
          label: semanticsLabel,
          container: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final thumbnailWidth = constraints.maxWidth < 332 ? 96.0 : 112.0;
              final thumbnailHeight = thumbnailWidth * 9 / 16;
              final dragHandleVisible =
                  widget.canReorder && (_hovered || _focused);

              return MouseRegion(
                onEnter: (_) {
                  if (!_hovered) setState(() => _hovered = true);
                },
                onExit: (_) {
                  if (_hovered) setState(() => _hovered = false);
                },
                child: AnimatedContainer(
                  constraints: BoxConstraints(minHeight: thumbnailHeight + 16),
                  duration: AppMotion.duration(context, AppMotion.quick),
                  curve: AppMotion.standardCurve,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xs,
                    AppSpace.xs,
                    AppSpace.xxs,
                    AppSpace.xs,
                  ),
                  decoration: BoxDecoration(
                    color: widget.isCurrent
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.022)
                        : Colors.transparent,
                    border: Border(
                      bottom: BorderSide(
                        color: AppTheme.border.withValues(alpha: 0.52),
                      ),
                    ),
                  ),
                  child: Stack(
                    children: [
                      InkWell(
                        onTap: widget.onPlay,
                        child: Row(
                          children: [
                            _QueueThumbnail(
                              entry: entry,
                              future: _thumbnailFuture,
                              provisional: _lastResolvedThumbnail,
                              width: thumbnailWidth,
                              height: thumbnailHeight,
                              selected: widget.isCurrent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.title,
                                    key: ValueKey('queue-title-${entry.id}'),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: widget.isCurrent
                                              ? AppTheme.text
                                              : AppTheme.secondaryText,
                                          fontSize: AppType.body,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(height: 3),
                                  Tooltip(
                                    message: entry.path,
                                    child: Text(
                                      entry.path,
                                      key: ValueKey('queue-path-${entry.id}'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: AppTheme.muted,
                                            fontSize: AppType.caption,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (widget.isCurrent && widget.isPlaying)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: PlayingEqualizerGlyph(
                                  index: widget.index,
                                  size: 14,
                                ),
                              ),
                            IconButton(
                              tooltip: 'Remove ${entry.title} from queue',
                              onPressed: widget.onRemove,
                              style: IconButton.styleFrom(
                                foregroundColor: AppTheme.muted,
                                minimumSize: const Size(44, 44),
                                padding: EdgeInsets.zero,
                              ),
                              icon: const Icon(Icons.close_rounded, size: 17),
                            ),
                          ],
                        ),
                      ),
                      if (widget.canReorder)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          child: Tooltip(
                            message: 'Drag to reorder',
                            child: Semantics(
                              button: true,
                              label: 'Drag to reorder',
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: ReorderableDragStartListener(
                                  key: ValueKey('queue-drag-${entry.id}'),
                                  index: widget.index,
                                  enabled: true,
                                  child: SizedBox(
                                    width: 22,
                                    height: 44,
                                    child: ColoredBox(
                                      color: Colors.transparent,
                                      child: Center(
                                        child: AnimatedOpacity(
                                          opacity: dragHandleVisible ? 1 : 0,
                                          duration: AppMotion.duration(
                                            context,
                                            AppMotion.quick,
                                          ),
                                          curve: AppMotion.standardCurve,
                                          child: const Icon(
                                            Icons.drag_indicator_rounded,
                                            size: 17,
                                            color: AppTheme.secondaryText,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static String _formatTime(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _QueueThumbnail extends StatelessWidget {
  const _QueueThumbnail({
    required this.entry,
    this.future,
    this.provisional,
    required this.width,
    required this.height,
    required this.selected,
  });

  final MediaEntry entry;
  final Future<MediaThumbnail?>? future;
  final MediaThumbnail? provisional;
  final double width;
  final double height;
  final bool selected;

  @override
  Widget build(BuildContext context) => FutureBuilder<MediaThumbnail?>(
    key: ValueKey<String>(
      'queue-thumbnail-validation-${entry.id}-${entry.path}',
    ),
    future: future,
    builder: (context, snapshot) {
      final thumbnail = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : provisional;
      final duration = entry.duration > Duration.zero
          ? entry.duration
          : (thumbnail?.duration ?? Duration.zero);
      final imageIsAvailable = thumbnail != null && thumbnail.bytes.isNotEmpty;

      final ratio =
          MediaQuery.maybeDevicePixelRatioOf(context) ??
          View.of(context).devicePixelRatio;
      final targetWidth = (width * ratio).round().clamp(1, 320);
      final targetHeight = (height * ratio).round().clamp(1, 320);

      return AnimatedContainer(
        key: ValueKey('queue-thumbnail-${entry.id}'),
        width: width,
        height: height,
        duration: AppMotion.duration(context, AppMotion.quick),
        curve: AppMotion.standardCurve,
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.88)
                : AppTheme.border.withValues(alpha: 0.72),
            width: selected ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: AppMotion.duration(context, AppMotion.quick),
                switchInCurve: AppMotion.enter,
                switchOutCurve: AppMotion.exit,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: imageIsAvailable
                    ? SizedBox.expand(
                        key: ValueKey<String>(
                          'queue-image-${entry.id}-${entry.path}',
                        ),
                        child: Image(
                          image: ResizeImage(
                            MemoryImage(thumbnail.bytes),
                            width: targetWidth,
                            height: targetHeight,
                            // The decode box is 16:9, but the artwork may not
                            // be. Fit preserves its aspect ratio before
                            // BoxFit.cover crops it into the frame.
                            policy: ResizeImagePolicy.fit,
                          ),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (context, error, stackTrace) =>
                              _placeholder('error'),
                        ),
                      )
                    : _placeholder(snapshot.hasError ? 'error' : 'empty'),
              ),
              if (duration > Duration.zero)
                Positioned(
                  right: 5,
                  bottom: 5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.stage.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      child: Text(
                        _QueueEntryState._formatTime(duration),
                        key: ValueKey('queue-duration-${entry.id}'),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppTheme.text,
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  Widget _placeholder(String state) => ColoredBox(
    key: ValueKey<String>('queue-placeholder-${entry.id}-$state'),
    color: AppTheme.deepBackground,
    child: Center(
      child: Icon(
        Icons.movie_outlined,
        size: 23,
        color: AppTheme.muted.withValues(alpha: 0.75),
      ),
    ),
  );
}

class _QueueEmpty extends StatelessWidget {
  const _QueueEmpty({super.key, required this.hasQueue, this.onClearSearch});

  final bool hasQueue;
  final VoidCallback? onClearSearch;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasQueue ? Icons.search_off_rounded : Icons.queue_play_next_rounded,
            color: AppTheme.muted,
            size: 26,
          ),
          const SizedBox(height: 10),
          Text(
            hasQueue ? 'No matches' : 'Queue is empty',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppTheme.secondaryText),
          ),
          if (hasQueue && onClearSearch != null) ...[
            const SizedBox(height: 4),
            TextButton(
              onPressed: onClearSearch,
              child: const Text('Clear search'),
            ),
          ],
          if (!hasQueue) ...[
            const SizedBox(height: 4),
            Text(
              'Add a video or drop one into the player.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    ),
  );
}

class _QueueFooter extends StatelessWidget {
  const _QueueFooter({
    required this.canUndo,
    required this.hasItems,
    required this.onAddFiles,
    required this.onUndo,
    required this.onClear,
  });

  final bool canUndo;
  final bool hasItems;
  final VoidCallback onAddFiles;
  final VoidCallback onUndo;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(AppSpace.xs, 5, AppSpace.xs, 5),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: AppTheme.border)),
    ),
    child: OverflowBar(
      alignment: MainAxisAlignment.spaceBetween,
      overflowAlignment: OverflowBarAlignment.end,
      spacing: 4,
      overflowSpacing: 2,
      children: [
        TextButton.icon(
          key: const ValueKey('queue-add-files'),
          onPressed: onAddFiles,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text(
            'Add files',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.primary,
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
        if (canUndo)
          TextButton.icon(
            onPressed: onUndo,
            icon: const Icon(Icons.undo_rounded, size: 17),
            label: const Text(
              'Undo',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.secondaryText,
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
            ),
          ),
        if (hasItems)
          TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.clear_all_rounded, size: 17),
            label: const Text(
              'Clear queue',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: AppSpace.xs),
              ),
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed)) {
                  return AppTheme.danger;
                }
                return AppTheme.secondaryText;
              }),
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed)) {
                  return AppTheme.danger.withValues(alpha: 0.1);
                }
                return Colors.transparent;
              }),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
              ),
              side: WidgetStateProperty.resolveWith((states) {
                return states.contains(WidgetState.focused)
                    ? BorderSide(color: Theme.of(context).colorScheme.primary)
                    : BorderSide.none;
              }),
            ),
          ),
      ],
    ),
  );
}
