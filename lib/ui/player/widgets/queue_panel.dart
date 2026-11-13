import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_thumbnail.dart';
import '../../../utils/format.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_dialog.dart';
import '../../core/toast/app_toast.dart';
import '../../core/components/playback_pulse.dart';
import '../player_controller.dart';

/// How long a row spends collapsing before the queue drops it.
const Duration _queueRemovalDuration = Duration(milliseconds: 150);

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

  /// Rows currently collapsing out, keyed by entry id so a queue that changes
  /// mid-animation can never remove the wrong item.
  final _removingIds = <String>{};
  Timer? _scrollDebounceTimer;
  String _query = '';
  QueueSnapshot? _cachedFilterSnapshot;
  String? _cachedFilterQuery;
  List<(int, MediaEntry)> _cachedVisible = const <(int, MediaEntry)>[];

  List<(int, MediaEntry)> _visibleFor(QueueSnapshot snapshot) {
    if (identical(_cachedFilterSnapshot, snapshot) &&
        _cachedFilterQuery == _query) {
      return _cachedVisible;
    }
    _cachedFilterSnapshot = snapshot;
    _cachedFilterQuery = _query;
    _cachedVisible = snapshot.filterIndexed(_query);
    return _cachedVisible;
  }

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
        final visible = _visibleFor(snapshot);

        return Container(
          decoration: BoxDecoration(
            color: context.palette.surface,
            border: Border(left: BorderSide(color: context.palette.border)),
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
                          const Icon(Icons.queue_music_rounded, size: 20),
                          const SizedBox(width: 8),
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
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScrollNotification,
                  child: _QueueScrollScope(
                    isScrolling: _isScrollingNotifier,
                    child: visible.isEmpty
                        ? _buildEmpty(context, queue.isNotEmpty)
                        : _buildList(context, snapshot, visible),
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

  Widget _buildEmpty(BuildContext context, bool hasQueue) => AnimatedSize(
    duration: AppMotion.duration(context, AppMotion.quick),
    curve: AppMotion.standardCurve,
    alignment: Alignment.topCenter,
    child: _QueueEmpty(
      hasQueue: hasQueue,
      onClearSearch: _query.isNotEmpty ? _clearSearch : null,
    ),
  );

  Widget _buildList(
    BuildContext context,
    QueueSnapshot snapshot,
    List<(int, MediaEntry)> visible,
  ) {
    // Reordering a filtered view would move rows the user cannot see, so search
    // drops the drag handles and keeps the true queue indices for playback.
    final reorderable = _query.isEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final thumbnailWidth = constraints.maxWidth < 332 ? 96.0 : 112.0;

        // One list widget for both modes: swapping list keys per keystroke
        // would rebuild every row and drop the scroll position.
        return ReorderableListView.builder(
          key: const PageStorageKey<String>('queue-list'),
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.symmetric(vertical: 3),
          itemCount: visible.length,
          proxyDecorator: _buildDragProxy,
          onReorderItem: (oldIndex, newIndex) =>
              unawaited(widget.controller.reorder(oldIndex, newIndex)),
          itemBuilder: (context, visibleIndex) => _buildEntry(
            snapshot: snapshot,
            visible: visible,
            visibleIndex: visibleIndex,
            thumbnailWidth: thumbnailWidth,
            canReorder: reorderable,
          ),
        );
      },
    );
  }

  Widget _buildEntry({
    required QueueSnapshot snapshot,
    required List<(int, MediaEntry)> visible,
    required int visibleIndex,
    required double thumbnailWidth,
    required bool canReorder,
  }) {
    final (index, entry) = visible[visibleIndex];
    final isCurrent = index == snapshot.currentIndex;
    return _QueueRemovalCollapse(
      key: ValueKey('queue-${entry.id}'),
      removing: _removingIds.contains(entry.id),
      child: isCurrent
          ? ValueListenableBuilder<TransportState>(
              valueListenable: widget.controller.transportListenable,
              builder: (context, transport, _) => _QueueEntry(
                controller: widget.controller,
                entry: entry,
                index: index,
                queueLength: snapshot.entries.length,
                thumbnailWidth: thumbnailWidth,
                isCurrent: true,
                isPlaying: transport.isPlaying,
                canReorder: canReorder,
                onFocusChanged: (focused) =>
                    widget.onQueueFocus(focused ? entry.id : null),
                onPlay: () => unawaited(widget.controller.playIndex(index)),
                onRemove: () => unawaited(_remove(index)),
              ),
            )
          : _QueueEntry(
              controller: widget.controller,
              entry: entry,
              index: index,
              queueLength: snapshot.entries.length,
              thumbnailWidth: thumbnailWidth,
              isCurrent: false,
              isPlaying: false,
              canReorder: canReorder,
              onFocusChanged: (focused) =>
                  widget.onQueueFocus(focused ? entry.id : null),
              onPlay: () => unawaited(widget.controller.playIndex(index)),
              onRemove: () => unawaited(_remove(index)),
            ),
    );
  }

  /// Lifts the dragged row off the list instead of sliding it around flat.
  Widget _buildDragProxy(
    Widget child,
    int index,
    Animation<double> animation,
  ) => AnimatedBuilder(
    animation: animation,
    builder: (context, _) => Material(
      color: context.palette.raisedSurface,
      borderRadius: BorderRadius.circular(AppRadii.control),
      clipBehavior: Clip.antiAlias,
      elevation: 10 * Curves.easeOut.transform(animation.value),
      child: child,
    ),
  );

  /// Collapses the row first so the entries below travel into place instead of
  /// jumping, then removes whatever still carries that id.
  Future<void> _remove(int index) async {
    final entries = widget.controller.queueSnapshot.entries;
    if (index < 0 || index >= entries.length) return;
    final id = entries[index].id;
    if (!_removingIds.add(id)) return;
    widget.onQueueFocus(null);
    setState(() {});

    final collapse = AppMotion.reduce(context)
        ? Duration.zero
        : _queueRemovalDuration;
    await Future<void>.delayed(collapse);
    if (!mounted) return;
    setState(() => _removingIds.remove(id));

    final target = widget.controller.queueSnapshot.entries.indexWhere(
      (entry) => entry.id == id,
    );
    if (target < 0) return;
    try {
      await widget.controller.removeAt(target);
      if (!mounted) return;
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
    final confirmed = await AppDialog.show<bool>(
      context: context,
      builder: (context) => AppDialog(
        maxWidth: 420,
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
    label: '$count ${count == 1 ? 'item' : 'items'} in queue',
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
          color: context.palette.card,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(
            color: context.palette.border.withValues(alpha: 0.72),
          ),
        ),
        child: Text(
          '$count',
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
  );
}

/// Publishes the queue's scroll state without making every row a dependent.
///
/// Rows read this through [InheritedWidget.dependOnInheritedWidgetOfExactType]
/// but only the ones that actually deferred a thumbnail subscribe to the
/// notifier, so a scroll gesture no longer rebuilds the whole visible list.
class _QueueScrollScope extends InheritedWidget {
  const _QueueScrollScope({required this.isScrolling, required super.child});

  final ValueListenable<bool> isScrolling;

  static ValueListenable<bool>? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_QueueScrollScope>()
      ?.isScrolling;

  @override
  bool updateShouldNotify(covariant _QueueScrollScope oldWidget) =>
      oldWidget.isScrolling != isScrolling;
}

/// Collapses a row out of the list before the queue drops it, so the rows below
/// travel up into place instead of teleporting.
class _QueueRemovalCollapse extends StatefulWidget {
  const _QueueRemovalCollapse({
    super.key,
    required this.removing,
    required this.child,
  });

  final bool removing;
  final Widget child;

  @override
  State<_QueueRemovalCollapse> createState() => _QueueRemovalCollapseState();
}

class _QueueRemovalCollapseState extends State<_QueueRemovalCollapse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = AppMotion.reduce(context)
        ? Duration.zero
        : _queueRemovalDuration;
    if (widget.removing && _controller.isDismissed) _controller.forward();
  }

  @override
  void didUpdateWidget(covariant _QueueRemovalCollapse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.removing == oldWidget.removing) return;
    if (widget.removing) {
      _controller.forward();
    } else {
      // An undo or a queue rewrite can put the row back mid-collapse.
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.removing && _controller.isDismissed) return widget.child;

    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final progress = AppMotion.exit.transform(_controller.value);
        if (progress == 0) {
          return IgnorePointer(ignoring: widget.removing, child: child);
        }
        return IgnorePointer(
          ignoring: widget.removing,
          child: Transform.translate(
            offset: Offset(progress * 20, 0),
            child: ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: (1 - progress).clamp(0.0, 1.0),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _QueueEntry extends StatefulWidget {
  const _QueueEntry({
    required this.controller,
    required this.entry,
    required this.index,
    required this.queueLength,
    required this.thumbnailWidth,
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
  final double thumbnailWidth;
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
  ValueListenable<bool>? _scrollScope;
  bool _scrollSubscribed = false;

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
        _unsubscribeScroll();
        _requestThumbnail();
        setState(() {});
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = _QueueScrollScope.of(context);
    if (!identical(scope, _scrollScope)) {
      _unsubscribeScroll();
      _scrollScope = scope;
      if (_isDeferred) _subscribeScroll();
    }
    if (_thumbnailFuture == null) _initThumbnail();
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
      _isDeferred = false;
      _unsubscribeScroll();
      _lastResolvedThumbnail = widget.controller.peekThumbnail(widget.entry);
      _initThumbnail();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unsubscribeScroll();
    _thumbnailRequestGeneration++;
    _thumbnailHandle?.release();
    _thumbnailHandle = null;
    super.dispose();
  }

  void _subscribeScroll() {
    final scope = _scrollScope;
    if (scope == null || _scrollSubscribed) return;
    scope.addListener(_handleScrollSettled);
    _scrollSubscribed = true;
  }

  void _unsubscribeScroll() {
    if (!_scrollSubscribed) return;
    _scrollScope?.removeListener(_handleScrollSettled);
    _scrollSubscribed = false;
  }

  void _handleScrollSettled() {
    if (!_isDeferred || (_scrollScope?.value ?? false)) return;
    _isDeferred = false;
    _unsubscribeScroll();
    // Resuming after a scroll is housekeeping, not the work the user is
    // looking at, so it must not outrank the rows being revealed now.
    _requestThumbnail(priority: ThumbnailPriority.normal);
    if (mounted) setState(() {});
  }

  void _initThumbnail() {
    _lastResolvedThumbnail = widget.controller.peekThumbnail(widget.entry);
    if (_scrollScope?.value ?? false) {
      _isDeferred = true;
      _thumbnailFuture = null;
      _subscribeScroll();
    } else {
      _isDeferred = false;
      _requestThumbnail();
    }
  }

  void _requestThumbnail({
    ThumbnailPriority priority = ThumbnailPriority.high,
  }) {
    _thumbnailHandle?.release();
    final generation = ++_thumbnailRequestGeneration;
    final entry = widget.entry;
    final controller = widget.controller;
    _lastResolvedThumbnail ??= controller.peekThumbnail(entry);
    final handle = widget.controller.requestThumbnail(
      entry,
      priority: priority,
    );
    _thumbnailHandle = handle;
    final future =
        (handle?.thumbnail ??
                _loadFallbackThumbnail(entry, controller, priority))
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
    ThumbnailPriority priority,
  ) async {
    try {
      return await controller.loadThumbnail(entry, priority: priority);
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final duration = entry.duration > Duration.zero
        ? entry.duration
        : Duration.zero;

    final semanticsLabel =
        '${entry.title}, track ${widget.index + 1} of ${widget.queueLength}'
        '${widget.isCurrent && widget.isPlaying ? ', currently playing' : ''}'
        '${widget.isCurrent && !widget.isPlaying ? ', current item' : ''}'
        '${duration > Duration.zero ? ', ${formatTime(duration)}' : ''}';

    final reorderActions = <CustomSemanticsAction, VoidCallback>{
      if (widget.canReorder && widget.index > 0)
        const CustomSemanticsAction(label: 'Move up'): _moveUp,
      if (widget.canReorder && widget.index < widget.queueLength - 1)
        const CustomSemanticsAction(label: 'Move down'): _moveDown,
    };

    final thumbnailWidth = widget.thumbnailWidth;
    final thumbnailHeight = thumbnailWidth * 9 / 16;
    final active = _hovered || _focused;
    final background = widget.isCurrent
        ? Color.alphaBlend(accent.withValues(alpha: 0.1), palette.surface)
        : active
        ? palette.hover
        : Colors.transparent;
    final motion = AppMotion.duration(context, AppMotion.hover);

    return Focus(
      onFocusChange: (focused) {
        if (_focused != focused) setState(() => _focused = focused);
        widget.onFocusChanged(focused);
      },
      child: CallbackShortcuts(
        // Scoped to this row's focus so the shortcut cannot reach another row,
        // and kept in the tree in both modes so the subtree shape stays stable
        // while the search field is being typed into.
        bindings: widget.canReorder
            ? <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
                    _moveUp,
                const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
                    _moveDown,
              }
            : const <ShortcutActivator, VoidCallback>{},
        child: Semantics(
          selected: widget.isCurrent,
          label: semanticsLabel,
          container: true,
          customSemanticsActions: reorderActions.isEmpty
              ? null
              : reorderActions,
          child: MouseRegion(
            onEnter: (_) {
              if (!_hovered) setState(() => _hovered = true);
            },
            onExit: (_) {
              if (_hovered) setState(() => _hovered = false);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.xxs,
                vertical: 1,
              ),
              child: AnimatedContainer(
                duration: motion,
                curve: AppMotion.standardCurve,
                constraints: BoxConstraints(
                  minHeight: thumbnailHeight + AppSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: AnimatedOpacity(
                            opacity: widget.isCurrent ? 1 : 0,
                            duration: motion,
                            curve: AppMotion.standardCurve,
                            child: Container(
                              width: 3,
                              height: thumbnailHeight,
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(
                                  AppRadii.pill,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: widget.onPlay,
                        borderRadius: BorderRadius.circular(AppRadii.control),
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpace.xxs),
                          child: Row(
                            children: [
                              _buildDragHandle(context, active, motion),
                              _QueueThumbnail(
                                entry: entry,
                                future: _thumbnailFuture,
                                provisional: _lastResolvedThumbnail,
                                width: thumbnailWidth,
                                height: thumbnailHeight,
                                selected: widget.isCurrent,
                                playing: widget.isCurrent && widget.isPlaying,
                                pulseIndex: widget.index,
                              ),
                              const SizedBox(width: AppSpace.sm - 2),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            color: widget.isCurrent
                                                ? palette.text
                                                : palette.secondaryText,
                                            fontSize: AppType.body,
                                            fontWeight: widget.isCurrent
                                                ? FontWeight.w700
                                                : FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: 2),
                                    Tooltip(
                                      message: entry.path,
                                      child: Text(
                                        entry.path,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: palette.muted,
                                              fontSize: AppType.caption,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _buildRemoveButton(
                                context,
                                active,
                                motion,
                                entry,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [PlayerController.reorder] takes final positions, so a one-step nudge is
  /// just the neighbouring index; the downward-drag convention of
  /// [ReorderableListView] deliberately does not apply.
  void _moveUp() {
    if (!widget.canReorder || widget.index <= 0) return;
    unawaited(widget.controller.reorder(widget.index, widget.index - 1));
  }

  void _moveDown() {
    if (!widget.canReorder || widget.index >= widget.queueLength - 1) return;
    unawaited(widget.controller.reorder(widget.index, widget.index + 1));
  }

  /// The grip lives in the row flow, not on top of the artwork, and search
  /// results keep the slot empty so rows never shift when the user types.
  Widget _buildDragHandle(BuildContext context, bool active, Duration motion) {
    const width = 18.0;
    if (!widget.canReorder) return const SizedBox(width: width);

    return Tooltip(
      message: 'Drag to reorder (Alt+↑/↓)',
      child: ExcludeSemantics(
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: ReorderableDragStartListener(
            index: widget.index,
            enabled: true,
            child: SizedBox(
              width: width,
              height: 40,
              child: Center(
                child: AnimatedOpacity(
                  opacity: active ? 1 : 0,
                  duration: motion,
                  curve: AppMotion.standardCurve,
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    size: 15,
                    color: context.palette.muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Row actions stay out of the way until the pointer or the keyboard asks for
  /// them, which keeps a long queue readable.
  Widget _buildRemoveButton(
    BuildContext context,
    bool active,
    Duration motion,
    MediaEntry entry,
  ) {
    final palette = context.palette;
    bool engaged(Set<WidgetState> states) =>
        states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.pressed) ||
        states.contains(WidgetState.focused);

    return IgnorePointer(
      ignoring: !active,
      child: AnimatedOpacity(
        opacity: active ? 1 : 0,
        duration: motion,
        curve: AppMotion.standardCurve,
        child: IconButton(
          tooltip: 'Remove ${entry.title} from queue',
          onPressed: widget.onRemove,
          style:
              IconButton.styleFrom(
                minimumSize: const Size(30, 30),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ).copyWith(
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => engaged(states) ? palette.danger : palette.muted,
                ),
                overlayColor: WidgetStateProperty.resolveWith(
                  (states) => engaged(states)
                      ? palette.danger.withValues(alpha: 0.12)
                      : Colors.transparent,
                ),
              ),
          icon: const Icon(Icons.close_rounded, size: 16),
        ),
      ),
    );
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
    required this.playing,
    required this.pulseIndex,
  });

  final MediaEntry entry;
  final Future<MediaThumbnail?>? future;
  final MediaThumbnail? provisional;
  final double width;
  final double height;
  final bool selected;
  final bool playing;
  final int pulseIndex;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;

    return FutureBuilder<MediaThumbnail?>(
      future: future,
      builder: (context, snapshot) {
        final thumbnail = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : provisional;
        final duration = entry.duration > Duration.zero
            ? entry.duration
            : (thumbnail?.duration ?? Duration.zero);
        final imageIsAvailable =
            thumbnail != null && thumbnail.bytes.isNotEmpty;

        final ratio =
            MediaQuery.maybeDevicePixelRatioOf(context) ??
            View.of(context).devicePixelRatio;
        final targetWidth = (width * ratio).round().clamp(1, 320);
        final targetHeight = (height * ratio).round().clamp(1, 320);

        return AnimatedContainer(
          width: width,
          height: height,
          duration: AppMotion.duration(context, AppMotion.hover),
          curve: AppMotion.standardCurve,
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(AppRadii.control),
            // Constant width so selecting a row cannot nudge the artwork by a
            // pixel; only the colour travels.
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.75)
                  : palette.border.withValues(alpha: 0.5),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.control - 1),
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
                                _placeholder(context, 'error'),
                          ),
                        )
                      : _placeholder(
                          context,
                          snapshot.hasError ? 'error' : 'empty',
                        ),
                ),
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: _badge(context, duration),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// One fixed-size corner badge: the live equalizer while the row plays, the
  /// runtime otherwise. Swapping contents rather than adding a glyph keeps the
  /// row from relayouting every time playback starts or stops.
  Widget _badge(BuildContext context, Duration duration) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.stage.withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(AppRadii.control - 2),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: SizedBox(
        height: 18,
        child: Center(
          child: playing
              ? PlayingEqualizerGlyph(
                  index: pulseIndex,
                  size: 12,
                  color: AppColors.onStage,
                  semanticLabel: 'Now playing',
                )
              : Text(
                  duration > Duration.zero ? formatTime(duration) : '--:--',
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.onStage,
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
      ),
    ),
  );

  Widget _placeholder(BuildContext context, String state) => ColoredBox(
    key: ValueKey<String>('queue-placeholder-${entry.id}-$state'),
    color: context.palette.deepBackground,
    child: Center(
      child: Icon(
        Icons.movie_outlined,
        size: 23,
        color: context.palette.muted.withValues(alpha: 0.75),
      ),
    ),
  );
}

class _QueueEmpty extends StatelessWidget {
  const _QueueEmpty({required this.hasQueue, this.onClearSearch});

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
            color: context.palette.muted,
            size: 26,
          ),
          const SizedBox(height: 10),
          Text(
            hasQueue ? 'No matches' : 'Queue is empty',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.palette.secondaryText,
            ),
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
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: context.palette.border)),
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
              foregroundColor: context.palette.secondaryText,
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
                  return context.palette.danger;
                }
                return context.palette.secondaryText;
              }),
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed)) {
                  return context.palette.danger.withValues(alpha: 0.1);
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
