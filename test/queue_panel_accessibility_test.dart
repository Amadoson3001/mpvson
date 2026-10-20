import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/domain/models/session_progress.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/widgets/queue_panel.dart';

void main() {
  const moveUp = CustomSemanticsAction(label: 'Move up');
  const moveDown = CustomSemanticsAction(label: 'Move down');
  const moveToStart = CustomSemanticsAction(label: 'Move to the start');
  const moveToEnd = CustomSemanticsAction(label: 'Move to the end');

  Map<CustomSemanticsAction, VoidCallback> getSemanticsActions(
    WidgetTester tester,
    Key itemKey,
  ) {
    final semanticsWidgets = find
        .ancestor(of: find.byKey(itemKey), matching: find.byType(Semantics))
        .evaluate()
        .map((element) => element.widget as Semantics);

    final actions = <CustomSemanticsAction, VoidCallback>{};
    for (final s in semanticsWidgets) {
      final custom = s.properties.customSemanticsActions;
      if (custom != null) {
        actions.addAll(custom);
      }
    }
    return actions;
  }

  Widget buildQueuePanel(PlayerController controller) {
    return MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: SizedBox(
          width: 352,
          height: 700,
          child: QueuePanel(
            controller: controller,
            onClose: () {},
            onQueueFocus: (_) {},
            onAddFiles: () {},
          ),
        ),
      ),
    );
  }

  // Queue mutations debounce a session save for two seconds. Let that timer
  // fire before the test binding checks for pending timers at teardown.
  Future<void> flushPendingSave(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  late _TestFixture fixture;

  setUp(() async {
    fixture = await _TestFixture.create();
  });

  tearDown(() async {
    await fixture.dispose();
  });

  testWidgets('queue exposes shuffle directly and keeps the current row', (
    tester,
  ) async {
    await tester.pumpWidget(buildQueuePanel(fixture.controller));
    await tester.pumpAndSettle();
    final currentId = fixture.controller.current?.id;
    final shuffleToggle = find.byKey(const ValueKey('queue-shuffle-toggle'));
    expect(shuffleToggle, findsOneWidget);

    await tester.tap(shuffleToggle);
    await tester.pumpAndSettle();

    expect(fixture.controller.shuffle, isTrue);
    expect(fixture.controller.current?.id, currentId);
    expect(find.byTooltip('Turn shuffle off'), findsOneWidget);
    await flushPendingSave(tester);
  });

  testWidgets(
    'unfiltered queue renders with ReorderableListView, drag handles, and working structure',
    (tester) async {
      await tester.pumpWidget(buildQueuePanel(fixture.controller));
      await tester.pumpAndSettle();

      // Renders with ReorderableListView
      expect(find.byType(ReorderableListView), findsOneWidget);
      expect(
        find.byKey(const PageStorageKey<String>('queue-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const PageStorageKey<String>('queue-list-filtered')),
        findsNothing,
      );

      // Drag handles are present for each item
      final firstDragHandle = find.byKey(
        const ValueKey('queue-drag-queue-alpha'),
      );
      final secondDragHandle = find.byKey(
        const ValueKey('queue-drag-queue-beta'),
      );
      final thirdDragHandle = find.byKey(
        const ValueKey('queue-drag-queue-gamma'),
      );

      expect(firstDragHandle, findsOneWidget);
      expect(secondDragHandle, findsOneWidget);
      expect(thirdDragHandle, findsOneWidget);

      // On mouse hover, drag handle opacity animates to visible (1.0)
      final firstEntryFinder = find.byKey(const ValueKey('queue-queue-alpha'));
      final hover = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      final firstEntryCenter = tester.getCenter(firstEntryFinder);
      await hover.addPointer(location: firstEntryCenter);
      await hover.moveTo(firstEntryCenter);
      await tester.pumpAndSettle();

      final dragHandleOpacity = find.descendant(
        of: firstDragHandle,
        matching: find.byType(AnimatedOpacity),
      );
      expect(dragHandleOpacity, findsOneWidget);
      expect(
        tester.widget<AnimatedOpacity>(dragHandleOpacity).opacity,
        equals(1.0),
      );
      await hover.removePointer();
    },
  );

  testWidgets(
    'unfiltered queue exposes semantic reordering with working upward and downward movement',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(buildQueuePanel(fixture.controller));
        await tester.pumpAndSettle();

        expect(fixture.controller.queue.map((e) => e.id).toList(), [
          'queue-alpha',
          'queue-beta',
          'queue-gamma',
        ]);

        // 1. Downward movement: Move first item ('queue-alpha') down
        Map<CustomSemanticsAction, VoidCallback> alphaActions =
            getSemanticsActions(tester, const ValueKey('queue-queue-alpha'));
        expect(alphaActions.containsKey(moveDown), isTrue);
        expect(alphaActions.containsKey(moveToEnd), isTrue);
        expect(alphaActions.containsKey(moveUp), isFalse);
        expect(alphaActions.containsKey(moveToStart), isFalse);

        // Execute downward movement
        alphaActions[moveDown]!();
        await tester.pumpAndSettle();

        // Queue order after moving 'queue-alpha' down: ['queue-beta', 'queue-alpha', 'queue-gamma']
        expect(fixture.controller.queue.map((e) => e.id).toList(), [
          'queue-beta',
          'queue-alpha',
          'queue-gamma',
        ]);

        // 2. Upward movement: Move 'queue-alpha' (now at index 1) back up
        alphaActions = getSemanticsActions(
          tester,
          const ValueKey('queue-queue-alpha'),
        );
        expect(alphaActions.containsKey(moveUp), isTrue);
        expect(alphaActions.containsKey(moveDown), isTrue);

        // Execute upward movement
        alphaActions[moveUp]!();
        await tester.pumpAndSettle();

        // Queue order restored to: ['queue-alpha', 'queue-beta', 'queue-gamma']
        expect(fixture.controller.queue.map((e) => e.id).toList(), [
          'queue-alpha',
          'queue-beta',
          'queue-gamma',
        ]);

        // 3. Upward movement from the bottom: Move 'queue-gamma' (index 2) up
        Map<CustomSemanticsAction, VoidCallback> gammaActions =
            getSemanticsActions(tester, const ValueKey('queue-queue-gamma'));
        expect(gammaActions.containsKey(moveUp), isTrue);
        expect(gammaActions.containsKey(moveToStart), isTrue);
        expect(gammaActions.containsKey(moveDown), isFalse);
        expect(gammaActions.containsKey(moveToEnd), isFalse);

        // Execute upward movement
        gammaActions[moveUp]!();
        await tester.pumpAndSettle();

        // Queue order after moving 'queue-gamma' up: ['queue-alpha', 'queue-gamma', 'queue-beta']
        expect(fixture.controller.queue.map((e) => e.id).toList(), [
          'queue-alpha',
          'queue-gamma',
          'queue-beta',
        ]);
        await flushPendingSave(tester);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'filtered search results render with ListView.builder and remove reorder semantics and drag handles',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(buildQueuePanel(fixture.controller));
        await tester.pumpAndSettle();

        // Type query to filter results
        final searchField = find.byKey(const ValueKey('queue-search'));
        expect(searchField, findsOneWidget);
        await tester.enterText(searchField, 'beta');
        await tester.pumpAndSettle();

        // Filtered results must render using a standard ListView (not ReorderableListView)
        expect(find.byType(ReorderableListView), findsNothing);
        expect(
          find.byKey(const PageStorageKey<String>('queue-list-filtered')),
          findsOneWidget,
        );
        expect(find.byType(ListView), findsOneWidget);

        // Beta is visible; alpha and gamma are filtered out
        expect(find.byKey(const ValueKey('queue-queue-beta')), findsOneWidget);
        expect(find.byKey(const ValueKey('queue-queue-alpha')), findsNothing);
        expect(find.byKey(const ValueKey('queue-queue-gamma')), findsNothing);

        // Drag handles must NOT be rendered in filtered mode
        expect(
          find.byKey(const ValueKey('queue-drag-queue-beta')),
          findsNothing,
        );

        // Reorder semantics (moveUp, moveDown, moveToStart, moveToEnd) must NOT be exposed
        final betaActions = getSemanticsActions(
          tester,
          const ValueKey('queue-queue-beta'),
        );
        expect(
          betaActions.containsKey(moveUp),
          isFalse,
          reason: 'Filtered items must not expose move up reorder action',
        );
        expect(
          betaActions.containsKey(moveDown),
          isFalse,
          reason: 'Filtered items must not expose move down reorder action',
        );
        expect(
          betaActions.containsKey(moveToStart),
          isFalse,
          reason: 'Filtered items must not expose move to start reorder action',
        );
        expect(
          betaActions.containsKey(moveToEnd),
          isFalse,
          reason: 'Filtered items must not expose move to end reorder action',
        );
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'clearing search restores ReorderableListView, drag handles, and functional semantic reordering',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(buildQueuePanel(fixture.controller));
        await tester.pumpAndSettle();

        // Enter search
        final searchField = find.byKey(const ValueKey('queue-search'));
        await tester.enterText(searchField, 'alpha');
        await tester.pumpAndSettle();

        expect(find.byType(ReorderableListView), findsNothing);
        expect(
          find.byKey(const PageStorageKey<String>('queue-list-filtered')),
          findsOneWidget,
        );

        // Clear search using the suffix icon button
        final clearButton = find.byTooltip('Clear search');
        expect(clearButton, findsOneWidget);
        await tester.tap(clearButton);
        await tester.pumpAndSettle();

        // ReorderableListView is restored
        expect(find.byType(ReorderableListView), findsOneWidget);
        expect(
          find.byKey(const PageStorageKey<String>('queue-list')),
          findsOneWidget,
        );
        expect(
          find.byKey(const PageStorageKey<String>('queue-list-filtered')),
          findsNothing,
        );

        // All drag handles are restored
        expect(
          find.byKey(const ValueKey('queue-drag-queue-alpha')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('queue-drag-queue-beta')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('queue-drag-queue-gamma')),
          findsOneWidget,
        );

        // Reorder semantics are functional again
        final alphaActions = getSemanticsActions(
          tester,
          const ValueKey('queue-queue-alpha'),
        );
        expect(alphaActions.containsKey(moveDown), isTrue);
        alphaActions[moveDown]!();
        await tester.pumpAndSettle();

        expect(fixture.controller.queue.map((e) => e.id).toList(), [
          'queue-beta',
          'queue-alpha',
          'queue-gamma',
        ]);
        await flushPendingSave(tester);
      } finally {
        handle.dispose();
      }
    },
  );
}

class _TestFixture {
  _TestFixture({
    required this.playback,
    required this.controller,
    required this.sessions,
  });

  final _FakePlaybackService playback;
  final PlayerController controller;
  final _MemorySessionRepository sessions;

  static Future<_TestFixture> create() async {
    final alpha = MediaEntry(
      id: 'queue-alpha',
      path: 'https://media.example/alpha.mp4',
      title: 'Alpha Video',
      lastPlayed: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final beta = MediaEntry(
      id: 'queue-beta',
      path: 'https://media.example/beta.mkv',
      title: 'Beta Movie',
      lastPlayed: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final gamma = MediaEntry(
      id: 'queue-gamma',
      path: 'https://media.example/gamma.mp4',
      title: 'Gamma Clip',
      lastPlayed: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final repository = _MemorySessionRepository()
      ..session = PlaybackSession(
        queue: [alpha, beta, gamma],
        recent: [],
        currentId: alpha.id,
        volume: 100,
        saveNetworkUrls: true,
      );

    final playback = _FakePlaybackService();
    final controller = PlayerController(
      playback: playback,
      sessions: repository,
    );
    await controller.initialize();

    return _TestFixture(
      playback: playback,
      controller: controller,
      sessions: repository,
    );
  }

  Future<void> dispose() async {
    await controller.close();
  }
}

class _MemorySessionRepository extends SessionRepository {
  PlaybackSession? session;
  SessionProgress? progress;

  @override
  Future<void> init() async {}

  @override
  Future<PlaybackSession?> load() async => session;

  @override
  Future<SessionLoadResult> loadDetailed() async =>
      SessionLoadResult(session: session);

  @override
  Future<void> save(PlaybackSession value) async => session = value;

  @override
  Future<void> saveScrubbed(PlaybackSession value) async => session = value;

  @override
  Future<SessionProgress?> loadProgress() async => progress;

  @override
  Future<void> saveProgress(SessionProgress value) async => progress = value;

  @override
  Future<void> scrubNetworkUrls() async {
    final current = session;
    if (current != null && current.hasNetworkEntries) {
      session = current.withoutNetworkUrls();
    }
    progress = const SessionProgress();
  }
}

class _FakePlaybackService implements PlaybackService {
  String? lastSubtitlePath;
  final StreamController<PlaybackSnapshot> _stream =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);
  PlaybackSnapshot _state = const PlaybackSnapshot(
    duration: Duration(minutes: 4),
  );
  int _sourceStart = 0;

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _stream.stream;

  @override
  String get engineVersion => 'libmpv test fake';

  @override
  Player get player =>
      throw StateError('The injected video builder skips libmpv.');

  @override
  VideoController get videoController =>
      throw StateError('The injected video builder skips libmpv.');

  VideoOutputPolicy _videoOutputPolicy = const VideoOutputPolicy();

  @override
  VideoOutputPolicy get videoOutputPolicy => _videoOutputPolicy;

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    _videoOutputPolicy = policy;
  }

  void _emit(PlaybackSnapshot state) {
    _state = state;
    _stream.add(state);
  }

  @override
  Future<void> prepare() async {}

  @override
  Future<void> open(String path, {bool play = true}) async {
    _sourceStart++;
    _emit(
      _state.copyWith(
        sourceStart: _sourceStart,
        nativeSource: MediaEntry.canonicalSource(path),
        sourceLoaded: true,
        isPlaying: play,
        isBuffering: false,
      ),
    );
  }

  @override
  Future<void> stop() async {
    _sourceStart++;
    _emit(
      _state.copyWith(
        sourceStart: _sourceStart,
        isPlaying: false,
        clearNativeSource: true,
        sourceLoaded: false,
      ),
    );
  }

  @override
  Future<void> play() async => _emit(_state.copyWith(isPlaying: true));

  @override
  Future<void> pause() async => _emit(_state.copyWith(isPlaying: false));

  @override
  Future<void> seek(Duration position) async =>
      _emit(_state.copyWith(position: position));

  @override
  Future<void> setVolume(double value) async =>
      _emit(_state.copyWith(volume: value));

  @override
  Future<void> setRate(double value) async =>
      _emit(_state.copyWith(rate: value));

  @override
  Future<void> setShuffle(bool value) async =>
      _emit(_state.copyWith(shuffle: value));

  @override
  Future<void> setRepeatMode(String value) async {}

  @override
  Future<void> setAudioTrack(AudioTrack track) async =>
      _emit(_state.copyWith(currentAudioTrack: track));

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async =>
      _emit(_state.copyWith(currentSubtitleTrack: track));

  @override
  Future<void> loadSubtitle(String path) async => lastSubtitlePath = path;

  @override
  Future<void> dispose() async => _stream.close();
}
