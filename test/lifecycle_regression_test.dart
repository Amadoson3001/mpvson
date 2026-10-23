import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watcher/watcher.dart';

import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/data/repositories/in_memory_media_library_repository.dart';
import 'package:mpvson/data/repositories/media_library_repository_impl.dart';
import 'package:mpvson/data/services/media_probe_service.dart';
import 'package:mpvson/data/services/media_probe_service_impl.dart';
import 'package:mpvson/data/services/media_scanner_service.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/ui/library/viewmodels/library_view_model.dart';

void main() {
  test(
    'database close drains concurrent callers and allows a clean reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mpvson-db-close-',
      );
      final path = '${directory.path}${Platform.pathSeparator}library.db';
      try {
        final first = await LibraryDatabase.open(path: path);
        final folder = LibraryFolderRecord(
          path: '${directory.path}${Platform.pathSeparator}media',
          addedAt: DateTime.utc(2026, 1, 1),
        );
        await first.insertFolder(folder);
        await Future.wait<void>(<Future<void>>[first.close(), first.close()]);

        await expectLater(first.getFolder(folder.path), throwsStateError);

        final reopened = await LibraryDatabase.open(path: path);
        expect((await reopened.getFolder(folder.path))?.path, folder.path);
        await reopened.markFolderAvailability(folder.path, false);
        await reopened.close();

        final verified = await LibraryDatabase.open(path: path);
        expect((await verified.getFolder(folder.path))?.isAvailable, isFalse);
        await verified.close();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('repository disposal waits for an in-flight database open', () async {
    final opened = Completer<LibraryDatabase>();
    final repository = MediaLibraryRepositoryImpl(
      databaseOpener: () => opened.future,
    );
    final initialization = repository.initialize();
    await Future<void>.delayed(Duration.zero);
    final disposal = repository.dispose();

    final database = await LibraryDatabase.open(inMemory: true);
    opened.complete(database);
    await Future.wait<void>(<Future<void>>[initialization, disposal]);

    expect(database.isClosed, isTrue);
  });

  test('a stale same-query search cannot replace the latest result', () async {
    final repository = _DelayedQueryRepository();
    final viewModel = LibraryViewModel(
      repository: repository,
      searchDebounceDuration: Duration.zero,
    );
    final oldSearch = viewModel.search('same');
    final newSearch = viewModel.search('same');
    expect(repository.pending, hasLength(2));

    final latest = _mediaItem('latest');
    repository.pending[1].complete(<MediaItemRecord>[latest]);
    await newSearch;
    repository.pending[0].complete(<MediaItemRecord>[_mediaItem('stale')]);
    await oldSearch;

    expect(viewModel.searchResults.single.id, 'latest');
    expect(viewModel.isSearching, isFalse);
    viewModel.dispose();
  });

  test(
    'cancelling probes keeps their native concurrency slots until drained',
    () async {
      final directory = await Directory.systemTemp.createTemp('mpvson-probe-');
      final engine = _QueuedProbeEngine();
      final service = MediaProbeServiceImpl(
        engine: engine,
        maxConcurrentProbes: 2,
      );
      try {
        final files = <File>[
          File('${directory.path}${Platform.pathSeparator}one.mp3'),
          File('${directory.path}${Platform.pathSeparator}two.mp3'),
          File('${directory.path}${Platform.pathSeparator}three.mp3'),
        ];
        for (final file in files) {
          await file.writeAsBytes(<int>[1]);
        }

        final first = _captureCancellation(service.probe(files[0].path));
        final second = _captureCancellation(service.probe(files[1].path));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engine.started, 2);

        service.cancelAll();
        final third = service.probe(files[2].path);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engine.started, 2);

        engine.completeNext();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(engine.started, 3);
        engine.completeNext();
        engine.completeNext();

        expect(await first, isTrue);
        expect(await second, isTrue);
        expect((await third).path, files[2].path);
        expect(engine.maxActive, 2);
      } finally {
        service.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'overlapping scans stay serialized while replacement requests queue',
    () async {
      final parent = await Directory.systemTemp.createTemp('mpvson-scan-');
      final firstRoot = Directory(
        '${parent.path}${Platform.pathSeparator}first',
      );
      final secondRoot = Directory(
        '${parent.path}${Platform.pathSeparator}second',
      );
      final latestRoot = Directory(
        '${parent.path}${Platform.pathSeparator}latest',
      );
      await Future.wait<void>(<Future<void>>[
        firstRoot.create(),
        secondRoot.create(),
        latestRoot.create(),
      ]);
      final entered = <String, Completer<void>>{};
      final releases = <String, Completer<void>>{};
      final completedRoots = <String>[];
      var activeCallbacks = 0;
      var maxActiveCallbacks = 0;
      final scanner = MediaScannerService(
        probeService: _EmptyProbeService(),
        debounceDuration: Duration.zero,
        watcherFactory: (_) => _FakeDirectoryWatcher(),
        onFolderAvailabilityChanged: (path, available) async {
          activeCallbacks++;
          if (activeCallbacks > maxActiveCallbacks) {
            maxActiveCallbacks = activeCallbacks;
          }
          final release = Completer<void>();
          entered[path] = Completer<void>()..complete();
          releases[path] = release;
          await release.future;
          activeCallbacks--;
        },
        onFolderScanCompleted:
            (path, {required fileCount, required lastScannedAt}) async {
              completedRoots.add(path);
            },
      );
      try {
        final first = scanner.scanFolder(firstRoot.path);
        await _waitForCondition(() => entered.containsKey(firstRoot.path));
        final second = scanner.scanFolder(secondRoot.path);
        final third = scanner.scanFolder(latestRoot.path);

        releases[firstRoot.path]!.complete();
        await _waitForCondition(() => entered.containsKey(latestRoot.path));
        for (final release in releases.values) {
          if (!release.isCompleted) release.complete();
        }
        await Future.wait<void>(<Future<void>>[first, second, third]);

        expect(completedRoots, contains(latestRoot.path));
        expect(maxActiveCallbacks, 1);
      } finally {
        for (final release in releases.values) {
          if (!release.isCompleted) release.complete();
        }
        await scanner.dispose();
        await parent.delete(recursive: true);
      }
    },
  );

  test('unregister stops a deferred watcher overflow scan', () async {
    final directory = await Directory.systemTemp.createTemp('mpvson-watch-');
    final watcher = _FakeDirectoryWatcher();
    final availabilityEntered = Completer<void>();
    final releaseAvailability = Completer<void>();
    var availabilityWrites = 0;
    var discoveredWrites = 0;
    var scanCompletedWrites = 0;
    final scanner = MediaScannerService(
      probeService: _EmptyProbeService(),
      debounceDuration: Duration.zero,
      watcherFactory: (_) => watcher,
      onFolderScanCompleted:
          (path, {required fileCount, required lastScannedAt}) async {
            scanCompletedWrites++;
          },
      onFolderAvailabilityChanged: (path, available) async {
        availabilityWrites++;
        if (!availabilityEntered.isCompleted) {
          availabilityEntered.complete();
          await releaseAvailability.future;
        }
      },
      onDiscoveredFiles: (_) async {
        discoveredWrites++;
      },
    );
    try {
      scanner.registerFolder(directory.path);
      for (var i = 0; i < 2049; i++) {
        watcher.add(
          WatchEvent(
            ChangeType.ADD,
            '${directory.path}${Platform.pathSeparator}$i.mp3',
          ),
        );
      }
      await availabilityEntered.future.timeout(const Duration(seconds: 2));
      scanner.unregisterFolder(directory.path);
      releaseAvailability.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(availabilityWrites, 1);
      expect(discoveredWrites, 0);
      expect(scanCompletedWrites, 0);
    } finally {
      if (!releaseAvailability.isCompleted) releaseAvailability.complete();
      await scanner.dispose();
      await directory.delete(recursive: true);
    }
  });
}

Future<void> _waitForCondition(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

class _FakeDirectoryWatcher implements DirectoryWatcher {
  final StreamController<WatchEvent> _events =
      StreamController<WatchEvent>.broadcast();

  void add(WatchEvent event) => _events.add(event);

  @override
  String get directory => path;

  @override
  String get path => '';

  @override
  Stream<WatchEvent> get events => _events.stream;

  @override
  bool get isReady => true;

  @override
  Future<void> get ready async {}
}

class _EmptyProbeService implements MediaProbeService {
  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) =>
      Future<ProbeResult>.error(UnsupportedError('No probes expected'));

  @override
  Future<String?> resolveArtwork(
    String filePath, {
    bool embeddedOnly = false,
  }) async => null;

  @override
  void cancelAll() {}

  @override
  void dispose() {}
}

Future<bool> _captureCancellation(Future<ProbeResult> request) async {
  try {
    await request;
    return false;
  } on ProbeCancelledException {
    return true;
  }
}

MediaItemRecord _mediaItem(String id) => MediaItemRecord(
  id: id,
  canonicalSource: id,
  path: '$id.mp3',
  kind: MediaKind.audio,
  metadata: const MediaMetadata(title: 'same'),
  addedAt: DateTime.utc(2026, 1, 1),
);

class _DelayedQueryRepository extends InMemoryMediaLibraryRepository {
  final List<Completer<List<MediaItemRecord>>> pending =
      <Completer<List<MediaItemRecord>>>[];

  @override
  Future<List<MediaItemRecord>> queryMedia({
    MediaKind? kind,
    String? searchQuery,
    String? artist,
    String? album,
    bool? onlyFavorites,
    bool onlyPlayed = false,
    int? limit,
    int? offset,
    String? sortBy,
    bool ascending = true,
  }) {
    final completer = Completer<List<MediaItemRecord>>();
    pending.add(completer);
    return completer.future;
  }
}

class _QueuedProbeEngine implements MediaProbeEngine {
  final List<Completer<DiscoveredMediaInfo?>> _requests =
      <Completer<DiscoveredMediaInfo?>>[];
  int active = 0;
  int maxActive = 0;
  int started = 0;

  @override
  Future<DiscoveredMediaInfo?> inspect(
    String filePath, {
    required bool isAudioHint,
    CancellationToken? cancellationToken,
  }) async {
    final completer = Completer<DiscoveredMediaInfo?>();
    _requests.add(completer);
    started++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      return await completer.future;
    } finally {
      active--;
    }
  }

  void completeNext() {
    _requests
        .removeAt(0)
        .complete(
          const DiscoveredMediaInfo(
            tracks: <DiscoveredTrack>[
              DiscoveredTrack(id: 'audio', isVideo: false, isAudio: true),
            ],
            rawTags: <String, String>{},
          ),
        );
  }

  @override
  Future<Uint8List?> extractEmbeddedArtwork(
    String filePath, {
    CancellationToken? cancellationToken,
  }) async => null;

  @override
  void dispose() {}
}
