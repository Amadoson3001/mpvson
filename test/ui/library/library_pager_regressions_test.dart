import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/library/views/music_view.dart';
import 'package:mpvson/ui/library/views/videos_view.dart';
import 'package:mpvson/ui/player/player_controller.dart';

import '../../support/library_view_fixtures.dart';

/// Library rows per page. Matches `kLibraryBrowsePageSize` in the app.
const int _pageSize = 80;

MediaItemRecord _song({
  required String id,
  required String title,
  String artist = 'Test Artist',
  String album = 'Test Album',
  bool isFavorite = false,
}) {
  return makeLibraryRecord(
    id: id,
    path: r'C:\media\' + id + r'.mp3',
    kind: MediaKind.audio,
    title: title,
    artist: artist,
    album: album,
  ).copyWith(isFavorite: isFavorite);
}

MediaItemRecord _video(String id, String title) {
  return makeLibraryRecord(
    id: id,
    path: r'C:\media\' + id + r'.mp4',
    kind: MediaKind.video,
    title: title,
  );
}

void main() {
  late Directory tempDir;
  late FakePlaybackService playback;
  late SessionRepository sessions;
  late PlayerController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mpvson_pager_regression_');
    playback = FakePlaybackService();
    sessions = SessionRepository(directory: tempDir);
    controller = PlayerController(playback: playback, sessions: sessions);
  });

  tearDown(() async {
    await controller.close(discard: true, force: true);
    await playback.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  FakeMediaLibraryRepository repositoryWith(
    List<MediaItemRecord> items, {
    List<String> albums = const <String>[],
    List<String> artists = const <String>[],
  }) {
    return FakeMediaLibraryRepository(
      items: items,
      albums: albums,
      artists: artists,
    );
  }

  Future<void> openMusic(
    WidgetTester tester,
    FakeMediaLibraryRepository repository, {
    String? searchQuery,
  }) async {
    await tester.pumpWidget(
      buildLibraryTestApp(
        controller: controller,
        home: MusicView(
          repository: repository,
          controller: controller,
          searchQuery: searchQuery,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openVideos(
    WidgetTester tester,
    FakeMediaLibraryRepository repository, {
    String? searchQuery,
  }) async {
    await tester.pumpWidget(
      buildLibraryTestApp(
        controller: controller,
        home: VideosView(
          repository: repository,
          controller: controller,
          searchQuery: searchQuery,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Pumps a frame without waiting for loading to finish, so a deliberately
  /// held query stays open.
  Future<void> pumpFrame(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// Pumps a bounded number of frames so pending microtasks and one rebuild
  /// land without waiting for an idle tree.
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  ScrollController browseScrollController(WidgetTester tester) {
    final scrollable = tester.widget<Scrollable>(find.byType(Scrollable).first);
    return scrollable.controller!;
  }

  /// Asks the browse list for another page by scrolling to its end.
  ///
  /// A drag would fling and fire the scroll listener on many frames, which asks
  /// for more than one page. The back-off and the return to the end happen in
  /// the same frame, so the listener always sees a change but only the first
  /// notification can start a page: the rest arrive while one is in flight.
  ///
  /// Frames are pumped a bounded number of times rather than settled, because a
  /// scroll to the end of a virtualized list can keep scheduling work.
  Future<void> requestNextPage(WidgetTester tester) async {
    final controller = browseScrollController(tester);
    final extent = controller.position.maxScrollExtent;
    controller.jumpTo((extent - 200).clamp(0.0, extent));
    controller.jumpTo(extent);
    await pumpFrames(tester);
  }

  /// Scrolls the browse list back to its first rows.
  Future<void> scrollToTop(WidgetTester tester) async {
    browseScrollController(tester).jumpTo(0);
    await pumpFrames(tester);
  }

  group('Music row removal', () {
    testWidgets(
      'removing a song drops only that row while the refresh is held',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final repository = repositoryWith(<MediaItemRecord>[
          _song(id: 'a', title: 'Alpha Track'),
          _song(id: 'b', title: 'Bravo Track'),
          _song(id: 'c', title: 'Charlie Track'),
        ]);

        await openMusic(tester, repository);
        expect(find.text('Bravo Track'), findsOneWidget);

        // Hold the refresh the delete triggers so the local update is the only
        // thing that can have removed the row.
        final gate = Completer<void>();
        repository.queryGate = gate;

        await tester.tap(
          find.text('Bravo Track'),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await pumpAfterIo(tester);
        await tester.tap(find.text('Remove'));
        await pumpFrame(tester);

        expect(repository.deletedMediaIds, ['b']);
        expect(find.text('Bravo Track'), findsNothing);
        expect(find.text('Alpha Track'), findsOneWidget);
        expect(find.text('Charlie Track'), findsOneWidget);

        await releaseGate(tester, gate);
        await tester.pumpAndSettle();
        expect(find.text('Bravo Track'), findsNothing);
        expect(find.text('Alpha Track'), findsOneWidget);
        expect(find.text('Charlie Track'), findsOneWidget);
      },
    );

    testWidgets('removing the selected song clears only that selection', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _song(id: 'a', title: 'Alpha Track'),
        _song(id: 'b', title: 'Bravo Track'),
        _song(id: 'c', title: 'Charlie Track'),
      ]);

      await openMusic(tester, repository);
      await tester.tap(find.text('Bravo Track'));
      await tester.pumpAndSettle();

      final gate = Completer<void>();
      repository.queryGate = gate;

      await tester.tap(
        find.text('Bravo Track'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await pumpAfterIo(tester);
      await tester.tap(find.text('Remove'));
      await pumpFrame(tester);

      expect(find.text('Bravo Track'), findsNothing);
      expect(find.text('Alpha Track'), findsOneWidget);
      expect(find.text('Charlie Track'), findsOneWidget);

      await releaseGate(tester, gate);
      await tester.pumpAndSettle();
    });
  });

  group('Music album and artist detail', () {
    testWidgets(
      'album detail updates favorite and removal before the refresh',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final repository = repositoryWith(
          <MediaItemRecord>[_song(id: 'a', title: 'Alpha Track')],
          albums: <String>['Test Album'],
        );

        await openMusic(tester, repository);
        await tester.tap(find.text('Albums'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Test Album'));
        await tester.pumpAndSettle();
        expect(find.text('Alpha Track'), findsOneWidget);
        expect(find.byTooltip('Add to favorites'), findsOneWidget);

        final gate = Completer<void>();
        repository.queryGate = gate;

        await tester.tap(find.byTooltip('Add to favorites'));
        await pumpFrame(tester);
        expect(repository.favoriteToggles, [('a', true)]);
        expect(find.byTooltip('Remove favorite'), findsOneWidget);

        await releaseGate(tester, gate);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Remove favorite'), findsOneWidget);
      },
    );

    testWidgets('album detail removal drops the row before the refresh', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(
        <MediaItemRecord>[
          _song(id: 'a', title: 'Alpha Track'),
          _song(id: 'b', title: 'Bravo Track'),
        ],
        albums: <String>['Test Album'],
      );

      await openMusic(tester, repository);
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Album'));
      await tester.pumpAndSettle();
      expect(find.text('Bravo Track'), findsOneWidget);

      final gate = Completer<void>();
      repository.queryGate = gate;

      await tester.tap(
        find.text('Bravo Track'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await pumpAfterIo(tester);
      await tester.tap(find.text('Remove'));
      await pumpFrame(tester);

      expect(find.text('Bravo Track'), findsNothing);
      expect(find.text('Alpha Track'), findsOneWidget);

      await releaseGate(tester, gate);
      await tester.pumpAndSettle();
    });

    testWidgets('artist detail favorite updates through the overflow menu', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(
        <MediaItemRecord>[_song(id: 'a', title: 'Alpha Track')],
        artists: <String>['Test Artist'],
      );

      await openMusic(tester, repository);
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Artist'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha Track'), findsOneWidget);

      final gate = Completer<void>();
      repository.queryGate = gate;

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favorite'));
      await pumpFrame(tester);

      expect(repository.favoriteToggles, [('a', true)]);
      expect(find.byTooltip('Remove favorite'), findsOneWidget);

      await releaseGate(tester, gate);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove favorite'), findsOneWidget);
    });
  });

  group('Failed queries offer a retry', () {
    testWidgets('Music shows the error state and recovers on retry', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _song(id: 'a', title: 'Alpha Track'),
      ]);
      repository.failQueryCalls.add(1);

      await openMusic(tester, repository);

      expect(tester.takeException(), isNull);
      expect(find.text("Couldn't load music"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Alpha Track'), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text("Couldn't load music"), findsNothing);
      expect(find.text('Alpha Track'), findsOneWidget);
    });

    testWidgets('Videos shows the error state and recovers on retry', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _video('a', 'Alpha Video'),
      ]);
      repository.failQueryCalls.add(1);

      await openVideos(tester, repository);

      expect(tester.takeException(), isNull);
      expect(find.text("Couldn't load videos"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Alpha Video'), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text("Couldn't load videos"), findsNothing);
      expect(find.text('Alpha Video'), findsOneWidget);
    });

    testWidgets(
      'a successful query with no results still shows the empty state',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final repository = repositoryWith(<MediaItemRecord>[]);

        await openVideos(tester, repository);

        expect(find.text('No videos found'), findsOneWidget);
        expect(find.text("Couldn't load videos"), findsNothing);
      },
    );
  });

  group('A failed later page keeps the loaded rows', () {
    testWidgets('Videos keeps its rows and retries at the same offset', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        // Two pages plus a remainder, so a failed page can be retried without
        // the list running out of results.
        for (var i = 0; i < _pageSize * 2 + 4; i++) _video('v$i', 'Video $i'),
      ]);

      await openVideos(tester, repository);
      expect(find.text('Video 0'), findsOneWidget);
      expect(repository.queryCallCount, 1);
      expect(repository.queryOffsets, [0]);
      final firstPageExtent = browseScrollController(
        tester,
      ).position.maxScrollExtent;

      // The second page fails. The rows already loaded stay on screen, the
      // footer clears, and the offset is left where it was.
      repository.failQueryCalls.add(2);
      await requestNextPage(tester);

      expect(tester.takeException(), isNull);
      expect(repository.queryOffsets, [0, _pageSize]);
      // Nothing from the failed page reached the list, so it is exactly as long
      // as it was and the first rows are still there.
      expect(
        browseScrollController(tester).position.maxScrollExtent,
        firstPageExtent,
      );
      await scrollToTop(tester);
      expect(find.text('Video 0'), findsOneWidget);

      // Retrying asks for the same offset and appends the page once.
      await requestNextPage(tester);

      expect(repository.queryOffsets, [0, _pageSize, _pageSize]);
      // The appended page grew the list.
      expect(
        browseScrollController(tester).position.maxScrollExtent,
        greaterThan(firstPageExtent),
      );
      await scrollToTop(tester);
      expect(find.text('Video 0'), findsOneWidget);
    });
  });

  group('A background refresh keeps the list on screen', () {
    testWidgets('Videos keeps its rows and toolbar while the refresh runs', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _video('a', 'Alpha Video'),
        _video('b', 'Bravo Video'),
      ]);

      await openVideos(tester, repository);
      expect(find.byTooltip('Descending'), findsOneWidget);

      final gate = Completer<void>();
      repository.queryGate = gate;
      repository.notifyListeners();
      await pumpFrame(tester);

      // The rows and the toolbar stay mounted while the replacement is open.
      expect(find.text('Alpha Video'), findsOneWidget);
      expect(find.text('Bravo Video'), findsOneWidget);
      expect(find.byTooltip('Descending'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await releaseGate(tester, gate);
      await tester.pumpAndSettle();
      expect(find.text('Alpha Video'), findsOneWidget);
      expect(find.text('Bravo Video'), findsOneWidget);
    });

    testWidgets('Music keeps its rows while the refresh runs', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _song(id: 'a', title: 'Alpha Track'),
        _song(id: 'b', title: 'Bravo Track'),
      ]);

      await openMusic(tester, repository);

      final gate = Completer<void>();
      repository.queryGate = gate;
      repository.notifyListeners();
      await pumpFrame(tester);

      expect(find.text('Alpha Track'), findsOneWidget);
      expect(find.text('Bravo Track'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await releaseGate(tester, gate);
      await tester.pumpAndSettle();
      expect(find.text('Alpha Track'), findsOneWidget);
      expect(find.text('Bravo Track'), findsOneWidget);
    });

    testWidgets('a refresh that fails keeps the last good rows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _video('a', 'Alpha Video'),
      ]);

      await openVideos(tester, repository);
      repository.failQueryCalls.add(2);

      repository.notifyListeners();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Alpha Video'), findsOneWidget);
    });

    testWidgets('repeated notifications coalesce into one refresh', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _video('a', 'Alpha Video'),
      ]);

      await openVideos(tester, repository);
      expect(repository.queryCallCount, 1);

      // All three notifications arrive while the first refresh is still open.
      // They coalesce into the drain's single rerun, not three reloads.
      final gate = Completer<void>();
      repository.queryGate = gate;
      repository.notifyListeners();
      repository.notifyListeners();
      repository.notifyListeners();
      await pumpFrame(tester);
      expect(repository.queryCallCount, 2);

      await releaseGate(tester, gate);
      await tester.pumpAndSettle();

      // The rerun for the latest state, and only one of it however many
      // notifications arrived.
      expect(repository.queryCallCount, 3);
      expect(find.text('Alpha Video'), findsOneWidget);
    });
  });

  group('Only the newest query may publish', () {
    testWidgets('a superseded first page never displays under the new query', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _song(id: 'a', title: 'Alpha Track'),
        _song(id: 'b', title: 'Bravo Track'),
      ]);

      await openMusic(tester, repository);

      // Search A is held open.
      final gateA = Completer<void>();
      repository.queryGate = gateA;
      await tester.pumpWidget(
        buildLibraryTestApp(
          controller: controller,
          home: MusicView(
            repository: repository,
            controller: controller,
            searchQuery: 'alpha',
          ),
        ),
      );
      await pumpFrame(tester);
      expect(repository.queryCallCount, 2);

      // Search B replaces it while A is still in flight.
      final gateB = Completer<void>();
      repository.queryGate = gateB;
      await tester.pumpWidget(
        buildLibraryTestApp(
          controller: controller,
          home: MusicView(
            repository: repository,
            controller: controller,
            searchQuery: 'bravo',
          ),
        ),
      );
      await pumpFrame(tester);

      // A resolves after B was requested: its rows must not appear.
      await releaseGate(tester, gateA);
      await pumpFrame(tester);
      expect(find.text('Alpha Track'), findsNothing);

      await releaseGate(tester, gateB);
      await tester.pumpAndSettle();
      expect(find.text('Bravo Track'), findsOneWidget);
      expect(find.text('Alpha Track'), findsNothing);
    });

    testWidgets('a superseded append never lands under the new query', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        for (var i = 0; i < _pageSize + 4; i++) _video('v$i', 'Video $i'),
      ]);

      await openVideos(tester, repository);
      expect(find.text('Video 0'), findsOneWidget);

      // Hold the next page open, then scroll to ask for it.
      final gatePage = Completer<void>();
      repository.queryGate = gatePage;
      await requestNextPage(tester);
      expect(repository.queryOffsets, [0, _pageSize]);

      // A new query starts while the append is in flight.
      final gateSearch = Completer<void>();
      repository.queryGate = gateSearch;
      await tester.pumpWidget(
        buildLibraryTestApp(
          controller: controller,
          home: VideosView(
            repository: repository,
            controller: controller,
            searchQuery: 'Video 1',
          ),
        ),
      );
      await pumpFrame(tester);

      await releaseGate(tester, gatePage);
      await pumpFrame(tester);
      // The held page must not append beneath the new query's rows.
      expect(find.text('Video $_pageSize'), findsNothing);

      await releaseGate(tester, gateSearch);
      await tester.pumpAndSettle();
      expect(find.text('Video $_pageSize'), findsNothing);
    });

    testWidgets('closing the view during a pending request is safe', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = repositoryWith(<MediaItemRecord>[
        _video('a', 'Alpha Video'),
      ]);

      await openVideos(tester, repository);

      final gate = Completer<void>();
      repository.queryGate = gate;
      repository.notifyListeners();
      await pumpFrame(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      await releaseGate(tester, gate);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
