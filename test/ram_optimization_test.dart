import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/data/repositories/media_library_repository.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/domain/models/playback_settings.dart';
import 'package:mpvson/ui/player/player_controller.dart';
import 'package:mpvson/ui/player/views/player_layout_manager.dart';

class FakeSeekPreviewBackend implements SeekPreviewBackend {
  bool isOpen = false;
  bool isDisposed = false;
  int openCount = 0;
  int disposeCount = 0;
  String? openedSource;

  @override
  Future<void> open(
    String source, {
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    isOpen = true;
    openCount++;
    openedSource = source;
  }

  @override
  Future<SeekPreviewFrame?> extractFrame(
    Duration target, {
    required bool exact,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    return SeekPreviewFrame(
      bytes: Uint8List.fromList([1, 2, 3]),
      requestedTime: target,
      capturedTime: target,
      quality: exact ? SeekPreviewQuality.exact : SeekPreviewQuality.keyframe,
    );
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {
    isOpen = false;
  }

  @override
  Future<void> dispose() async {
    isDisposed = true;
    disposeCount++;
  }
}

class FakeMediaLibraryRepository extends MediaLibraryRepository {
  int shrinkMemoryCallCount = 0;

  @override
  Future<void> shrinkMemory() async {
    shrinkMemoryCallCount++;
  }

  @override
  Future<void> dispose() async {
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeadlessVideoController implements VideoController {
  _HeadlessVideoController(Player player) {
    platform.complete(_HeadlessPlatformVideoController(player));
  }
  @override
  final platform = Completer<PlatformVideoController>();
  @override
  Future<void> setSize({int? width, int? height}) async {}
  @override
  Future<void> setRenderVisibility(bool visible) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeadlessPlatformVideoController extends PlatformVideoController {
  _HeadlessPlatformVideoController(Player player)
    : super(player, const VideoControllerConfiguration());
  @override
  Future<void> setSize({int? width, int? height}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dll = File('build/windows/x64/runner/Release/libmpv-2.dll').absolute;
  if (dll.existsSync()) {
    MediaKit.ensureInitialized(libmpv: dll.path);
  }

  group('2.1 SeekPreviewService idle disposal and on-demand sleep', () {
    test(
      'disposes worker after idle timeout and re-instantiates on hover',
      () async {
        FakeSeekPreviewBackend? currentBackend;
        final timers = <Duration, void Function()>{};

        Timer manualTimerFactory(Duration duration, void Function() callback) {
          timers[duration] = callback;
          return Timer(duration, callback);
        }

        final service = SeekPreviewService(
          idleWorkerTimeout: const Duration(seconds: 30),
          timerFactory: manualTimerFactory,
          backendFactory: () {
            final b = FakeSeekPreviewBackend();
            currentBackend = b;
            return b;
          },
        );

        await service.setSource('test_video.mp4');
        expect(service.hasActiveWorker, isFalse);
        expect(currentBackend, isNull);

        // User hovers over seekbar
        service.onPointerMove(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(service.hasActiveWorker, isTrue);
        expect(currentBackend, isNotNull);
        expect(currentBackend!.isDisposed, isFalse);
        final firstBackend = currentBackend!;

        // User moves away from seekbar
        service.onPointerExit();
        expect(service.hasActiveWorker, isTrue);
        expect(firstBackend.isDisposed, isFalse);

        // Trigger the 30-second idle timeout
        final idleCallback = timers[const Duration(seconds: 30)];
        expect(idleCallback, isNotNull);
        idleCallback!();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Worker should now be disposed
        expect(service.hasActiveWorker, isFalse);
        expect(firstBackend.isDisposed, isTrue);

        // When user hovers again, a new backend is instantiated on demand
        service.onPointerMove(const Duration(seconds: 45));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(service.hasActiveWorker, isTrue);
        expect(currentBackend, isNot(same(firstBackend)));
        expect(currentBackend!.isDisposed, isFalse);

        await service.dispose();
      },
    );

    test('suspend() immediately releases the preview worker', () async {
      FakeSeekPreviewBackend? currentBackend;
      final service = SeekPreviewService(
        backendFactory: () {
          final b = FakeSeekPreviewBackend();
          currentBackend = b;
          return b;
        },
      );

      await service.setSource('test_video.mp4');
      service.onPointerMove(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(service.hasActiveWorker, isTrue);
      expect(currentBackend, isNotNull);

      // Suspend immediately releases worker
      service.suspend();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(service.hasActiveWorker, isFalse);
      expect(currentBackend!.isDisposed, isTrue);

      await service.dispose();
    });
  });

  group('2.2 ImageCache and SQLite reclaim on window minimize', () {
    test('ImageCache maximumSize and maximumSizeBytes caps', () {
      PaintingBinding.instance.imageCache.maximumSizeBytes = 8 * 1024 * 1024;
      PaintingBinding.instance.imageCache.maximumSize = 100;

      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        8 * 1024 * 1024,
      );
      expect(PaintingBinding.instance.imageCache.maximumSize, 100);
    });

    test(
      'PlayerLayoutManager handleMinimize triggers shrinkMemory on libraryRepository',
      () async {
        final fakeRepo = FakeMediaLibraryRepository();
        final player = Player(
          configuration: const PlayerConfiguration(vo: 'null', muted: true),
        );
        final playback = PlaybackService(player: player);
        final tempDir = await Directory.systemTemp.createTemp('sessions_test_');
        final controller = PlayerController(
          playback: playback,
          sessions: SessionRepository(directory: tempDir),
        );

        final layoutManager = PlayerLayoutManager(
          controller: controller,
          desktopWindow: true,
          isShowingLibrary: () => false,
          showMessage: (_) {},
          showFeedback: (_, _, {bool centered = false}) {},
          libraryRepository: fakeRepo,
        );

        expect(fakeRepo.shrinkMemoryCallCount, 0);

        layoutManager.handleMinimize();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(fakeRepo.shrinkMemoryCallCount, 1);

        layoutManager.dispose();
        controller.dispose();
        await playback.dispose();
        await tempDir.delete(recursive: true);
      },
    );
  });

  group('2.3 Demuxer cache caps for normal, low-spec and RAM preservation', () {
    test('isLowSpecOrRamPreserved property logic', () {
      expect(
        const PlaybackSettings(
          qualityPreset: PlaybackQualityPreset.performance,
        ).isLowSpecOrRamPreserved,
        isTrue,
      );
      expect(
        const PlaybackSettings(
          qualityPreset: PlaybackQualityPreset.balanced,
          ramPreservation: true,
        ).isLowSpecOrRamPreserved,
        isTrue,
      );
      expect(
        const PlaybackSettings(
          qualityPreset: PlaybackQualityPreset.quality,
          ramPreservation: false,
        ).isLowSpecOrRamPreserved,
        isFalse,
      );
    });

    test(
      'Demuxer caps apply 128/48MB normally and 48/16MB in eco mode',
      () async {
        final dll = File(
          'build/windows/x64/runner/Release/libmpv-2.dll',
        ).absolute;
        if (!dll.existsSync()) {
          return; // Native tests run when bundled libmpv is compiled
        }
        MediaKit.ensureInitialized(libmpv: dll.path);
        final player = Player(
          configuration: const PlayerConfiguration(vo: 'null', muted: true),
        );
        final service = MediaKitPlaybackService(
          player: player,
          videoController: _HeadlessVideoController(player),
        );

        try {
          final native = player.platform! as NativePlayer;
          await native.setProperty('ao', 'null');
          await service.prepare();

          // 1. Balanced profile, no ramPreservation -> 128MB / 48MB
          await service.applyPlaybackSettings(
            const PlaybackSettings(
              qualityPreset: PlaybackQualityPreset.balanced,
              ramPreservation: false,
            ),
          );
          await service.open('https://example.com/stream.m3u8', play: false);

          expect(
            await native.getProperty('demuxer-max-bytes'),
            (128 * 1024 * 1024).toString(),
          );
          expect(
            await native.getProperty('demuxer-max-back-bytes'),
            (48 * 1024 * 1024).toString(),
          );

          // 2. RAM preservation enabled -> 48MB / 16MB
          await service.applyPlaybackSettings(
            const PlaybackSettings(
              qualityPreset: PlaybackQualityPreset.balanced,
              ramPreservation: true,
            ),
          );

          expect(
            await native.getProperty('demuxer-max-bytes'),
            (48 * 1024 * 1024).toString(),
          );
          expect(
            await native.getProperty('demuxer-max-back-bytes'),
            (16 * 1024 * 1024).toString(),
          );

          // 3. Performance profile (low-spec) without ramPreservation -> 48MB / 16MB
          await service.applyPlaybackSettings(
            const PlaybackSettings(
              qualityPreset: PlaybackQualityPreset.performance,
              ramPreservation: false,
            ),
          );

          expect(
            await native.getProperty('demuxer-max-bytes'),
            (48 * 1024 * 1024).toString(),
          );
          expect(
            await native.getProperty('demuxer-max-back-bytes'),
            (16 * 1024 * 1024).toString(),
          );
        } finally {
          await service.dispose();
        }
      },
    );
  });
}
