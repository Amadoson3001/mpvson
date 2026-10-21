import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/media_probe_service.dart';
import 'package:mpvson/data/services/media_scanner_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

class FakeMediaProbeService implements MediaProbeService {
  final List<String> probedFiles = <String>[];
  bool throwOnProbe = false;
  Completer<void>? probeBlocker;
  int cancelCount = 0;

  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) async {
    probedFiles.add(filePath);
    if (probeBlocker != null) {
      await probeBlocker!.future;
    }
    if (throwOnProbe) {
      throw Exception('Simulated probe failure');
    }
    return ProbeResult(
      canonicalSource: filePath,
      path: filePath,
      kind: MediaCatalog.kindFromExtension(filePath),
      metadata: MediaMetadata(title: p.basenameWithoutExtension(filePath)),
      fileSize: 1024,
      modifiedAt: DateTime.now(),
    );
  }

  @override
  Future<String?> resolveArtwork(String filePath, {bool embeddedOnly = false}) async =>
      null;

  @override
  void cancelAll() {
    cancelCount++;
    if (probeBlocker != null && !probeBlocker!.isCompleted) {
      probeBlocker!.complete();
    }
  }

  @override
  void dispose() {}
}

class FakeDirectoryWatcher implements DirectoryWatcher {
  FakeDirectoryWatcher(this.path);

  @override
  final String path;

  @override
  String get directory => path;

  final StreamController<WatchEvent> _controller =
      StreamController<WatchEvent>.broadcast();

  @override
  Stream<WatchEvent> get events => _controller.stream;

  @override
  bool get isReady => true;

  @override
  Future<void> get ready => Future<void>.value();

  void emit(WatchEvent event) {
    _controller.add(event);
  }

  void emitError(Object error) {
    _controller.addError(error);
  }

  void close() {
    _controller.close();
  }
}

void main() {
  group('MediaScannerService - Folder Deduplication', () {
    test('deduplicates overlapping child folders', () {
      final posixContext = p.Context(style: p.Style.posix);
      final folders = <String>[
        '/media/music',
        '/media/music/rock',
        '/media/videos',
        '/media/music/jazz/fusion',
      ];

      final roots = MediaScannerService.deduplicateFolderRoots(
        folders,
        pathContext: posixContext,
      );

      expect(roots, contains('/media/music'));
      expect(roots, contains('/media/videos'));
      expect(roots, isNot(contains('/media/music/rock')));
      expect(roots, isNot(contains('/media/music/jazz/fusion')));
      expect(roots.length, equals(2));
    });

    test('deduplicates child folders regardless of input order', () {
      final posixContext = p.Context(style: p.Style.posix);
      final folders = <String>[
        '/media/music/rock',
        '/media/music',
      ];

      final roots = MediaScannerService.deduplicateFolderRoots(
        folders,
        pathContext: posixContext,
      );

      expect(roots, equals(<String>['/media/music']));
    });

    test('deduplicates exact duplicates and trailing slashes', () {
      final posixContext = p.Context(style: p.Style.posix);
      final folders = <String>[
        '/media/music/',
        '/media/music',
        '/media/videos',
      ];

      final roots = MediaScannerService.deduplicateFolderRoots(
        folders,
        pathContext: posixContext,
      );

      expect(roots, equals(<String>['/media/music', '/media/videos']));
    });

    test('handles Windows drive paths and case-insensitivity', () {
      final winContext = p.Context(style: p.Style.windows);
      final folders = <String>[
        r'C:\Music',
        r'c:\music\Rock',
        r'D:\Movies',
      ];

      final roots = MediaScannerService.deduplicateFolderRoots(
        folders,
        pathContext: winContext,
      );

      expect(roots.length, equals(2));
      expect(roots.any((r) => r.toLowerCase() == r'c:\music'), isTrue);
      expect(roots.any((r) => r.toLowerCase() == r'd:\movies'), isTrue);
    });
  });

  group('MediaScannerService - Directory Traversal & Symlinks', () {
    late Directory tempDir;
    late Directory musicDir;
    late Directory externalDir;
    late FakeMediaProbeService fakeProbe;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mpvson_scanner_test_');
      musicDir = Directory(p.join(tempDir.path, 'Music'))..createSync();
      externalDir = Directory(p.join(tempDir.path, 'External'))..createSync();
      fakeProbe = FakeMediaProbeService();

      // Create supported audio/video files
      File(p.join(musicDir.path, 'track1.mp3')).writeAsStringSync('dummy mp3');
      File(p.join(musicDir.path, 'track2.flac')).writeAsStringSync('dummy flac');
      File(p.join(musicDir.path, 'notes.txt')).writeAsStringSync('text');

      // Create a subfolder with video
      final subDir = Directory(p.join(musicDir.path, 'Movies'))..createSync();
      File(p.join(subDir.path, 'movie.mp4')).writeAsStringSync('dummy mp4');

      // Create external files
      File(p.join(externalDir.path, 'secret.mp3')).writeAsStringSync('secret');

      // Create symlink pointing from musicDir/link_to_external to externalDir
      try {
        final link = Link(p.join(musicDir.path, 'link_to_external'));
        link.createSync(externalDir.path);
      } catch (_) {
        // Symlink creation may require elevated privileges on some Windows versions;
        // if not permitted, test continues for ordinary traversal.
      }
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('discovers supported media and NEVER traverses directory symlinks', () async {
      final discoveredFiles = <String>[];
      final enrichedUpdates = <String>[];

      final scanner = MediaScannerService(
        probeService: fakeProbe,
        onDiscoveredFiles: (paths) async {
          discoveredFiles.addAll(paths);
        },
        onUpdateMetadata: (source, {required kind, required metadata, required fileSize, required modifiedAt}) async {
          enrichedUpdates.add(source);
        },
      );

      await scanner.scanFolder(musicDir.path);

      final discoveredNames = discoveredFiles.map((p0) => p.basename(p0)).toSet();

      // Supported files inside musicDir and subDir must be discovered
      expect(discoveredNames, contains('track1.mp3'));
      expect(discoveredNames, contains('track2.flac'));
      expect(discoveredNames, contains('movie.mp4'));

      // Unsupported file must NOT be discovered
      expect(discoveredNames, isNot(contains('notes.txt')));

      // Symlinked external folder must NOT be traversed!
      expect(discoveredNames, isNot(contains('secret.mp3')));

      // Metadata must have been enriched
      expect(enrichedUpdates.length, equals(3));
      expect(fakeProbe.probedFiles.length, equals(3));

      await scanner.dispose();
    });

    test('marks missing or disconnected folder unavailable and does not delete', () async {
      final availabilityChanges = <String, bool>{};

      final scanner = MediaScannerService(
        probeService: fakeProbe,
        onFolderAvailabilityChanged: (folder, isAvailable) async {
          availabilityChanges[folder] = isAvailable;
        },
      );

      final nonExistentPath = p.join(tempDir.path, 'DisconnectedDriveFolder');
      await scanner.scanFolder(nonExistentPath);

      expect(availabilityChanges[nonExistentPath], isFalse);
      expect(scanner.scanStatus.discoveredCount, equals(0));

      await scanner.dispose();
    });

    test('handles unreadable or probe failure gracefully without aborting scan', () async {
      fakeProbe.throwOnProbe = true;
      final discovered = <String>[];
      final metadataUpdates = <String>[];

      final scanner = MediaScannerService(
        probeService: fakeProbe,
        onDiscoveredFiles: (paths) async {
          discovered.addAll(paths);
        },
        onUpdateMetadata: (source, {required kind, required metadata, required fileSize, required modifiedAt}) async {
          metadataUpdates.add(source);
        },
      );

      await scanner.scanFolder(musicDir.path);

      // Even with probe throwing, fallback metadata is recorded and scan completes
      expect(discovered.length, equals(3));
      expect(metadataUpdates.length, equals(3));
      expect(scanner.scanStatus.phase, equals(ScanPhase.idle));

      await scanner.dispose();
    });

    test('supports cancellation midway through enrichment', () async {
      fakeProbe.probeBlocker = Completer<void>();

      final scanner = MediaScannerService(
        probeService: fakeProbe,
      );

      // Start scan in background
      final scanFuture = scanner.scanFolder(musicDir.path);

      // Wait until scan begins enriching
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(scanner.scanStatus.isScanning, isTrue);

      // Cancel scan
      scanner.cancelScan();
      await scanFuture;

      expect(scanner.scanStatus.phase, equals(ScanPhase.idle));
      expect(fakeProbe.cancelCount, greaterThan(0));

      await scanner.dispose();
    });
  });

  group('MediaScannerService - Watcher with Debounce', () {
    late FakeDirectoryWatcher fakeWatcher;
    late FakeMediaProbeService fakeProbe;

    setUp(() {
      fakeProbe = FakeMediaProbeService();
    });

    test('debounces rapid file watch events into single batch', () async {
      final discovered = <String>[];
      final availability = <String, bool>{};

      final scanner = MediaScannerService(
        probeService: fakeProbe,
        debounceDuration: const Duration(milliseconds: 60),
        watcherFactory: (path) {
          fakeWatcher = FakeDirectoryWatcher(path);
          return fakeWatcher;
        },
        onDiscoveredFiles: (paths) async {
          discovered.addAll(paths);
        },
        onFileAvailabilityChanged: (path, isAvailable) async {
          availability[path] = isAvailable;
        },
      );

      final testDir = Directory.systemTemp.createTempSync('mpvson_watcher_test_');
      final file1 = File(p.join(testDir.path, 'song1.mp3'))..writeAsStringSync('1');
      final file2 = File(p.join(testDir.path, 'song2.flac'))..writeAsStringSync('2');

      try {
        scanner.registerFolder(testDir.path);

        // Rapidly emit watch events
        fakeWatcher.emit(WatchEvent(ChangeType.ADD, file1.path));
        fakeWatcher.emit(WatchEvent(ChangeType.MODIFY, file1.path));
        fakeWatcher.emit(WatchEvent(ChangeType.ADD, file2.path));

        // Before debounce fires: nothing discovered yet
        expect(discovered.isEmpty, isTrue);

        // Wait for debounce timer to expire
        await Future<void>.delayed(const Duration(milliseconds: 120));

        // Both files discovered in a single batch
        expect(discovered, contains(file1.path));
        expect(discovered, contains(file2.path));
        expect(discovered.length, equals(2));

        // Test REMOVE event
        fakeWatcher.emit(WatchEvent(ChangeType.REMOVE, file1.path));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(availability[file1.path], isFalse);
      } finally {
        await scanner.dispose();
        fakeWatcher.close();
        testDir.deleteSync(recursive: true);
      }
    });

    test('reconcile rescans registered folders', () async {
      final discovered = <String>[];
      final scanner = MediaScannerService(
        probeService: fakeProbe,
        onDiscoveredFiles: (paths) async {
          discovered.addAll(paths);
        },
      );

      final testDir = Directory.systemTemp.createTempSync('mpvson_reconcile_test_');
      final file = File(p.join(testDir.path, 'reconcile_song.mp3'))..writeAsStringSync('rec');

      try {
        scanner.registerFolder(testDir.path);
        await scanner.reconcile();

        expect(discovered, contains(file.path));
      } finally {
        await scanner.dispose();
        testDir.deleteSync(recursive: true);
      }
    });
  });
}
