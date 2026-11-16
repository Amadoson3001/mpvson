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

      // A first-page failure belongs to the query, not to pagination, so it
      // propagates for the host's reload coordinator to route to its error
      // state instead of being reported here.
      await expectLater(pager.loadFirst(), throwsA(isA<StateError>()));

      expect(reported, isEmpty);
      expect(pager.items, isEmpty);
      expect(pager.isLoading, isFalse);
      expect(pager.hasLoaded, isTrue);
    });

    test(
      'a later-page failure is reported and leaves the rows and offset',
      () async {
        var calls = 0;
        final failure = StateError('page 2 failed');
        final reported = <Object>[];
        final pages = _FakePages([
          [_item('a'), _item('b')],
          [_item('c'), _item('d')],
          [_item('e'), _item('f')],
        ]);
        final pager = MediaPager(
          fetch: (offset) {
            calls++;
            // The first page loads; every later page fails.
            return calls == 1
                ? pages.call(offset)
                : Future<PagedMediaBatch>.error(failure);
          },
          onError: reported.add,
        );

        await pager.loadFirst();
        await pager.loadMore();

        expect(reported, [failure]);
        expect(pager.items.map((item) => item.id), ['a', 'b']);
        expect(pager.offset, 2);
        expect(pager.isLoadingMore, isFalse);
        expect(pager.hasMore, isTrue);

        // The failed page can be retried at the same offset.
        await pager.loadMore();
        expect(reported, [failure, failure]);
        expect(pager.items.map((item) => item.id), ['a', 'b']);
        expect(pager.offset, 2);
      },
    );

    test('refresh keeps the rows and rewinds nothing when it fails', () async {
      var calls = 0;
      final failure = StateError('refresh failed');
      final pages = _FakePages([
        [_item('a'), _item('b')],
        [_item('c'), _item('d')],
        [_item('e'), _item('f')],
      ]);
      final pager = MediaPager(
        fetch: (offset) {
          calls++;
          return calls == 1
              ? pages.call(offset)
              : Future<PagedMediaBatch>.error(failure);
        },
      );

      await pager.loadFirst();
      await expectLater(pager.refresh(), throwsA(isA<StateError>()));

      expect(pager.items.map((item) => item.id), ['a', 'b']);
      expect(pager.isLoading, isFalse);

      // The offset still points past the retained rows, so a later append
      // continues after them instead of re-reading the first page.
      await pager.loadMore();
      expect(pager.items.map((item) => item.id), ['a', 'b']);
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

    test(
      'refresh keeps the rows mounted and commits the replacement',
      () async {
        var changes = 0;
        final gates = <Completer<void>>[];
        final pages = <List<MediaItemRecord>>[
          [_item('a'), _item('b')],
          [_item('c'), _item('d')],
        ];
        var served = 0;
        Future<PagedMediaBatch> fetch(int offset) {
          final gate = Completer<void>();
          gates.add(gate);
          final page = pages[served.clamp(0, pages.length - 1)];
          served++;
          return gate.future.then(
            (_) => PagedMediaBatch(items: page, hasMore: false),
          );
        }

        final pager = MediaPager(fetch: fetch, onChanged: () => changes++);

        final loading = pager.loadFirst();
        gates.first.complete();
        await loading;
        expect(pager.items.map((item) => item.id), ['a', 'b']);

        final refreshing = pager.refresh();
        // The rows stay on screen and the host never drops to its loading state
        // while the replacement is in flight.
        expect(pager.items.map((item) => item.id), ['a', 'b']);
        expect(pager.hasLoaded, isTrue);
        expect(pager.isLoading, isTrue);

        gates.last.complete();
        await refreshing;

        expect(pager.items.map((item) => item.id), ['c', 'd']);
        expect(pager.offset, 2);
        expect(pager.isLoading, isFalse);
        expect(changes, greaterThan(1));
      },
    );

    test('refresh blocks a page request while it runs', () async {
      final gates = <Completer<void>>[];
      var served = 0;
      final pages = <List<MediaItemRecord>>[
        [_item('a'), _item('b')],
        [_item('c'), _item('d')],
        [_item('e'), _item('f')],
      ];
      Future<PagedMediaBatch> fetch(int offset) {
        final gate = Completer<void>();
        gates.add(gate);
        final page = pages[served.clamp(0, pages.length - 1)];
        served++;
        return gate.future.then(
          (_) => PagedMediaBatch(items: page, hasMore: true),
        );
      }

      final pager = MediaPager(fetch: fetch);

      final loading = pager.loadFirst();
      gates.first.complete();
      await loading;

      final refreshing = pager.refresh();
      // An append must not interleave with the replacement.
      final appended = pager.loadMore();
      expect(gates, hasLength(2));

      gates.last.complete();
      await refreshing;
      await appended;
      expect(gates, hasLength(2));

      // Once the replacement lands, paging continues from its offset.
      final next = pager.loadMore();
      expect(gates, hasLength(3));
      gates.last.complete();
      await next;
      expect(pager.items.map((item) => item.id), ['c', 'd', 'e', 'f']);
    });

    test('a request the host has moved on from publishes nothing', () async {
      var current = true;
      final gate = Completer<void>();
      final pager = MediaPager(
        fetch: (_) => gate.future.then(
          (_) => PagedMediaBatch(items: [_item('stale')], hasMore: false),
        ),
        isCurrent: () => current,
      );

      final pending = pager.loadFirst();
      // The host queued a newer reload, so this request may no longer publish.
      current = false;
      gate.complete();
      await pending;

      expect(pager.items, isEmpty);
      expect(pager.isLoading, isTrue);
    });

    test('a superseded page failure is not reported', () async {
      final reported = <Object>[];
      var current = true;
      final gates = <Completer<void>>[];
      var served = 0;
      Future<PagedMediaBatch> fetch(int offset) {
        final gate = Completer<void>();
        gates.add(gate);
        served++;
        if (served == 1) {
          return gate.future.then(
            (_) => PagedMediaBatch(items: [_item('a')], hasMore: true),
          );
        }
        return gate.future.then((_) => throw StateError('stale failure'));
      }

      final pager = MediaPager(
        fetch: fetch,
        onError: reported.add,
        isCurrent: () => current,
      );

      final loading = pager.loadFirst();
      gates.first.complete();
      await loading;

      final appending = pager.loadMore();
      current = false;
      gates.last.complete();
      await appending;

      expect(reported, isEmpty);
      expect(pager.items.map((item) => item.id), ['a']);
    });
  });
}
