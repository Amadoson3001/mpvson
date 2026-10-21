// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../../domain/models/library_models.dart';
import '../../domain/models/media_catalog.dart';
import '../repositories/database/library_database.dart';
import 'media_probe_service.dart';

typedef DiscoveredFilesCallback = Future<void> Function(List<String> paths);

typedef UpdateMetadataCallback = Future<void> Function(
  String canonicalSource, {
  required MediaKind kind,
  required MediaMetadata metadata,
  required int fileSize,
  required DateTime modifiedAt,
});

typedef FolderAvailabilityCallback = Future<void> Function(
  String folderPath,
  bool isAvailable,
);

typedef FolderScanCompletedCallback = Future<void> Function(
  String folderPath, {
  required int fileCount,
  required DateTime lastScannedAt,
});

typedef FileAvailabilityCallback = Future<void> Function(
  String filePath,
  bool isAvailable,
);

typedef RegisteredFoldersProvider = Future<List<LibraryFolderRecord>> Function();

typedef DirectoryWatcherFactory = DirectoryWatcher Function(String path);

/// Background media library scanner and folder watcher service.
///
/// Discovers supported media files in explicitly registered library folders,
/// watches for file system changes with debouncing, enriches metadata using
/// [MediaProbeService] through a bounded queue, and safely handles disconnected drives.
class MediaScannerService {
  MediaScannerService({
    required MediaProbeService probeService,
    LibraryDatabase? database,
    DiscoveredFilesCallback? onDiscoveredFiles,
    UpdateMetadataCallback? onUpdateMetadata,
    FolderAvailabilityCallback? onFolderAvailabilityChanged,
    FolderScanCompletedCallback? onFolderScanCompleted,
    FileAvailabilityCallback? onFileAvailabilityChanged,
    RegisteredFoldersProvider? getRegisteredFolders,
    Duration debounceDuration = const Duration(milliseconds: 500),
    int maxConcurrentProbes = 4,
    DirectoryWatcherFactory? watcherFactory,
    p.Context? pathContext,
  })  : _probeService = probeService,
        _database = database,
        _onDiscoveredFiles = onDiscoveredFiles ?? database?.batchUpsertDiscoveredFiles,
        _onUpdateMetadata = onUpdateMetadata ?? database?.updateMediaMetadata,
        _onFolderAvailabilityChanged =
            onFolderAvailabilityChanged ?? database?.markFolderAvailability,
        _onFolderScanCompleted = onFolderScanCompleted ??
            (database != null
                ? ((folder, {required fileCount, required lastScannedAt}) =>
                    database.updateFolderScanStats(
                      folder,
                      fileCount: fileCount,
                      lastScannedAt: lastScannedAt,
                    ))
                : null),
        _onFileAvailabilityChanged = onFileAvailabilityChanged,
        _getRegisteredFolders = getRegisteredFolders ?? database?.getAllFolders,
        _debounceDuration = debounceDuration,
        _maxConcurrentProbes = maxConcurrentProbes,
        _watcherFactory = watcherFactory ?? _defaultWatcherFactory,
        _pathContext = pathContext ?? p.context;

  final MediaProbeService _probeService;
  final LibraryDatabase? _database;
  final DiscoveredFilesCallback? _onDiscoveredFiles;
  final UpdateMetadataCallback? _onUpdateMetadata;
  final FolderAvailabilityCallback? _onFolderAvailabilityChanged;
  final FolderScanCompletedCallback? _onFolderScanCompleted;
  final FileAvailabilityCallback? _onFileAvailabilityChanged;
  final RegisteredFoldersProvider? _getRegisteredFolders;
  final Duration _debounceDuration;
  final int _maxConcurrentProbes;
  final DirectoryWatcherFactory _watcherFactory;
  final p.Context _pathContext;

  /// Optional underlying database reference if provided.
  LibraryDatabase? get database => _database;

  final Set<String> _explicitFolders = <String>{};
  final Map<String, DirectoryWatcher> _watchers = <String, DirectoryWatcher>{};
  final Map<String, StreamSubscription<WatchEvent>> _watcherSubscriptions =
      <String, StreamSubscription<WatchEvent>>{};
  final Map<String, Timer> _debounceTimers = <String, Timer>{};
  final Map<String, List<WatchEvent>> _pendingEvents =
      <String, List<WatchEvent>>{};

  final StreamController<LibraryScanStatus> _statusController =
      StreamController<LibraryScanStatus>.broadcast();

  LibraryScanStatus _status = const LibraryScanStatus();
  bool _isCancelled = false;
  bool _isDisposed = false;
  Future<void>? _currentScanFuture;

  /// Current scan status.
  LibraryScanStatus get scanStatus => _status;

  /// Stream of scan status updates.
  Stream<LibraryScanStatus> get scanStatusStream => _statusController.stream;

  /// Unmodifiable view of registered folders.
  List<String> get registeredFolders => List.unmodifiable(_explicitFolders);

  /// Unmodifiable view of currently watched folder paths.
  List<String> get watchedFolders => List.unmodifiable(_watchers.keys);

  static DirectoryWatcher _defaultWatcherFactory(String path) =>
      DirectoryWatcher(path);

  /// Deduplicates overlapping folder roots so parent folders supersede child subdirectories.
  ///
  /// For example, if both `C:\Music` and `C:\Music\Rock` are registered, only
  /// `C:\Music` is retained as a scan root.
  static List<String> deduplicateFolderRoots(
    Iterable<String> folders, {
    p.Context? pathContext,
  }) {
    final ctx = pathContext ?? p.context;
    final normalized = <String>[];
    for (final folder in folders) {
      final trimmed = folder.trim();
      if (trimmed.isEmpty) continue;
      final norm = ctx.normalize(ctx.absolute(trimmed));
      if (!normalized.any((existing) => ctx.equals(existing, norm))) {
        normalized.add(norm);
      }
    }

    normalized.sort((a, b) => a.length.compareTo(b.length));

    final roots = <String>[];
    for (final candidate in normalized) {
      final hasAncestor = roots.any(
        (root) => ctx.equals(root, candidate) || ctx.isWithin(root, candidate),
      );
      if (!hasAncestor) {
        roots.add(candidate);
      }
    }
    return roots;
  }

  /// Registers a folder to be scanned and watched.
  void registerFolder(String path) {
    if (_isDisposed) return;
    final norm = _pathContext.normalize(_pathContext.absolute(path));
    if (_explicitFolders.add(norm)) {
      _startWatching(norm);
    }
  }

  /// Unregisters a folder, stopping its watcher and removing it from registered folders.
  void unregisterFolder(String path) {
    if (_isDisposed) return;
    final norm = _pathContext.normalize(_pathContext.absolute(path));
    _explicitFolders.remove(norm);
    _stopWatching(norm);
  }

  /// Scans a specific folder.
  Future<void> scanFolder(String folderPath) async {
    if (_isDisposed) return;
    final norm = _pathContext.normalize(_pathContext.absolute(folderPath));
    registerFolder(norm);
    await _runScanRoots(<String>[norm]);
  }

  /// Scans all registered library folders (deduplicating overlapping roots).
  Future<void> scanAll({List<String>? folders}) async {
    if (_isDisposed) return;
    if (folders != null) {
      for (final f in folders) {
        registerFolder(f);
      }
    } else if (_getRegisteredFolders != null) {
      final dbFolders = await _getRegisteredFolders();
      for (final f in dbFolders) {
        registerFolder(f.path);
      }
    }
    await _runScanRoots(deduplicateFolderRoots(_explicitFolders, pathContext: _pathContext));
  }

  /// Reconciles changes across all registered folders.
  ///
  /// Can be called on application startup or resume.
  Future<void> reconcile() async {
    if (_isDisposed) return;
    _updateStatus(_status.copyWith(phase: ScanPhase.reconciling));
    await scanAll();
  }

  /// Cancels any in-progress scan and enrichment.
  void cancelScan() {
    _isCancelled = true;
    _probeService.cancelAll();
    _updateStatus(
      _status.copyWith(
        phase: ScanPhase.idle,
        errorMessage: null,
      ),
    );
  }

  Future<void> _runScanRoots(List<String> roots) async {
    if (_isDisposed) return;
    if (_currentScanFuture != null) {
      cancelScan();
      try {
        await _currentScanFuture;
      } catch (_) {}
    }

    _isCancelled = false;
    final scanCompleter = Completer<void>();
    _currentScanFuture = scanCompleter.future;

    try {
      _updateStatus(
        _status.copyWith(
          phase: ScanPhase.discovering,
          discoveredCount: 0,
          enrichedCount: 0,
          totalToEnrich: 0,
          errorMessage: null,
        ),
      );

      final allDiscoveredFiles = <String>[];

      for (final root in roots) {
        if (_isCancelled || _isDisposed) break;

        _updateStatus(_status.copyWith(currentFolder: root));

        // Check if root exists (detects disconnected drive or missing directory)
        final rootDir = Directory(root);
        bool exists = false;
        try {
          exists = await rootDir.exists();
        } catch (_) {
          exists = false;
        }

        if (!exists) {
          // Disconnected drive or missing folder is marked unavailable (is_available = 0), NEVER deleted!
          await _onFolderAvailabilityChanged?.call(root, false);
          continue;
        }

        // Folder is available
        await _onFolderAvailabilityChanged?.call(root, true);

        final folderDiscovered = <String>[];
        await for (final file in _traverseDirectory(root)) {
          if (_isCancelled || _isDisposed) break;
          folderDiscovered.add(file);
          _updateStatus(
            _status.copyWith(
              discoveredCount: _status.discoveredCount + 1,
            ),
          );
        }

        if (_isCancelled || _isDisposed) {
          // Incomplete scans must NEVER delete records.
          break;
        }

        if (folderDiscovered.isNotEmpty) {
          await _onDiscoveredFiles?.call(folderDiscovered);
          allDiscoveredFiles.addAll(folderDiscovered);
        }

        await _onFolderScanCompleted?.call(
          root,
          fileCount: folderDiscovered.length,
          lastScannedAt: DateTime.now(),
        );
      }

      if (_isCancelled || _isDisposed) {
        _updateStatus(_status.copyWith(phase: ScanPhase.idle));
        return;
      }

      // Enrich discovered files in background using MediaProbeService through a bounded queue
      if (allDiscoveredFiles.isNotEmpty) {
        _updateStatus(
          _status.copyWith(
            phase: ScanPhase.enriching,
            totalToEnrich: allDiscoveredFiles.length,
            enrichedCount: 0,
          ),
        );
        await _enrichFiles(allDiscoveredFiles);
      }

      _updateStatus(
        _status.copyWith(
          phase: ScanPhase.idle,
          currentFolder: null,
        ),
      );
    } catch (e, st) {
      _updateStatus(
        _status.copyWith(
          phase: ScanPhase.error,
          errorMessage: e.toString(),
        ),
      );
      if (kDebugMode) {
        debugPrint('MediaScannerService scan error: $e\n$st');
      }
    } finally {
      _currentScanFuture = null;
      if (!scanCompleter.isCompleted) {
        scanCompleter.complete();
      }
    }
  }

  /// Traverses [root] directory iteratively without following symlinks or junctions.
  Stream<String> _traverseDirectory(String root) async* {
    final queue = Queue<String>()..add(root);
    final visitedDirs = <String>{};

    while (queue.isNotEmpty) {
      if (_isCancelled || _isDisposed) return;
      final current = queue.removeFirst();
      final normCurrent = _pathContext.normalize(current);
      if (!visitedDirs.add(normCurrent)) continue;

      final dir = Directory(current);
      Stream<FileSystemEntity> entityStream;
      try {
        entityStream = dir.list(recursive: false, followLinks: false);
      } catch (_) {
        // Unreadable directory or permission denied - do NOT fail scan!
        continue;
      }

      try {
        await for (final entity in entityStream) {
          if (_isCancelled || _isDisposed) return;

          // Traversal must NOT follow directory symlinks or junctions
          if (entity is Link) continue;

          FileSystemEntityType type;
          try {
            type = await FileSystemEntity.type(entity.path, followLinks: false);
          } catch (_) {
            continue;
          }

          if (type == FileSystemEntityType.link) {
            continue;
          }

          if (type == FileSystemEntityType.directory) {
            queue.add(entity.path);
          } else if (type == FileSystemEntityType.file) {
            try {
              if (MediaCatalog.isSupportedFile(entity.path)) {
                yield entity.path;
              }
            } catch (_) {
              // Unreadable file: do NOT fail scan!
            }
          }
        }
      } catch (_) {
        // Stream iteration error on directory - continue safely
        continue;
      }
    }
  }

  /// Enriches metadata in the background using [MediaProbeService] through a bounded queue.
  Future<void> _enrichFiles(List<String> filePaths) async {
    if (filePaths.isEmpty || _isCancelled || _isDisposed) return;

    final queue = Queue<String>.from(filePaths);
    final activeWorkers = <Future<void>>[];
    int completed = 0;

    Future<void> worker() async {
      while (queue.isNotEmpty && !_isCancelled && !_isDisposed) {
        final path = queue.removeFirst();
        try {
          final probeResult = await _probeService.probe(path);
          if (_isCancelled || _isDisposed) break;

          await _onUpdateMetadata?.call(
            probeResult.canonicalSource,
            kind: probeResult.kind,
            metadata: probeResult.metadata,
            fileSize: probeResult.fileSize,
            modifiedAt: probeResult.modifiedAt,
          );
        } catch (_) {
          // Probe error or unreadable file: do NOT fail scan, fall back to basic file stats
          try {
            final file = File(path);
            final stat = await file.stat();
            final kind = MediaCatalog.kindFromExtension(path);
            final title = _pathContext.basenameWithoutExtension(path);
            await _onUpdateMetadata?.call(
              path,
              kind: kind,
              metadata: MediaMetadata(title: title),
              fileSize: stat.size,
              modifiedAt: stat.modified,
            );
          } catch (_) {}
        } finally {
          completed++;
          _updateStatus(_status.copyWith(enrichedCount: completed));
        }
      }
    }

    final concurrency = _maxConcurrentProbes.clamp(1, 16);
    final workerCount = queue.length < concurrency ? queue.length : concurrency;
    for (var i = 0; i < workerCount; i++) {
      activeWorkers.add(worker());
    }

    await Future.wait(activeWorkers);
  }

  // ---------------------------------------------------------------------------
  // WATCHER & DEBOUNCE
  // ---------------------------------------------------------------------------

  void _startWatching(String folderPath) {
    final norm = _pathContext.normalize(_pathContext.absolute(folderPath));
    if (_watchers.containsKey(norm)) return;

    try {
      final watcher = _watcherFactory(norm);
      _watchers[norm] = watcher;
      _watcherSubscriptions[norm] = watcher.events.listen(
        (event) => _onWatchEvent(norm, event),
        onError: (Object error) {
          // Folder became inaccessible or disconnected
          _onFolderAvailabilityChanged?.call(norm, false);
        },
        cancelOnError: false,
      );
    } catch (_) {
      // Directory cannot be watched yet (e.g. not created yet or drive unmounted)
    }
  }

  void _stopWatching(String folderPath) {
    final norm = _pathContext.normalize(_pathContext.absolute(folderPath));
    _debounceTimers[norm]?.cancel();
    _debounceTimers.remove(norm);
    _pendingEvents.remove(norm);
    _watcherSubscriptions[norm]?.cancel();
    _watcherSubscriptions.remove(norm);
    _watchers.remove(norm);
  }

  void _onWatchEvent(String rootFolder, WatchEvent event) {
    if (_isDisposed) return;
    _pendingEvents.putIfAbsent(rootFolder, () => <WatchEvent>[]).add(event);
    _debounceTimers[rootFolder]?.cancel();
    _debounceTimers[rootFolder] = Timer(_debounceDuration, () {
      _processDebouncedEvents(rootFolder);
    });
  }

  Future<void> _processDebouncedEvents(String rootFolder) async {
    if (_isDisposed) return;
    final events = _pendingEvents.remove(rootFolder) ?? <WatchEvent>[];
    if (events.isEmpty) return;

    final addedOrModified = <String>{};
    final removed = <String>{};

    for (final ev in events) {
      if (!MediaCatalog.isSupportedFile(ev.path)) continue;
      if (ev.type == ChangeType.REMOVE) {
        removed.add(ev.path);
        addedOrModified.remove(ev.path);
      } else {
        addedOrModified.add(ev.path);
        removed.remove(ev.path);
      }
    }

    final validAdded = <String>[];
    for (final path in addedOrModified) {
      try {
        if (await File(path).exists()) {
          validAdded.add(path);
        }
      } catch (_) {}
    }

    if (validAdded.isNotEmpty) {
      await _onDiscoveredFiles?.call(validAdded);
      await _enrichFiles(validAdded);
    }

    for (final path in removed) {
      await _onFileAvailabilityChanged?.call(path, false);
    }
  }

  void _updateStatus(LibraryScanStatus newStatus) {
    _status = newStatus;
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  /// Disposes watchers, timers, and streams.
  Future<void> dispose() async {
    _isDisposed = true;
    cancelScan();

    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();

    for (final sub in _watcherSubscriptions.values) {
      await sub.cancel();
    }
    _watcherSubscriptions.clear();
    _watchers.clear();
    _pendingEvents.clear();

    await _statusController.close();
  }
}
