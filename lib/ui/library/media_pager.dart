import '../../domain/models/library_models.dart';
import 'paged_media_loader.dart';

/// Owns one browse list's paging lifecycle: the page offset, whether a page is
/// in flight, whether more results exist, and rejection of results that a
/// newer request superseded.
///
/// Views keep their own widget state (selection, scroll position, subtab,
/// search) and drive the pager from there: [loadFirst] when the query changes,
/// [loadMore] from a scroll listener, [clear] for queries that do not page.
/// The pager never touches widget state; it reports every observable change
/// through [onChanged] so the host can rebuild.
///
/// Stale results are rejected by request id rather than by an epoch owned
/// elsewhere: every [loadFirst] and [clear] starts a new request, and an
/// in-flight fetch that is no longer the current request drops its result.
class MediaPager {
  MediaPager({required this.fetch, this.onChanged, this.onError, this.filter});

  /// Loads one page starting at [offset].
  final Future<PagedMediaBatch> Function(int offset) fetch;

  /// Called after any observable change so the host can rebuild.
  final void Function()? onChanged;

  /// Called when a page fails to load.
  final void Function(Object error)? onError;

  /// Drops rows the host does not display, e.g. items already in a playlist.
  /// The page offset still advances by the unfiltered page length.
  final bool Function(MediaItemRecord item)? filter;

  final List<MediaItemRecord> _items = <MediaItemRecord>[];
  int _offset = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasLoaded = false;
  int _request = 0;

  /// Rows loaded so far. Do not mutate; use [patchItems] and [removeWhere].
  List<MediaItemRecord> get items => _items;

  /// Rows loaded for the current query, or null before the first page lands.
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

  /// Loads the first page of the current query, replacing any loaded rows.
  Future<void> loadFirst() async {
    beginQuery();
    await _load(append: false);
  }

  /// Loads the next page and appends it. Ignored while the first page is in
  /// flight, while another page is in flight, or when [hasMore] is false.
  Future<void> loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    _loadingMore = true;
    _notify();
    await _load(append: true);
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

  void _startRequest() {
    _request++;
    _offset = 0;
    _hasMore = false;
    _items.clear();
    _loading = false;
    _loadingMore = false;
    _hasLoaded = false;
  }

  Future<void> _load({required bool append}) async {
    final request = _request;
    try {
      final batch = await fetch(_offset);
      if (request != _request) return;
      final predicate = filter;
      final page = predicate == null
          ? batch.items
          : batch.items.where(predicate).toList();
      if (!append) _items.clear();
      _items.addAll(page);
      _offset += batch.items.length;
      _hasMore = batch.hasMore;
    } catch (error) {
      if (request != _request) return;
      onError?.call(error);
    } finally {
      if (request == _request) {
        _loading = false;
        _loadingMore = false;
        _hasLoaded = true;
        _notify();
      }
    }
  }

  void _notify() => onChanged?.call();
}
