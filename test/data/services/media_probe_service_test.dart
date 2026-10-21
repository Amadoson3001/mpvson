import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/media_probe_service.dart';
import 'package:mpvson/data/services/media_probe_service_impl.dart';
import 'package:mpvson/domain/models/media_kind.dart';
import 'package:path/path.dart' as p;

/// Mock test engine allowing deterministic control of discovered media info and artwork.
class MockMediaProbeEngine implements MediaProbeEngine {
  MockMediaProbeEngine({
    this.inspectHandler,
    this.extractArtworkHandler,
  });

  Future<DiscoveredMediaInfo?> Function(
    String filePath, {
    required bool isAudioHint,
    CancellationToken? cancellationToken,
  })? inspectHandler;

  Future<Uint8List?> Function(
    String filePath, {
    CancellationToken? cancellationToken,
  })? extractArtworkHandler;

  int inspectCallCount = 0;
  int artworkCallCount = 0;
  bool isDisposed = false;

  @override
  Future<DiscoveredMediaInfo?> inspect(
    String filePath, {
    required bool isAudioHint,
    CancellationToken? cancellationToken,
  }) async {
    inspectCallCount++;
    if (inspectHandler != null) {
      return await inspectHandler!(
        filePath,
        isAudioHint: isAudioHint,
        cancellationToken: cancellationToken,
      );
    }
    return null;
  }

  @override
  Future<Uint8List?> extractEmbeddedArtwork(
    String filePath, {
    CancellationToken? cancellationToken,
  }) async {
    artworkCallCount++;
    if (extractArtworkHandler != null) {
      return await extractArtworkHandler!(
        filePath,
        cancellationToken: cancellationToken,
      );
    }
    return null;
  }

  @override
  void dispose() {
    isDisposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory cacheDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mpvson-probe-test-');
    cacheDir = Directory(p.join(tempDir.path, 'cache'))..createSync();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Classification of audio vs video', () {
    test('audio without artwork is classified as MediaKind.audio', () async {
      final audioFile = File(p.join(tempDir.path, 'song.mp3'))..writeAsBytesSync(<int>[1, 2, 3]);

      final engine = MockMediaProbeEngine(
        inspectHandler: (filePath, {required isAudioHint, cancellationToken}) async {
          return const DiscoveredMediaInfo(
            tracks: [
              DiscoveredTrack(id: '1', isVideo: false, isAudio: true, codec: 'mp3'),
            ],
            rawTags: {'title': 'My Song'},
            hasEmbeddedArtwork: false,
          );
        },
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
      );
      addTearDown(service.dispose);

      final result = await service.probe(audioFile.path);
      expect(result.kind, MediaKind.audio);
      expect(result.hasEmbeddedArtwork, isFalse);
      expect(result.metadata.title, 'My Song');
      expect(result.fileSize, 3);
    });

    test('audio with embedded artwork is classified as MediaKind.audio and NOT video', () async {
      final audioFile = File(p.join(tempDir.path, 'album_track.flac'))..writeAsBytesSync(<int>[1, 2, 3, 4]);

      final engine = MockMediaProbeEngine(
        inspectHandler: (filePath, {required isAudioHint, cancellationToken}) async {
          return const DiscoveredMediaInfo(
            tracks: [
              DiscoveredTrack(id: '1', isVideo: false, isAudio: true, codec: 'flac'),
              DiscoveredTrack(id: '2', isVideo: true, isArtwork: true, codec: 'mjpeg'),
            ],
            rawTags: {'title': 'Track with Art'},
            hasEmbeddedArtwork: true,
          );
        },
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
      );
      addTearDown(service.dispose);

      final result = await service.probe(audioFile.path);
      expect(result.kind, MediaKind.audio);
      expect(result.kind.isVideo, isFalse);
      expect(result.hasEmbeddedArtwork, isTrue);
    });

    test('artwork-only video tracks must NEVER classify a song as video', () {
      final tracks = [
        const DiscoveredTrack(id: '1', isVideo: false, isAudio: true),
        const DiscoveredTrack(id: 'cover', isVideo: true, isArtwork: true),
        const DiscoveredTrack(id: 'back', isVideo: true, isArtwork: true),
      ];

      final kind = MediaProbeServiceImpl.classifyMediaKind('song.mp3', tracks);
      expect(kind, MediaKind.audio);
      expect(kind, isNot(MediaKind.video));
    });

    test('ordinary video tracks classify as MediaKind.video', () async {
      final videoFile = File(p.join(tempDir.path, 'movie.mp4'))..writeAsBytesSync(<int>[1, 2]);

      final engine = MockMediaProbeEngine(
        inspectHandler: (filePath, {required isAudioHint, cancellationToken}) async {
          return const DiscoveredMediaInfo(
            tracks: [
              DiscoveredTrack(id: '1', isVideo: true, isArtwork: false, codec: 'h264'),
              DiscoveredTrack(id: '2', isVideo: false, isAudio: true, codec: 'aac'),
            ],
            rawTags: {'title': 'Feature Film'},
            hasEmbeddedArtwork: false,
          );
        },
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
      );
      addTearDown(service.dispose);

      final result = await service.probe(videoFile.path);
      expect(result.kind, MediaKind.video);
      expect(result.kind.isVideo, isTrue);
      expect(result.hasEmbeddedArtwork, isFalse);
    });

    test('audio probes receive isAudioHint=true to finish early', () async {
      final audioFile = File(p.join(tempDir.path, 'quick.flac'))..writeAsBytesSync(<int>[1]);
      bool? receivedAudioHint;

      final engine = MockMediaProbeEngine(
        inspectHandler: (filePath, {required isAudioHint, cancellationToken}) async {
          receivedAudioHint = isAudioHint;
          return const DiscoveredMediaInfo(
            tracks: [DiscoveredTrack(id: '1', isVideo: false, isAudio: true)],
            rawTags: {'title': 'Quick'},
          );
        },
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
      );
      addTearDown(service.dispose);

      await service.probe(audioFile.path);
      expect(receivedAudioHint, isTrue);
    });
  });

  group('Metadata tag normalization', () {
    test('normalizes tag keys case-insensitively and parses values', () {
      final rawTags = <String, String>{
        'TITLE': 'Bohemian Rhapsody',
        'ARTIST': 'Queen',
        'ALBUM_ARTIST': 'Queen Official',
        'ALBUM': 'A Night at the Opera',
        'GENRE': 'Classic Rock',
        'DATE': '1975-10-31',
        'TRACK': '11/12',
        'DISC': '1/2',
        'CODEC': 'flac',
        'SAMPLERATE': '96000',
        'CHANNELS': '2',
        'BITRATE': '1411000',
      };

      final metadata = MediaProbeServiceImpl.normalizeMetadata(
        rawTags: rawTags,
        duration: const Duration(minutes: 5, seconds: 55),
      );

      expect(metadata.title, 'Bohemian Rhapsody');
      expect(metadata.artist, 'Queen');
      expect(metadata.albumArtist, 'Queen Official');
      expect(metadata.album, 'A Night at the Opera');
      expect(metadata.genre, 'Classic Rock');
      expect(metadata.year, 1975);
      expect(metadata.trackNumber, 11);
      expect(metadata.discNumber, 1);
      expect(metadata.duration, const Duration(minutes: 5, seconds: 55));
      expect(metadata.audioInfo?.codec, 'flac');
      expect(metadata.audioInfo?.sampleRate, 96000);
      expect(metadata.audioInfo?.channels, 2);
      expect(metadata.audioInfo?.bitrate, 1411000);
    });

    test('handles tag aliases: albumartist, album-artist, tracknumber, etc.', () {
      final rawTags1 = <String, String>{
        'title': 'Track 1',
        'albumartist': 'Artist A',
        'tracknumber': '4',
        'discnumber': '2',
        'year': '1999',
      };
      final meta1 = MediaProbeServiceImpl.normalizeMetadata(
        rawTags: rawTags1,
        duration: Duration.zero,
      );
      expect(meta1.albumArtist, 'Artist A');
      expect(meta1.trackNumber, 4);
      expect(meta1.discNumber, 2);
      expect(meta1.year, 1999);

      final rawTags2 = <String, String>{
        'track_number': '05 of 10',
        'album-artist': 'Artist B',
        'disc_number': '1 of 1',
        'original_year': '1984',
      };
      final meta2 = MediaProbeServiceImpl.normalizeMetadata(
        rawTags: rawTags2,
        duration: Duration.zero,
      );
      expect(meta2.albumArtist, 'Artist B');
      expect(meta2.trackNumber, 5);
      expect(meta2.discNumber, 1);
      expect(meta2.year, 1984);
    });
  });

  group('Artwork extraction and nearby fallback', () {
    test('prefers embedded artwork over nearby files', () async {
      final albumDir = Directory(p.join(tempDir.path, 'album1'))..createSync();
      final songFile = File(p.join(albumDir.path, 'song.mp3'))..writeAsBytesSync(<int>[1]);
      File(p.join(albumDir.path, 'cover.jpg')).writeAsBytesSync(<int>[2, 2, 2]);

      final embeddedBytes = Uint8List.fromList(<int>[9, 9, 9]);

      final engine = MockMediaProbeEngine(
        extractArtworkHandler: (filePath, {cancellationToken}) async {
          return embeddedBytes;
        },
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
        imageNormalizer: (bytes, {maxDimension = 1024}) async => bytes,
      );
      addTearDown(service.dispose);

      final resolvedPath = await service.resolveArtwork(songFile.path);
      expect(resolvedPath, isNotNull);
      final savedBytes = File(resolvedPath!).readAsBytesSync();
      expect(savedBytes, embeddedBytes);
    });

    test('falls back to nearby cover.jpg when no embedded artwork exists', () async {
      final albumDir = Directory(p.join(tempDir.path, 'album2'))..createSync();
      final songFile = File(p.join(albumDir.path, 'song.flac'))..writeAsBytesSync(<int>[1]);
      final coverFile = File(p.join(albumDir.path, 'cover.jpg'))..writeAsBytesSync(<int>[5, 6, 7]);

      final engine = MockMediaProbeEngine(
        extractArtworkHandler: (filePath, {cancellationToken}) async => null,
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
        imageNormalizer: (bytes, {maxDimension = 1024}) async => bytes,
      );
      addTearDown(service.dispose);

      final resolvedPath = await service.resolveArtwork(songFile.path);
      expect(resolvedPath, isNotNull);
      expect(resolvedPath, isNot(coverFile.path)); // Saved into cache directory
      expect(File(resolvedPath!).readAsBytesSync(), <int>[5, 6, 7]);
    });

    test('falls back to front.png and folder.jpg when cover.jpg is missing', () async {
      final albumDir = Directory(p.join(tempDir.path, 'album3'))..createSync();
      final songFile = File(p.join(albumDir.path, 'track.m4a'))..writeAsBytesSync(<int>[1]);
      File(p.join(albumDir.path, 'folder.jpg')).writeAsBytesSync(<int>[8, 9, 10]);

      final engine = MockMediaProbeEngine(
        extractArtworkHandler: (filePath, {cancellationToken}) async => null,
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
        imageNormalizer: (bytes, {maxDimension = 1024}) async => bytes,
      );
      addTearDown(service.dispose);

      final resolvedPath = await service.resolveArtwork(songFile.path);
      expect(resolvedPath, isNotNull);
      expect(File(resolvedPath!).readAsBytesSync(), <int>[8, 9, 10]);
    });

    test('embeddedOnly=true ignores nearby artwork', () async {
      final albumDir = Directory(p.join(tempDir.path, 'album4'))..createSync();
      final songFile = File(p.join(albumDir.path, 'track.mp3'))..writeAsBytesSync(<int>[1]);
      File(p.join(albumDir.path, 'cover.png')).writeAsBytesSync(<int>[1, 2, 3]);

      final engine = MockMediaProbeEngine(
        extractArtworkHandler: (filePath, {cancellationToken}) async => null,
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
        imageNormalizer: (bytes, {maxDimension = 1024}) async => bytes,
      );
      addTearDown(service.dispose);

      final resolved = await service.resolveArtwork(songFile.path, embeddedOnly: true);
      expect(resolved, isNull);
    });
  });

  group('Bounded artwork rendition and cache eviction', () {
    test('normalizer bounds artwork dimension up to 1024px', () async {
      final songFile = File(p.join(tempDir.path, 'art_bound.mp3'))..writeAsBytesSync(<int>[1]);
      final rawLargeArtwork = Uint8List.fromList(<int>[10, 20, 30, 40]);
      int? requestedMaxDimension;

      final engine = MockMediaProbeEngine(
        extractArtworkHandler: (filePath, {cancellationToken}) async => rawLargeArtwork,
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
        maxArtworkDimension: 1024,
        imageNormalizer: (bytes, {int maxDimension = 1024}) async {
          requestedMaxDimension = maxDimension;
          return Uint8List.fromList(<int>[99]);
        },
      );
      addTearDown(service.dispose);

      final resolvedPath = await service.resolveArtwork(songFile.path);
      expect(resolvedPath, isNotNull);
      expect(requestedMaxDimension, 1024);
      expect(File(resolvedPath!).readAsBytesSync(), <int>[99]);
    });

    test('retains only a bounded cache and evicts oldest files', () async {
      final file1 = File(p.join(tempDir.path, 'song1.mp3'))..writeAsBytesSync(<int>[1]);
      final file2 = File(p.join(tempDir.path, 'song2.mp3'))..writeAsBytesSync(<int>[2]);
      final file3 = File(p.join(tempDir.path, 'song3.mp3'))..writeAsBytesSync(<int>[3]);

      final engine = MockMediaProbeEngine(
        extractArtworkHandler: (filePath, {cancellationToken}) async {
          if (filePath.contains('song1')) return Uint8List.fromList([1, 1]);
          if (filePath.contains('song2')) return Uint8List.fromList([2, 2]);
          if (filePath.contains('song3')) return Uint8List.fromList([3, 3]);
          return null;
        },
      );

      // Max 2 entries in cache
      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
        maxCacheEntries: 2,
        imageNormalizer: (bytes, {maxDimension = 1024}) async => bytes,
      );
      addTearDown(service.dispose);

      final path1 = await service.resolveArtwork(file1.path);
      final path2 = await service.resolveArtwork(file2.path);
      expect(File(path1!).existsSync(), isTrue);
      expect(File(path2!).existsSync(), isTrue);

      // Adding 3rd artwork should evict path1 from disk
      final path3 = await service.resolveArtwork(file3.path);
      expect(File(path3!).existsSync(), isTrue);
      expect(File(path2).existsSync(), isTrue);
      expect(File(path1).existsSync(), isFalse); // Evicted and removed!
    });
  });

  group('Prioritization and cancellation', () {
    test('cancelAll cancels queued and in-flight probes with ProbeCancelledException', () async {
      final file1 = File(p.join(tempDir.path, 'f1.mp3'))..writeAsBytesSync(<int>[1]);
      final file2 = File(p.join(tempDir.path, 'f2.mp3'))..writeAsBytesSync(<int>[2]);

      final completer = Completer<void>();
      final engine = MockMediaProbeEngine(
        inspectHandler: (filePath, {required isAudioHint, cancellationToken}) async {
          await completer.future;
          return const DiscoveredMediaInfo(
            tracks: [DiscoveredTrack(id: '1', isVideo: false, isAudio: true)],
            rawTags: {},
          );
        },
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
        maxConcurrentProbes: 1,
      );
      addTearDown(service.dispose);

      final p1 = service.probe(file1.path);
      final p2 = service.probe(file2.path);

      service.cancelAll();
      completer.complete();

      expect(p1, throwsA(isA<ProbeCancelledException>()));
      expect(p2, throwsA(isA<ProbeCancelledException>()));
    });

    test('high-priority probe requests jump ahead of lower-priority requests in queue', () async {
      final runningFile = File(p.join(tempDir.path, 'active.mp3'))..writeAsBytesSync(<int>[1]);
      final lowFile = File(p.join(tempDir.path, 'low.mp3'))..writeAsBytesSync(<int>[2]);
      final highFile = File(p.join(tempDir.path, 'high.mp3'))..writeAsBytesSync(<int>[3]);

      final activeCompleter = Completer<void>();
      final executionOrder = <String>[];

      final engine = MockMediaProbeEngine(
        inspectHandler: (filePath, {required isAudioHint, cancellationToken}) async {
          if (filePath.contains('active')) {
            await activeCompleter.future;
          }
          executionOrder.add(p.basename(filePath));
          return const DiscoveredMediaInfo(
            tracks: [DiscoveredTrack(id: '1', isVideo: false, isAudio: true)],
            rawTags: {},
          );
        },
      );

      final service = MediaProbeServiceImpl(
        engine: engine,
        cacheDirectory: cacheDir,
        maxConcurrentProbes: 1,
      );
      addTearDown(service.dispose);

      // Start active probe (occupies single worker slot)
      final pActive = service.probe(runningFile.path, priority: 0);

      // Enqueue low-priority then high-priority
      final pLow = service.probe(lowFile.path, priority: 0);
      final pHigh = service.probe(highFile.path, priority: 10);

      // Release active probe
      activeCompleter.complete();

      await Future.wait([pActive, pLow, pHigh]);

      // high.mp3 should have run BEFORE low.mp3
      expect(executionOrder, ['active.mp3', 'high.mp3', 'low.mp3']);
    });
  });
}
