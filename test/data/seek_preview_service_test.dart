import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/seek_preview_service.dart';

class _FakeSeekPreviewBackend implements SeekPreviewBackend {
  _FakeSeekPreviewBackend({this.textureId = 42});

  final int? textureId;

  final List<String> openedSources = <String>[];
  final List<Map<String, String>?> openedHeaders = <Map<String, String>?>[];
  final List<({Duration target, bool exact})> liveSeeks =
      <({Duration target, bool exact})>[];
  final List<({Duration target, bool exact})> extractedFrames =
      <({Duration target, bool exact})>[];
  int stopCount = 0;
  int pauseCount = 0;
  int disposeCount = 0;
  bool disposed = false;

  void Function()? onBeforeDispose;

  @override
  int? get liveTextureId => !disposed ? textureId : null;

  @override
  bool get supportsLiveTexture => !disposed && textureId != null;

  @override
  Future<void> open(
    String source, {
    Map<String, String>? httpHeaders,
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    openedSources.add(source);
    openedHeaders.add(httpHeaders);
  }

  @override
  Future<void> seekLive(Duration target, {required bool exact}) async {
    liveSeeks.add((target: target, exact: exact));
  }

  @override
  Future<SeekPreviewFrame?> extractFrame(
    Duration target, {
    required bool exact,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    extractedFrames.add((target: target, exact: exact));
    return SeekPreviewFrame(
      bytes: Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]),
      requestedTime: target,
      capturedTime: target,
      quality: exact ? SeekPreviewQuality.exact : SeekPreviewQuality.keyframe,
    );
  }

  @override
  void cancelExtraction() {}

  @override
  Future<void> pause() async {
    pauseCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> dispose() async {
    onBeforeDispose?.call();
    disposed = true;
    disposeCount++;
  }
}

class _DelayedOpenBackend implements SeekPreviewBackend {
  final releasedOpen = Completer<void>();
  int openCount = 0;
  int disposeCount = 0;

  @override
  int? get liveTextureId => disposeCount == 0 ? 42 : null;

  @override
  bool get supportsLiveTexture => disposeCount == 0;

  @override
  Future<void> open(
    String source, {
    Map<String, String>? httpHeaders,
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) {
    openCount++;
    return releasedOpen.future;
  }

  @override
  Future<void> seekLive(Duration target, {required bool exact}) async {}

  @override
  Future<SeekPreviewFrame?> extractFrame(
    Duration target, {
    required bool exact,
    Duration timeout = const Duration(seconds: 3),
  }) async => null;

  @override
  void cancelExtraction() {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

void main() {
  group('SeekPreviewService local live texture', () {
    test(
      'pre-warms local video and seeks live texture without loading or screenshot capture',
      () async {
        final createdBackends = <_FakeSeekPreviewBackend>[];
        final service = SeekPreviewService(
          backendFactory: () {
            final backend = _FakeSeekPreviewBackend(textureId: 99);
            createdBackends.add(backend);
            return backend;
          },
          localPrewarmDelay: const Duration(milliseconds: 20),
          localIdleWorkerTimeout: const Duration(seconds: 10),
        );
        addTearDown(service.dispose);

        final observedStates = <SeekPreviewState>[];
        service.stateListenable.addListener(() {
          observedStates.add(service.state);
        });

        await service.setSource('C:/videos/movie.mkv');
        expect(service.state.isRemote, isFalse);
        expect(service.state.status, SeekPreviewStatus.idle);
        expect(service.state.isUpdating, isFalse);

        // Wait for pre-warm to open the local file in the background.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(createdBackends, hasLength(1));
        expect(createdBackends.first.openedSources, <String>[
          'C:/videos/movie.mkv',
        ]);

        // Hovering immediately exposes the live GPU texture without loading state.
        service.onPointerMove(const Duration(seconds: 12));
        expect(service.state.status, SeekPreviewStatus.ready);
        expect(service.state.liveTextureId, 99);
        expect(service.state.isUpdating, isFalse);
        expect(service.state.isRemote, isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(createdBackends.first.extractedFrames, isEmpty);
        expect(createdBackends.first.liveSeeks, isNotEmpty);
        expect(
          createdBackends.first.liveSeeks.first.target,
          const Duration(seconds: 12),
        );
        expect(createdBackends.first.liveSeeks.first.exact, isFalse);

        // Never entered SeekPreviewStatus.loading or isUpdating=true at any point.
        expect(
          observedStates.any(
            (s) => s.status == SeekPreviewStatus.loading || s.isUpdating,
          ),
          isFalse,
        );
      },
    );

    test(
      'reuses preview worker across local video switches and disposes on stop',
      () async {
        final createdBackends = <_FakeSeekPreviewBackend>[];
        final service = SeekPreviewService(
          backendFactory: () {
            final backend = _FakeSeekPreviewBackend(textureId: 77);
            createdBackends.add(backend);
            return backend;
          },
          localPrewarmDelay: const Duration(milliseconds: 15),
        );
        addTearDown(service.dispose);

        await service.setSource('C:/videos/one.mp4');
        await Future<void>.delayed(const Duration(milliseconds: 45));
        expect(createdBackends, hasLength(1));

        await service.setSource('C:/videos/two.mp4');
        await Future<void>.delayed(const Duration(milliseconds: 45));
        expect(createdBackends, hasLength(1));
        expect(createdBackends.first.stopCount, greaterThanOrEqualTo(1));
        expect(createdBackends.first.disposeCount, 0);
        expect(createdBackends.first.openedSources, <String>[
          'C:/videos/one.mp4',
          'C:/videos/two.mp4',
        ]);

        await service.setSource(null);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(createdBackends.first.disposeCount, 1);
      },
    );

    test('clears liveTextureId before disposing backend on suspend', () async {
      int? textureIdDuringDispose;
      final backend = _FakeSeekPreviewBackend(textureId: 55);
      final service = SeekPreviewService(
        backendFactory: () => backend,
        localPrewarmDelay: const Duration(milliseconds: 10),
      );
      addTearDown(service.dispose);

      backend.onBeforeDispose = () {
        textureIdDuringDispose = service.state.liveTextureId;
      };

      await service.setSource('C:/videos/clip.mp4');
      await Future<void>.delayed(const Duration(milliseconds: 35));
      service.onPointerMove(const Duration(seconds: 5));
      expect(service.state.liveTextureId, 55);

      service.suspend();
      expect(service.state.liveTextureId, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(backend.disposeCount, 1);
      expect(textureIdDuringDispose, isNull);
    });
  });

  group('SeekPreviewService remote stream path', () {
    test(
      'uses extractFrame and sets remote loading state for HTTP streams',
      () async {
        final backend = _FakeSeekPreviewBackend(textureId: 88);
        final service = SeekPreviewService(
          backendFactory: () => backend,
          localPrewarmDelay: const Duration(milliseconds: 10),
        );
        addTearDown(service.dispose);

        await service.setSource('https://example.com/video.m3u8');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // Remote streams must NOT pre-warm automatically.
        expect(backend.openedSources, isEmpty);

        service.onPointerMove(const Duration(seconds: 20));
        expect(service.state.isRemote, isTrue);
        expect(service.state.status, SeekPreviewStatus.loading);
        expect(service.state.isUpdating, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(backend.extractedFrames, hasLength(1));
        expect(backend.liveSeeks, isEmpty);
        expect(service.state.status, SeekPreviewStatus.ready);
        expect(service.state.currentFrame, isNotNull);
      },
    );
  });

  group('SeekPreviewService interaction teardown', () {
    test('detaching before any hover schedules no timer or worker', () {
      fakeAsync((async) {
        final created = <_FakeSeekPreviewBackend>[];
        final service = SeekPreviewService(
          backendFactory: () {
            final backend = _FakeSeekPreviewBackend();
            created.add(backend);
            return backend;
          },
        );

        service.detachInteraction(Object());

        expect(async.nonPeriodicTimerCount, 0);
        expect(created, isEmpty);
        async.run((_) => service.dispose());
        async.flushMicrotasks();
      });
    });

    test(
      'detaching during prewarm cancels the prewarm and leaves no timer',
      () {
        fakeAsync((async) {
          final created = <_FakeSeekPreviewBackend>[];
          final service = SeekPreviewService(
            backendFactory: () {
              final backend = _FakeSeekPreviewBackend();
              created.add(backend);
              return backend;
            },
            localPrewarmDelay: const Duration(milliseconds: 20),
          );

          async.run((_) {
            unawaited(service.setSource('C:/videos/movie.mkv'));
          });
          async.flushMicrotasks();
          expect(async.nonPeriodicTimerCount, 1); // prewarm timer only

          service.detachInteraction(Object());

          expect(async.nonPeriodicTimerCount, 0);
          async.elapse(const Duration(seconds: 2));
          async.flushMicrotasks();
          expect(created, isEmpty);
          async.run((_) => service.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'detaching during extraction cancels timers and releases the worker',
      () {
        fakeAsync((async) {
          final backend = _FakeSeekPreviewBackend();
          final service = SeekPreviewService(backendFactory: () => backend);
          final owner = Object();

          async.run((_) {
            unawaited(service.setSource('https://example.com/live.m3u8'));
            service.onPointerMove(const Duration(seconds: 12), owner: owner);
          });
          async.flushMicrotasks();
          expect(backend.extractedFrames, isNotEmpty);
          expect(async.nonPeriodicTimerCount, greaterThan(0));

          service.detachInteraction(owner);

          expect(async.nonPeriodicTimerCount, 0);
          async.flushMicrotasks();
          expect(backend.disposeCount, 1);
          async.run((_) => service.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test('detaching after a source change leaves no timer or live worker', () {
      fakeAsync((async) {
        final created = <_FakeSeekPreviewBackend>[];
        final service = SeekPreviewService(
          backendFactory: () {
            final backend = _FakeSeekPreviewBackend();
            created.add(backend);
            return backend;
          },
          localPrewarmDelay: const Duration(milliseconds: 10),
        );

        async.run((_) {
          unawaited(service.setSource('C:/videos/one.mp4'));
        });
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(created, hasLength(1));

        async.run((_) {
          unawaited(service.setSource('C:/videos/two.mp4'));
        });
        async.flushMicrotasks();

        service.detachInteraction(Object());

        expect(async.nonPeriodicTimerCount, 0);
        async.flushMicrotasks();
        expect(created.single.disposeCount, 1);
        async.run((_) => service.dispose());
        async.flushMicrotasks();
      });
    });

    test('an outgoing seek-bar surface cannot detach another surface', () {
      fakeAsync((async) {
        final backend = _FakeSeekPreviewBackend();
        final service = SeekPreviewService(backendFactory: () => backend);
        final outgoing = Object();
        final incoming = Object();

        async.run((_) {
          unawaited(service.setSource('https://example.com/live.m3u8'));
          service.onPointerMove(const Duration(seconds: 5), owner: outgoing);
        });
        async.flushMicrotasks();

        service.onPointerMove(const Duration(seconds: 9), owner: incoming);
        async.flushMicrotasks();

        // A late teardown from the outgoing surface is ignored.
        service.detachInteraction(outgoing);
        async.flushMicrotasks();
        expect(backend.disposeCount, 0);
        expect(service.state.targetTime, const Duration(seconds: 9));

        // The incoming surface still owns a live interaction.
        service.onPointerMove(const Duration(seconds: 11), owner: incoming);
        async.flushMicrotasks();
        expect(service.state.targetTime, const Duration(seconds: 11));

        service.detachInteraction(incoming);
        async.flushMicrotasks();
        expect(backend.disposeCount, 1);
        async.run((_) => service.dispose());
        async.flushMicrotasks();
      });
    });

    test('a queued detach is stale once a second seek bar takes over', () {
      fakeAsync((async) {
        final workers = <_DelayedOpenBackend>[];
        final service = SeekPreviewService(
          backendFactory: () {
            final worker = _DelayedOpenBackend();
            workers.add(worker);
            return worker;
          },
          localPrewarmDelay: const Duration(milliseconds: 10),
        );
        final outgoing = Object();
        final incoming = Object();

        unawaited(service.setSource('C:/test/video.mkv'));
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(workers, hasLength(1));
        final firstWorker = workers.single;
        expect(firstWorker.openCount, 1);

        service.onPointerMove(const Duration(seconds: 3), owner: outgoing);
        service.detachInteraction(outgoing);
        service.onPointerMove(const Duration(seconds: 8), owner: incoming);
        expect(firstWorker.disposeCount, 0);

        firstWorker.releasedOpen.complete();
        async.flushMicrotasks();
        expect(
          firstWorker.disposeCount,
          0,
          reason: 'The queued detach must not retire the incoming worker.',
        );

        service.detachInteraction(incoming);
        async.flushMicrotasks();
        expect(firstWorker.disposeCount, 1);
        async.run((_) => service.dispose());
        async.flushMicrotasks();
      });
    });

    test('an idle release cannot retire a worker after re-entry', () {
      fakeAsync((async) {
        final worker = _DelayedOpenBackend();
        final service = SeekPreviewService(
          backendFactory: () => worker,
          localPrewarmDelay: const Duration(milliseconds: 10),
          localIdleWorkerTimeout: const Duration(milliseconds: 50),
        );
        final outgoing = Object();
        final incoming = Object();

        unawaited(service.setSource('C:/test/video.mkv'));
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        service.onPointerMove(const Duration(seconds: 3), owner: outgoing);
        async.elapse(const Duration(milliseconds: 60));
        async.flushMicrotasks();
        // The idle timer fired while pre-warm's open was still blocked.
        service.onPointerMove(const Duration(seconds: 8), owner: incoming);

        worker.releasedOpen.complete();
        async.flushMicrotasks();
        expect(worker.disposeCount, 0);

        service.detachInteraction(incoming);
        async.flushMicrotasks();
        expect(worker.disposeCount, 1);
        async.run((_) => service.dispose());
        async.flushMicrotasks();
      });
    });

    test('a source change during prewarm keeps the adopted worker', () {
      fakeAsync((async) {
        final workers = <_DelayedOpenBackend>[];
        final service = SeekPreviewService(
          backendFactory: () {
            final worker = _DelayedOpenBackend();
            workers.add(worker);
            return worker;
          },
          localPrewarmDelay: const Duration(milliseconds: 10),
        );

        unawaited(service.setSource('C:/test/one.mkv'));
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        final firstWorker = workers.single;
        service.detachInteraction(Object());
        unawaited(service.setSource('C:/test/two.mkv'));
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();

        firstWorker.releasedOpen.complete();
        async.flushMicrotasks();
        // The stale release must not dispose the worker reused for the new
        // source; only the explicit dispose below may retire it.
        expect(firstWorker.disposeCount, 0);
        async.run((_) => service.dispose());
        async.flushMicrotasks();
      });
    });
  });
}
