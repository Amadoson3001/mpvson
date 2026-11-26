import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/media_entry.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_thumbnail.dart';
import 'diagnostic_log.dart';
import 'thumbnail_contract.dart';
import 'thumbnail_extractor.dart';
import 'thumbnail_image.dart';

export 'thumbnail_contract.dart';

/// Creates thumbnails with a separate, muted, headless libmpv player.
///
/// Cache files are kept under the OS application cache directory. Supplying
/// [cacheDirectory] or [cacheDirectoryProvider] is useful for tests and tools
/// that need an isolated cache. The provided directory is the exact thumbnail
/// cache directory, not a parent directory.
class MediaKitThumbnailService implements ThumbnailService {
  MediaKitThumbnailService({
    ThumbnailExtractor? extractor,
    ThumbnailImageValidator? imageValidator,
    Directory? cacheDirectory,
    Future<Directory> Function()? cacheDirectoryProvider,
    DiagnosticSink? diagnostics,
    int maxMemoryBytes = _defaultMemoryLimit,
    int maxDiskBytes = _defaultDiskLimit,
    Duration operationTimeout = const Duration(seconds: 18),
    Duration requestTimeoutGrace = const Duration(seconds: 8),
    Player Function()? playerFactory,
  }) : assert(cacheDirectory == null || cacheDirectoryProvider == null),
       _imageValidator = imageValidator ?? thumbnailImageIsDecodable,
       _providedCacheDirectory = cacheDirectory,
       _cacheDirectoryProvider = cacheDirectoryProvider,
       _diagnostics = diagnostics,
       // Keep the public tuning parameter names independent of private fields.
       // ignore: prefer_initializing_formals
       _maxMemoryBytes = maxMemoryBytes,
       // ignore: prefer_initializing_formals
       _maxDiskBytes = maxDiskBytes,
       // ignore: prefer_initializing_formals
       _operationTimeout = operationTimeout,
       // ignore: prefer_initializing_formals
       _requestTimeoutGrace = requestTimeoutGrace,
       _extractor =
           extractor ??
           MediaKitThumbnailExtractor(
             imageValidator: imageValidator ?? thumbnailImageIsDecodable,
             diagnostics: diagnostics,
             playerFactory: playerFactory,
           );

  static const int _defaultMemoryLimit = 4 * 1024 * 1024;
  static const int _defaultDiskLimit = 128 * 1024 * 1024;
  static const int _maximumCacheEntryBytes = 12 * 1024 * 1024;
  static const int _maximumMetadataBytes = 16 * 1024;
  static const int _maxThumbnailDimension = 320;
  static const int _maximumDiskEntries = 256;
  static const int _maximumSidecarBytes = 12 * 1024 * 1024;
  static const int _maximumPendingDiskWriteBytes = 8 * 1024 * 1024;
  static const int _maximumPendingDiskWriteCount = 256;
  static const int _diskRescanWriteInterval = 32;

  final ThumbnailExtractor _extractor;
  final ThumbnailImageValidator _imageValidator;
  final Directory? _providedCacheDirectory;
  final Future<Directory> Function()? _cacheDirectoryProvider;
  final DiagnosticSink? _diagnostics;
  final int _maxMemoryBytes;
  final int _maxDiskBytes;
  final Duration _operationTimeout;
  final Duration _requestTimeoutGrace;

  final LinkedHashMap<String, _MemoryThumbnail> _memory =
      LinkedHashMap<String, _MemoryThumbnail>();
  final Map<String, _ActiveThumbnailRequest> _activeRequests =
      <String, _ActiveThumbnailRequest>{};
  final List<_ExtractionTask> _extractionQueue = <_ExtractionTask>[];
  final List<_NormalizerTask> _normalizerQueue = <_NormalizerTask>[];
  final List<_DiskWriteTask> _diskQueue = <_DiskWriteTask>[];
  final Map<String, _DiskEntry> _diskEntries = <String, _DiskEntry>{};

  /// Disk writes that are queued or executing, keyed by digest. Readers use
  /// this to obtain the in-flight thumbnail instead of racing on files that
  /// are absent or half-replaced on disk.
  final Map<String, _DiskWriteTask> _activeDiskWrites =
      <String, _DiskWriteTask>{};
  final Set<String> _activeTempFiles = <String>{};
  final Set<Future<MediaThumbnail?>> _loadOperations =
      <Future<MediaThumbnail?>>{};
  final List<ThumbnailDiagnosticRecord> _recentDiagnostics =
      <ThumbnailDiagnosticRecord>[];

  bool _pumpingExtractionQueue = false;
  bool _pumpingNormalizerQueue = false;
  bool _pumpingDiskQueue = false;
  Completer<void>? _diskQueueDrainCompleter;
  bool _suspended = false;
  ThumbnailCancellation? _currentExtractionCancellation;
  Completer<void>? _resumeCompleter;
  Future<Directory>? _resolvedCacheDirectory;
  Future<void>? _disposal;
  int _memoryBytes = 0;
  int _diskBytes = 0;
  int _pendingDiskWriteBytes = 0;
  int _diskWritesSinceScan = 0;
  bool _diskAccountingInitialized = false;
  int _requestSequenceCounter = 0;
  bool _disposed = false;

  void _recordDiagnostic(
    String stage, {
    String? source,
    String? message,
    Object? error,
  }) {
    final redacted = source == null ? 'unknown' : MediaSource.redact(source);
    final redactedMessage = message == null
        ? null
        : MediaSource.redactText(message);
    final redactedError = error == null
        ? null
        : MediaSource.redactText('$error');
    final record = ThumbnailDiagnosticRecord(
      stage: stage,
      sourceId: redacted,
      timestamp: DateTime.now(),
      message: redactedMessage,
      error: redactedError,
    );
    if (_recentDiagnostics.length >= 64) {
      _recentDiagnostics.removeAt(0);
    }
    _recentDiagnostics.add(record);
    _diagnostics?.record(
      stage,
      sourceId: redacted,
      message: redactedMessage,
      error: redactedError,
    );
  }

  /// Requests a thumbnail with a reference-counted handle that can be cancelled.
  @override
  ThumbnailRequestHandle request(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  }) {
    if (_disposed) {
      return _ImmediateThumbnailRequestHandle(entry, null);
    }

    final key = MediaEntry.canonicalSource(entry.path);

    var active = _activeRequests[key];
    if (active == null || active.isCompleted) {
      active = _ActiveThumbnailRequest(
        service: this,
        entry: entry,
        key: key,
        sequence: ++_requestSequenceCounter,
        priority: priority,
      );
      _activeRequests[key] = active;
      active.start();
    } else if (priority == ThumbnailPriority.high) {
      active.promotePriority(priority);
    }
    return active.attach(entry, priority: priority);
  }

  /// Returns a memory-cached thumbnail for immediate display, if present.
  ///
  /// This is only a provisional read. Callers must still start [load] or
  /// [request], which asynchronously validates the source and sidecars before
  /// returning cached artwork as current.
  @override
  MediaThumbnail? peek(MediaEntry entry) {
    final key = MediaEntry.canonicalSource(entry.path);
    final memory = _memory[key];
    if (memory == null) return null;
    if (memory.expiresAt != null &&
        memory.expiresAt!.isBefore(DateTime.now())) {
      _removeMemory(key);
      return null;
    }
    _memory.remove(key);
    _memory[key] = memory;
    return _withKnownDuration(memory.thumbnail, entry.duration);
  }

  @override
  Future<MediaThumbnail?> load(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  }) async {
    if (_disposed) return null;
    final handle = request(entry, priority: priority);
    try {
      return await handle.thumbnail;
    } finally {
      handle.release();
    }
  }

  Future<void> _suspensionGate() {
    if (!_suspended) return Future<void>.value();
    return (_resumeCompleter ??= Completer<void>()).future;
  }

  void _interruptCurrentExtraction() {
    try {
      _currentExtractionCancellation?.interrupt();
    } catch (_) {}
  }

  @override
  void suspend() {
    if (_disposed) return;
    _suspended = true;
    _resumeCompleter ??= Completer<void>();
    for (final request in _activeRequests.values) {
      request.onSuspend();
    }
    _interruptCurrentExtraction();
    _extractor.requestIdleCleanup();
  }

  @override
  void trimMemory() {
    _memory.clear();
    _memoryBytes = 0;
    _extractor.requestIdleCleanup();
  }

  @override
  void resume() {
    if (_disposed) return;
    _suspended = false;
    final completer = _resumeCompleter;
    _resumeCompleter = null;
    completer?.complete();
    for (final request in _activeRequests.values) {
      request.onResume();
    }
    _pumpExtractionQueue();
    _pumpNormalizerQueue();
  }

  void _promoteActiveRequestPriority(_ActiveThumbnailRequest request) {
    for (var i = 0; i < _extractionQueue.length; i++) {
      final task = _extractionQueue[i];
      if (identical(task.cancellation, request.cancellation)) {
        task.priority = ThumbnailPriority.high;
        _extractionQueue.removeAt(i);
        _enqueueExtractionTask(task);
        break;
      }
    }
    for (var i = 0; i < _normalizerQueue.length; i++) {
      final task = _normalizerQueue[i];
      if (identical(task.cancellation, request.cancellation)) {
        task.priority = ThumbnailPriority.high;
        _normalizerQueue.removeAt(i);
        _enqueueNormalizerTask(task);
        break;
      }
    }
  }

  void _onActiveRequestCancelled(_ActiveThumbnailRequest request) {
    if (identical(_activeRequests[request.key], request)) {
      _activeRequests.remove(request.key);
    }
    final cancelledExtraction = <_ExtractionTask>[];
    _extractionQueue.removeWhere((task) {
      if (identical(task.cancellation, request.cancellation)) {
        cancelledExtraction.add(task);
        return true;
      }
      return false;
    });
    for (final task in cancelledExtraction) {
      task.cancel();
    }

    final cancelledNorm = <_NormalizerTask>[];
    _normalizerQueue.removeWhere((task) {
      if (identical(task.cancellation, request.cancellation)) {
        cancelledNorm.add(task);
        return true;
      }
      return false;
    });
    for (final task in cancelledNorm) {
      task.cancel();
    }
  }

  Future<MediaThumbnail?> _loadTracked(
    MediaEntry entry,
    String key,
    ThumbnailCancellation cancellation, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
    int sequence = 0,
  }) {
    final operation = _load(
      entry,
      key,
      cancellation,
      priority: priority,
      sequence: sequence,
    );
    _loadOperations.add(operation);
    return operation.whenComplete(() {
      _loadOperations.remove(operation);
    });
  }

  Future<MediaThumbnail?> _load(
    MediaEntry entry,
    String key,
    ThumbnailCancellation cancellation, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
    int sequence = 0,
  }) async {
    final snapshot = await _snapshot(entry, key);
    if (snapshot == null) {
      _recordDiagnostic(
        'snapshot',
        source: entry.path,
        message: 'Source file not found or inaccessible',
      );
      return null;
    }
    if (_disposed || cancellation.isCancelled) return null;

    if (snapshot.memoryCacheable) {
      final memory = _memory[key];
      if (memory != null &&
          memory.fingerprint == snapshot.fingerprint &&
          (memory.expiresAt == null ||
              memory.expiresAt!.isAfter(DateTime.now()))) {
        _memory.remove(key);
        _memory[key] = memory;
        return _withKnownDuration(memory.thumbnail, entry.duration);
      }
      if (memory != null) _removeMemory(key);
    }

    if (cancellation.isCancelled) return null;

    if (snapshot.cacheable) {
      final disk = await _readDisk(
        key,
        snapshot.fingerprint,
        cancellation: cancellation,
        priority: priority,
        sequence: sequence,
      );
      if (disk != null && !_disposed && !cancellation.isCancelled) {
        _remember(key, snapshot.fingerprint, disk);
        return _withKnownDuration(disk, entry.duration);
      }
    }

    if (cancellation.isCancelled) return null;

    final sidecar = await _readSidecar(
      snapshot,
      cancellation: cancellation,
      priority: priority,
      sequence: sequence,
    );
    if (sidecar != null) {
      var duration = entry.duration;
      if (duration <= Duration.zero) {
        duration =
            await _runExtractionSerialized<Duration>(
              () => _extractor.probeDuration(
                snapshot.source,
                cancellation: cancellation,
              ),
              cancellation,
              priority: priority,
            ) ??
            Duration.zero;
      }
      if (cancellation.isCancelled) return null;
      final thumbnail = MediaThumbnail(bytes: sidecar, duration: duration);
      if (snapshot.memoryCacheable && !_disposed && !cancellation.isCancelled) {
        _remember(
          key,
          snapshot.fingerprint,
          thumbnail,
          expiresAt: snapshot.cacheable
              ? null
              : DateTime.now().add(const Duration(minutes: 10)),
        );
      }
      if (snapshot.cacheable && !_disposed && !cancellation.isCancelled) {
        unawaited(_scheduleDiskWrite(key, snapshot.fingerprint, thumbnail));
      }
      return _disposed || cancellation.isCancelled ? null : thumbnail;
    }

    if (cancellation.isCancelled) return null;

    final outputDirectory = await Directory.systemTemp.createTemp(
      'mpvson-thumbnail-',
    );
    try {
      final extraction = await _runExtractionSerialized<MediaThumbnail?>(
        () => _extractor.extract(
          snapshot.source,
          outputDirectory: outputDirectory,
          cancellation: cancellation,
        ),
        cancellation,
        priority: priority,
        sequence: sequence,
      );
      if (extraction == null || cancellation.isCancelled) {
        if (!cancellation.isCancelled) {
          _recordDiagnostic(
            'capture',
            source: snapshot.source,
            message: 'No video frame could be extracted from source',
          );
        }
        return null;
      }

      final normalizedBytes = await _runNormalized(
        extraction.bytes,
        cancellation,
        priority: priority,
        sequence: sequence,
        validator: _customValidator,
      );
      if (normalizedBytes == null || normalizedBytes.isEmpty) {
        _recordDiagnostic(
          'decode',
          source: snapshot.source,
          message: 'Artwork exceeded 32 megapixels or could not be normalized',
        );
        return null;
      }

      final duration = extraction.duration > Duration.zero
          ? extraction.duration
          : entry.duration;
      final thumbnail = MediaThumbnail(
        bytes: normalizedBytes,
        duration: duration,
      );
      if (snapshot.memoryCacheable && !_disposed && !cancellation.isCancelled) {
        _remember(
          key,
          snapshot.fingerprint,
          thumbnail,
          expiresAt: snapshot.cacheable
              ? null
              : DateTime.now().add(const Duration(minutes: 10)),
        );
      }
      if (snapshot.cacheable && !_disposed && !cancellation.isCancelled) {
        unawaited(_scheduleDiskWrite(key, snapshot.fingerprint, thumbnail));
      }
      return _disposed || cancellation.isCancelled ? null : thumbnail;
    } finally {
      try {
        if (await outputDirectory.exists()) {
          await outputDirectory.delete(recursive: true);
        }
      } on Object {
        // Temporary-output cleanup must not turn a failed decode into a crash.
      }
    }
  }

  Future<_SourceSnapshot?> _snapshot(MediaEntry entry, String key) async {
    if (MediaEntry.isNetworkUrl(entry.path)) {
      return _SourceSnapshot(
        source: entry.path,
        cacheable: false,
        memoryCacheable: true,
        fingerprint: sha256.convert(utf8.encode('remote:$key')).toString(),
        sidecars: const <File>[],
      );
    }

    final source = MediaEntry.normalizeSourcePath(entry.path);
    final sourceFile = File(source);
    try {
      final sourceStat = await sourceFile.stat();
      if (sourceStat.type != FileSystemEntityType.file) return null;

      final sidecars = _sidecarFiles(source);
      final sourceSignature = _statSignature(source, sourceStat);
      final signatures = <String>[sourceSignature];
      for (final sidecar in sidecars) {
        try {
          final stat = await sidecar.stat();
          if (stat.type == FileSystemEntityType.file) {
            signatures.add(_statSignature(sidecar.path, stat));
          } else {
            signatures.add('${sidecar.path}:missing');
          }
        } on FileSystemException {
          signatures.add('${sidecar.path}:missing');
        }
      }
      final fingerprint = sha256
          .convert(utf8.encode(signatures.join('\n')))
          .toString();
      return _SourceSnapshot(
        source: source,
        cacheable: true,
        memoryCacheable: true,
        fingerprint: fingerprint,
        sidecars: sidecars,
      );
    } on FileSystemException {
      return null;
    }
  }

  static String _statSignature(String path, FileStat stat) =>
      '$path:${stat.size}:${stat.modified.microsecondsSinceEpoch}';

  static List<File> _sidecarFiles(String source) {
    final base = p.withoutExtension(source);
    return <String>[
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
    ].map((extension) => File('$base$extension')).toList(growable: false);
  }

  Future<Uint8List?> _readSidecar(
    _SourceSnapshot snapshot, {
    required ThumbnailCancellation cancellation,
    ThumbnailPriority priority = ThumbnailPriority.normal,
    int sequence = 0,
  }) async {
    for (final file in snapshot.sidecars) {
      if (cancellation.isCancelled) return null;
      try {
        final bytes = await _readFileBounded(
          file,
          maximumBytes: _maximumSidecarBytes,
        );
        if (bytes == null) continue;
        if (!thumbnailBytesLookLikeImage(bytes) || cancellation.isCancelled) {
          continue;
        }
        final normalized = await _runNormalized(
          bytes,
          cancellation,
          priority: priority,
          sequence: sequence,
          validator: _customValidator,
        );
        if (normalized != null && normalized.isNotEmpty) {
          return normalized;
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  void _enqueueExtractionTask(_ExtractionTask task) {
    var insertIndex = _extractionQueue.length;
    for (var i = 0; i < _extractionQueue.length; i++) {
      final existing = _extractionQueue[i];
      if (task.priority.index > existing.priority.index) {
        insertIndex = i;
        break;
      } else if (task.priority == existing.priority &&
          task.sequence < existing.sequence) {
        insertIndex = i;
        break;
      }
    }
    _extractionQueue.insert(insertIndex, task);
  }

  Future<T?> _runExtractionSerialized<T>(
    Future<T> Function() operation,
    ThumbnailCancellation cancellation, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
    int sequence = 0,
  }) async {
    if (_disposed || cancellation.isCancelled) return null;

    final completer = Completer<T?>();
    final task = _ExtractionTask(
      priority: priority,
      sequence: sequence,
      cancellation: cancellation,
      run: () async {
        if (_disposed || cancellation.isCancelled) {
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        _currentExtractionCancellation = cancellation;
        try {
          while (!_disposed && !cancellation.isCancelled) {
            if (_suspended) {
              await _suspensionGate();
              if (_disposed || cancellation.isCancelled) {
                if (!completer.isCompleted) completer.complete(null);
                return;
              }
            }
            final interruptionGeneration = cancellation.interruptionGeneration;
            try {
              cancellation.resetInterrupted();
              final result = await operation();
              final wasInterrupted =
                  cancellation.isInterrupted ||
                  cancellation.interruptionGeneration != interruptionGeneration;
              if (wasInterrupted && !cancellation.isCancelled && !_disposed) {
                if (_suspended) await _suspensionGate();
                continue;
              }
              if (!completer.isCompleted) {
                completer.complete(cancellation.isCancelled ? null : result);
              }
              return;
            } on Object {
              final wasInterrupted =
                  cancellation.isInterrupted ||
                  cancellation.interruptionGeneration != interruptionGeneration;
              if (wasInterrupted && !cancellation.isCancelled && !_disposed) {
                if (_suspended) await _suspensionGate();
                continue;
              }
              if (!completer.isCompleted) completer.complete(null);
              return;
            }
          }
        } finally {
          if (identical(_currentExtractionCancellation, cancellation)) {
            _currentExtractionCancellation = null;
          }
        }
      },
      cancel: () {
        cancellation.setWaitingInQueue(false);
        if (!completer.isCompleted) completer.complete(null);
      },
    );

    cancellation.setWaitingInQueue(true);
    _enqueueExtractionTask(task);
    _pumpExtractionQueue();
    return completer.future;
  }

  void _pumpExtractionQueue() {
    if (_pumpingExtractionQueue || _suspended || _disposed) return;
    _pumpingExtractionQueue = true;
    unawaited(() async {
      try {
        while (_extractionQueue.isNotEmpty && !_suspended && !_disposed) {
          final cancelled = <_ExtractionTask>[];
          _extractionQueue.removeWhere((t) {
            if (t.cancellation.isCancelled) {
              cancelled.add(t);
              return true;
            }
            return false;
          });
          for (final c in cancelled) {
            c.cancel();
          }
          if (_extractionQueue.isEmpty || _suspended || _disposed) break;

          final task = _extractionQueue.removeAt(0);
          task.cancellation.setWaitingInQueue(false);
          if (task.cancellation.isCancelled) {
            task.cancel();
            continue;
          }

          await task.run();
        }
      } finally {
        _pumpingExtractionQueue = false;
      }
    }());
  }

  void _enqueueNormalizerTask(_NormalizerTask task) {
    var insertIndex = _normalizerQueue.length;
    for (var i = 0; i < _normalizerQueue.length; i++) {
      final existing = _normalizerQueue[i];
      if (task.priority.index > existing.priority.index) {
        insertIndex = i;
        break;
      } else if (task.priority == existing.priority &&
          task.sequence < existing.sequence) {
        insertIndex = i;
        break;
      }
    }
    _normalizerQueue.insert(insertIndex, task);
  }

  /// The caller-supplied validator, or null when it is the built-in default.
  ///
  /// [_normalizeArtwork] only consults a validator on the decode-failure path,
  /// so skipping the default there avoids a second doomed decode attempt.
  ThumbnailImageValidator? get _customValidator =>
      _imageValidator == thumbnailImageIsDecodable ? null : _imageValidator;

  Future<Uint8List?> _runNormalized(
    Uint8List bytes,
    ThumbnailCancellation cancellation, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
    int sequence = 0,
    ThumbnailImageValidator? validator,
  }) async {
    if (_disposed || cancellation.isCancelled) return null;

    final completer = Completer<Uint8List?>();
    final task = _NormalizerTask(
      priority: priority,
      sequence: sequence,
      cancellation: cancellation,
      run: () async {
        if (_disposed || cancellation.isCancelled) {
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        try {
          final result = await _normalizeArtwork(bytes, validator: validator);
          if (!completer.isCompleted) {
            completer.complete(cancellation.isCancelled ? null : result);
          }
        } on Object {
          if (!completer.isCompleted) completer.complete(null);
        }
      },
      cancel: () {
        cancellation.setWaitingInQueue(false);
        if (!completer.isCompleted) completer.complete(null);
      },
    );

    cancellation.setWaitingInQueue(true);
    _enqueueNormalizerTask(task);
    _pumpNormalizerQueue();
    return completer.future;
  }

  void _pumpNormalizerQueue() {
    if (_pumpingNormalizerQueue || _suspended || _disposed) return;
    _pumpingNormalizerQueue = true;
    unawaited(() async {
      try {
        while (_normalizerQueue.isNotEmpty && !_suspended && !_disposed) {
          final cancelled = <_NormalizerTask>[];
          _normalizerQueue.removeWhere((t) {
            if (t.cancellation.isCancelled) {
              cancelled.add(t);
              return true;
            }
            return false;
          });
          for (final c in cancelled) {
            c.cancel();
          }
          if (_normalizerQueue.isEmpty || _suspended || _disposed) break;

          final task = _normalizerQueue.removeAt(0);
          task.cancellation.setWaitingInQueue(false);
          if (task.cancellation.isCancelled) {
            task.cancel();
            continue;
          }

          await task.run();
        }
      } finally {
        _pumpingNormalizerQueue = false;
      }
    }());
  }

  void _remember(
    String key,
    String fingerprint,
    MediaThumbnail thumbnail, {
    DateTime? expiresAt,
  }) {
    _removeMemory(key);
    if (thumbnail.byteLength > _maxMemoryBytes) return;
    _memory[key] = _MemoryThumbnail(fingerprint, thumbnail, expiresAt);
    _memoryBytes += thumbnail.byteLength;
    while (_memory.isNotEmpty &&
        (_memoryBytes > _maxMemoryBytes || _memory.length > 128)) {
      _removeMemory(_memory.keys.first);
    }
  }

  void _removeMemory(String key) {
    final removed = _memory.remove(key);
    if (removed != null) _memoryBytes -= removed.thumbnail.byteLength;
  }

  Future<Directory?> _cacheDirectory() async {
    try {
      final directory = await (_resolvedCacheDirectory ??=
          _resolveCacheDirectory());
      await directory.create(recursive: true);
      return directory;
    } on Object {
      return null;
    }
  }

  Future<Directory> _resolveCacheDirectory() async {
    final provided = _providedCacheDirectory;
    if (provided != null) return provided;
    final provider = _cacheDirectoryProvider;
    if (provider != null) return provider();
    final root = await getApplicationCacheDirectory();
    return Directory(p.join(root.path, 'mpvson', 'thumbnails-v1'));
  }

  /// Consults the in-flight disk write for [digest], if any.
  ///
  /// - `thumbnail != null`: the queued/executing write carries exactly the
  ///   content this reader asked for; return it as a cache hit.
  /// - `thumbnail == null, present == true`: a write for a different
  ///   fingerprint owns the cache pair; the reader must not delete the files
  ///   because the writer is about to replace them.
  /// - `present == false`: no write is active and the on-disk pair is safe to
  ///   inspect and clean up.
  ({bool present, MediaThumbnail? thumbnail}) _inflightDiskWrite(
    String digest,
    String fingerprint,
  ) {
    final inflight = _activeDiskWrites[digest];
    if (inflight == null) return (present: false, thumbnail: null);
    final matches =
        inflight.fingerprint == fingerprint &&
        inflight.thumbnail.byteLength > 0 &&
        inflight.thumbnail.byteLength <= _maximumCacheEntryBytes;
    return (present: true, thumbnail: matches ? inflight.thumbnail : null);
  }

  Future<MediaThumbnail?> _readDisk(
    String key,
    String fingerprint, {
    required ThumbnailCancellation cancellation,
    ThumbnailPriority priority = ThumbnailPriority.normal,
    int sequence = 0,
  }) async {
    final directory = await _cacheDirectory();
    if (directory == null || cancellation.isCancelled) return null;
    final digest = sha256.convert(utf8.encode(key)).toString();
    final metadataFile = File(p.join(directory.path, '$digest.json'));
    final bytesFile = File(p.join(directory.path, '$digest.img'));
    try {
      final metadataBytes = await _readFileBounded(
        metadataFile,
        maximumBytes: _maximumMetadataBytes,
      );
      if (metadataBytes == null) {
        final inflight = _inflightDiskWrite(digest, fingerprint);
        if (inflight.thumbnail != null) return inflight.thumbnail;
        if (inflight.present) return null;
        await _deleteCachePair(metadataFile, bytesFile);
        _forgetDiskEntry(digest);
        return null;
      }
      final decoded = jsonDecode(utf8.decode(metadataBytes));
      if (decoded is! Map<String, Object?> ||
          decoded['fingerprint'] != fingerprint) {
        final inflight = _inflightDiskWrite(digest, fingerprint);
        if (inflight.thumbnail != null) return inflight.thumbnail;
        if (inflight.present) return null;
        await _deleteCachePair(metadataFile, bytesFile);
        _forgetDiskEntry(digest);
        return null;
      }
      final bytes = await _readFileBounded(
        bytesFile,
        maximumBytes: _maximumCacheEntryBytes,
      );
      if (bytes == null || !thumbnailBytesLookLikeImage(bytes)) {
        final inflight = _inflightDiskWrite(digest, fingerprint);
        if (inflight.thumbnail != null) return inflight.thumbnail;
        if (inflight.present) return null;
        await _deleteCachePair(metadataFile, bytesFile);
        _forgetDiskEntry(digest);
        return null;
      }
      if (cancellation.isCancelled) return null;
      final normalized = await _runNormalized(
        bytes,
        cancellation,
        priority: priority,
        sequence: sequence,
        validator: _customValidator,
      );
      if (cancellation.isCancelled) return null;
      if (normalized == null || normalized.isEmpty) {
        final inflight = _inflightDiskWrite(digest, fingerprint);
        if (inflight.thumbnail != null) return inflight.thumbnail;
        if (inflight.present) return null;
        await _deleteCachePair(metadataFile, bytesFile);
        _forgetDiskEntry(digest);
        return null;
      }
      try {
        await metadataFile.setLastModified(DateTime.now());
        _touchDiskEntry(digest);
      } on FileSystemException {
        // Cache reads still succeed if the filesystem disallows touch updates.
      }
      final durationMs = decoded['durationMs'];
      final thumbnail = MediaThumbnail(
        bytes: normalized,
        duration: Duration(
          milliseconds: durationMs is int && durationMs > 0 ? durationMs : 0,
        ),
      );
      if (!identical(normalized, bytes)) {
        // Persisting the re-normalized copy is bookkeeping; the caller already
        // holds the result and must not wait on background disk work.
        unawaited(
          _scheduleDiskWrite(
            key,
            fingerprint,
            thumbnail,
            cancellation: cancellation,
          ),
        );
      }
      return thumbnail;
    } on FileSystemException {
      final inflight = _inflightDiskWrite(digest, fingerprint);
      if (inflight.thumbnail != null) return inflight.thumbnail;
      if (!inflight.present) _forgetDiskEntry(digest);
      return null;
    } on FormatException {
      final inflight = _inflightDiskWrite(digest, fingerprint);
      if (inflight.thumbnail != null) return inflight.thumbnail;
      if (inflight.present) return null;
      await _deleteCachePair(metadataFile, bytesFile);
      _forgetDiskEntry(digest);
      return null;
    }
  }

  Future<void> _scheduleDiskWrite(
    String key,
    String fingerprint,
    MediaThumbnail thumbnail, {
    ThumbnailCancellation? cancellation,
  }) {
    if (_disposed) return Future<void>.value();
    if (thumbnail.byteLength <= 0 ||
        thumbnail.byteLength > _maximumPendingDiskWriteBytes) {
      return Future<void>.value();
    }
    final digest = sha256.convert(utf8.encode(key)).toString();
    for (var index = _diskQueue.length - 1; index >= 0; index--) {
      final queued = _diskQueue[index];
      if (queued.digest != digest) continue;
      _diskQueue.removeAt(index);
      _pendingDiskWriteBytes -= queued.thumbnail.byteLength;
      queued.cancellation?.setWaitingInQueue(false);
      if (!queued.completer.isCompleted) queued.completer.complete();
    }
    if (_pendingDiskWriteBytes + thumbnail.byteLength >
            _maximumPendingDiskWriteBytes ||
        _diskQueue.length >= _maximumPendingDiskWriteCount) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    final task = _DiskWriteTask(
      digest: digest,
      fingerprint: fingerprint,
      thumbnail: thumbnail,
      cancellation: cancellation,
      completer: completer,
    );
    _diskQueue.add(task);
    _activeDiskWrites[digest] = task;
    _pendingDiskWriteBytes += thumbnail.byteLength;
    cancellation?.setWaitingInQueue(true);
    _pumpDiskQueue();
    return completer.future;
  }

  void _pumpDiskQueue() {
    if (_pumpingDiskQueue) return;
    _pumpingDiskQueue = true;
    unawaited(() async {
      try {
        while (_diskQueue.isNotEmpty) {
          final task = _diskQueue.removeAt(0);
          _pendingDiskWriteBytes -= task.thumbnail.byteLength;
          task.cancellation?.setWaitingInQueue(false);
          try {
            await _executeDiskWrite(task);
          } catch (_) {
            // Cache writes are best-effort
          } finally {
            if (identical(_activeDiskWrites[task.digest], task)) {
              _activeDiskWrites.remove(task.digest);
            }
            if (!task.completer.isCompleted) task.completer.complete();
          }
        }
      } finally {
        _pumpingDiskQueue = false;
        _completeDiskQueueDrainIfIdle();
      }
    }());
  }

  void _completeDiskQueueDrainIfIdle() {
    if (_pumpingDiskQueue || _diskQueue.isNotEmpty) return;
    final completer = _diskQueueDrainCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _diskQueueDrainCompleter = null;
  }

  Future<void> _executeDiskWrite(_DiskWriteTask task) async {
    final fingerprint = task.fingerprint;
    final thumbnail = task.thumbnail;
    if (thumbnail.byteLength <= 0 ||
        thumbnail.byteLength > _maximumCacheEntryBytes ||
        thumbnail.byteLength > _maxDiskBytes) {
      return;
    }
    final directory = await _cacheDirectory();
    if (directory == null) return;
    await _initializeDiskAccounting(directory);
    final digest = task.digest;
    final bytesFile = File(p.join(directory.path, '$digest.img'));
    final metadataFile = File(p.join(directory.path, '$digest.json'));
    final bytesTemp = File(p.join(directory.path, '$digest.img.tmp'));
    final metadataTemp = File(p.join(directory.path, '$digest.json.tmp'));

    _activeTempFiles.add(p.normalize(bytesTemp.path));
    _activeTempFiles.add(p.normalize(metadataTemp.path));

    try {
      final oldSize = _diskEntries[digest]?.bytesSize ?? 0;

      await bytesTemp.writeAsBytes(thumbnail.bytes, flush: true);
      await _replaceFile(bytesTemp, bytesFile);
      await metadataTemp.writeAsString(
        jsonEncode(<String, Object?>{
          'fingerprint': fingerprint,
          'durationMs': thumbnail.duration.inMilliseconds,
        }),
        flush: true,
      );
      await _replaceFile(metadataTemp, metadataFile);

      _diskBytes = _diskBytes - oldSize + thumbnail.byteLength;
      if (_diskBytes < 0) _diskBytes = thumbnail.byteLength;
      _diskEntries[digest] = _DiskEntry(
        digest,
        metadataFile,
        bytesFile,
        DateTime.now(),
        thumbnail.byteLength,
      );
      _diskWritesSinceScan++;
      await _pruneDisk(directory, keepDigest: digest);
    } on Object {
      // A cache write is best-effort; extraction results remain usable.
    } finally {
      _activeTempFiles.remove(p.normalize(bytesTemp.path));
      _activeTempFiles.remove(p.normalize(metadataTemp.path));
      await _deleteIfPresent(bytesTemp);
      await _deleteIfPresent(metadataTemp);
    }
  }

  /// Replaces [destination] with [temporary].
  ///
  /// The rename is attempted first because it is atomic where the platform
  /// allows replacing the destination directly. When the filesystem refuses
  /// (Windows may while a reader holds the destination open), the contents are
  /// copied over the destination instead so the cache entry still lands.
  static Future<void> _replaceFile(File temporary, File destination) async {
    try {
      await temporary.rename(destination.path);
      return;
    } on FileSystemException {
      // Fall through to the copy-based replacement.
    }
    try {
      await temporary.copy(destination.path);
    } on FileSystemException {
      // The destination itself may be the blocker; drop it and copy again.
      await _deleteIfPresent(destination);
      await temporary.copy(destination.path);
    }
    await _deleteIfPresent(temporary);
  }

  Future<void> _pruneDisk(
    Directory directory, {
    required String keepDigest,
  }) async {
    try {
      if (_diskWritesSinceScan >= _diskRescanWriteInterval) {
        await _rebuildDiskAccounting(directory);
      }
      final entries = _diskEntries.values.toList(growable: false);
      entries.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
      var bytesUsed = _diskBytes;
      var entriesLeft = _diskEntries.length;
      for (final item in entries) {
        if (bytesUsed <= _maxDiskBytes && entriesLeft <= _maximumDiskEntries) {
          break;
        }
        if (item.digest == keepDigest) continue;
        await _deleteCachePair(item.metadata, item.bytes);
        _diskEntries.remove(item.digest);
        bytesUsed -= item.bytesSize;
        entriesLeft--;
      }
      _diskBytes = bytesUsed;
    } on Object {
      // Pruning must never make a successful thumbnail unavailable.
    }
  }

  Future<void> _initializeDiskAccounting(Directory directory) async {
    if (_diskAccountingInitialized) return;
    await _rebuildDiskAccounting(directory);
  }

  Future<void> _rebuildDiskAccounting(Directory directory) async {
    final files = <String, File>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) files[p.basename(entity.path)] = entity;
    }

    final entries = <String, _DiskEntry>{};
    var totalBytes = 0;
    for (final file in files.values) {
      final name = p.basename(file.path);
      if (!name.endsWith('.json')) continue;
      final digest = p.basenameWithoutExtension(name);
      if (!_isCacheDigest(digest)) continue;
      final bytes = File(p.join(directory.path, '$digest.img'));
      try {
        final metadataStat = await file.stat();
        final bytesStat = await bytes.stat();
        if (metadataStat.type != FileSystemEntityType.file ||
            bytesStat.type != FileSystemEntityType.file ||
            bytesStat.size <= 0 ||
            bytesStat.size > _maximumCacheEntryBytes) {
          await _deleteCachePair(file, bytes);
          continue;
        }
        final entry = _DiskEntry(
          digest,
          file,
          bytes,
          metadataStat.modified,
          bytesStat.size,
        );
        entries[digest] = entry;
        totalBytes += bytesStat.size;
      } on FileSystemException {
        await _deleteCachePair(file, bytes);
      }
    }

    for (final file in files.values) {
      final name = p.basename(file.path);
      if (RegExp(r'^[a-f0-9]{64}\.(?:img|json)\.tmp$').hasMatch(name)) {
        final normalized = p.normalize(file.path);
        if (!_activeTempFiles.contains(normalized)) {
          await _deleteIfPresent(file);
        }
      } else if (RegExp(r'^[a-f0-9]{64}\.img$').hasMatch(name)) {
        final digest = p.basenameWithoutExtension(name);
        if (!entries.containsKey(digest)) await _deleteIfPresent(file);
      }
    }

    _diskEntries
      ..clear()
      ..addAll(entries);
    _diskBytes = totalBytes;
    _diskWritesSinceScan = 0;
    _diskAccountingInitialized = true;
  }

  void _forgetDiskEntry(String digest) {
    final removed = _diskEntries.remove(digest);
    if (removed != null) {
      _diskBytes -= removed.bytesSize;
      if (_diskBytes < 0) _diskBytes = 0;
    }
  }

  void _touchDiskEntry(String digest) {
    final entry = _diskEntries[digest];
    if (entry == null) return;
    _diskEntries[digest] = _DiskEntry(
      entry.digest,
      entry.metadata,
      entry.bytes,
      DateTime.now(),
      entry.bytesSize,
    );
  }

  static Future<void> _deleteCachePair(File metadata, File bytes) async {
    await _deleteIfPresent(metadata);
    await _deleteIfPresent(bytes);
  }

  /// Reads at most [maximumBytes] even if a file grows after it is inspected.
  /// A changed or incomplete file is treated as unusable and can be retried by
  /// the caller on a later request.
  static Future<Uint8List?> _readFileBounded(
    File file, {
    required int maximumBytes,
  }) async {
    RandomAccessFile? handle;
    try {
      final before = await file.stat();
      if (before.type != FileSystemEntityType.file ||
          before.size <= 0 ||
          before.size > maximumBytes) {
        return null;
      }

      handle = await file.open(mode: FileMode.read);
      final length = await handle.length();
      if (length <= 0 || length > maximumBytes) return null;
      final bytes = await handle.read(length);
      final after = await file.stat();
      if (bytes.length != length ||
          after.type != FileSystemEntityType.file ||
          after.size != length) {
        return null;
      }
      return bytes;
    } on FileSystemException {
      return null;
    } finally {
      try {
        await handle?.close();
      } on Object {
        // Closing a failed read must not hide its unusable result.
      }
    }
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cache cleanup is best-effort.
    }
  }

  static bool _isCacheDigest(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  static MediaThumbnail _withKnownDuration(
    MediaThumbnail thumbnail,
    Duration hint,
  ) => thumbnail.duration > Duration.zero || hint <= Duration.zero
      ? thumbnail
      : MediaThumbnail(bytes: thumbnail.bytes, duration: hint);

  /// Inspects image dimensions before decoding and normalizes artwork to fit within 320x320
  /// while preserving aspect ratio. Rejects images exceeding 32 megapixels.
  static Future<Uint8List?> _normalizeArtwork(
    Uint8List bytes, {
    ThumbnailImageValidator? validator,
  }) async {
    if (bytes.isEmpty) return null;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width < 1 ||
          height < 1 ||
          width > thumbnailMaximumDimension ||
          height > thumbnailMaximumDimension) {
        return null;
      }
      if (width * height > thumbnailMaximumMegaPixels) {
        // Strictly bound decoding memory by rejecting images exceeding 32 megapixels.
        return null;
      }

      int targetWidth = width;
      int targetHeight = height;
      if (width > _maxThumbnailDimension || height > _maxThumbnailDimension) {
        if (width >= height) {
          targetWidth = _maxThumbnailDimension;
          targetHeight = ((height * _maxThumbnailDimension) / width)
              .round()
              .clamp(1, _maxThumbnailDimension);
        } else {
          targetHeight = _maxThumbnailDimension;
          targetWidth = ((width * _maxThumbnailDimension) / height)
              .round()
              .clamp(1, _maxThumbnailDimension);
        }
      }

      if (targetWidth < width || targetHeight < height) {
        codec = await descriptor.instantiateCodec(
          targetWidth: targetWidth,
          targetHeight: targetHeight,
        );
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data != null) {
            return data.buffer.asUint8List();
          }
        } finally {
          frame.image.dispose();
        }
      }
      return bytes;
    } on Object {
      if (validator != null && await validator(bytes)) {
        return bytes;
      }
      return null;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  @override
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    _suspended = false;
    final resumeCompleter = _resumeCompleter;
    _resumeCompleter = null;
    resumeCompleter?.complete();
    _disposal = () async {
      for (final request in _activeRequests.values.toList(growable: false)) {
        request.cancel();
      }
      _activeRequests.clear();
      final queuedExt = _extractionQueue.toList(growable: false);
      _extractionQueue.clear();
      for (final task in queuedExt) {
        task.cancel();
      }
      final queuedNorm = _normalizerQueue.toList(growable: false);
      _normalizerQueue.clear();
      for (final task in queuedNorm) {
        task.cancel();
      }
      _pumpDiskQueue();
      if (_pumpingDiskQueue || _diskQueue.isNotEmpty) {
        final drained = _diskQueueDrainCompleter ??= Completer<void>();
        await drained.future.timeout(
          const Duration(seconds: 8),
          onTimeout: () {},
        );
      }
      await _extractor.dispose();
      while (_loadOperations.isNotEmpty) {
        final pending = _loadOperations.toList(growable: false);
        await Future.wait<void>(
          pending.map((operation) async {
            try {
              await operation;
            } on Object {
              // Failed loads still need to finish their output cleanup.
            }
          }),
        );
      }
      _memory.clear();
      _memoryBytes = 0;
    }();
    return _disposal!;
  }
}

class _SourceSnapshot {
  const _SourceSnapshot({
    required this.source,
    required this.cacheable,
    required this.memoryCacheable,
    required this.fingerprint,
    required this.sidecars,
  });

  final String source;
  final bool cacheable;
  final bool memoryCacheable;
  final String fingerprint;
  final List<File> sidecars;
}

class _MemoryThumbnail {
  const _MemoryThumbnail(this.fingerprint, this.thumbnail, this.expiresAt);

  final String fingerprint;
  final MediaThumbnail thumbnail;
  final DateTime? expiresAt;
}

class _ExtractionTask {
  _ExtractionTask({
    required this.priority,
    required this.sequence,
    required this.cancellation,
    required this.run,
    required this.cancel,
  });

  ThumbnailPriority priority;
  final int sequence;
  final ThumbnailCancellation cancellation;
  final Future<void> Function() run;
  final void Function() cancel;
}

class _NormalizerTask {
  _NormalizerTask({
    required this.priority,
    required this.sequence,
    required this.cancellation,
    required this.run,
    required this.cancel,
  });

  ThumbnailPriority priority;
  final int sequence;
  final ThumbnailCancellation cancellation;
  final Future<void> Function() run;
  final void Function() cancel;
}

class _DiskWriteTask {
  _DiskWriteTask({
    required this.digest,
    required this.fingerprint,
    required this.thumbnail,
    required this.cancellation,
    required this.completer,
  });

  final String digest;
  final String fingerprint;
  final MediaThumbnail thumbnail;
  final ThumbnailCancellation? cancellation;
  final Completer<void> completer;
}

class _ActiveThumbnailRequest {
  _ActiveThumbnailRequest({
    required this.service,
    required this.entry,
    required this.key,
    required this.sequence,
    this._priority = ThumbnailPriority.normal,
  }) {
    cancellation.bindQueueWait((bool waiting) {
      if (waiting) {
        _pauseTimeout();
      } else {
        _resumeTimeoutIfActive();
      }
    });
  }

  final MediaKitThumbnailService service;
  final MediaEntry entry;
  final String key;
  final int sequence;
  final ThumbnailCancellation cancellation = ThumbnailCancellation();

  final List<_ThumbnailRequestHandleImpl> _handles =
      <_ThumbnailRequestHandleImpl>[];
  final Completer<MediaThumbnail?> _completer = Completer<MediaThumbnail?>();
  bool _started = false;
  ThumbnailPriority _priority;

  Timer? _timeoutTimer;
  Duration _remainingTimeout = Duration.zero;
  DateTime? _lastActiveStartTime;

  ThumbnailPriority get priority => _priority;
  bool get isCompleted => _completer.isCompleted;

  void promotePriority(ThumbnailPriority priority) {
    if (priority == ThumbnailPriority.high &&
        _priority != ThumbnailPriority.high) {
      _priority = ThumbnailPriority.high;
      service._promoteActiveRequestPriority(this);
    }
  }

  ThumbnailRequestHandle attach(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  }) {
    if (priority == ThumbnailPriority.high) {
      promotePriority(priority);
    }
    final handle = _ThumbnailRequestHandleImpl(this, entry);
    _handles.add(handle);
    if (_completer.isCompleted) {
      _completer.future.then((thumb) {
        if (!handle.isReleased) {
          handle._complete(thumb);
        }
      });
    }
    return handle;
  }

  void onHandleReleased(_ThumbnailRequestHandleImpl handle) {
    if (_completer.isCompleted) return;
    final hasActive = _handles.any((h) => !h.isReleased);
    if (!hasActive) {
      cancel();
    }
  }

  void onSuspend() {
    _pauseTimeout();
  }

  void onResume() {
    _resumeTimeoutIfActive();
  }

  void _pauseTimeout() {
    if (_timeoutTimer != null && _timeoutTimer!.isActive) {
      _timeoutTimer!.cancel();
      _timeoutTimer = null;
      if (_lastActiveStartTime != null) {
        final elapsed = DateTime.now().difference(_lastActiveStartTime!);
        _remainingTimeout = _remainingTimeout - elapsed;
        if (_remainingTimeout < Duration.zero) {
          _remainingTimeout = Duration.zero;
        }
        _lastActiveStartTime = null;
      }
    }
  }

  void _resumeTimeoutIfActive() {
    if (_completer.isCompleted) return;
    if (service._suspended || cancellation.isWaitingInQueue) return;
    if (_timeoutTimer == null || !_timeoutTimer!.isActive) {
      _startTimeoutTimer();
    }
  }

  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    if (_completer.isCompleted ||
        service._suspended ||
        cancellation.isWaitingInQueue) {
      return;
    }
    _lastActiveStartTime = DateTime.now();
    _timeoutTimer = Timer(_remainingTimeout, _handleTimeout);
  }

  void _handleTimeout() {
    if (_completer.isCompleted) return;
    final timeout = service._operationTimeout + service._requestTimeoutGrace;
    service._recordDiagnostic(
      'timeout',
      source: entry.path,
      message: 'Thumbnail request timed out after $timeout',
    );
    cancel();
  }

  void cancel() {
    if (_completer.isCompleted) return;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    cancellation.cancel();
    service._onActiveRequestCancelled(this);
    _complete(null);
  }

  void start() {
    if (_started) return;
    _started = true;
    _remainingTimeout =
        service._operationTimeout + service._requestTimeoutGrace;
    if (!service._suspended) {
      _startTimeoutTimer();
    }
    service
        ._loadTracked(
          entry,
          key,
          cancellation,
          priority: _priority,
          sequence: sequence,
        )
        .then((thumbnail) {
          _complete(thumbnail);
        })
        .catchError((Object error) {
          service._recordDiagnostic(
            'error',
            source: entry.path,
            message: 'Thumbnail loading encountered an unexpected error',
            error: error,
          );
          _complete(null);
          return null;
        });
  }

  void _complete(MediaThumbnail? thumbnail) {
    if (!_completer.isCompleted) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      cancellation.bindQueueWait(null);
      _completer.complete(thumbnail);
      if (identical(service._activeRequests[key], this)) {
        service._activeRequests.remove(key);
      }
      for (final handle in _handles) {
        if (!handle.isReleased) {
          handle._complete(thumbnail);
        }
      }
    }
  }
}

class _ThumbnailRequestHandleImpl implements ThumbnailRequestHandle {
  _ThumbnailRequestHandleImpl(this._request, this.entry);

  final _ActiveThumbnailRequest _request;

  @override
  final MediaEntry entry;

  final Completer<MediaThumbnail?> _thumbnailCompleter =
      Completer<MediaThumbnail?>();
  bool _released = false;

  bool get isReleased => _released;

  @override
  Future<MediaThumbnail?> get thumbnail => _thumbnailCompleter.future;

  @override
  Future<Uint8List?> get result =>
      _thumbnailCompleter.future.then((thumb) => thumb?.bytes);

  void _complete(MediaThumbnail? thumbnail) {
    if (!_thumbnailCompleter.isCompleted) {
      _thumbnailCompleter.complete(thumbnail);
    }
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    if (!_thumbnailCompleter.isCompleted) {
      _thumbnailCompleter.complete(null);
    }
    _request.onHandleReleased(this);
  }

  @override
  void cancel() => release();
}

class _ImmediateThumbnailRequestHandle implements ThumbnailRequestHandle {
  _ImmediateThumbnailRequestHandle(this.entry, this._thumbnail);

  @override
  final MediaEntry entry;
  final MediaThumbnail? _thumbnail;

  @override
  Future<Uint8List?> get result => Future<Uint8List?>.value(_thumbnail?.bytes);

  @override
  Future<MediaThumbnail?> get thumbnail =>
      Future<MediaThumbnail?>.value(_thumbnail);

  @override
  void release() {}

  @override
  void cancel() {}
}

class _DiskEntry {
  const _DiskEntry(
    this.digest,
    this.metadata,
    this.bytes,
    this.lastUsed,
    this.bytesSize,
  );

  final String digest;
  final File metadata;
  final File bytes;
  final DateTime lastUsed;
  final int bytesSize;
}
