import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/seek_preview_service.dart';

class _FakeSeekPreviewBackend implements SeekPreviewBackend {
  _FakeSeekPreviewBackend({this.textureId = 42});

  final int? textureId;

  final List<String> openedSources = <String>[];
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
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    openedSources.add(source);
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
}
