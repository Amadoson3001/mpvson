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

typedef UpdateMetadataCallback =
    Future<void> Function(
      String canonicalSource, {
      required MediaKind kind,
      required MediaMetadata metadata,
      required int fileSize,
      required DateTime modifiedAt,
    });

typedef FolderAvailabilityCallback =
    Future<void> Function(String folderPath, bool isAvailable);

typedef FolderScanCompletedCallback =
    Future<void> Function(
      String folderPath, {
      required int fileCount,
      required DateTime lastScannedAt,
    });

typedef FileAvailabilityCallback =
    Future<void> Function(String filePath, bool isAvailable);

typedef FolderReconciliationCallback =
    Future<void> Function(String folderPath, List<String> discoveredPaths);

typedef RegisteredFoldersProvider =
    Future<List<LibraryFolderRecord>> Function();

typedef DirectoryWatcherFactory = DirectoryWatcher Function(String path);

/// Background media library scanner and folder watcher service.
///
/// Discovers supported media files in explicitly registered library folders,
/// watches for file system changes with debouncing, enriches metadata using
/// [MediaProbeService] through a bounded queue, and safely handles disconnected drives.
class MediaScannerService {
  static const int _maxPendingWatcherPaths = 2048;
  static const Duration _maxWatcherBatchDelay = Duration(seconds: 2);

  MediaScannerService({
    required MediaProbeService probeService,
    LibraryDatabase? database,
    DiscoveredFilesCallback? onDiscoveredFiles,
    UpdateMetadataCallback? onUpdateMetadata,
    FolderAvailabilityCallback? onFolderAvailabilityChanged,
    FolderScanCompletedCallback? onFolderScanCompleted,
    FileAvailabilityCallback? onFileAvailabilityChanged,
    FolderReconciliationCallback? onFolderReconciled,
    RegisteredFoldersProvider? getRegisteredFolders,
    Duration debounceDuration = const Duration(milliseconds: 500),
    Duration reconnectInterval = const Duration(seconds: 30),
    int maxConcurrentProbes = 4,
    DirectoryWatcherFactory? watcherFactory,
    p.Context? pathContext,
  }) : _probeService = probeService,
       _database = database,
       _onDiscoveredFiles =
           onDiscoveredFiles ?? database?.batchUpsertDiscoveredFiles,
       _onUpdateMetadata = onUpdateMetadata ?? database?.updateMediaMetadata,
       _onFolderAvailabilityChanged =
           onFolderAvailabilityChanged ?? database?.markFolderAvailability,
       _onFolderScanCompleted =
           onFolderScanCompleted ??
           (database != null
               ? ((folder, {required fileCount, required lastScannedAt}) =>
                     database.updateFolderScanStats(
                       folder,
                       fileCount: fileCount,
                       lastScannedAt: lastScannedAt,
                     ))
               : null),
       _onFileAvailabilityChanged =
           onFileAvailabilityChanged ?? database?.markFileAvailability,
       _onFolderReconciled =
           onFolderReconciled ?? database?.reconcileFolderFiles,
       _getRegisteredFolders = getRegisteredFolders ?? database?.getAllFolders,
       _debounceDuration = debounceDuration,
       _reconnectInterval = reconnectInterval,
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
  final FolderReconciliationCallback? _onFolderReconciled;
  final RegisteredFoldersProvider? _getRegisteredFolders;
  final Duration _debounceDuration;
  final Duration _reconnectInterval;
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
  final Map<String, Timer> _reconnectTimers = <String, Timer>{};
  final Map<String, Map<String, ChangeType>> _pendingEvents =
      <String, Map<String, ChangeType>>{};
  final Set<String> _pendingFullRescans = <String>{};
  final Map<String, Set<String>> _knownDirectories = <String, Set<String>>{};
  final Map<String, DateTime> _pendingEventStarts = <String, DateTime>{};
  final Map<String, Future<void>> _watcherDrains = <String, Future<void>>{};

  final StreamController<LibraryScanStatus> _statusController =
      StreamController<LibraryScanStatus>.broadcast();

  LibraryScanStatus _status = const LibraryScanStatus();
  bool _isCancelled = false;
  bool _isDisposed = false;
  Future<void>? _currentScanFuture;
  Future<void> _scanTransitionTail = Future<void>.value();
  DateTime? _lastStatusEmission;

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

  bool _isPathInRegisteredFolder(String path) {
    if (_isDisposed) return false;
    final normalizedPath = _pathContext.normalize(_pathContext.absolute(path));
    return _explicitFolders.any(
      (root) =>
          _pathContext.equals(root, normalizedPath) ||
          _pathContext.isWithin(root, normalizedPath),
    );
  }

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
    _knownDirectories.remove(norm);
    _reconnectTimers.remove(norm)?.cancel();
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
      if (_isDisposed) return;
      for (final f in dbFolders) {
        registerFolder(f.path);
      }
    }
    await _runScanRoots(
      deduplicateFolderRoots(_explicitFolders, pathContext: _pathContext),
    );
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
    _updateStatus(_status.copyWith(phase: ScanPhase.idle, errorMessage: null));
  }

  Future<void> _runScanRoots(
    List<String> roots, {
    bool replaceCurrent = true,
  }) async {
    if (_isDisposed) return;
    final previousTransition = _scanTransitionTail;
    final transition = Completer<void>();
    _scanTransitionTail = transition.future;
    Future<void>? scan;
    try {
      await previousTransition;
      while (_currentScanFuture != null) {
        if (_isDisposed) return;
        if (replaceCurrent) cancelScan();
        final activeScan = _currentScanFuture!;
        try {
          await activeScan;
        } catch (_) {}
        if (replaceCurrent) break;
      }
      if (_isDisposed) return;

      final scanRoots = replaceCurrent
          ? roots
          : roots.where(_explicitFolders.contains).toList(growable: false);
      if (scanRoots.isEmpty) return;

      _isCancelled = false;
      final scanCompleter = Completer<void>();
      scan = scanCompleter.future;
      _currentScanFuture = scan;
      unawaited(_performScanRoots(scanRoots, scan, scanCompleter));
    } finally {
      transition.complete();
    }
    await scan;
  }

  Future<void> _performScanRoots(
    List<String> roots,
    Future<void> scan,
    Completer<void> scanCompleter,
  ) async {
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
        if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
          break;
        }

        _updateStatus(_status.copyWith(currentFolder: root));

        // Check if root exists (detects disconnected drive or missing directory)
        final rootDir = Directory(root);
        bool exists = false;
        try {
          exists = await rootDir.exists();
        } catch (_) {
          exists = false;
        }
        if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
          break;
        }

        if (!exists) {
          // Disconnected drive or missing folder is marked unavailable (is_available = 0), NEVER deleted!
          await _onFolderAvailabilityChanged?.call(root, false);
          _stopWatching(root);
          _scheduleReconnect(root);
          if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
            continue;
          }
          continue;
        }

        // Folder is available
        _reconnectTimers.remove(root)?.cancel();
        _startWatching(root);
        await _onFolderAvailabilityChanged?.call(root, true);
        if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
          continue;
        }

        final folderDiscovered = <String>[];
        final directories = <String>{};
        var traversalComplete = true;
        await for (final file in _traverseDirectory(
          root,
          onError: () => traversalComplete = false,
          onDirectory: directories.add,
        )) {
          if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
            break;
          }
          folderDiscovered.add(file);
          _updateStatus(
            _status.copyWith(discoveredCount: _status.discoveredCount + 1),
          );
        }

        if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
          // Incomplete scans must NEVER delete records.
          break;
        }

        if (folderDiscovered.isNotEmpty) {
          await _onDiscoveredFiles?.call(folderDiscovered);
          if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
            break;
          }
          allDiscoveredFiles.addAll(folderDiscovered);
        }

        if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
          break;
        }

        if (traversalComplete) {
          _knownDirectories[root] = directories;
          await _onFolderReconciled?.call(root, folderDiscovered);
          if (_isCancelled || _isDisposed || !_explicitFolders.contains(root)) {
            break;
          }
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
        await _enrichFiles(
          allDiscoveredFiles,
          shouldContinue: _isPathInRegisteredFolder,
          skipUnchanged: true,
        );
      }

      _updateStatus(
        _status.copyWith(phase: ScanPhase.idle, currentFolder: null),
      );
    } catch (e, st) {
      _updateStatus(
        _status.copyWith(phase: ScanPhase.error, errorMessage: e.toString()),
      );
      if (kDebugMode) {
        debugPrint('MediaScannerService scan error: $e\n$st');
      }
    } finally {
      if (identical(_currentScanFuture, scan)) _currentScanFuture = null;
      if (!scanCompleter.isCompleted) {
        scanCompleter.complete();
      }
    }
  }

  /// Traverses [root] directory iteratively without following symlinks or junctions.
  Stream<String> _traverseDirectory(
    String root, {
    void Function()? onError,
    void Function(String path)? onDirectory,
  }) async* {
    final queue = Queue<String>()..add(root);
    final visitedDirs = <String>{};

    while (queue.isNotEmpty) {
      if (_isCancelled || _isDisposed) return;
      final current = queue.removeFirst();
      final normCurrent = _pathContext.normalize(current);
      if (!visitedDirs.add(normCurrent)) continue;
      onDirectory?.call(normCurrent);

      final dir = Directory(current);
      Stream<FileSystemEntity> entityStream;
      try {
        entityStream = dir.list(recursive: false, followLinks: false);
      } catch (_) {
        // Unreadable directory or permission denied - do NOT fail scan!
        onError?.call();
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
            onError?.call();
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
        onError?.call();
        continue;
      }
    }
  }

  /// Enriches metadata in the background using [MediaProbeService] through a bounded queue.
  Future<void> _enrichFiles(
    List<String> filePaths, {
    bool Function(String path)? shouldContinue,
    bool ignoreScanCancellation = false,
    bool skipUnchanged = false,
  }) async {
    bool stopped() => _isDisposed || (_isCancelled && !ignoreScanCancellation);
    if (filePaths.isEmpty || stopped()) return;

    final queue = Queue<String>.from(filePaths);
    final activeWorkers = <Future<void>>[];
    int completed = 0;

    Future<void> worker() async {
      while (queue.isNotEmpty && !stopped()) {
        final path = queue.removeFirst();
        if (!(shouldContinue?.call(path) ?? true)) continue;
        try {
          if (skipUnchanged && _database != null) {
            final stat = await File(path).stat();
            final existing = await _database.getMediaByCanonicalSource(path);
            if (existing != null &&
                existing.metadata.duration > Duration.zero &&
                existing.fileSize == stat.size &&
                existing.modifiedAt?.millisecondsSinceEpoch ==
                    stat.modified.millisecondsSinceEpoch) {
              continue;
            }
          }
          if (stopped() || !(shouldContinue?.call(path) ?? true)) break;
          final probeResult = await _probeService.probe(path);
          if (stopped() || !(shouldContinue?.call(path) ?? true)) {
            break;
          }

          await _onUpdateMetadata?.call(
            probeResult.canonicalSource,
            kind: probeResult.kind,
            metadata: probeResult.metadata,
            fileSize: probeResult.fileSize,
            modifiedAt: probeResult.modifiedAt,
          );
        } catch (_) {
          if (stopped() || !(shouldContinue?.call(path) ?? true)) {
            break;
          }
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
        onError: (Object error) => _handleWatcherUnavailable(norm),
        onDone: () => _handleWatcherUnavailable(norm),
        cancelOnError: false,
      );
    } catch (_) {
      // Directory cannot be watched yet (e.g. not created yet or drive unmounted)
    }
  }

  void _handleWatcherUnavailable(String root) {
    if (_isDisposed || !_explicitFolders.contains(root)) return;
    _stopWatching(root);
    _scheduleReconnect(root);
    final update = _onFolderAvailabilityChanged?.call(root, false);
    if (update != null) {
      unawaited(
        update
            .then((_) {
              if (!_isDisposed && _explicitFolders.contains(root)) {
                _updateStatus(_status, force: true);
              }
            })
            .catchError((Object error, StackTrace stackTrace) {
              if (kDebugMode) {
                debugPrint(
                  'MediaScannerService watcher availability error: $error\n$stackTrace',
                );
              }
            }),
      );
    }
  }

  void _scheduleReconnect(String root) {
    if (_isDisposed ||
        !_explicitFolders.contains(root) ||
        _reconnectTimers.containsKey(root)) {
      return;
    }
    _reconnectTimers[root] = Timer(_reconnectInterval, () async {
      _reconnectTimers.remove(root);
      if (_isDisposed || !_explicitFolders.contains(root)) return;
      try {
        if (await Directory(root).exists()) {
          if (!_isDisposed && _explicitFolders.contains(root)) {
            await _runScanRoots(<String>[root], replaceCurrent: false);
          }
        } else {
          _scheduleReconnect(root);
        }
      } catch (_) {
        _scheduleReconnect(root);
      }
    });
  }

  void _stopWatching(String folderPath) {
    final norm = _pathContext.normalize(_pathContext.absolute(folderPath));
    _debounceTimers[norm]?.cancel();
    _debounceTimers.remove(norm);
    _pendingEvents.remove(norm);
    _pendingFullRescans.remove(norm);
    _pendingEventStarts.remove(norm);
    _watcherSubscriptions[norm]?.cancel();
    _watcherSubscriptions.remove(norm);
    _watchers.remove(norm);
  }

  void _onWatchEvent(String rootFolder, WatchEvent event) {
    if (_isDisposed) return;
    final eventPath = _pathContext.normalize(_pathContext.absolute(event.path));
    if (event.type == ChangeType.REMOVE &&
        _pathContext.equals(rootFolder, eventPath)) {
      _handleWatcherUnavailable(rootFolder);
      return;
    }
    if (!MediaCatalog.isSupportedFile(event.path)) {
      if (event.type == ChangeType.ADD) {
        unawaited(_checkAddedDirectory(rootFolder, eventPath));
        return;
      }
      if (event.type == ChangeType.REMOVE &&
          (_pathContext.extension(event.path).isEmpty ||
              (_knownDirectories[rootFolder]?.any(
                    (path) => _pathContext.equals(path, eventPath),
                  ) ??
                  false))) {
        _pendingEvents.remove(rootFolder);
        _pendingFullRescans.add(rootFolder);
      } else {
        return;
      }
    }
    if (MediaCatalog.isSupportedFile(event.path) &&
        !_pendingFullRescans.contains(rootFolder)) {
      final events = _pendingEvents.putIfAbsent(
        rootFolder,
        () => <String, ChangeType>{},
      );
      if (events.containsKey(event.path) ||
          events.length < _maxPendingWatcherPaths) {
        events[event.path] = event.type;
      } else {
        events.clear();
        _pendingFullRescans.add(rootFolder);
      }
    }
    _scheduleWatcherDrain(rootFolder);
  }

  Future<void> _checkAddedDirectory(String rootFolder, String path) async {
    try {
      if (!await Directory(path).exists() ||
          _isDisposed ||
          !_explicitFolders.contains(rootFolder)) {
        return;
      }
      _pendingEvents.remove(rootFolder);
      _pendingFullRescans.add(rootFolder);
      _scheduleWatcherDrain(rootFolder);
    } catch (_) {}
  }

  void _scheduleWatcherDrain(String rootFolder) {
    final now = DateTime.now();
    final started = _pendingEventStarts.putIfAbsent(rootFolder, () => now);
    final maximumDelayRemaining =
        _maxWatcherBatchDelay - now.difference(started);
    _debounceTimers[rootFolder]?.cancel();
    final delay = maximumDelayRemaining <= Duration.zero
        ? Duration.zero
        : _debounceDuration < maximumDelayRemaining
        ? _debounceDuration
        : maximumDelayRemaining;
    _debounceTimers[rootFolder] = Timer(delay, () {
      _drainWatcherEvents(rootFolder);
    });
  }

  void _drainWatcherEvents(String rootFolder) {
    if (_isDisposed || _watcherDrains.containsKey(rootFolder)) return;
    final drain = _processDebouncedEvents(rootFolder).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      if (kDebugMode) {
        debugPrint('MediaScannerService watcher error: $error\n$stackTrace');
      }
    });
    _watcherDrains[rootFolder] = drain;
    unawaited(
      drain.whenComplete(() {
        _watcherDrains.remove(rootFolder);
        if (_isDisposed) return;
        final hasPending =
            _pendingFullRescans.contains(rootFolder) ||
            (_pendingEvents[rootFolder]?.isNotEmpty ?? false);
        if (hasPending) {
          _debounceTimers[rootFolder]?.cancel();
          _debounceTimers[rootFolder] = Timer(
            Duration.zero,
            () => _drainWatcherEvents(rootFolder),
          );
        }
      }),
    );
  }

  Future<void> _processDebouncedEvents(String rootFolder) async {
    if (_isDisposed || !_explicitFolders.contains(rootFolder)) return;
    _debounceTimers.remove(rootFolder);
    _pendingEventStarts.remove(rootFolder);
    if (_pendingFullRescans.remove(rootFolder)) {
      _pendingEvents.remove(rootFolder);
      if (!_isDisposed && _explicitFolders.contains(rootFolder)) {
        await _runScanRoots(<String>[rootFolder], replaceCurrent: false);
      }
      return;
    }
    final events = _pendingEvents.remove(rootFolder) ?? <String, ChangeType>{};
    if (events.isEmpty) return;

    final addedOrModified = <String>{};
    final removed = <String>{};

    for (final entry in events.entries) {
      if (entry.value == ChangeType.REMOVE) {
        removed.add(entry.key);
        addedOrModified.remove(entry.key);
      } else {
        addedOrModified.add(entry.key);
        removed.remove(entry.key);
      }
    }

    final validAdded = <String>[];
    for (final path in addedOrModified) {
      if (_isDisposed || !_explicitFolders.contains(rootFolder)) return;
      try {
        if (await File(path).exists()) {
          validAdded.add(path);
        }
      } catch (_) {}
    }

    if (validAdded.isNotEmpty) {
      if (_isDisposed || !_explicitFolders.contains(rootFolder)) return;
      await _onDiscoveredFiles?.call(validAdded);
      if (_isDisposed || !_explicitFolders.contains(rootFolder)) return;
      await _enrichFiles(
        validAdded,
        ignoreScanCancellation: true,
        shouldContinue: (path) =>
            !_isDisposed && _explicitFolders.contains(rootFolder),
      );
    }

    for (final path in removed) {
      if (_isDisposed || !_explicitFolders.contains(rootFolder)) return;
      await _onFileAvailabilityChanged?.call(path, false);
    }
    if (!_isDisposed && _explicitFolders.contains(rootFolder)) {
      await _database?.refreshFolderFileCount(rootFolder);
      _updateStatus(_status, force: true);
    }
  }

  void _updateStatus(LibraryScanStatus newStatus, {bool force = false}) {
    final previous = _status;
    _status = newStatus;
    final now = DateTime.now();
    final onlyCountsChanged =
        previous.phase == newStatus.phase &&
        previous.currentFolder == newStatus.currentFolder &&
        previous.errorMessage == newStatus.errorMessage;
    if (!force &&
        onlyCountsChanged &&
        _lastStatusEmission != null &&
        now.difference(_lastStatusEmission!) <
            const Duration(milliseconds: 100)) {
      return;
    }
    _lastStatusEmission = now;
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  /// Disposes watchers, timers, and streams.
  Future<void> dispose() async {
    _isDisposed = true;
    cancelScan();

    final activeScan = _currentScanFuture;
    if (activeScan != null) {
      await activeScan;
    }

    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
    for (final timer in _reconnectTimers.values) {
      timer.cancel();
    }
    _reconnectTimers.clear();

    for (final sub in _watcherSubscriptions.values) {
      await sub.cancel();
    }
    _watcherSubscriptions.clear();
    _watchers.clear();
    _pendingEvents.clear();
    _pendingFullRescans.clear();
    _knownDirectories.clear();
    _pendingEventStarts.clear();
    await Future.wait(_watcherDrains.values, eagerError: false);
    _watcherDrains.clear();

    await _statusController.close();
  }
}
