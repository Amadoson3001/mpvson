import '../../domain/models/library_models.dart';
import 'paged_media_loader.dart';

/// Owns one browse list's paging lifecycle: the page offset, whether a page is
/// in flight, whether more results exist, and rejection of results that a
/// newer request superseded.
///
/// Views keep their own widget state (selection, scroll position, subtab,
/// search) and drive the pager from there: [loadFirst] for a new query,
/// [refresh] for the same query, [loadMore] from a scroll listener, and
/// [clear] for queries that do not page. The pager never touches widget state;
/// it reports every observable change through [onChanged] so the host can
/// rebuild.
///
/// A first-page failure propagates to the caller so the host can route it to
/// its error state and retry action. A later-page failure stays local to
/// pagination: the rows already on screen and the offset they ended at are
/// left alone so the same page can be tried again.
class MediaPager {
  MediaPager({
    required this.fetch,
    this.onChanged,
    this.onError,
    this.filter,
    this.isCurrent,
  });

  /// Loads one page starting at [offset].
  final Future<PagedMediaBatch> Function(int offset) fetch;

  /// Called after any observable change so the host can rebuild.
  final void Function()? onChanged;

  /// Called when a page beyond the first fails to load.
  final void Function(Object error)? onError;

  /// Drops rows the host does not display, e.g. items already in a playlist.
  /// The page offset still advances by the unfiltered page length.
  final bool Function(MediaItemRecord item)? filter;

  /// Whether the host still wants the request that is about to publish.
  ///
  /// Checked after the fetch resolves and before any row or error is
  /// published. The pager's own request id only advances when the pager starts
  /// a request, but a host that serializes reloads elsewhere — see
  /// [LibraryReloadCoordinator], which advances its epoch as soon as it queues
  /// a newer reload — has already moved on by then. Without this check a
  /// superseded request would publish its rows before the host could discard
  /// them.
  final bool Function()? isCurrent;

  final List<MediaItemRecord> _items = <MediaItemRecord>[];
  int _offset = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasLoaded = false;
  int _request = 0;

  /// Rows loaded so far. Do not mutate; use [patchItems] and [removeWhere].
  List<MediaItemRecord> get items => _items;

  /// Offset the next appended page starts at. Counts rows the repository
  /// returned, not rows the host displays, so a [filter] cannot desynchronize
  /// it from the query.
  int get offset => _offset;

  /// Whether the repository reported another page after the last one loaded.
  bool get hasMore => _hasMore;

  /// Whether the first page of the current query is in flight.
  bool get isLoading => _loading;

  /// Whether a page beyond the first is in flight.
  bool get isLoadingMore => _loadingMore;

  /// Whether the first page of the current query has landed or failed, so a
  /// host can tell "still loading the first page" from "nothing matched".
  bool get hasLoaded => _hasLoaded;

  /// Starts a new query: clears loaded rows and reports [isLoading] until the
  /// first page arrives.
  void beginQuery() {
    _startRequest();
    _loading = true;
    _notify();
  }

  /// Clears loaded rows for a query the host pages itself (a grid of album or
  /// artist summaries, for instance) so no page is left in flight.
  void clear() {
    _startRequest();
    _notify();
  }

  /// Loads the first page of a new query, replacing any loaded rows and
  /// reporting [isLoading] until it arrives.
  ///
  /// Throws when the first page fails so the host can show its error state.
  Future<void> loadFirst() async {
    beginQuery();
    await _load(fetchOffset: 0, append: false, replaceRows: true);
  }

  /// Reloads the first page of the same query without dropping the rows
  /// already on screen.
  ///
  /// A repository notification re-runs the query the user is looking at, and a
  /// refresh that takes longer than a frame must not replace a populated list
  /// with a spinner or hide its toolbar. The rows stay mounted and scrollable
  /// until the replacement commits, and page requests are blocked while it runs
  /// so an append cannot interleave with the replacement.
  ///
  /// On success the replacement rows, the next offset and [hasMore] commit
  /// together. On failure the last good rows stay and the offset is left where
  /// it was, so a later append continues after them instead of re-reading the
  /// first page beneath them.
  Future<void> refresh() async {
    _startRequest(keepItems: true);
    _loading = true;
    _notify();
    await _load(fetchOffset: 0, append: false, replaceRows: true);
  }

  /// Loads the next page and appends it. Ignored while a page is in flight or
  /// when [hasMore] is false.
  ///
  /// A failure is reported through [onError] and leaves the loaded rows and the
  /// offset untouched, so the same page can be retried.
  Future<void> loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    _loadingMore = true;
    _notify();
    await _load(fetchOffset: _offset, append: true, replaceRows: false);
  }

  /// Applies [patch] to loaded rows in place, for favorite toggles.
  void patchItems(MediaItemRecord Function(MediaItemRecord item) patch) {
    for (var index = 0; index < _items.length; index++) {
      _items[index] = patch(_items[index]);
    }
    _notify();
  }

  /// Removes loaded rows matching [predicate], for deletions.
  void removeWhere(bool Function(MediaItemRecord item) predicate) {
    _items.removeWhere(predicate);
    _notify();
  }

  void _startRequest({bool keepItems = false}) {
    _request++;
    _hasMore = false;
    _loading = false;
    _loadingMore = false;
    if (keepItems) {
      // A refresh of the same query: the rows and the offset they ended at
      // stay until the replacement commits, so the host never drops to its
      // initial-loading state and a failed refresh cannot rewind the offset
      // beneath rows that are still on screen.
      return;
    }
    _items.clear();
    _offset = 0;
    _hasLoaded = false;
  }

  Future<void> _load({
    required int fetchOffset,
    required bool append,
    required bool replaceRows,
  }) async {
    final request = _request;
    try {
      final batch = await fetch(fetchOffset);
      if (!_stillCurrent(request)) return;
      final predicate = filter;
      final page = predicate == null
          ? batch.items
          : batch.items.where(predicate).toList();
      if (replaceRows) _items.clear();
      _items.addAll(page);
      _offset = append ? _offset + batch.items.length : batch.items.length;
      _hasMore = batch.hasMore;
    } catch (error) {
      if (!_stillCurrent(request)) return;
      if (append) {
        // Pagination's own failure: the rows on screen and the offset stay, and
        // the footer clears in the finally below so the page can be retried.
        onError?.call(error);
        return;
      }
      rethrow;
    } finally {
      if (_stillCurrent(request)) {
        _loading = false;
        _loadingMore = false;
        _hasLoaded = true;
        _notify();
      }
    }
  }

  /// Whether [request] is still the request whose result may be published.
  bool _stillCurrent(int request) =>
      request == _request && (isCurrent?.call() ?? true);

  void _notify() => onChanged?.call();
}
