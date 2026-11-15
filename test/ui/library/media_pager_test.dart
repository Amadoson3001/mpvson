import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/library/media_pager.dart';
import 'package:mpvson/ui/library/paged_media_loader.dart';

MediaItemRecord _item(String id) => MediaItemRecord(
  id: id,
  canonicalSource: 'file:///media/$id.mp3',
  path: 'C:/media/$id.mp3',
  kind: MediaKind.audio,
  addedAt: DateTime.utc(2026, 1, 1),
);

/// A repository page source that hands out fixed pages.
class _FakePages {
  _FakePages(this.pages);

  final List<List<MediaItemRecord>> pages;

  final List<int> requestedOffsets = <int>[];

  Future<PagedMediaBatch> call(int offset) {
    requestedOffsets.add(offset);
    final index = offset ~/ _pageSize;
    final page = index < pages.length
        ? pages[index]
        : const <MediaItemRecord>[];
    return Future.value(
      PagedMediaBatch(items: page, hasMore: index + 1 < pages.length),
    );
  }

  static const int _pageSize = 2;
}

void main() {
  group('MediaPager', () {
    test('loadFirst loads the first page and reports progress', () async {
      var changes = 0;
      final pages = _FakePages([
        [_item('a'), _item('b')],
        [_item('c'), _item('d')],
      ]);
      final pager = MediaPager(fetch: pages.call, onChanged: () => changes++);

      expect(pager.isLoading, isFalse);
      expect(pager.items, isEmpty);

      final pending = pager.loadFirst();
      expect(pager.isLoading, isTrue);
      expect(pager.isLoadingMore, isFalse);

      await pending;

      expect(pager.isLoading, isFalse);
      expect(pager.items.map((item) => item.id), ['a', 'b']);
      expect(pager.offset, 2);
      expect(pager.hasMore, isTrue);
      expect(pages.requestedOffsets, [0]);
      expect(changes, greaterThan(0));
    });

    test('loadMore appends the next page at the tracked offset', () async {
      final pages = _FakePages([
        [_item('a'), _item('b')],
        [_item('c'), _item('d')],
      ]);
      final pager = MediaPager(fetch: pages.call);

      await pager.loadFirst();
      await pager.loadMore();

      expect(pager.items.map((item) => item.id), ['a', 'b', 'c', 'd']);
      expect(pager.offset, 4);
      expect(pager.hasMore, isFalse);
      expect(pages.requestedOffsets, [0, 2]);
    });

    test('loadMore is ignored when no page remains', () async {
      final pages = _FakePages([
        [_item('a'), _item('b')],
      ]);
      final pager = MediaPager(fetch: pages.call);

      await pager.loadFirst();
      expect(pager.hasMore, isFalse);

      await pager.loadMore();

      expect(pages.requestedOffsets, [0]);
      expect(pager.items, hasLength(2));
    });

    test('a page that arrives after a new query started is dropped', () async {
      final gates = <Completer<void>>[];
      Future<PagedMediaBatch> fetch(int offset) {
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future.then(
          (_) =>
              PagedMediaBatch(items: [_item('stale-$offset')], hasMore: false),
        );
      }

      final pager = MediaPager(fetch: fetch);

      final first = pager.loadFirst();
      final second = pager.loadFirst();
      // Only the newest request may publish; the earlier one is superseded.
      gates.last.complete();
      await second;
      gates.first.complete();
      await first;

      expect(pager.items.map((item) => item.id), ['stale-0']);
      expect(gates, hasLength(2));
    });

    test('a page that arrives after clear is dropped', () async {
      final gate = Completer<PagedMediaBatch>();
      final pager = MediaPager(fetch: (_) => gate.future);

      final pending = pager.loadFirst();
      pager.clear();
      gate.complete(PagedMediaBatch(items: [_item('a')], hasMore: false));
      await pending;

      expect(pager.items, isEmpty);
      expect(pager.isLoading, isFalse);
    });

    test('a failing current page reports the error once', () async {
      final failure = StateError('probe failed');
      final reported = <Object>[];
      final pager = MediaPager(
        fetch: (_) => Future.error(failure),
        onError: reported.add,
      );

      await pager.loadFirst();

      expect(reported, [failure]);
      expect(pager.items, isEmpty);
      expect(pager.isLoading, isFalse);
    });

    test(
      'a page that fails after a new query started is not reported',
      () async {
        final reported = <Object>[];
        final gates = <Completer<void>>[];
        Future<PagedMediaBatch> fetch(int offset) {
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future.then(
            (_) => PagedMediaBatch(items: [_item('$offset')], hasMore: false),
          );
        }

        final pager = MediaPager(fetch: fetch, onError: reported.add);

        final first = pager.loadFirst();
        final second = pager.loadFirst();
        gates.first.completeError(StateError('late failure'));
        await first;
        gates.last.complete();
        await second;

        expect(reported, isEmpty);
        expect(pager.items.map((item) => item.id), ['0']);
      },
    );

    test('filter drops rows but still advances the offset', () async {
      final pages = _FakePages([
        [_item('keep'), _item('drop')],
        [_item('keep2'), _item('drop2')],
      ]);
      final pager = MediaPager(
        fetch: pages.call,
        filter: (item) => item.id.startsWith('keep'),
      );

      await pager.loadFirst();
      await pager.loadMore();

      expect(pager.items.map((item) => item.id), ['keep', 'keep2']);
      expect(pager.offset, 4);
      expect(pages.requestedOffsets, [0, 2]);
    });

    test('patchItems and removeWhere update loaded rows', () async {
      final pages = _FakePages([
        [_item('a'), _item('b')],
      ]);
      final pager = MediaPager(fetch: pages.call);
      await pager.loadFirst();

      pager.patchItems((item) => item.copyWith(isFavorite: true));
      expect(pager.items.every((item) => item.isFavorite), isTrue);

      pager.removeWhere((item) => item.id == 'a');
      expect(pager.items.map((item) => item.id), ['b']);
    });

    test('loadMore calls that overlap collapse into one page', () async {
      final pages = _FakePages([
        [_item('a'), _item('b')],
        [_item('c'), _item('d')],
        [_item('e'), _item('f')],
      ]);
      final pager = MediaPager(fetch: pages.call);

      await pager.loadFirst();
      await Future.wait<void>(<Future<void>>[
        pager.loadMore(),
        pager.loadMore(),
        pager.loadMore(),
      ]);
      await pager.loadMore();

      expect(pages.requestedOffsets, [0, 2, 4]);
      expect(pager.items, hasLength(6));
    });
  });
}
