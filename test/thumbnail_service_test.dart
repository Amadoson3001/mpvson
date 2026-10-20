import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/diagnostic_log.dart';
import 'package:mpvson/data/services/thumbnail_service.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/media_thumbnail.dart';
import 'package:path/path.dart' as p;

void main() {
  group('MediaThumbnail', () {
    test('copies input and output byte buffers', () {
      final input = _jpeg(17);
      final thumbnail = MediaThumbnail(bytes: input);
      input[4] = 99;
      final output = thumbnail.bytes;

      expect(thumbnail.bytes[4], 17);
      expect(identical(thumbnail.bytes, output), isTrue);
      expect(() => output[4] = 88, throwsUnsupportedError);
      expect(thumbnail.byteLength, greaterThan(0));
      expect(thumbnail.duration, Duration.zero);
    });
  });

  group('MediaKitThumbnailService', () {
    late Directory sandbox;
    late Directory cache;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('mpvson-thumb-test-');
      cache = Directory(p.join(sandbox.path, 'cache'));
      await cache.create(recursive: true);
    });

    tearDown(() async {
      if (await sandbox.exists()) {
        try {
          await sandbox.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          if (await sandbox.exists()) {
            try {
              await sandbox.delete(recursive: true);
            } catch (_) {}
          }
        }
      }
    });

    test(
      'prefers a valid same-basename sidecar and probes its duration',
      () async {
        final source = await _writeSource(sandbox, 'movie.mp4');
        final sidecar = Uint8List.fromList(<int>[
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
          ...List<int>.filled(16, 0),
        ]);
        await File(
          '${p.withoutExtension(source.path)}.png',
        ).writeAsBytes(sidecar);
        final extractor = _FakeExtractor(
          result: ThumbnailExtraction(
            bytes: _jpeg(9),
            duration: const Duration(seconds: 9),
          ),
          probedDuration: const Duration(seconds: 42),
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final thumbnail = await service.load(_entry(source.path));

        expect(thumbnail, isNotNull);
        expect(thumbnail!.bytes, equals(sidecar));
        expect(thumbnail.duration, const Duration(seconds: 42));
        expect(extractor.extractCalls, 0);
        expect(extractor.probeCalls, 1);
        await service.dispose();
      },
    );

    test(
      'uses known queue duration without a metadata probe for sidecars',
      () async {
        final source = await _writeSource(sandbox, 'known.mp4');
        final sidecar = _jpeg(8);
        await File(
          '${p.withoutExtension(source.path)}.jpg',
        ).writeAsBytes(sidecar);
        final extractor = _FakeExtractor();
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final thumbnail = await service.load(
          _entry(source.path, duration: const Duration(seconds: 13)),
        );

        expect(thumbnail?.duration, const Duration(seconds: 13));
        expect(extractor.probeCalls, 0);
        expect(extractor.extractCalls, 0);
        await service.dispose();
      },
    );

    test('deduplicates concurrent requests by canonical source', () async {
      final source = await _writeSource(sandbox, 'shared.mp4');
      final releaseExtraction = Completer<ThumbnailExtraction?>();
      final extractionStarted = Completer<void>();
      final extractor = _FakeExtractor(
        onExtract: (path, outputDirectory, [cancellation]) {
          if (!extractionStarted.isCompleted) extractionStarted.complete();
          return releaseExtraction.future;
        },
      );
      final service = MediaKitThumbnailService(
        extractor: extractor,
        imageValidator: _testImageValidator,
        cacheDirectory: cache,
      );

      final first = service.load(_entry(source.path, id: 'first'));
      final second = service.load(_entry(source.path, id: 'second'));
      await extractionStarted.future.timeout(const Duration(seconds: 2));
      expect(extractor.extractCalls, 1);

      releaseExtraction.complete(
        ThumbnailExtraction(
          bytes: _jpeg(11),
          duration: const Duration(seconds: 7),
        ),
      );
      final results = await Future.wait(<Future<MediaThumbnail?>>[
        first,
        second,
      ]);

      expect(results[0]?.bytes, equals(results[1]?.bytes));
      expect(results[0]?.duration, const Duration(seconds: 7));
      await service.dispose();
    });

    test(
      'caches a decoded frame on disk for later service instances',
      () async {
        final source = await _writeSource(sandbox, 'disk-cache.mp4');
        final firstExtractor = _FakeExtractor(
          result: ThumbnailExtraction(
            bytes: _jpeg(22),
            duration: const Duration(seconds: 31),
          ),
        );
        final firstService = MediaKitThumbnailService(
          extractor: firstExtractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        final first = await firstService.load(_entry(source.path));
        await firstService.dispose();

        final secondExtractor = _FakeExtractor(result: null);
        final secondService = MediaKitThumbnailService(
          extractor: secondExtractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        final second = await secondService.load(_entry(source.path));

        expect(second?.bytes, equals(first?.bytes));
        expect(second?.duration, const Duration(seconds: 31));
        expect(secondExtractor.extractCalls, 0);
        await secondService.dispose();
      },
    );

    test(
      'normalizes a large legacy disk image and rewrites the cached bytes',
      () async {
        final source = await _writeSource(sandbox, 'legacy-cache.mp4');
        final sidecar = File('${p.withoutExtension(source.path)}.png');
        final originalImage = await _createPng(640, 360);
        await sidecar.writeAsBytes(originalImage, flush: true);

        final writerService = MediaKitThumbnailService(
          cacheDirectory: cache,
          maxMemoryBytes: 0,
        );
        final writerResult = await writerService.load(_entry(source.path));
        expect(
          await _getImageSize(writerResult!.bytes),
          const ui.Size(320, 180),
        );
        await writerService.dispose();

        final cachedImage = await cache
            .list()
            .where((entity) => entity is File && entity.path.endsWith('.img'))
            .cast<File>()
            .single;
        // This is the shape of a cache entry written before 320x320
        // normalization was enforced on disk reads.
        await cachedImage.writeAsBytes(originalImage, flush: true);

        final fallbackExtractor = _FakeExtractor(result: null);
        final readerService = MediaKitThumbnailService(
          extractor: fallbackExtractor,
          cacheDirectory: cache,
          maxMemoryBytes: 0,
        );
        final result = await readerService.load(_entry(source.path));

        expect(result, isNotNull);
        expect(await _getImageSize(result!.bytes), const ui.Size(320, 180));
        expect(fallbackExtractor.extractCalls, 0);
        expect(
          await _getImageSize(await cachedImage.readAsBytes()),
          const ui.Size(320, 180),
        );
        await readerService.dispose();
      },
    );

    test(
      'falls back to extraction when a cached image cannot be decoded',
      () async {
        final source = await _writeSource(sandbox, 'corrupt-cache.mp4');
        final firstService = MediaKitThumbnailService(
          extractor: _FakeExtractor(
            result: ThumbnailExtraction(bytes: _jpeg(27)),
          ),
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        await firstService.load(_entry(source.path));
        await firstService.dispose();

        final imageFiles = await cache
            .list()
            .where((entity) => entity is File && entity.path.endsWith('.img'))
            .toList();
        expect(imageFiles, hasLength(1));
        await (imageFiles.single as File).writeAsBytes(_jpeg(99));

        final fallbackExtractor = _FakeExtractor(
          result: ThumbnailExtraction(bytes: _jpeg(28)),
        );
        final fallbackService = MediaKitThumbnailService(
          extractor: fallbackExtractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        final thumbnail = await fallbackService.load(_entry(source.path));

        expect(thumbnail?.bytes, equals(_jpeg(28)));
        expect(fallbackExtractor.extractCalls, 1);
        await fallbackService.dispose();
      },
    );

    test('invalidates cached frames when the local source changes', () async {
      final source = await _writeSource(sandbox, 'changed.mp4');
      var frame = 1;
      final extractor = _FakeExtractor(
        onExtract: (path, outputDirectory, [cancellation]) async =>
            ThumbnailExtraction(
              bytes: _jpeg(frame++),
              duration: const Duration(seconds: 8),
            ),
      );
      final service = MediaKitThumbnailService(
        extractor: extractor,
        imageValidator: _testImageValidator,
        cacheDirectory: cache,
      );

      final first = await service.load(_entry(source.path));
      await source.writeAsBytes(<int>[1, 2, 3, 4, 5, 6]);
      final second = await service.load(_entry(source.path));

      expect(first?.bytes, isNot(equals(second?.bytes)));
      expect(extractor.extractCalls, 2);
      await service.dispose();
    });

    test(
      'revalidates sidecar freshness after a provisional memory peek',
      () async {
        final source = await _writeSource(sandbox, 'sidecar-refresh.mp4');
        final sidecar = File('${p.withoutExtension(source.path)}.jpg');
        final original = await _createPng(2, 2);
        final replacement = await _createPng(80, 80);
        await sidecar.writeAsBytes(original);
        final extractor = _FakeExtractor();
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        final entry = _entry(source.path);

        expect((await service.load(entry))?.bytes, equals(original));
        expect(service.peek(entry)?.bytes, equals(original));

        await sidecar.writeAsBytes(replacement, flush: true);
        // A peek is deliberately provisional. The following request performs
        // async fingerprint validation before returning a cache hit.
        expect(service.peek(entry)?.bytes, equals(original));
        final handle = service.request(entry);
        final refreshed = await handle.thumbnail;
        handle.release();

        expect(refreshed?.bytes, equals(replacement));
        expect(extractor.extractCalls, 0);
        await service.dispose();
      },
    );

    test(
      'returns discovered duration and cleans its private output directory',
      () async {
        final source = await _writeSource(sandbox, 'duration.mp4');
        final extractor = _FakeExtractor(
          result: ThumbnailExtraction(
            bytes: _jpeg(25),
            duration: const Duration(minutes: 2, seconds: 17),
          ),
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final thumbnail = await service.load(_entry(source.path));

        expect(thumbnail?.duration, const Duration(minutes: 2, seconds: 17));
        expect(extractor.outputDirectoryExistedDuringExtraction, isTrue);
        expect(extractor.lastOutputDirectory, isNotNull);
        expect(await extractor.lastOutputDirectory!.exists(), isFalse);
        await service.dispose();
      },
    );

    test(
      'returns null for missing sources, corrupt sidecars, corrupt output, and no frame',
      () async {
        final missingExtractor = _FakeExtractor();
        final missingService = MediaKitThumbnailService(
          extractor: missingExtractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        expect(
          await missingService.load(
            _entry(p.join(sandbox.path, 'missing.mp4')),
          ),
          isNull,
        );
        expect(missingExtractor.extractCalls, 0);
        await missingService.dispose();

        final corruptSidecarSource = await _writeSource(
          sandbox,
          'corrupt-sidecar.mkv',
        );
        await File(
          '${p.withoutExtension(corruptSidecarSource.path)}.jpg',
        ).writeAsBytes(_jpeg(99));
        final fallbackExtractor = _FakeExtractor(
          result: ThumbnailExtraction(bytes: _jpeg(30)),
        );
        final fallbackService = MediaKitThumbnailService(
          extractor: fallbackExtractor,
          imageValidator: _testImageValidator,
          cacheDirectory: Directory(p.join(sandbox.path, 'fallback-cache')),
        );
        expect(
          await fallbackService.load(_entry(corruptSidecarSource.path)),
          isNotNull,
        );
        expect(fallbackExtractor.extractCalls, 1);
        await fallbackService.dispose();

        final corruptOutputSource = await _writeSource(
          sandbox,
          'corrupt-output.mp4',
        );
        final corruptOutputService = MediaKitThumbnailService(
          extractor: _FakeExtractor(
            result: ThumbnailExtraction(bytes: _jpeg(99)),
          ),
          imageValidator: _testImageValidator,
          cacheDirectory: Directory(p.join(sandbox.path, 'corrupt-cache')),
        );
        expect(
          await corruptOutputService.load(_entry(corruptOutputSource.path)),
          isNull,
        );
        await corruptOutputService.dispose();

        final noFrameSource = await _writeSource(sandbox, 'no-frame.mp4');
        final noFrameExtractor = _FakeExtractor(result: null);
        final noFrameService = MediaKitThumbnailService(
          extractor: noFrameExtractor,
          imageValidator: _testImageValidator,
          cacheDirectory: Directory(p.join(sandbox.path, 'empty-cache')),
        );
        expect(await noFrameService.load(_entry(noFrameSource.path)), isNull);
        await noFrameService.dispose();
      },
    );

    test(
      'dispose waits for requests, releases the extractor, and rejects new loads',
      () async {
        final source = await _writeSource(sandbox, 'dispose.mp4');
        final releaseExtraction = Completer<ThumbnailExtraction?>();
        final started = Completer<void>();
        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) {
            started.complete();
            return releaseExtraction.future;
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        final pending = service.load(_entry(source.path));
        await started.future.timeout(const Duration(seconds: 2));
        final disposal = service.dispose();
        expect(extractor.disposed, isTrue);
        releaseExtraction.complete(ThumbnailExtraction(bytes: _jpeg(41)));

        expect(await pending, isNull);
        await disposal;
        expect(extractor.disposed, isTrue);
        expect(await service.load(_entry(source.path)), isNull);
      },
    );

    test('keeps remote thumbnails in bounded session memory only', () async {
      final extractor = _FakeExtractor(
        result: ThumbnailExtraction(bytes: _jpeg(45)),
      );
      final service = MediaKitThumbnailService(
        extractor: extractor,
        imageValidator: _testImageValidator,
      );
      final entry = _entry('https://example.test/video.mp4');

      final first = await service.load(entry);
      final second = await service.load(
        entry.copyWith(id: 'another-queue-row'),
      );

      expect(second?.bytes, equals(first?.bytes));
      expect(extractor.extractCalls, 1);
      await service.dispose();
    });

    test(
      'bounds its cache without pruning unrelated files in the cache directory',
      () async {
        final firstSource = await _writeSource(sandbox, 'first.mp4');
        final secondSource = await _writeSource(sandbox, 'second.mp4');
        final unrelatedJson = File(p.join(cache.path, 'application.json'));
        final unrelatedTemp = File(p.join(cache.path, 'application.tmp'));
        await unrelatedJson.writeAsString('keep');
        await unrelatedTemp.writeAsString('keep');
        final extractor = _FakeExtractor(
          result: ThumbnailExtraction(bytes: _jpeg(46)),
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
          maxMemoryBytes: 0,
          maxDiskBytes: 8,
        );

        await service.load(_entry(firstSource.path));
        await service.load(_entry(secondSource.path));
        await service.dispose();

        expect(await unrelatedJson.readAsString(), 'keep');
        expect(await unrelatedTemp.readAsString(), 'keep');
        final metadataFiles = await cache
            .list()
            .where(
              (entity) =>
                  entity is File &&
                  RegExp(
                    r'^[a-f0-9]{64}\.json$',
                  ).hasMatch(p.basename(entity.path)),
            )
            .toList();
        expect(metadataFiles, hasLength(1));
      },
    );

    // =========================================================================
    // Item 19: Reference-counted request handles & cancellation
    // =========================================================================
    test(
      'ThumbnailRequestHandle releases request and interrupts active decoder when cancelled',
      () async {
        final source = await _writeSource(sandbox, 'cancel-single.mp4');
        final extractionStarted = Completer<void>();
        final releaseExtraction = Completer<ThumbnailExtraction?>();
        ThumbnailCancellation? observedCancellation;

        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) {
            observedCancellation = cancellation;
            extractionStarted.complete();
            return releaseExtraction.future;
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final handle = service.request(_entry(source.path));
        await extractionStarted.future.timeout(const Duration(seconds: 2));

        expect(observedCancellation, isNotNull);
        expect(observedCancellation!.isCancelled, isFalse);

        handle.cancel();

        expect(await handle.result, isNull);
        expect(await handle.thumbnail, isNull);
        expect(observedCancellation!.isCancelled, isTrue);

        releaseExtraction.complete(ThumbnailExtraction(bytes: _jpeg(1)));
        await service.dispose();
      },
    );

    test(
      'ThumbnailRequestHandle retains shared request while at least one consumer remains active',
      () async {
        final source = await _writeSource(sandbox, 'cancel-shared.mp4');
        final extractionStarted = Completer<void>();
        final releaseExtraction = Completer<ThumbnailExtraction?>();
        ThumbnailCancellation? observedCancellation;

        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) {
            observedCancellation = cancellation;
            extractionStarted.complete();
            return releaseExtraction.future;
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final handle1 = service.request(_entry(source.path, id: 'row-1'));
        final handle2 = service.request(_entry(source.path, id: 'row-2'));

        await extractionStarted.future.timeout(const Duration(seconds: 2));
        expect(extractor.extractCalls, 1);

        // Releasing handle 1 must NOT cancel the underlying operation for handle 2
        handle1.release();
        expect(observedCancellation!.isCancelled, isFalse);

        releaseExtraction.complete(
          ThumbnailExtraction(
            bytes: _jpeg(12),
            duration: const Duration(seconds: 14),
          ),
        );

        final res1 = await handle1.result;
        final res2 = await handle2.result;

        expect(res1, isNull); // Released handle completes with null
        expect(res2, equals(_jpeg(12))); // Active handle completes with bytes
        expect(await handle2.thumbnail, isNotNull);

        await service.dispose();
      },
    );

    test(
      'retries an interrupted shared extraction after rapid suspend and resume',
      () async {
        final source = await _writeSource(sandbox, 'suspend-resume-shared.mp4');
        final firstStarted = Completer<void>();
        final releaseInterruptedCall = Completer<void>();
        var calls = 0;
        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) async {
            calls++;
            if (calls == 1) {
              firstStarted.complete();
              await releaseInterruptedCall.future;
              if (cancellation!.isInterrupted) return null;
            }
            return ThumbnailExtraction(bytes: _jpeg(52));
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        final firstConsumer = service.request(_entry(source.path, id: 'row-a'));
        final secondConsumer = service.request(
          _entry(source.path, id: 'row-b'),
        );

        await firstStarted.future.timeout(const Duration(seconds: 2));
        service.suspend();
        firstConsumer.release();
        service.resume();
        releaseInterruptedCall.complete();

        expect(await firstConsumer.thumbnail, isNull);
        expect((await secondConsumer.thumbnail)?.bytes, equals(_jpeg(52)));
        expect(calls, 2);
        expect(extractor.disposed, isFalse);

        await service.dispose();
      },
    );

    test(
      'queued extraction does not time out while an earlier operation stalls',
      () async {
        final blockerSource = await _writeSource(
          sandbox,
          'deadline-blocker.mp4',
        );
        final queuedSource = await _writeSource(sandbox, 'deadline-queued.mp4');
        final blockerStarted = Completer<void>();
        final releaseBlocker = Completer<void>();
        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) async {
            if (p.basename(path) == 'deadline-blocker.mp4') {
              blockerStarted.complete();
              await releaseBlocker.future;
            }
            return ThumbnailExtraction(bytes: _jpeg(61));
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
          operationTimeout: Duration.zero,
          requestTimeoutGrace: const Duration(milliseconds: 500),
        );

        final beforeBlocker = await _thumbnailTempDirectories();
        final blocker = service.request(_entry(blockerSource.path));
        await blockerStarted.future.timeout(const Duration(seconds: 2));
        await _waitForNewThumbnailDirectories(beforeBlocker, 1);

        final beforeQueued = await _thumbnailTempDirectories();
        final queued = service.request(_entry(queuedSource.path));
        await _waitForNewThumbnailDirectories(beforeQueued, 1);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // The first request's timer expires while the fake extractor keeps
        // occupying the serialized lane. A queued request must pause its own
        // timeout until the lane starts its work.
        await Future<void>.delayed(const Duration(milliseconds: 650));
        var queuedCompleted = false;
        unawaited(
          queued.thumbnail.then<void>((_) {
            queuedCompleted = true;
          }),
        );
        await Future<void>.delayed(Duration.zero);
        expect(queuedCompleted, isFalse);

        releaseBlocker.complete();

        expect(await blocker.thumbnail, isNull);
        expect((await queued.thumbnail)?.bytes, equals(_jpeg(61)));
        await service.dispose();
      },
    );

    test(
      'ThumbnailRequestHandle cancels operation when all shared consumers release',
      () async {
        final source = await _writeSource(sandbox, 'cancel-all-shared.mp4');
        final extractionStarted = Completer<void>();
        final releaseExtraction = Completer<ThumbnailExtraction?>();
        ThumbnailCancellation? observedCancellation;

        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) {
            observedCancellation = cancellation;
            extractionStarted.complete();
            return releaseExtraction.future;
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final handle1 = service.request(_entry(source.path, id: 'row-1'));
        final handle2 = service.request(_entry(source.path, id: 'row-2'));

        await extractionStarted.future.timeout(const Duration(seconds: 2));

        handle1.release();
        expect(observedCancellation!.isCancelled, isFalse);

        // When the final consumer releases, decoder is interrupted
        handle2.release();
        expect(observedCancellation!.isCancelled, isTrue);

        releaseExtraction.complete(ThumbnailExtraction(bytes: _jpeg(15)));
        expect(await handle1.result, isNull);
        expect(await handle2.result, isNull);

        await service.dispose();
      },
    );

    test('cancelling a queued row removes only its queued output', () async {
      final firstSource = await _writeSource(sandbox, 'queued-active.mp4');
      final secondSource = await _writeSource(sandbox, 'queued-row.mp4');
      final before = await _thumbnailTempDirectories();
      final activeStarted = Completer<void>();
      final releaseActive = Completer<ThumbnailExtraction?>();
      final extractor = _FakeExtractor(
        onExtract: (path, outputDirectory, [cancellation]) {
          activeStarted.complete();
          return releaseActive.future;
        },
      );
      final service = MediaKitThumbnailService(
        extractor: extractor,
        imageValidator: _testImageValidator,
        cacheDirectory: cache,
      );

      final active = service.request(_entry(firstSource.path));
      await activeStarted.future.timeout(const Duration(seconds: 2));
      final queued = service.request(_entry(secondSource.path));
      final created = await _waitForNewThumbnailDirectories(before, 2);
      final activeDirectory = extractor.lastOutputDirectory!;
      final queuedDirectory = created.singleWhere(
        (path) => path != activeDirectory.path,
      );
      queued.release();

      expect(await queued.result, isNull);
      await _waitUntil(() async {
        return !(await Directory(queuedDirectory).exists());
      });
      expect(await activeDirectory.exists(), isTrue);
      expect(extractor.extractCalls, 1);

      releaseActive.complete(ThumbnailExtraction(bytes: _jpeg(61)));
      expect(await active.result, isNotNull);
      await service.dispose();
      expect(await activeDirectory.exists(), isFalse);
    });

    test(
      'row disposal waits for active worker output cleanup on service close',
      () async {
        final source = await _writeSource(sandbox, 'row-disposal.mp4');
        final started = Completer<void>();
        final releaseWorker = Completer<ThumbnailExtraction?>();
        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) async {
            await File(
              p.join(outputDirectory.path, 'worker.marker'),
            ).writeAsBytes(<int>[1], flush: true);
            started.complete();
            return releaseWorker.future;
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );
        final row = service.request(_entry(source.path));
        await started.future.timeout(const Duration(seconds: 2));
        final outputDirectory = extractor.lastOutputDirectory!;

        row.release();
        expect(await row.result, isNull);
        expect(await outputDirectory.exists(), isTrue);
        expect(
          await File(p.join(outputDirectory.path, 'worker.marker')).exists(),
          isTrue,
        );

        var disposed = false;
        final disposal = service.dispose().then<void>((_) {
          disposed = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(disposed, isFalse);
        expect(await outputDirectory.exists(), isTrue);
        releaseWorker.complete(ThumbnailExtraction(bytes: _jpeg(62)));
        await disposal;

        expect(extractor.disposed, isTrue);
        expect(await outputDirectory.exists(), isFalse);
      },
    );

    test(
      'a replacement request survives completion of a cancelled same-key load',
      () async {
        final source = await _writeSource(sandbox, 'same-key-retry.mp4');
        final firstStarted = Completer<void>();
        final secondStarted = Completer<void>();
        final releaseFirst = Completer<ThumbnailExtraction?>();
        final releaseSecond = Completer<ThumbnailExtraction?>();
        var extraction = 0;
        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) {
            extraction++;
            if (extraction == 1) {
              firstStarted.complete();
              return releaseFirst.future;
            }
            secondStarted.complete();
            return releaseSecond.future;
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
          maxMemoryBytes: 0,
        );

        final oldRow = service.request(_entry(source.path, id: 'old-row'));
        await firstStarted.future.timeout(const Duration(seconds: 2));
        oldRow.release();
        final replacement = service.request(_entry(source.path, id: 'new-row'));
        releaseFirst.complete(ThumbnailExtraction(bytes: _jpeg(63)));
        await secondStarted.future.timeout(const Duration(seconds: 2));
        releaseSecond.complete(ThumbnailExtraction(bytes: _jpeg(64)));

        expect(await oldRow.result, isNull);
        expect(await replacement.result, equals(_jpeg(64)));
        expect(extraction, 2);
        await service.dispose();
      },
    );

    // =========================================================================
    // Item 20: Resolve intermittent native thumbnail capture & diagnostics
    // =========================================================================
    test(
      'records stage-specific failure diagnostic with redacted source ID',
      () async {
        final diagSink = MemoryDiagnosticLog();
        final extractor = _FakeExtractor(result: null);
        final service = MediaKitThumbnailService(
          extractor: extractor,
          diagnostics: diagSink,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final remoteUrl =
            'https://user:secret@media.test/video.mp4?auth=secret123#frag';
        final thumbnail = await service.load(_entry(remoteUrl));
        expect(thumbnail, isNull);

        // Verify recentDiagnostics on the service and records on DiagnosticSink
        expect(service.recentDiagnostics, isNotEmpty);
        final diagnostic = service.recentDiagnostics.first;
        expect(diagnostic.sourceId, isNot(contains('secret')));
        expect(diagnostic.sourceId, isNot(contains('frag')));

        await service.dispose();
      },
    );

    test(
      'handles cold decoder startup delay without failing extraction',
      () async {
        final source = await _writeSource(sandbox, 'cold-start.mp4');
        var probeAttempts = 0;

        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) async {
            // Simulate cold decoder spin-up taking a couple ticks
            while (probeAttempts < 3) {
              probeAttempts++;
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
            return ThumbnailExtraction(
              bytes: _jpeg(50),
              duration: const Duration(seconds: 120),
            );
          },
        );

        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final thumbnail = await service.load(_entry(source.path));
        expect(thumbnail, isNotNull);
        expect(thumbnail!.bytes, equals(_jpeg(50)));
        expect(thumbnail.duration, const Duration(seconds: 120));
        await service.dispose();
      },
    );

    // =========================================================================
    // Item 21: Bounded decoding before allocation & 320x320 normalization
    // =========================================================================
    test(
      'rejects extracted file exceeding 12 MiB limit before reading into memory',
      () async {
        final source = await _writeSource(sandbox, 'oversized-file.mp4');
        final diagSink = MemoryDiagnosticLog();

        // Extractor that writes an oversized output file (> 12 MiB)
        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) async {
            final file = File(p.join(outputDirectory.path, 'oversized.jpg'));
            // Create a sparse or filled file > 12 MiB (12.5 MiB)
            final raf = await file.open(mode: FileMode.write);
            await raf.truncate(13 * 1024 * 1024);
            await raf.close();
            return null; // extractor enforces limit
          },
        );

        final service = MediaKitThumbnailService(
          extractor: extractor,
          diagnostics: diagSink,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final thumbnail = await service.load(_entry(source.path));
        expect(thumbnail, isNull);
        await service.dispose();
      },
    );

    test(
      'inspects dimensions and rejects image exceeding 32 megapixels before decoding',
      () async {
        final source = await _writeSource(sandbox, 'oversized-mp.mp4');
        // Create an oversized PNG header (8000x5000 = 40 megapixels > 32 MP)
        final oversizedPng = _createOversizedPng(8000, 5000);
        await File(
          '${p.withoutExtension(source.path)}.png',
        ).writeAsBytes(oversizedPng);

        // When sidecar exceeds 32 megapixels, it must be rejected without decoding.
        // It falls back to extraction, where an oversized extraction is also rejected.
        final extractor = _FakeExtractor(
          result: ThumbnailExtraction(bytes: oversizedPng),
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          cacheDirectory: cache,
        );

        final thumbnail = await service.load(_entry(source.path));
        expect(thumbnail, isNull);
        // Extractor was invoked as fallback, and its oversized extraction was also rejected
        expect(extractor.extractCalls, 1);
        await service.dispose();
      },
    );

    test(
      'normalizes large landscape image to fit within 320x320 preserving 16:9 aspect ratio',
      () async {
        final source = await _writeSource(sandbox, 'landscape.mp4');
        // 640x360 is 16:9 aspect ratio
        final fullImage = await _createPng(640, 360);
        await File(
          '${p.withoutExtension(source.path)}.png',
        ).writeAsBytes(fullImage);

        final service = MediaKitThumbnailService(cacheDirectory: cache);
        final thumbnail = await service.load(_entry(source.path));

        expect(thumbnail, isNotNull);
        final size = await _getImageSize(thumbnail!.bytes);
        // Normalized dimensions must fit within 320x320 with preserved aspect ratio
        expect(size.width, 320);
        expect(size.height, 180);
        await service.dispose();
      },
    );

    test(
      'normalizes large portrait image to fit within 320x320 preserving 9:16 aspect ratio',
      () async {
        final source = await _writeSource(sandbox, 'portrait.mp4');
        // 360x640 is 9:16 aspect ratio
        final fullImage = await _createPng(360, 640);
        await File(
          '${p.withoutExtension(source.path)}.png',
        ).writeAsBytes(fullImage);

        final service = MediaKitThumbnailService(cacheDirectory: cache);
        final thumbnail = await service.load(_entry(source.path));

        expect(thumbnail, isNotNull);
        final size = await _getImageSize(thumbnail!.bytes);
        expect(size.width, 180);
        expect(size.height, 320);
        await service.dispose();
      },
    );

    test('preserves small artwork dimensions without upscaling', () async {
      final source = await _writeSource(sandbox, 'small.mp4');
      // 200x150 is already within 320x320
      final smallImage = await _createPng(200, 150);
      await File(
        '${p.withoutExtension(source.path)}.png',
      ).writeAsBytes(smallImage);

      final service = MediaKitThumbnailService(cacheDirectory: cache);
      final thumbnail = await service.load(_entry(source.path));

      expect(thumbnail, isNotNull);
      final size = await _getImageSize(thumbnail!.bytes);
      expect(size.width, 200);
      expect(size.height, 150);
      await service.dispose();
    });

    // =========================================================================
    // Item 22: Single decoder reuse, prioritization, suspension & cache bounds
    // =========================================================================
    test(
      'reuses single decoder across multiple extractions and probes without recreating Player',
      () async {
        var playerCreations = 0;
        final spyPlayer = _SpyPlayer();
        final extractor = MediaKitThumbnailExtractor(
          imageValidator: _testImageValidator,
          playerFactory: () {
            playerCreations++;
            return spyPlayer;
          },
        );

        final out1 = Directory(p.join(sandbox.path, 'out1'));
        await out1.create(recursive: true);
        final out2 = Directory(p.join(sandbox.path, 'out2'));
        await out2.create(recursive: true);

        // First extraction
        final extraction1 = await extractor.extract(
          'video1.mp4',
          outputDirectory: out1,
        );
        expect(extraction1, isNotNull);
        expect(playerCreations, 1);
        expect(
          spyPlayer.openCalls,
          2,
          reason:
              'Metadata discovery and selected-track capture each open once',
        );
        expect(spyPlayer.playCalls, 1);
        expect(spyPlayer.stopCalls, greaterThanOrEqualTo(1));
        expect(spyPlayer.isDisposed, isFalse);

        // Probe duration
        final duration = await extractor.probeDuration('video2.mp4');
        expect(duration, const Duration(seconds: 120));
        expect(playerCreations, 1); // Not recreated!
        expect(spyPlayer.openCalls, 3);
        expect(spyPlayer.stopCalls, greaterThanOrEqualTo(2));
        expect(spyPlayer.isDisposed, isFalse);

        // Second extraction
        final extraction2 = await extractor.extract(
          'video3.mp4',
          outputDirectory: out2,
        );
        expect(extraction2, isNotNull);
        expect(playerCreations, 1); // Still single instance!
        expect(spyPlayer.openCalls, 5);
        expect(spyPlayer.isDisposed, isFalse);

        // Only during disposal should player be disposed
        await extractor.dispose();
        expect(spyPlayer.isDisposed, isTrue);
        expect(spyPlayer.disposeCalls, 1);
      },
    );

    test(
      'reuses the native decoder across regular, sidecar, cancellation, and later frame work',
      () async {
        var playerCreations = 0;
        final spyPlayer = _SpyPlayer();
        final extractor = MediaKitThumbnailExtractor(
          imageValidator: _testImageValidator,
          playerFactory: () {
            playerCreations++;
            return spyPlayer;
          },
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final regularSource = await _writeSource(sandbox, 'reuse-regular.mp4');
        expect(await service.load(_entry(regularSource.path)), isNotNull);
        expect(playerCreations, 1);
        expect(spyPlayer.openCalls, 2);

        final coverSource = await _writeSource(sandbox, 'reuse-cover.mp4');
        final cover = _jpeg(72);
        await File(
          '${p.withoutExtension(coverSource.path)}.jpg',
        ).writeAsBytes(cover);
        expect(
          (await service.load(_entry(coverSource.path)))?.bytes,
          equals(cover),
        );
        expect(playerCreations, 1);
        expect(spyPlayer.openCalls, 3);

        final cancelSource = await _writeSource(sandbox, 'reuse-cancel.mp4');
        final playStarted = Completer<void>();
        final allowPlayToFinish = Completer<void>();
        spyPlayer.onPlay = () async {
          if (!playStarted.isCompleted) playStarted.complete();
          await allowPlayToFinish.future;
        };
        final cancelled = service.request(_entry(cancelSource.path));
        await playStarted.future.timeout(const Duration(seconds: 2));
        cancelled.release();
        allowPlayToFinish.complete();
        expect(await cancelled.thumbnail, isNull);
        expect(spyPlayer.openCalls, 5);

        spyPlayer.onPlay = null;
        final nextSource = await _writeSource(
          sandbox,
          'reuse-after-cancel.mp4',
        );
        expect(await service.load(_entry(nextSource.path)), isNotNull);
        expect(playerCreations, 1);
        expect(spyPlayer.isDisposed, isFalse);
        expect(spyPlayer.openCalls, 7);

        await service.dispose();
        expect(spyPlayer.isDisposed, isTrue);
        expect(spyPlayer.disposeCalls, 1);
      },
    );

    test(
      'cancellation stops the job without disposing the decoder and subsequent job succeeds',
      () async {
        var playerCreations = 0;
        final spyPlayer = _SpyPlayer();
        final extractor = MediaKitThumbnailExtractor(
          imageValidator: _testImageValidator,
          playerFactory: () {
            playerCreations++;
            return spyPlayer;
          },
        );

        final outDir = Directory(p.join(sandbox.path, 'cancel_out'));
        await outDir.create(recursive: true);

        final token = ThumbnailCancellation();
        token.cancel();

        final result = await extractor.extract(
          'cancel.mp4',
          outputDirectory: outDir,
          cancellation: token,
        );
        expect(result, isNull);
        // Player must not be disposed by cancellation
        expect(spyPlayer.isDisposed, isFalse);

        // Subsequent job succeeds with the same decoder
        final successOut = Directory(p.join(sandbox.path, 'success_out'));
        await successOut.create(recursive: true);
        final nextResult = await extractor.extract(
          'next.mp4',
          outputDirectory: successOut,
        );
        expect(nextResult, isNotNull);
        expect(playerCreations, 1);
        expect(spyPlayer.isDisposed, isFalse);

        await extractor.dispose();
        expect(spyPlayer.isDisposed, isTrue);
      },
    );

    test(
      'prioritizes high priority requests over normal priority in queue',
      () async {
        final activeStarted = Completer<void>();
        final releaseActive = Completer<ThumbnailExtraction?>();
        final executionOrder = <String>[];

        final extractor = _FakeExtractor(
          onExtract: (source, outputDirectory, [cancellation]) async {
            final id = p.basenameWithoutExtension(source);
            executionOrder.add(id);
            if (id == 'blocking') {
              activeStarted.complete();
              return releaseActive.future;
            }
            return ThumbnailExtraction(bytes: _jpeg(10));
          },
        );

        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final blockingSource = await _writeSource(sandbox, 'blocking.mp4');
        final normal1Source = await _writeSource(sandbox, 'normal1.mp4');
        final highSource = await _writeSource(sandbox, 'high.mp4');
        final normal2Source = await _writeSource(sandbox, 'normal2.mp4');

        // Launch blocking task
        final blockingHandle = service.request(_entry(blockingSource.path));
        await activeStarted.future.timeout(const Duration(seconds: 2));

        // Queue items while blocking task is running
        final normal1Handle = service.request(
          _entry(normal1Source.path),
          priority: ThumbnailPriority.normal,
        );
        final highHandle = service.request(
          _entry(highSource.path),
          priority: ThumbnailPriority.high,
        );
        final normal2Handle = service.request(
          _entry(normal2Source.path),
          priority: ThumbnailPriority.normal,
        );

        // Allow requests to reach the queue while the blocking task is active
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Release blocking task
        releaseActive.complete(ThumbnailExtraction(bytes: _jpeg(1)));
        await blockingHandle.thumbnail;

        // Wait for all queued items
        await Future.wait([
          normal1Handle.thumbnail,
          highHandle.thumbnail,
          normal2Handle.thumbnail,
        ]);

        // High priority must have been extracted before normal1 and normal2
        expect(executionOrder, ['blocking', 'high', 'normal1', 'normal2']);

        await service.dispose();
      },
    );

    test(
      'suspension pauses extraction and resumption drains queue in priority order',
      () async {
        final executionOrder = <String>[];
        final extractor = _FakeExtractor(
          onExtract: (source, outputDirectory, [cancellation]) async {
            executionOrder.add(p.basenameWithoutExtension(source));
            return ThumbnailExtraction(bytes: _jpeg(20));
          },
        );

        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final sourceNormal = await _writeSource(sandbox, 'suspend_normal.mp4');
        final sourceHigh = await _writeSource(sandbox, 'suspend_high.mp4');
        final sourceCancelled = await _writeSource(
          sandbox,
          'suspend_cancel.mp4',
        );

        // Suspend the service
        service.suspend();

        final normalHandle = service.request(
          _entry(sourceNormal.path),
          priority: ThumbnailPriority.normal,
        );
        final highHandle = service.request(
          _entry(sourceHigh.path),
          priority: ThumbnailPriority.high,
        );
        final cancelHandle = service.request(
          _entry(sourceCancelled.path),
          priority: ThumbnailPriority.normal,
        );

        // Cancel one handle while suspended
        cancelHandle.cancel();

        await Future<void>.delayed(const Duration(milliseconds: 50));
        // No extractions must have started while suspended
        expect(executionOrder, isEmpty);

        // Resume service
        service.resume();

        final results = await Future.wait([
          normalHandle.thumbnail,
          highHandle.thumbnail,
          cancelHandle.thumbnail,
        ]);

        expect(results[0], isNotNull);
        expect(results[1], isNotNull);
        expect(results[2], isNull); // Cancelled handle returns null
        expect(executionOrder, ['suspend_high', 'suspend_normal']);

        await service.dispose();
      },
    );

    test(
      'enforces the compressed memory cache byte limit with LRU eviction',
      () async {
        final extractor = _FakeExtractor(
          onExtract: (source, outputDirectory, [cancellation]) async {
            return ThumbnailExtraction(bytes: _jpeg(30));
          },
        );

        // Two seven-byte thumbnails fit. Touching the first one before adding
        // the third must evict the second entry.
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
          maxMemoryBytes: 14,
          maxDiskBytes: 0,
        );

        final s1 = await _writeSource(sandbox, 'mem1.mp4');
        final s2 = await _writeSource(sandbox, 'mem2.mp4');
        final s3 = await _writeSource(sandbox, 'mem3.mp4');

        await service.load(_entry(s1.path));
        expect(extractor.extractCalls, 1);

        await service.load(_entry(s2.path));
        expect(extractor.extractCalls, 2);

        expect(service.peek(_entry(s1.path)), isNotNull);
        await service.load(_entry(s3.path));
        expect(extractor.extractCalls, 3);

        await service.load(_entry(s1.path));
        expect(extractor.extractCalls, 3);
        await service.load(_entry(s2.path));
        expect(extractor.extractCalls, 4);

        await service.dispose();
      },
    );

    test(
      'returns thumbnail immediately while serialized cache write happens in background',
      () async {
        final extractor = _FakeExtractor(
          result: ThumbnailExtraction(
            bytes: _jpeg(77),
            duration: const Duration(seconds: 45),
          ),
        );

        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
        );

        final source = await _writeSource(sandbox, 'bg_write.mp4');
        final thumbnail = await service.load(_entry(source.path));

        // Returned immediately
        expect(thumbnail, isNotNull);
        expect(thumbnail!.bytes, equals(_jpeg(77)));

        // Dispose drains and flushes background writes cleanly
        await service.dispose();

        // Verify file was written to disk cache
        final cacheFiles = await cache
            .list()
            .where((e) => e is File && e.path.endsWith('.img'))
            .toList();
        expect(cacheFiles, hasLength(1));
      },
    );

    test(
      'bounds pending disk bytes and coalesces writes for a changed source',
      () async {
        final source = await _writeSource(sandbox, 'disk-coalesce.mp4');
        final skippedSource = await _writeSource(sandbox, 'disk-skipped.mp4');
        final firstWriteStarted = Completer<void>();
        final releaseFirstWrite = Completer<void>();
        var diskWriteCalls = 0;
        var payload = 41;
        final extractor = _FakeExtractor(
          onExtract: (path, outputDirectory, [cancellation]) async =>
              ThumbnailExtraction(bytes: _largeJpeg(payload)),
        );
        final service = MediaKitThumbnailService(
          extractor: extractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
          maxMemoryBytes: 0,
          maxDiskBytes: 64 * 1024 * 1024,
          beforeDiskWrite: () async {
            diskWriteCalls++;
            if (diskWriteCalls == 1) {
              firstWriteStarted.complete();
              await releaseFirstWrite.future;
            }
          },
        );

        expect(await service.load(_entry(source.path)), isNotNull);
        await firstWriteStarted.future.timeout(const Duration(seconds: 2));

        await source.writeAsBytes(<int>[1, 2, 3, 4]);
        payload = 42;
        expect(await service.load(_entry(source.path)), isNotNull);
        await source.writeAsBytes(<int>[1, 2, 3, 4, 5]);
        payload = 43;
        expect(await service.load(_entry(source.path)), isNotNull);

        // One latest 5 MiB update for this digest is pending. A second unique
        // 5 MiB image would exceed the 8 MiB pending-write budget and is skipped.
        payload = 44;
        expect(await service.load(_entry(skippedSource.path)), isNotNull);
        releaseFirstWrite.complete();
        await service.dispose();

        final imageFiles = await cache
            .list()
            .where((entity) => entity is File && entity.path.endsWith('.img'))
            .toList();
        expect(imageFiles, hasLength(1));

        final fallbackExtractor = _FakeExtractor(result: null);
        final reader = MediaKitThumbnailService(
          extractor: fallbackExtractor,
          imageValidator: _testImageValidator,
          cacheDirectory: cache,
          maxMemoryBytes: 0,
        );
        final cached = await reader.load(_entry(source.path));
        expect(cached?.bytes.length, 5 * 1024 * 1024);
        expect(cached?.bytes[4], 43);
        expect(fallbackExtractor.extractCalls, 0);
        await reader.dispose();
      },
    );
  });
}

MediaEntry _entry(
  String path, {
  String id = 'entry',
  Duration duration = Duration.zero,
}) => MediaEntry(
  id: id,
  path: path,
  title: p.basename(path),
  duration: duration,
  lastPlayed: DateTime.utc(2026),
);

Future<File> _writeSource(Directory directory, String name) async {
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(<int>[1, 2, 3]);
  return file;
}

Uint8List _jpeg(int payload) =>
    Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xe0, payload, 0xff, 0xd9]);

Uint8List _largeJpeg(int payload) {
  final bytes = Uint8List(5 * 1024 * 1024);
  bytes[0] = 0xff;
  bytes[1] = 0xd8;
  bytes[2] = 0xff;
  bytes[3] = 0xe0;
  bytes[4] = payload;
  bytes[bytes.length - 2] = 0xff;
  bytes[bytes.length - 1] = 0xd9;
  return bytes;
}

Future<bool> _testImageValidator(Uint8List bytes) async =>
    bytes.length > 5 && bytes[4] != 99;

Future<Uint8List> _createPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint()..color = const ui.Color(0xFF2196F3);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    paint,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<ui.Size> _getImageSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      return ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

Future<Set<String>> _thumbnailTempDirectories() async {
  final directories = <String>{};
  await for (final entity in Directory.systemTemp.list(followLinks: false)) {
    if (entity is Directory &&
        p.basename(entity.path).startsWith('mpvson-thumbnail-')) {
      directories.add(entity.path);
    }
  }
  return directories;
}

Future<Set<String>> _waitForNewThumbnailDirectories(
  Set<String> before,
  int count,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    final created = (await _thumbnailTempDirectories()).difference(before);
    if (created.length >= count) return created;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Thumbnail output directories were not created.');
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Thumbnail cleanup did not finish.');
}

/// Creates a valid PNG with width and height in IHDR set to [width] and [height],
/// computing the correct CRC32 for the IHDR chunk.
Uint8List _createOversizedPng(int width, int height) {
  // A minimal valid 1x1 PNG data structure
  final png = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG signature
    0x00, 0x00, 0x00, 0x0d, // IHDR chunk length = 13
    0x49, 0x48, 0x44, 0x52, // 'IHDR'
    0x00, 0x00, 0x00, 0x01, // width = 1
    0x00, 0x00, 0x00, 0x01, // height = 1
    0x08, 0x06, 0x00, 0x00, 0x00, // 8-bit RGBA
    0x1f, 0x15, 0xc4, 0x89, // CRC32 for original 1x1
    // IDAT chunk:
    0x00, 0x00, 0x00, 0x0a,
    0x49, 0x44, 0x41, 0x54,
    0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
    0x0d, 0x0a, 0x2d, 0xb4,
    // IEND chunk:
    0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4e, 0x44,
    0xae, 0x42, 0x60, 0x82,
  ]);

  // Overwrite width and height
  final bdata = ByteData.view(png.buffer);
  bdata.setUint32(16, width);
  bdata.setUint32(20, height);

  // Recompute CRC32 for chunk data: bytes 12..29 (type + data)
  final crc = _crc32(png.sublist(12, 29));
  bdata.setUint32(29, crc);

  return png;
}

int _crc32(List<int> bytes) {
  int crc = 0xffffffff;
  for (final b in bytes) {
    crc ^= b;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xedb88320 : (crc >>> 1);
    }
  }
  return (~crc) & 0xffffffff;
}

typedef _ExtractCallback =
    Future<ThumbnailExtraction?> Function(
      String source,
      Directory outputDirectory, [
      ThumbnailCancellation? cancellation,
    ]);

class _FakeExtractor implements ThumbnailExtractor {
  _FakeExtractor({
    this.result,
    this.probedDuration = const Duration(seconds: 19),
    _ExtractCallback? onExtract,
    // ignore: prefer_initializing_formals
  }) : _onExtract = onExtract;

  final ThumbnailExtraction? result;
  final Duration probedDuration;
  final _ExtractCallback? _onExtract;
  int extractCalls = 0;
  int probeCalls = 0;
  bool disposed = false;
  bool outputDirectoryExistedDuringExtraction = false;
  Directory? lastOutputDirectory;
  ThumbnailCancellation? lastCancellation;

  @override
  Future<ThumbnailExtraction?> extract(
    String source, {
    required Directory outputDirectory,
    ThumbnailCancellation? cancellation,
  }) async {
    extractCalls++;
    lastCancellation = cancellation;
    lastOutputDirectory = outputDirectory;
    outputDirectoryExistedDuringExtraction = await outputDirectory.exists();
    final callback = _onExtract;
    if (callback != null) {
      return callback(source, outputDirectory, cancellation);
    }
    return result;
  }

  @override
  Future<Duration> probeDuration(
    String source, {
    ThumbnailCancellation? cancellation,
  }) async {
    probeCalls++;
    lastCancellation = cancellation;
    return probedDuration;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _SpyPlayerState implements PlayerState {
  @override
  Duration get duration => const Duration(seconds: 120);

  @override
  Tracks get tracks => const Tracks(video: [VideoTrack('1', 'video', '1080p')]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SpyNativePlayer implements NativePlayer {
  final Map<String, String> properties = <String, String>{};

  @override
  Future<void> setProperty(
    String name,
    String value, {
    bool waitForInitialization = true,
  }) async {
    properties[name] = value;
  }

  @override
  Future<String> getProperty(
    String name, {
    bool waitForInitialization = true,
  }) async {
    if (name == 'duration') return '120.0';
    return properties[name] ?? '';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SpyPlayer implements Player {
  final _SpyNativePlayer _platform = _SpyNativePlayer();
  final _SpyPlayerState _state = _SpyPlayerState();
  Future<void> Function()? onPlay;
  int stopCalls = 0;
  int disposeCalls = 0;
  int openCalls = 0;
  int playCalls = 0;
  bool isDisposed = false;

  @override
  NativePlayer get platform => _platform;

  @override
  PlayerState get state => _state;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCalls++;
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> play() async {
    playCalls++;
    await onPlay?.call();
    final outdir = _platform.properties['vo-image-outdir'];
    if (outdir != null) {
      final frameFile = File(p.join(outdir, '00000001.jpg'));
      await frameFile.writeAsBytes(_jpeg(42), flush: true);
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    isDisposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
