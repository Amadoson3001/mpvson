import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/media_entry.dart';
import '../../domain/models/playback_session.dart';
import '../../domain/models/session_progress.dart';

/// Asynchronously serializes a [PlaybackSession] to JSON.
typedef SessionEncoder = FutureOr<String> Function(PlaybackSession session);

/// Thrown when persisting the playback session fails.
class SessionSaveException implements Exception {
  const SessionSaveException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause != null
      ? 'SessionSaveException: $message ($cause)'
      : 'SessionSaveException: $message';
}

/// Outcome of [SessionRepository.loadDetailed].
class SessionLoadResult {
  const SessionLoadResult({
    this.session,
    this.primaryRejected = false,
    this.note,
  });

  final PlaybackSession? session;

  /// Whether the primary file was structurally unusable. The backup was used
  /// when one was available.
  final bool primaryRejected;

  /// Short, user-readable reason for a rejected primary.
  final String? note;
}

/// Reads and writes the stopped playback session in the OS support directory.
class SessionRepository {
  SessionRepository({
    Directory? directory,
    Duration lockTimeout = lockDeadline,
    SessionEncoder? encoder,
  }) : _providedDirectory = directory,
       // Keep the public tuning parameter name independent of the private field.
       // ignore: prefer_initializing_formals
       _lockTimeout = lockTimeout,
       _encoder = encoder ?? _defaultEncoder;

  /// How long a save waits for the inter-process session lock.
  static const Duration lockDeadline = Duration(seconds: 5);

  static final Map<String, Future<void>> _directorySaveTails =
      <String, Future<void>>{};

  final Directory? _providedDirectory;
  final Duration _lockTimeout;
  final SessionEncoder _encoder;
  Future<Directory>? _directoryFuture;
  Future<void>? _activeSave;
  _PendingSaveRequest? _pendingSave;
  Future<void>? _activeProgressSave;
  _PendingProgressRequest? _pendingProgressSave;
  Future<void>? _scrubFuture;

  /// Default session encoder that performs heavy JSON serialization in a background isolate.
  static Future<String> _defaultEncoder(PlaybackSession session) =>
      Isolate.run(() => jsonEncode(session.toJson()));

  Future<void> init() async {
    final directory = await _resolveDirectory();
    await directory.create(recursive: true);
  }

  Future<PlaybackSession?> load() async => (await loadDetailed()).session;

  /// Loads the session, falling back to the recovery copy.
  ///
  /// A structurally invalid primary no longer becomes an empty session: it is
  /// rejected so the backup can supply the state instead.
  Future<SessionLoadResult> loadDetailed() async {
    try {
      await init();
      final file = await _sessionFile();
      try {
        final primary = await _readSession(file);
        if (primary != null) return SessionLoadResult(session: primary);
        if (!await file.exists()) {
          // No primary at all: the backup may still carry the last session.
          final backup = await _readSession(_backupFile(file));
          return SessionLoadResult(
            session: backup,
            note: backup == null ? null : 'Recovered from the session backup.',
          );
        }
      } on SessionFormatException catch (error) {
        final backup = await _readSession(_backupFile(file));
        return SessionLoadResult(
          session: backup,
          primaryRejected: true,
          note: backup == null
              ? 'The stored session was rejected: ${error.message}'
              : 'The stored session was rejected and the backup was used: '
                    '${error.message}',
        );
      }
      return const SessionLoadResult();
    } on Object catch (error) {
      // A missing, truncated, or incompatible session must not prevent launch.
      return SessionLoadResult(
        note: 'The stored session could not be read: $error',
      );
    }
  }

  Future<void> save(PlaybackSession session) =>
      _enqueueSave(session, scrubBackup: false);

  /// Saves [session] and replaces the recovery copy with the same content.
  ///
  /// An ordinary save keeps the previous primary as the recovery copy, which is
  /// what makes it recoverable. When stream URLs were intentionally removed from
  /// the session that copy would keep them, so the recovery copy is rewritten
  /// with the scrubbed content instead.
  Future<void> saveScrubbed(PlaybackSession session) =>
      _enqueueSave(session, scrubBackup: true);

  Future<void> _enqueueSave(
    PlaybackSession session, {
    required bool scrubBackup,
  }) {
    final completer = Completer<void>();
    if (_activeSave == null) {
      final active = _performSave(session, scrubBackup: scrubBackup);
      _activeSave = active;
      active
          .whenComplete(() {
            _activeSave = null;
            _drainPendingSave();
          })
          .then(
            (_) {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (Object error, StackTrace stack) {
              if (!completer.isCompleted) completer.completeError(error, stack);
            },
          );
      return completer.future;
    }

    final pending = _pendingSave ??= _PendingSaveRequest(
      session,
      scrubBackup: scrubBackup,
    );
    pending.session = session;
    if (scrubBackup) pending.scrubBackup = true;
    pending.completers.add(completer);
    return completer.future;
  }

  void _drainPendingSave() {
    final pending = _pendingSave;
    if (pending == null) return;
    _pendingSave = null;
    final active = _performSave(
      pending.session,
      scrubBackup: pending.scrubBackup,
    );
    _activeSave = active;
    active
        .whenComplete(() {
          _activeSave = null;
          _drainPendingSave();
        })
        .then(
          (_) {
            for (final c in pending.completers) {
              if (!c.isCompleted) c.complete();
            }
          },
          onError: (Object error, StackTrace stack) {
            for (final c in pending.completers) {
              if (!c.isCompleted) c.completeError(error, stack);
            }
          },
        );
  }

  /// Writes the small periodic progress checkpoint.
  Future<void> saveProgress(SessionProgress progress) {
    final completer = Completer<void>();
    if (_activeProgressSave == null) {
      final active = _performSaveProgress(progress);
      _activeProgressSave = active;
      active
          .whenComplete(() {
            _activeProgressSave = null;
            _drainPendingProgress();
          })
          .then(
            (_) {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (Object error, StackTrace stack) {
              if (!completer.isCompleted) completer.completeError(error, stack);
            },
          );
      return completer.future;
    }

    final pending = _pendingProgressSave ??= _PendingProgressRequest(progress);
    pending.progress = progress;
    pending.completers.add(completer);
    return completer.future;
  }

  /// Waits until this repository has written every active and coalesced save.
  ///
  /// Used during shutdown and before privacy scrubs so a queued write cannot
  /// recreate data after the files have been cleaned.
  Future<void> flush() async {
    while (true) {
      final sessionSave = _activeSave;
      final progressSave = _activeProgressSave;
      if (sessionSave == null &&
          progressSave == null &&
          _pendingSave == null &&
          _pendingProgressSave == null) {
        return;
      }

      await Future.wait<void>(<Future<void>>[
        if (sessionSave != null)
          sessionSave.then<void>((_) {}, onError: (Object _) {}),
        if (progressSave != null)
          progressSave.then<void>((_) {}, onError: (Object _) {}),
      ]);
      // Let each active write's completion callback start its latest pending
      // request before checking the queues again.
      await Future<void>.delayed(Duration.zero);
    }
  }

  void _drainPendingProgress() {
    final pending = _pendingProgressSave;
    if (pending == null) return;
    _pendingProgressSave = null;
    final active = _performSaveProgress(pending.progress);
    _activeProgressSave = active;
    active
        .whenComplete(() {
          _activeProgressSave = null;
          _drainPendingProgress();
        })
        .then(
          (_) {
            for (final c in pending.completers) {
              if (!c.isCompleted) c.complete();
            }
          },
          onError: (Object error, StackTrace stack) {
            for (final c in pending.completers) {
              if (!c.isCompleted) c.completeError(error, stack);
            }
          },
        );
  }

  /// Reads the last written progress checkpoint, when it is usable.
  Future<SessionProgress?> loadProgress() async {
    try {
      await init();
      final file = await _progressFile();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return SessionProgress.tryFromJson(Map<String, Object?>.from(decoded));
    } on Object {
      // A corrupt or partially replaced checkpoint is simply ignored: the
      // session file still holds the last complete progress.
      return null;
    }
  }

  /// Removes stream URLs from every file this application owns.
  ///
  /// Used when URL persistence is disabled or was never consented to: the queue
  /// and history keep their local files, while stream URLs disappear from the
  /// primary, the recovery copy and the checkpoint.
  Future<void> scrubNetworkUrls() {
    final existing = _scrubFuture;
    if (existing != null) return existing;

    late final Future<void> scrub;
    scrub = _scrubNetworkUrls().whenComplete(() {
      if (identical(_scrubFuture, scrub)) _scrubFuture = null;
    });
    _scrubFuture = scrub;
    return scrub;
  }

  Future<void> _scrubNetworkUrls() async {
    // Drain writes that may have captured the old consent setting. Callers
    // disable future stream persistence before entering this barrier.
    await flush();
    final session = await load();
    if (session != null) {
      // Always mirror the scrubbed content into the recovery copy too. The
      // primary can already be clean while its backup still contains a URL.
      await saveScrubbed(session.withoutNetworkUrls());
    }
    // A checkpoint that names a stream, or an entry the session no longer
    // stores, cannot be trusted to describe a local file: drop it so a stream
    // position cannot be reported back to the user.
    final checkpointFile = await _progressFile();
    final checkpointExists = await checkpointFile.exists();
    final checkpoint = await loadProgress();
    final checkpointId = checkpoint?.entryId;
    if (checkpointExists &&
        (checkpointId == null ||
            _describesNetworkEntry(session, checkpointId))) {
      await saveProgress(const SessionProgress());
    }
    await flush();
  }

  /// Whether the checkpoint entry [entryId] belongs to a stream URL.
  ///
  /// An id that names nothing stored is treated as a stream: the file it came
  /// from is gone, so its position must not outlive it.
  bool _describesNetworkEntry(PlaybackSession? session, String entryId) {
    if (MediaEntry.isNetworkUrl(entryId)) return true;
    if (session == null) return true;
    for (final entry in <MediaEntry>[...session.queue, ...session.recent]) {
      if (entry.id == entryId) return MediaEntry.isNetworkUrl(entry.path);
    }
    return true;
  }

  Future<void> _performSave(
    PlaybackSession session, {
    required bool scrubBackup,
  }) async {
    try {
      await init();
      final directory = await _resolveDirectory();
      await _withDirectorySaveLock(directory, () async {
        final target = File(p.join(directory.path, 'session.json'));
        final backup = _backupFile(target);
        final temporaryDirectory = await directory.createTemp('.session-');
        final temporary = File(p.join(temporaryDirectory.path, 'session.json'));
        try {
          final encoded = await _encoder(session);
          await temporary.writeAsString(encoded, flush: true);
          final hadPreviousFile = await target.exists();
          if (hadPreviousFile) {
            if (await backup.exists()) await backup.delete();
            await target.rename(backup.path);
          }
          try {
            await temporary.rename(target.path);
          } on Object {
            if (hadPreviousFile && await backup.exists()) {
              await backup.rename(target.path);
            }
            rethrow;
          }
          if (scrubBackup) {
            // The recovery copy must not keep what the user removed from the
            // session, so it is replaced with the same content.
            final mirror = File(p.join(temporaryDirectory.path, 'backup.json'));
            await mirror.writeAsString(encoded, flush: true);
            if (await backup.exists()) await backup.delete();
            await mirror.rename(backup.path);
          }
          // Keep the last complete session as a recovery copy. On the next
          // write it is replaced only after the new temporary file is ready.
        } finally {
          if (await temporaryDirectory.exists()) {
            await temporaryDirectory.delete(recursive: true);
          }
        }
      });
    } on Object catch (exception) {
      if (exception is SessionSaveException) rethrow;
      throw SessionSaveException('Failed to save playback session', exception);
    }
  }

  Future<void> _performSaveProgress(SessionProgress progress) async {
    try {
      await init();
      final directory = await _resolveDirectory();
      await _withDirectorySaveLock(directory, () async {
        final target = await _progressFile();
        final temporary = File('${target.path}.tmp');
        // The checkpoint is replaced in one rename, so an interrupted write
        // leaves the previous checkpoint intact.
        await temporary.writeAsString(
          jsonEncode(progress.toJson()),
          flush: true,
        );
        await temporary.rename(target.path);
      });
    } on Object catch (exception) {
      if (exception is SessionSaveException) rethrow;
      throw SessionSaveException('Failed to save playback progress', exception);
    }
  }

  Future<void> _withDirectorySaveLock(
    Directory directory,
    Future<void> Function() action,
  ) async {
    var key = p.normalize(p.absolute(directory.path));
    if (Platform.isWindows) key = key.toLowerCase();

    // File locks coordinate separate processes; this tail also serializes
    // repository instances in one isolate, including platforms whose file
    // locks are process-scoped.
    final previous = _directorySaveTails[key] ?? Future<void>.value();
    final release = Completer<void>();
    final releaseFuture = release.future;
    _directorySaveTails[key] = releaseFuture;
    await previous;
    try {
      final lockFile = File(p.join(directory.path, 'session.lock'));
      final handle = await lockFile.open(mode: FileMode.append);
      try {
        await _acquireLock(handle);
        await action();
      } finally {
        try {
          await handle.unlock();
        } on Object {
          // Closing the handle releases an OS lock if explicit unlock fails.
        }
        await handle.close();
      }
    } finally {
      release.complete();
      if (identical(_directorySaveTails[key], releaseFuture)) {
        _directorySaveTails.remove(key);
      }
    }
  }

  /// Takes the inter-process lock without blocking indefinitely.
  ///
  /// Waiting for a lock another process never released would leave the shutdown
  /// path stuck, so acquisition retries with a bounded, jittered backoff and
  /// reports a save failure once [_lockTimeout] expires.
  Future<void> _acquireLock(RandomAccessFile handle) async {
    final deadline = DateTime.now().add(_lockTimeout);
    var attempt = 0;
    while (true) {
      try {
        await handle.lock(FileLock.exclusive);
        return;
      } on FileSystemException catch (error) {
        attempt++;
        if (!DateTime.now().isBefore(deadline)) {
          throw SessionSaveException(
            'Timed out waiting for the session lock.',
            error,
          );
        }
        final backoff = min(20 + attempt * 15, 120);
        await Future<void>.delayed(Duration(milliseconds: backoff));
      }
    }
  }

  /// Reads one session file, throwing [SessionFormatException] when the stored
  /// structure is unusable so the caller can try the recovery copy.
  Future<PlaybackSession?> _readSession(File file) async {
    if (!await file.exists()) return null;
    final jsonString = await file.readAsString();
    try {
      return await Isolate.run(() {
        final Object? decoded;
        try {
          decoded = jsonDecode(jsonString);
        } on FormatException catch (error) {
          throw SessionFormatException(
            'The stored file is not valid JSON ($error)',
          );
        }
        if (decoded is! Map) {
          throw const SessionFormatException(
            'The stored file is not a JSON object',
          );
        }
        return PlaybackSession.fromJson(Map<String, Object?>.from(decoded));
      });
    } on SessionFormatException {
      rethrow;
    } on FormatException catch (error) {
      throw SessionFormatException(
        'The stored file is not valid JSON ($error)',
      );
    } on Object catch (error) {
      final message = error.toString();
      if (message.contains('SessionFormatException:')) {
        final detail = message.replaceFirst(
          RegExp(r'.*SessionFormatException:\s*'),
          '',
        );
        throw SessionFormatException(detail);
      }
      rethrow;
    }
  }

  File _backupFile(File target) => File('${target.path}.bak');

  Future<File> _sessionFile() async {
    final directory = await _resolveDirectory();
    return File(p.join(directory.path, 'session.json'));
  }

  Future<File> _progressFile() async {
    final directory = await _resolveDirectory();
    return File(p.join(directory.path, 'progress.json'));
  }

  Future<Directory> _resolveDirectory() {
    return _directoryFuture ??= _providedDirectory == null
        ? getApplicationSupportDirectory().then(
            (directory) => Directory(p.join(directory.path, 'mpvson')),
          )
        : Future<Directory>.value(_providedDirectory);
  }
}

class _PendingSaveRequest {
  _PendingSaveRequest(this.session, {required this.scrubBackup});

  PlaybackSession session;
  bool scrubBackup;
  final List<Completer<void>> completers = <Completer<void>>[];
}

class _PendingProgressRequest {
  _PendingProgressRequest(this.progress);

  SessionProgress progress;
  final List<Completer<void>> completers = <Completer<void>>[];
}
