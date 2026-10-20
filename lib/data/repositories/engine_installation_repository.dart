import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

// The public testing hook keeps a readable name instead of exposing the
// repository's private field name as a constructor parameter.
// ignore_for_file: prefer_initializing_formals

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/updates/engine_selection.dart';
import '../../domain/updates/semantic_version.dart';

/// Persists and stages Windows libmpv builds without touching a loaded DLL.
class EngineInstallationRepository {
  EngineInstallationRepository({
    Directory? enginesDirectory,
    Future<Directory> Function()? supportDirectoryProvider,
    Future<void> Function()? beforeSelectionWriteForTesting,
    Future<void> Function()? beforeExtractionForTesting,
    Future<void> Function()? beforeStageFailureCleanupForTesting,
    this.maxArchiveEntries = 4096,
    this.maxUncompressedBytes = 2 * 1024 * 1024 * 1024,
    this.bootLeaseTimeout = const Duration(seconds: 3),
  }) : _providedEnginesDirectory = enginesDirectory,
       _beforeSelectionWriteForTesting = beforeSelectionWriteForTesting,
       _beforeExtractionForTesting = beforeExtractionForTesting,
       _beforeStageFailureCleanupForTesting =
           beforeStageFailureCleanupForTesting,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const String selectionFileName = 'engine-selection.json';
  static const String storeLockFileName = '.engine-store.lock';
  static const String bootLeaseFileName = '.engine-boot.lease';
  static const String engineLibraryFileName = 'libmpv-2.dll';
  static const String stageOwnershipMarkerFileName =
      '.mpvson-engine-stage.json';
  static const String stageLeaseFileName = '.mpvson-stage.lease';
  static const String stageCancellationDirectoryName = '.mpvson-stage-cancel';

  /// Marker written inside every engine directory this updater installs.
  ///
  /// Only this durable ownership metadata authorizes removing a directory that
  /// the selection state no longer references.
  static const String engineOwnershipMarkerFileName = '.mpvson-engine.json';
  static const String engineOwnershipMarkerOwner = 'mpvson-engine-updater';
  static const String stageOwnershipMarkerOwner = 'mpvson-engine-stage';
  static final Map<String, Future<void>> _processLockTails =
      <String, Future<void>>{};
  static final Map<String, EngineInstallationRepository>
  _activeBootLeaseHolders = <String, EngineInstallationRepository>{};
  static final Map<String, Set<String>> _activeStageAttempts =
      <String, Set<String>>{};

  final Directory? _providedEnginesDirectory;
  final Future<void> Function()? _beforeSelectionWriteForTesting;
  final Future<void> Function()? _beforeExtractionForTesting;
  final Future<void> Function()? _beforeStageFailureCleanupForTesting;
  final Future<Directory> Function() _supportDirectoryProvider;
  final int maxArchiveEntries;
  final int maxUncompressedBytes;
  final Duration bootLeaseTimeout;
  Future<Directory>? _enginesDirectoryFuture;
  final Random _random = Random.secure();
  RandomAccessFile? _currentBootLeaseHandle;
  String? _currentBootAttemptToken;

  Future<Directory> get enginesDirectory => _resolveEnginesDirectory();

  Future<T> _withStoreLock<T>(Future<T> Function() action) async {
    await initialize();
    final root = p.normalize(
      p.absolute((await _resolveEnginesDirectory()).path),
    );
    final key = Platform.isWindows ? root.toLowerCase() : root;
    final predecessor = _processLockTails[key] ?? Future<void>.value();
    final releaseGate = Completer<void>();
    final gate = releaseGate.future;
    _processLockTails[key] = gate;

    void releaseProcessGate() {
      if (!releaseGate.isCompleted) releaseGate.complete();
      if (identical(_processLockTails[key], gate)) {
        _processLockTails.remove(key);
      }
    }

    try {
      await predecessor.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      predecessor.whenComplete(releaseProcessGate);
      throw StateError('Engine store is busy; retry the operation shortly.');
    }

    RandomAccessFile? lockHandle;
    var locked = false;
    try {
      final lockFile = File(p.join(root, storeLockFileName));
      if (await FileSystemEntity.type(lockFile.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException(
          'Engine store lock must not be a link.',
          lockFile.path,
        );
      }
      lockHandle = await lockFile.open(mode: FileMode.append);
      final stopwatch = Stopwatch()..start();
      while (!locked) {
        try {
          await lockHandle.lock(FileLock.exclusive);
          locked = true;
        } on FileSystemException {
          if (stopwatch.elapsed >= const Duration(seconds: 3)) {
            throw StateError(
              'Engine store is busy; retry the operation shortly.',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      return await action();
    } finally {
      try {
        if (locked && lockHandle != null) {
          try {
            await lockHandle.unlock();
          } on Object {
            // Closing the handle releases the OS lock as a final safeguard.
          }
        }
        if (lockHandle != null) {
          try {
            await lockHandle.close();
          } on Object {
            // Releasing the process-local gate is more important than a close
            // error after the transaction has completed.
          }
        }
      } finally {
        releaseProcessGate();
      }
    }
  }

  Future<void> initialize() async {
    final root = await _resolveEnginesDirectory();
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'The engine store must be a real directory, not a link.',
        root.path,
      );
    }
  }

  Future<String> _canonicalStoreKey() async {
    final root = p.normalize(
      p.absolute((await _resolveEnginesDirectory()).path),
    );
    return Platform.isWindows ? root.toLowerCase() : root;
  }

  Future<RandomAccessFile?> _tryLockBootLeaseFile() async {
    await initialize();
    final root = p.normalize(
      p.absolute((await _resolveEnginesDirectory()).path),
    );
    final leaseFile = File(p.join(root, bootLeaseFileName));
    if (await FileSystemEntity.type(leaseFile.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'Engine boot lease must not be a link.',
        leaseFile.path,
      );
    }
    final handle = await leaseFile.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return handle;
    } on FileSystemException {
      try {
        await handle.close();
      } on Object {
        // Ignored: best-effort close on lease lock failure.
      }
      return null;
    }
  }

  Future<bool> _isBootLeaseHeldByAnotherProcess() async {
    final key = await _canonicalStoreKey();
    final holder = _activeBootLeaseHolders[key];
    if (holder != null && !identical(holder, this)) {
      return true;
    }
    final testHandle = await _tryLockBootLeaseFile();
    if (testHandle == null) {
      return true;
    }
    try {
      await testHandle.unlock();
    } on Object {
      // Ignored: best-effort unlock on probe handle.
    }
    try {
      await testHandle.close();
    } on Object {
      // Ignored: best-effort close on probe handle.
    }
    return false;
  }

  Future<RandomAccessFile> _acquireBootLeaseHandle() async {
    final key = await _canonicalStoreKey();
    final holder = _activeBootLeaseHolders[key];
    if (holder != null && !identical(holder, this)) {
      throw StateError(
        'Engine boot lease is currently held by another process.',
      );
    }
    final handle = await _tryLockBootLeaseFile();
    if (handle == null) {
      throw StateError(
        'Engine boot lease is currently held by another process.',
      );
    }
    _activeBootLeaseHolders[key] = this;
    return handle;
  }

  Future<void> _releaseBootLease() async {
    final key = await _canonicalStoreKey();
    if (identical(_activeBootLeaseHolders[key], this)) {
      _activeBootLeaseHolders.remove(key);
    }
    final handle = _currentBootLeaseHandle;
    _currentBootLeaseHandle = null;
    _currentBootAttemptToken = null;
    if (handle != null) {
      try {
        await handle.unlock();
      } on Object {
        // Ignored: best-effort unlock on lease release.
      }
      try {
        await handle.close();
      } on Object {
        // Ignored: best-effort close on lease release.
      }
    }
  }

  String _generateAttemptToken() {
    final a = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final b = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '$a-$b';
  }

  /// Releases the held OS boot lease without committing confirmation or rejection.
  ///
  /// Used in tests to simulate an unexpected process crash during boot.
  Future<void> simulateCrashForTesting() => _releaseBootLease();

  /// Reads selection state after discarding records whose paths escape the
  /// engine store or no longer contain the expected library.
  ///
  /// A parseable primary file whose records no longer validate would otherwise
  /// hide a usable backup, so both files are validated before one is chosen.
  /// The primary's explicit decisions win: a bundled selection or an
  /// interrupted boot attempt is never replaced by an install the backup
  /// remembers, and a recovered backup never proposes a pending install,
  /// because that install may be the one this startup already rejected.
  Future<EngineSelectionState> loadSelection() async {
    await initialize();
    final file = await _selectionFile();
    final primary = await _readSanitizedSelection(file);
    if (primary != null && _hasSelectionTarget(primary)) return primary;
    final backup = await _readSanitizedSelection(File('${file.path}.bak'));
    return _recoveredSelection(primary, backup);
  }

  Future<EngineSelectionState?> _readSanitizedSelection(File file) async {
    final raw = await _readStateFile(file);
    if (raw == null) return null;
    return _sanitizeState(raw);
  }

  /// True when the state points at something that can be selected: a validated
  /// install or an explicit bundled choice.
  bool _hasSelectionTarget(EngineSelectionState state) =>
      state.active != null ||
      state.previous != null ||
      state.pending != null ||
      state.activeIsBundled ||
      state.pendingBundled;

  EngineSelectionState _recoveredSelection(
    EngineSelectionState? primary,
    EngineSelectionState? backup,
  ) {
    if (primary == null) {
      final state = backup ?? const EngineSelectionState();
      return _withoutRejectedRecords(
        _withoutPendingInstall(state),
        state.lastRejectedVersion,
      );
    }
    if (backup == null || _hasSelectionTarget(primary)) return primary;
    if (primary.activeIsBundled ||
        primary.pendingBundled ||
        primary.pendingBootInProgress) {
      return primary;
    }
    final rejected = primary.lastRejectedVersion ?? backup.lastRejectedVersion;
    final recovered = _withoutRejectedRecords(
      _withoutPendingInstall(
        EngineSelectionState(
          active: backup.active,
          previous: backup.previous,
          activeIsBundled: backup.activeIsBundled,
          lastRejectedVersion: rejected,
        ),
      ),
      rejected,
    );
    return _hasSelectionTarget(recovered) ? recovered : primary;
  }

  /// Drops an unconfirmed pending install recovered from a stale file.
  EngineSelectionState _withoutPendingInstall(EngineSelectionState state) {
    if (state.pending == null && !state.pendingBundled) return state;
    return EngineSelectionState(
      active: state.active,
      previous: state.previous,
      activeIsBundled: state.activeIsBundled,
      pendingRollback: false,
      lastRejectedVersion: state.lastRejectedVersion,
    );
  }

  EngineSelectionState _withoutRejectedRecords(
    EngineSelectionState state,
    String? rejected,
  ) {
    if (rejected == null) return state;
    final active = _withoutRejected(state.active, rejected);
    final previous = _withoutRejected(state.previous, rejected);
    final pending = _withoutRejected(state.pending, rejected);
    if (identical(active, state.active) &&
        identical(previous, state.previous) &&
        identical(pending, state.pending)) {
      return state;
    }
    return EngineSelectionState(
      active: active,
      previous: previous,
      pending: pending,
      pendingBootInProgress: state.pendingBootInProgress,
      activeIsBundled: state.activeIsBundled,
      pendingBundled: state.pendingBundled,
      pendingRollback: state.pendingRollback,
      lastRejectedVersion: rejected,
      bootAttemptToken: state.bootAttemptToken,
    );
  }

  EngineInstallRecord? _withoutRejected(
    EngineInstallRecord? record,
    String rejected,
  ) {
    if (record == null) return null;
    return record.version == rejected ? null : record;
  }

  /// Chooses the library for MediaKit before initialization.
  ///
  /// A pending package gets one boot attempt. If the previous launch left its
  /// attempt marker set, this call rolls it back and selects the prior active
  /// install or [bundledEnginePath].
  Future<EngineBootSelection> selectEngineForBoot({
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) => _withStoreLock(
    () => _selectEngineForBoot(
      bundledEnginePath: bundledEnginePath,
      bundledEngineVersion: bundledEngineVersion,
      isCompatible: isCompatible,
    ),
  );

  Future<EngineBootSelection> _selectEngineForBoot({
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) async {
    if (_currentBootLeaseHandle != null) {
      await _releaseBootLease();
    }

    var state = await loadSelection();

    if (state.pendingBootInProgress) {
      final isHeld = await _isBootLeaseHeldByAnotherProcess();
      if (isHeld) {
        final stopwatch = Stopwatch()..start();
        var stillHeld = true;
        while (stopwatch.elapsed < bootLeaseTimeout) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          stillHeld = await _isBootLeaseHeldByAnotherProcess();
          if (!stillHeld) break;
        }

        if (stillHeld) {
          return _bootSafeConfirmed(
            state,
            bundledEnginePath: bundledEnginePath,
            bundledEngineVersion: bundledEngineVersion,
            isCompatible: isCompatible,
          );
        }

        state = await loadSelection();
      }

      if (state.pendingBootInProgress) {
        state = EngineSelectionState(
          active: state.active,
          previous: state.previous,
          activeIsBundled: state.activeIsBundled,
          lastRejectedVersion:
              state.pending?.version ?? state.lastRejectedVersion,
        );
        await _writeState(state);
      }
    }

    if (state.pendingBundled) {
      final token = _generateAttemptToken();
      final leaseHandle = await _acquireBootLeaseHandle();
      _currentBootLeaseHandle = leaseHandle;
      _currentBootAttemptToken = token;

      await _writeState(
        EngineSelectionState(
          active: state.active,
          previous: state.previous,
          pendingBootInProgress: true,
          activeIsBundled: state.activeIsBundled,
          pendingBundled: true,
          pendingRollback: state.pendingRollback,
          bootAttemptToken: token,
        ),
      );
      return EngineBootSelection(
        libraryPath: bundledEnginePath,
        version: bundledEngineVersion,
        isBundled: bundledEnginePath != null,
        isPending: true,
      );
    }

    final pending = state.pending;
    if (pending != null) {
      final verified = await _usableRecord(
        pending,
        isCompatible,
        alreadyValidated: true,
      );
      if (verified != null) {
        final token = _generateAttemptToken();
        final leaseHandle = await _acquireBootLeaseHandle();
        _currentBootLeaseHandle = leaseHandle;
        _currentBootAttemptToken = token;

        await _writeState(
          EngineSelectionState(
            active: state.active,
            previous: state.previous,
            pending: verified,
            pendingBootInProgress: true,
            activeIsBundled: state.activeIsBundled,
            pendingRollback: state.pendingRollback,
            bootAttemptToken: token,
          ),
        );
        return EngineBootSelection(
          libraryPath: p.join(verified.path, engineLibraryFileName),
          version: verified.version,
          isBundled: false,
          isPending: true,
        );
      }
      state = EngineSelectionState(
        active: state.active,
        previous: state.previous,
        activeIsBundled: state.activeIsBundled,
      );
      await _writeState(state);
    }

    return _bootSafeConfirmed(
      state,
      bundledEnginePath: bundledEnginePath,
      bundledEngineVersion: bundledEngineVersion,
      isCompatible: isCompatible,
    );
  }

  Future<EngineBootSelection> _bootSafeConfirmed(
    EngineSelectionState state, {
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) async {
    if (state.activeIsBundled) {
      return EngineBootSelection(
        libraryPath: bundledEnginePath,
        version: bundledEngineVersion,
        isBundled: bundledEnginePath != null,
        isPending: false,
      );
    }

    var active = await _usableRecord(
      state.active,
      isCompatible,
      alreadyValidated: true,
    );
    if (active == null) {
      active = await _usableRecord(
        state.previous,
        isCompatible,
        alreadyValidated: true,
      );
      if (active != null) {
        state = EngineSelectionState(
          active: active,
          pending: state.pending,
          pendingBootInProgress: state.pendingBootInProgress,
          bootAttemptToken: state.bootAttemptToken,
        );
        await _writeState(state);
      } else if (state.active != null) {
        state = EngineSelectionState(
          activeIsBundled: true,
          pending: state.pending,
          pendingBootInProgress: state.pendingBootInProgress,
          bootAttemptToken: state.bootAttemptToken,
        );
        await _writeState(state);
      }
    }
    if (active != null) {
      return EngineBootSelection(
        libraryPath: p.join(active.path, engineLibraryFileName),
        version: active.version,
        isBundled: false,
        isPending: false,
      );
    }
    return EngineBootSelection(
      libraryPath: bundledEnginePath,
      version: bundledEngineVersion,
      isBundled: bundledEnginePath != null,
      isPending: false,
    );
  }

  /// Confirms a pending package after MediaKit initializes successfully.
  Future<void> confirmPendingBoot() => _withStoreLock(_confirmPendingBoot);

  Future<void> _confirmPendingBoot() async {
    final state = await loadSelection();
    if (!state.pendingBootInProgress) {
      throw StateError('There is no pending engine boot attempt to confirm.');
    }
    if (_currentBootAttemptToken == null ||
        state.bootAttemptToken != _currentBootAttemptToken) {
      throw StateError(
        'Boot attempt token does not match the active boot attempt.',
      );
    }
    try {
      if (state.pendingBundled) {
        await _writeState(
          EngineSelectionState(
            previous: state.activeIsBundled ? state.previous : state.active,
            activeIsBundled: true,
          ),
        );
        return;
      }
      final pending = await _validatedRecord(state.pending);
      if (pending == null) {
        throw StateError('There is no pending engine boot attempt to confirm.');
      }
      await _writeState(
        EngineSelectionState(
          active: pending,
          previous: state.activeIsBundled ? null : state.active,
        ),
      );
    } finally {
      await _releaseBootLease();
    }
  }

  /// Rejects a failed pending boot and returns the prior usable engine.
  Future<EngineBootSelection> rejectPendingBoot({
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) => _withStoreLock(
    () => _rejectPendingBoot(
      bundledEnginePath: bundledEnginePath,
      bundledEngineVersion: bundledEngineVersion,
      isCompatible: isCompatible,
    ),
  );

  Future<EngineBootSelection> _rejectPendingBoot({
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) async {
    final state = await loadSelection();
    if (state.pendingBootInProgress &&
        (_currentBootAttemptToken == null ||
            state.bootAttemptToken != _currentBootAttemptToken)) {
      throw StateError(
        'Boot attempt token does not match the active boot attempt.',
      );
    }
    try {
      final currentActive = await _usableRecord(state.active, isCompatible);
      final previous = await _usableRecord(state.previous, isCompatible);
      final active = state.activeIsBundled ? null : currentActive ?? previous;
      final useBundle = state.activeIsBundled || active == null;
      await _writeState(
        EngineSelectionState(
          active: active,
          // Keep the old previous candidate available if the current active
          // engine is selected. The caller may need to reject it later in this
          // same startup and try the previous version before the bundled DLL.
          previous: useBundle
              ? previous
              : (currentActive == null ? null : previous),
          activeIsBundled: useBundle,
          lastRejectedVersion:
              state.pending?.version ?? state.lastRejectedVersion,
        ),
      );
      if (!useBundle) {
        return EngineBootSelection(
          libraryPath: p.join(active.path, engineLibraryFileName),
          version: active.version,
          isBundled: false,
          isPending: false,
        );
      }
      return EngineBootSelection(
        libraryPath: bundledEnginePath,
        version: bundledEngineVersion,
        isBundled: bundledEnginePath != null,
        isPending: false,
      );
    } finally {
      await _releaseBootLease();
    }
  }

  /// Rejects the exact custom engine returned by [selectEngineForBoot].
  ///
  /// Pending engines are cleared. If a confirmed active engine fails to load,
  /// the previous install becomes active, or the bundled fallback is returned
  /// when no previous install remains.
  Future<EngineBootSelection> rejectBootSelection(
    EngineBootSelection failed, {
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) => _withStoreLock(
    () => _rejectBootSelection(
      failed,
      bundledEnginePath: bundledEnginePath,
      bundledEngineVersion: bundledEngineVersion,
      isCompatible: isCompatible,
    ),
  );

  Future<EngineBootSelection> _rejectBootSelection(
    EngineBootSelection failed, {
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) async {
    if (failed.isPending) {
      return _rejectPendingBoot(
        bundledEnginePath: bundledEnginePath,
        bundledEngineVersion: bundledEngineVersion,
        isCompatible: isCompatible,
      );
    }
    if (failed.isBundled || failed.version == null) {
      final state = await loadSelection();
      final previous = await _usableRecord(state.previous, isCompatible);
      if (state.activeIsBundled && previous != null) {
        await _writeState(
          EngineSelectionState(
            active: previous,
            pending: state.pending,
            pendingBootInProgress: state.pendingBootInProgress,
            pendingBundled: state.pendingBundled,
            pendingRollback: state.pendingRollback,
            bootAttemptToken: state.bootAttemptToken,
            lastRejectedVersion: state.lastRejectedVersion,
          ),
        );
        return EngineBootSelection(
          libraryPath: p.join(previous.path, engineLibraryFileName),
          version: previous.version,
          isBundled: false,
          isPending: false,
        );
      }
      return EngineBootSelection(
        libraryPath: bundledEnginePath,
        version: bundledEngineVersion,
        isBundled: bundledEnginePath != null,
        isPending: false,
      );
    }

    final state = await loadSelection();
    final active = await _usableRecord(state.active, isCompatible);
    final previous = await _usableRecord(state.previous, isCompatible);
    final failedPath = failed.libraryPath == null
        ? null
        : p.normalize(p.absolute(failed.libraryPath!));
    final expectedActivePath = active == null
        ? null
        : p.normalize(p.absolute(p.join(active.path, engineLibraryFileName)));
    final failedActiveMatches =
        active != null &&
        active.version == failed.version &&
        failedPath != null &&
        _pathsEqual(failedPath, expectedActivePath!);
    if (!failedActiveMatches && active != null) {
      return EngineBootSelection(
        libraryPath: p.join(active.path, engineLibraryFileName),
        version: active.version,
        isBundled: false,
        isPending: false,
      );
    }

    final fallback = state.activeIsBundled ? null : previous;
    await _writeState(
      EngineSelectionState(
        active: fallback,
        previous: null,
        pending: state.pending,
        pendingBootInProgress: state.pendingBootInProgress,
        pendingBundled: state.pendingBundled,
        pendingRollback: state.pendingRollback,
        bootAttemptToken: state.bootAttemptToken,
        activeIsBundled: fallback == null,
        // The recovery path must not select the engine this startup rejected.
        lastRejectedVersion: failed.version ?? state.lastRejectedVersion,
      ),
    );
    if (fallback != null) {
      return EngineBootSelection(
        libraryPath: p.join(fallback.path, engineLibraryFileName),
        version: fallback.version,
        isBundled: false,
        isPending: false,
      );
    }
    return EngineBootSelection(
      libraryPath: bundledEnginePath,
      version: bundledEngineVersion,
      isBundled: bundledEnginePath != null,
      isPending: false,
    );
  }

  /// Queues the last known-good custom install or the bundled engine for the
  /// next launch. It deliberately does not change the engine loaded now.
  Future<EngineBootSelection> scheduleRollback({
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) => _withStoreLock(
    () => _scheduleRollback(
      bundledEnginePath: bundledEnginePath,
      bundledEngineVersion: bundledEngineVersion,
      isCompatible: isCompatible,
    ),
  );

  Future<EngineBootSelection> _scheduleRollback({
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) async {
    final state = await loadSelection();
    if (state.pending != null ||
        state.pendingBundled ||
        state.pendingBootInProgress) {
      throw StateError('An engine selection is already pending.');
    }

    final previous = await _usableRecord(state.previous, isCompatible);
    final active = await _usableRecord(state.active, isCompatible);
    if (previous != null) {
      await _writeState(
        EngineSelectionState(
          active: state.active,
          previous: previous,
          pending: previous,
          activeIsBundled: state.activeIsBundled,
          pendingRollback: true,
        ),
      );
      return EngineBootSelection(
        libraryPath: p.join(previous.path, engineLibraryFileName),
        version: previous.version,
        isBundled: false,
        isPending: true,
      );
    }
    if (state.activeIsBundled || active == null) {
      throw StateError('There is no compatible engine rollback target.');
    }

    await _writeState(
      EngineSelectionState(
        active: active,
        pendingBootInProgress: false,
        activeIsBundled: false,
        pendingBundled: true,
        pendingRollback: true,
      ),
    );
    return EngineBootSelection(
      libraryPath: bundledEnginePath,
      version: bundledEngineVersion,
      isBundled: bundledEnginePath != null,
      isPending: true,
    );
  }

  Future<void> discardPending() => _withStoreLock(_discardPending);

  Future<void> _discardPending() async {
    final state = await loadSelection();
    if (state.pendingBootInProgress) {
      throw StateError('A pending engine boot attempt cannot be discarded.');
    }
    await _writeState(
      EngineSelectionState(
        active: state.active,
        previous: state.previous,
        activeIsBundled: state.activeIsBundled,
      ),
    );
    await _deleteUnreferencedInstall(
      state.pending,
      state.active,
      state.previous,
    );
  }

  /// Extracts a verified ZIP into a fresh version directory and marks it
  /// pending. It refuses to replace any directory, including an active one.
  Future<EngineInstallRecord> stagePackage({
    required String version,
    required File packageFile,
    String mediaKitVersion = '1.2.6',
    String minimumAppVersion = '0.0.0',
    String? maximumAppVersionExclusive,
    bool Function()? shouldCancel,
  }) async {
    SemanticVersion.parse(version);
    SemanticVersion.parse(mediaKitVersion);
    SemanticVersion.parse(minimumAppVersion);
    if (maximumAppVersionExclusive != null) {
      SemanticVersion.parse(maximumAppVersionExclusive);
    }
    if (shouldCancel?.call() == true) {
      throw const _EngineStageCancelled();
    }

    final attempt = await _createStageAttempt(version, shouldCancel);
    final finalDirectory = Directory(
      p.join(attempt.directory.parent.path, version),
    );
    final stagingDirectory = attempt.directory;
    var createdFinalDirectory = false;
    try {
      if (shouldCancel?.call() == true) {
        throw const _EngineStageCancelled();
      }
      await _beforeExtractionForTesting?.call();
      if (shouldCancel?.call() == true) {
        throw const _EngineStageCancelled();
      }

      final params = _ExtractionParams(
        packageFilePath: packageFile.path,
        stagingDirectoryPath: stagingDirectory.path,
        cancellationSignalPath: p.join(
          stagingDirectory.path,
          stageCancellationDirectoryName,
        ),
        maxArchiveEntries: maxArchiveEntries,
        maxUncompressedBytes: maxUncompressedBytes,
        engineLibraryFileName: engineLibraryFileName,
      );

      final extractionResult = await _runExtractionWorker(
        params,
        shouldCancel: shouldCancel,
      );

      if (shouldCancel?.call() == true) {
        throw const _EngineStageCancelled();
      }

      await _writeOwnershipMarker(
        stagingDirectory,
        version: version,
        attemptId: attempt.id,
        librarySha256: extractionResult.librarySha256,
        dependencies: extractionResult.dependencies,
      );
      if (shouldCancel?.call() == true) {
        throw const _EngineStageCancelled();
      }

      return await _withStoreLock(() async {
        final stateBeforeCommit = await loadSelection();
        if (stateBeforeCommit.pendingBootInProgress ||
            stateBeforeCommit.pending != null ||
            stateBeforeCommit.pendingBundled) {
          throw StateError('An engine selection is already pending.');
        }

        // The package is extracted and verified before anything touches an
        // existing directory, so a rejected archive never removes a directory it
        // cannot replace.
        await _prepareFinalDirectory(finalDirectory, version: version);
        if (shouldCancel?.call() == true) {
          throw const _EngineStageCancelled();
        }
        await _releaseStageLease(attempt);
        await _renameStagedDirectory(
          stagingDirectory,
          finalDirectory,
          shouldCancel: shouldCancel,
        );
        createdFinalDirectory = true;
        await _removeStageControlFiles(finalDirectory);
        final record = EngineInstallRecord(
          version: version,
          path: p.normalize(p.absolute(finalDirectory.path)),
          sha256: extractionResult.librarySha256,
          mediaKitVersion: mediaKitVersion,
          minimumAppVersion: minimumAppVersion,
          maximumAppVersionExclusive: maximumAppVersionExclusive,
        );
        final state = await loadSelection();
        if (shouldCancel?.call() == true) {
          throw const _EngineStageCancelled();
        }
        await _writeState(
          EngineSelectionState(
            active: state.active,
            previous: state.previous,
            pending: record,
            activeIsBundled: state.activeIsBundled,
            bootAttemptToken: state.bootAttemptToken,
            lastRejectedVersion: state.lastRejectedVersion,
          ),
          shouldCancel: shouldCancel,
        );
        return record;
      });
    } on Object {
      try {
        await _beforeStageFailureCleanupForTesting?.call();
      } on Object {
        // The failure hook is only for deterministic concurrency tests.
      }
      try {
        await _cleanupFailedStageAttempt(
          attempt,
          finalDirectory: finalDirectory,
          createdFinalDirectory: createdFinalDirectory,
        );
      } on Object {
        // Cleanup is best-effort; selection ownership checks make a later
        // stale-stage sweep safe if the process cannot remove this attempt.
      }
      rethrow;
    } finally {
      await _releaseStageLease(attempt);
      _forgetStageAttempt(attempt);
    }
  }

  Future<_StageAttempt> _createStageAttempt(
    String version,
    bool Function()? shouldCancel,
  ) => _withStoreLock(() async {
    await _sweepStaleStageAttempts();
    final state = await loadSelection();
    if (state.pendingBootInProgress ||
        state.pending != null ||
        state.pendingBundled) {
      throw StateError('An engine selection is already pending.');
    }
    if (shouldCancel?.call() == true) {
      throw const _EngineStageCancelled();
    }

    final rootPath = p.normalize(
      p.absolute((await _resolveEnginesDirectory()).path),
    );
    final storeKey = Platform.isWindows ? rootPath.toLowerCase() : rootPath;
    final id = _generateStageAttemptId();
    final directoryPath = p.normalize(p.join(rootPath, '.staging-$id'));
    if (p.dirname(directoryPath) != rootPath ||
        !p.isWithin(rootPath, directoryPath) ||
        await FileSystemEntity.type(directoryPath, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw FileSystemException(
        'A unique engine staging directory could not be created.',
        directoryPath,
      );
    }

    final directory = Directory(directoryPath);
    await directory.create();
    RandomAccessFile? leaseHandle;
    try {
      await File(
        p.join(directory.path, stageOwnershipMarkerFileName),
      ).writeAsString(
        jsonEncode({
          'owner': stageOwnershipMarkerOwner,
          'attemptId': id,
          'version': version,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      final leaseFile = File(p.join(directory.path, stageLeaseFileName));
      leaseHandle = await leaseFile.open(mode: FileMode.append);
      await leaseHandle.lock(FileLock.exclusive);
      if (shouldCancel?.call() == true) {
        throw const _EngineStageCancelled();
      }
      _activeStageAttempts.putIfAbsent(storeKey, () => <String>{}).add(id);
      return _StageAttempt(
        id: id,
        storeKey: storeKey,
        version: version,
        directory: directory,
        leaseHandle: leaseHandle,
      );
    } on Object {
      if (leaseHandle != null) {
        await _closeStageLease(leaseHandle);
      }
      if (!await _containsLink(directory)) {
        try {
          await directory.delete(recursive: true);
        } on Object {
          // An incomplete owned attempt is left for the next safe sweep.
        }
      }
      rethrow;
    }
  });

  String _generateStageAttemptId() {
    String part() => _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '${part()}${part()}${part()}${part()}';
  }

  Future<void> _sweepStaleStageAttempts() async {
    final rootPath = p.normalize(
      p.absolute((await _resolveEnginesDirectory()).path),
    );
    final root = Directory(rootPath);
    if (await FileSystemEntity.type(rootPath, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'The engine store must be a real directory, not a link.',
        rootPath,
      );
    }

    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final match = RegExp(r'^\.staging-([0-9a-f]{32})$').firstMatch(name);
      if (match == null) continue;
      final targetPath = p.normalize(p.absolute(entity.path));
      if (p.dirname(targetPath) != rootPath ||
          !p.isWithin(rootPath, targetPath) ||
          await FileSystemEntity.type(targetPath, followLinks: false) !=
              FileSystemEntityType.directory) {
        continue;
      }
      final directory = Directory(targetPath);
      final attemptId = match.group(1)!;
      final storeKey = Platform.isWindows ? rootPath.toLowerCase() : rootPath;
      if (_activeStageAttempts[storeKey]?.contains(attemptId) == true) {
        continue;
      }

      RandomAccessFile? leaseHandle;
      try {
        leaseHandle = await _tryLockStageLease(directory);
      } on Object {
        continue;
      }
      var safeToDelete = false;
      try {
        if (leaseHandle == null &&
            await FileSystemEntity.type(
                  p.join(directory.path, stageLeaseFileName),
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound) {
          // A live stage operation owns a lease this process cannot acquire.
          continue;
        }
        if (!await _containsLink(directory) &&
            await _readStageAttemptMarker(directory, attemptId) != null) {
          safeToDelete = true;
        }
      } finally {
        if (leaseHandle != null) await _closeStageLease(leaseHandle);
      }
      if (!safeToDelete) continue;

      // The store lock serializes attempt creation and sweeping. A live stage
      // operation either holds the OS lease or, while creating the attempt,
      // holds the store lock. An owned attempt without a lease is the residue
      // of a crash between marker creation and lease creation.
      try {
        await directory.delete(recursive: true);
      } on Object {
        // An inaccessible stale attempt is harmless and can be retried later.
      }
    }
  }

  Future<Map<String, Object?>?> _readStageAttemptMarker(
    Directory directory,
    String expectedId,
  ) async {
    final marker = File(p.join(directory.path, stageOwnershipMarkerFileName));
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map) return null;
      final value = decoded.cast<String, Object?>();
      if (value['owner'] != stageOwnershipMarkerOwner ||
          value['attemptId'] != expectedId ||
          value['version'] is! String ||
          value['createdAt'] is! String ||
          DateTime.tryParse(value['createdAt'] as String) == null) {
        return null;
      }
      SemanticVersion.parse(value['version'] as String);
      return value;
    } on Object {
      return null;
    }
  }

  Future<RandomAccessFile?> _tryLockStageLease(Directory directory) async {
    final leaseFile = File(p.join(directory.path, stageLeaseFileName));
    if (await FileSystemEntity.type(leaseFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final handle = await leaseFile.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return handle;
    } on Object {
      await _closeStageLease(handle);
      return null;
    }
  }

  Future<void> _closeStageLease(RandomAccessFile handle) async {
    try {
      await handle.unlock();
    } on Object {
      // Closing the handle also releases the OS lease.
    }
    try {
      await handle.close();
    } on Object {
      // The lease must not prevent cleanup or commit.
    }
  }

  Future<void> _releaseStageLease(_StageAttempt attempt) async {
    final handle = attempt.leaseHandle;
    attempt.leaseHandle = null;
    if (handle != null) await _closeStageLease(handle);
  }

  void _forgetStageAttempt(_StageAttempt attempt) {
    final active = _activeStageAttempts[attempt.storeKey];
    active?.remove(attempt.id);
    if (active != null && active.isEmpty) {
      _activeStageAttempts.remove(attempt.storeKey);
    }
  }

  Future<void> _removeStageControlFiles(Directory directory) async {
    for (final name in [stageOwnershipMarkerFileName, stageLeaseFileName]) {
      final file = File(p.join(directory.path, name));
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await file.delete();
      }
    }
    final cancellationDirectory = Directory(
      p.join(directory.path, stageCancellationDirectoryName),
    );
    if (await FileSystemEntity.type(
          cancellationDirectory.path,
          followLinks: false,
        ) ==
        FileSystemEntityType.directory) {
      await cancellationDirectory.delete();
    }
  }

  Future<void> _cleanupFailedStageAttempt(
    _StageAttempt attempt, {
    required Directory finalDirectory,
    required bool createdFinalDirectory,
  }) async {
    await _withStoreLock(() async {
      final rootPath = p.normalize(
        p.absolute((await _resolveEnginesDirectory()).path),
      );
      final stagingPath = p.normalize(p.absolute(attempt.directory.path));
      if (p.dirname(stagingPath) == rootPath &&
          p.isWithin(rootPath, stagingPath) &&
          await FileSystemEntity.type(stagingPath, followLinks: false) ==
              FileSystemEntityType.directory) {
        final staging = Directory(stagingPath);
        if (!await _containsLink(staging) &&
            await _readStageAttemptMarker(staging, attempt.id) != null) {
          var leaseHandle = attempt.leaseHandle;
          leaseHandle ??= await _tryLockStageLease(staging);
          if (leaseHandle != null) {
            if (identical(leaseHandle, attempt.leaseHandle)) {
              attempt.leaseHandle = null;
            }
            await _closeStageLease(leaseHandle);
            try {
              await staging.delete(recursive: true);
            } on Object {
              // A later sweep can retry this owned attempt.
            }
          }
        }
      }

      if (!createdFinalDirectory) return;
      final target = p.normalize(p.absolute(finalDirectory.path));
      if (p.dirname(target) != rootPath ||
          !p.isWithin(rootPath, target) ||
          await FileSystemEntity.type(target, followLinks: false) !=
              FileSystemEntityType.directory) {
        return;
      }
      final finalDir = Directory(target);
      if (await _containsLink(finalDir) ||
          !await _isOwnedInstall(
            finalDir,
            version: attempt.version,
            attemptId: attempt.id,
          ) ||
          await _isReferencedByAnySelectionFile(target)) {
        return;
      }
      try {
        await finalDir.delete(recursive: true);
      } on Object {
        // The unreferenced package remains updater-owned for a later install.
      }
    });
  }

  Future<bool> _isReferencedByAnySelectionFile(String target) async {
    final primary = await _selectionFile();
    for (final file in [primary, File('${primary.path}.bak')]) {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) return true;
      final state = await _readStateFile(file);
      if (state == null) return true;
      for (final record in [state.active, state.previous, state.pending]) {
        if (record != null &&
            _pathsEqual(target, p.normalize(p.absolute(record.path)))) {
          return true;
        }
      }
    }
    return false;
  }

  /// Makes the version directory available to the commit rename.
  ///
  /// A directory this updater installed carries [engineOwnershipMarkerFileName];
  /// only that durable ownership metadata authorizes cleanup. Anything else — a
  /// user-managed directory, files from another tool, or an install from an
  /// older release without a marker — is left untouched and staging fails
  /// instead of deleting it.
  Future<void> _prepareFinalDirectory(
    Directory finalDirectory, {
    required String version,
  }) async {
    if (await FileSystemEntity.type(finalDirectory.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final rawStateFile = await _selectionFile();
    final rawState = await _readStateFile(rawStateFile);
    final backupState = await _readStateFile(File('${rawStateFile.path}.bak'));
    final referencesVersion =
        <EngineInstallRecord?>[
          rawState?.active,
          rawState?.previous,
          rawState?.pending,
          backupState?.active,
          backupState?.previous,
          backupState?.pending,
        ].whereType<EngineInstallRecord>().any(
          (record) => _pathsEqual(
            p.normalize(p.absolute(record.path)),
            p.normalize(p.absolute(finalDirectory.path)),
          ),
        );
    if (referencesVersion ||
        await FileSystemEntity.type(finalDirectory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw FileSystemException(
        'Engine version directory already exists and will not be overwritten.',
        finalDirectory.path,
      );
    }
    if (await _containsLink(finalDirectory)) {
      throw FileSystemException(
        'An orphaned engine directory containing links will not be removed.',
        finalDirectory.path,
      );
    }
    if (!await _isOwnedInstall(finalDirectory, version: version)) {
      throw FileSystemException(
        'The existing engine directory is not owned by the Mpvson engine '
        'updater, so it was left untouched. Remove it manually to install this '
        'version.',
        finalDirectory.path,
      );
    }
    await finalDirectory.delete(recursive: true);
  }

  Future<void> _writeOwnershipMarker(
    Directory staging, {
    required String version,
    required String attemptId,
    required String librarySha256,
    required List<_ExtractionDependency> dependencies,
  }) async {
    final marker = File(p.join(staging.path, engineOwnershipMarkerFileName));
    final depList = dependencies.map((d) => d.toJson()).toList();
    await marker.writeAsString(
      jsonEncode({
        'owner': engineOwnershipMarkerOwner,
        'version': version,
        'attemptId': attemptId,
        'sha256': librarySha256,
        'installedAt': DateTime.now().toUtc().toIso8601String(),
        'inventory': depList,
        'dependencies': depList,
      }),
      flush: true,
    );
  }

  /// True when [directory] carries this updater's ownership marker for
  /// [version].
  Future<bool> _isOwnedInstall(
    Directory directory, {
    required String version,
    String? attemptId,
  }) async {
    final marker = File(p.join(directory.path, engineOwnershipMarkerFileName));
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    try {
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map) return false;
      if (decoded['owner'] != engineOwnershipMarkerOwner) return false;
      if (decoded['version'] != version) return false;
      final sha256 = decoded['sha256'];
      if (sha256 is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256) ||
          (attemptId != null && decoded['attemptId'] != attemptId)) {
        return false;
      }
      return _ownershipInventory(decoded, librarySha256: sha256) != null;
    } on Object {
      return false;
    }
  }

  Future<void> _renameStagedDirectory(
    Directory staging,
    Directory destination, {
    bool Function()? shouldCancel,
  }) async {
    // Windows scanners can briefly hold freshly extracted runtime DLLs open.
    // Retry only sharing/access failures and never replace an existing target.
    for (var attempt = 0; ; attempt++) {
      if (shouldCancel?.call() == true) {
        throw const _EngineStageCancelled();
      }
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'The engine destination already exists and cannot be replaced.',
          destination.path,
        );
      }
      try {
        await staging.rename(destination.path);
        return;
      } on FileSystemException catch (error) {
        if (!Platform.isWindows ||
            attempt >= 19 ||
            !const {5, 32, 33}.contains(error.osError?.errorCode)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<EngineSelectionState> _sanitizeState(
    EngineSelectionState state,
  ) async {
    final active = await _validatedRecord(state.active);
    final previous = await _validatedRecord(state.previous);
    final pending = await _validatedRecord(state.pending);
    final inProgress =
        state.pendingBootInProgress &&
        (pending != null || state.pendingBundled);
    return EngineSelectionState(
      active: active,
      previous: previous,
      pending: pending,
      pendingBootInProgress: inProgress,
      activeIsBundled: state.activeIsBundled,
      pendingBundled: state.pendingBundled && pending == null,
      pendingRollback:
          state.pendingRollback && (pending != null || state.pendingBundled),
      lastRejectedVersion: state.lastRejectedVersion,
      bootAttemptToken: inProgress ? state.bootAttemptToken : null,
    );
  }

  Future<EngineInstallRecord?> _usableRecord(
    EngineInstallRecord? record,
    bool Function(EngineInstallRecord)? isCompatible, {
    bool alreadyValidated = false,
  }) async {
    final validated = alreadyValidated
        ? record
        : await _validatedRecord(record);
    if (validated == null ||
        (isCompatible != null && !isCompatible(validated))) {
      return null;
    }
    return validated;
  }

  Future<EngineInstallRecord?> _validatedRecord(
    EngineInstallRecord? record,
  ) async {
    if (record == null) return null;
    final root = p.normalize(
      p.absolute((await _resolveEnginesDirectory()).path),
    );
    final candidate = p.normalize(p.absolute(record.path));
    if (!p.isWithin(root, candidate) || p.dirname(candidate) != root) {
      return null;
    }
    if (p.basename(candidate) != record.version) return null;
    if (await FileSystemEntity.type(candidate, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final candidateDir = Directory(candidate);
    if (await _containsLink(candidateDir)) {
      return null;
    }
    if (!await _isOwnedInstall(candidateDir, version: record.version)) {
      return null;
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(record.sha256)) {
      return null;
    }
    // The inventory includes the library. Anchor its digest to the selection
    // record and hash it once alongside its dependencies.
    if (!await _verifyStagedDependencies(
      candidateDir,
      librarySha256: record.sha256,
    )) {
      return null;
    }
    return EngineInstallRecord(
      version: record.version,
      path: candidate,
      sha256: record.sha256.toLowerCase(),
      mediaKitVersion: record.mediaKitVersion,
      minimumAppVersion: record.minimumAppVersion,
      maximumAppVersionExclusive: record.maximumAppVersionExclusive,
    );
  }

  Future<bool> _verifyStagedDependencies(
    Directory directory, {
    required String librarySha256,
  }) async {
    final markerFile = File(
      p.join(directory.path, engineOwnershipMarkerFileName),
    );
    if (await FileSystemEntity.type(markerFile.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    try {
      final decoded = jsonDecode(await markerFile.readAsString());
      if (decoded is! Map) return false;
      final sha256 = decoded['sha256'];
      if (sha256 is! String ||
          sha256.toLowerCase() != librarySha256.toLowerCase()) {
        return false;
      }
      final dependencies = _ownershipInventory(
        decoded,
        librarySha256: librarySha256,
      );
      if (dependencies == null) return false;
      for (final dependency in dependencies) {
        final targetPath = p.normalize(p.join(directory.path, dependency.path));
        if (!p.isWithin(directory.path, targetPath)) {
          return false;
        }
        if (await FileSystemEntity.type(targetPath, followLinks: false) !=
            FileSystemEntityType.file) {
          return false;
        }
        final stat = await FileStat.stat(targetPath);
        if (stat.size != dependency.size) {
          return false;
        }
        final actualSha256 = await crypto.sha256
            .bind(File(targetPath).openRead())
            .single;
        if (actualSha256.toString().toLowerCase() != dependency.sha256) {
          return false;
        }
      }
      return true;
    } on Object {
      return false;
    }
  }

  List<_ExtractionDependency>? _ownershipInventory(
    Map<dynamic, dynamic> marker, {
    required String librarySha256,
  }) {
    final inventory = marker['inventory'];
    final dependencies = marker['dependencies'];
    if (inventory is! List || dependencies is! List || inventory.isEmpty) {
      return null;
    }
    List<_ExtractionDependency>? parse(List<dynamic> values) {
      final parsed = <_ExtractionDependency>[];
      final paths = <String>{};
      for (final item in values) {
        if (item is! Map) return null;
        final rawPath = item['path'];
        final size = item['size'];
        final sha256 = item['sha256'];
        if (rawPath is! String ||
            size is! int ||
            size < 0 ||
            sha256 is! String ||
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
          return null;
        }
        // Older Windows installs persisted native separators in their marker.
        // Canonicalize those and current forward-slash paths before validation.
        final archiveStylePath = rawPath.replaceAll('\\', '/');
        final path = _validatedArchivePath(
          archiveStylePath,
        ).replaceAll(p.separator, '/');
        if (path != archiveStylePath ||
            !_isExecutableDependency(path) ||
            !paths.add(path.toLowerCase())) {
          return null;
        }
        parsed.add(
          _ExtractionDependency(
            path: path,
            size: size,
            sha256: sha256.toLowerCase(),
          ),
        );
      }
      return parsed;
    }

    try {
      final parsedInventory = parse(inventory);
      final parsedDependencies = parse(dependencies);
      if (parsedInventory == null ||
          parsedDependencies == null ||
          parsedInventory.length != parsedDependencies.length) {
        return null;
      }
      for (var index = 0; index < parsedInventory.length; index++) {
        final left = parsedInventory[index];
        final right = parsedDependencies[index];
        if (left.path != right.path ||
            left.size != right.size ||
            left.sha256 != right.sha256) {
          return null;
        }
      }
      final library = parsedInventory.where(
        (dependency) => dependency.path == engineLibraryFileName,
      );
      if (library.length != 1 ||
          library.single.sha256 != librarySha256.toLowerCase()) {
        return null;
      }
      return parsedInventory;
    } on Object {
      return null;
    }
  }

  Future<void> _deleteUnreferencedInstall(
    EngineInstallRecord? candidate,
    EngineInstallRecord? active,
    EngineInstallRecord? previous,
  ) async {
    if (candidate == null) return;
    final target = p.normalize(p.absolute(candidate.path));
    if (<EngineInstallRecord?>[
      active,
      previous,
    ].whereType<EngineInstallRecord>().any(
      (record) => _pathsEqual(target, p.normalize(p.absolute(record.path))),
    )) {
      return;
    }
    final root = p.normalize(
      p.absolute((await _resolveEnginesDirectory()).path),
    );
    if (!p.isWithin(root, target) || p.dirname(target) != root) return;
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final directory = Directory(target);
    if (await _containsLink(directory)) return;
    if (!await _isOwnedInstall(directory, version: candidate.version)) return;
    await directory.delete(recursive: true);
  }

  Future<bool> _containsLink(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) return true;
      if (type == FileSystemEntityType.directory &&
          await _containsLink(Directory(entity.path))) {
        return true;
      }
    }
    return false;
  }

  bool _pathsEqual(String left, String right) {
    if (Platform.isWindows) return left.toLowerCase() == right.toLowerCase();
    return left == right;
  }

  Future<EngineSelectionState?> _readStateFile(File file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return EngineSelectionState.fromJson(decoded);
    } on Object {
      return null;
    }
  }

  Future<void> _writeState(
    EngineSelectionState state, {
    bool Function()? shouldCancel,
  }) async {
    final file = await _selectionFile();
    final root = await _resolveEnginesDirectory();
    await root.create(recursive: true);
    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final temporary = File('${file.path}.$pid-$suffix.tmp');
    final backup = File('${file.path}.bak');
    var movedOld = false;
    try {
      await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
      await _beforeSelectionWriteForTesting?.call();
      if (shouldCancel?.call() == true) {
        throw const _EngineStageCancelled();
      }
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
        movedOld = true;
      }
      if (shouldCancel?.call() == true) {
        throw const _EngineStageCancelled();
      }
      await temporary.rename(file.path);
      if (movedOld) {
        try {
          await backup.delete();
        } on Object {
          // The committed selection is valid; a stale backup is harmless.
        }
      }
    } on Object {
      if (movedOld && !await file.exists() && await backup.exists()) {
        try {
          await backup.rename(file.path);
        } on Object {
          // The backup remains available for recovery on the next launch.
        }
      }
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on Object {
          // A stale temporary selection file is ignored on load.
        }
      }
      rethrow;
    }
  }

  Future<File> _selectionFile() async {
    final root = await _resolveEnginesDirectory();
    return File(p.join(root.path, selectionFileName));
  }

  Future<Directory> _resolveEnginesDirectory() {
    return _enginesDirectoryFuture ??= _providedEnginesDirectory != null
        ? Future<Directory>.value(_providedEnginesDirectory)
        : _supportDirectoryProvider().then(
            (directory) =>
                Directory(p.join(directory.path, 'mpvson', 'engines')),
          );
  }
}

final class _EngineStageCancelled implements Exception {
  const _EngineStageCancelled();
}

final class _StageAttempt {
  _StageAttempt({
    required this.id,
    required this.storeKey,
    required this.version,
    required this.directory,
    required this.leaseHandle,
  });

  final String id;
  final String storeKey;
  final String version;
  final Directory directory;
  RandomAccessFile? leaseHandle;
}

final class _ExtractionParams {
  final String packageFilePath;
  final String stagingDirectoryPath;
  final String cancellationSignalPath;
  final int maxArchiveEntries;
  final int maxUncompressedBytes;
  final String engineLibraryFileName;

  const _ExtractionParams({
    required this.packageFilePath,
    required this.stagingDirectoryPath,
    required this.cancellationSignalPath,
    required this.maxArchiveEntries,
    required this.maxUncompressedBytes,
    required this.engineLibraryFileName,
  });
}

final class _ExtractionDependency {
  final String path;
  final int size;
  final String sha256;

  const _ExtractionDependency({
    required this.path,
    required this.size,
    required this.sha256,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'size': size,
    'sha256': sha256,
  };
}

final class _ExtractionWorkerResult {
  final String librarySha256;
  final List<_ExtractionDependency> dependencies;

  const _ExtractionWorkerResult({
    required this.librarySha256,
    required this.dependencies,
  });
}

bool _isExecutableDependency(String relativePath) {
  final lower = relativePath.toLowerCase();
  return lower.endsWith('.dll') || lower.endsWith('.exe');
}

Future<_ExtractionWorkerResult> _runExtractionWorker(
  _ExtractionParams params, {
  bool Function()? shouldCancel,
}) async {
  final messages = ReceivePort();
  final errors = ReceivePort();
  final started = Completer<void>();
  final response = Completer<Object?>();
  final failure = Completer<Object?>();
  final exited = Completer<void>();
  SendPort? workerCancellationPort;
  try {
    await Isolate.spawn<List<Object?>>(
      _extractionWorkerEntryPoint,
      <Object?>[messages.sendPort, params],
      onError: errors.sendPort,
      onExit: messages.sendPort,
      errorsAreFatal: true,
    );
  } on Object {
    messages.close();
    errors.close();
    rethrow;
  }

  final messageSubscription = messages.listen((message) {
    if (message is List &&
        message.length == 2 &&
        message[0] == 'started' &&
        message[1] is SendPort) {
      workerCancellationPort = message[1] as SendPort;
      if (!started.isCompleted) started.complete();
    } else if (message == null) {
      if (!exited.isCompleted) exited.complete();
    } else if (!response.isCompleted) {
      response.complete(message);
    }
  });
  final errorSubscription = errors.listen((message) {
    if (!failure.isCompleted) failure.complete(message);
  });

  Future<void> signalCancellationAndWait() async {
    workerCancellationPort?.send(null);
    final cancellationDirectory = Directory(params.cancellationSignalPath);
    try {
      final type = await FileSystemEntity.type(
        cancellationDirectory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        await cancellationDirectory.create();
      } else if (type != FileSystemEntityType.directory) {
        throw StateError('The engine cancellation signal path is not safe.');
      }
    } on Object {
      // The SendPort still cancels the worker when its event loop is available.
    }
    workerCancellationPort?.send(null);
    await exited.future;
  }

  try {
    while (!started.isCompleted &&
        !response.isCompleted &&
        !failure.isCompleted &&
        !exited.isCompleted) {
      if (shouldCancel?.call() == true) {
        await signalCancellationAndWait();
        throw const _EngineStageCancelled();
      }
      await Future.any<void>([
        started.future,
        response.future.then<void>((_) {}),
        failure.future.then<void>((_) {}),
        exited.future,
        Future<void>.delayed(const Duration(milliseconds: 20)),
      ]);
    }

    while (!response.isCompleted &&
        !failure.isCompleted &&
        !exited.isCompleted) {
      if (shouldCancel?.call() == true) {
        await signalCancellationAndWait();
        throw const _EngineStageCancelled();
      }
      await Future.any<void>([
        response.future.then<void>((_) {}),
        failure.future.then<void>((_) {}),
        exited.future,
        Future<void>.delayed(const Duration(milliseconds: 20)),
      ]);
    }

    if (shouldCancel?.call() == true) {
      await signalCancellationAndWait();
      throw const _EngineStageCancelled();
    }
    if (failure.isCompleted) {
      await exited.future;
      throw StateError('Engine package extraction worker failed.');
    }
    if (!response.isCompleted) {
      throw StateError('Engine package extraction worker exited unexpectedly.');
    }
    await exited.future;
    final message = await response.future;
    if (message is! List || message.isEmpty) {
      throw StateError(
        'Engine package extraction worker returned invalid data.',
      );
    }
    if (message[0] == 'cancelled') {
      if (message.length != 1) {
        throw StateError(
          'Engine package extraction worker returned invalid cancellation data.',
        );
      }
      throw const _EngineStageCancelled();
    }
    if (message.length != 3) {
      throw StateError(
        'Engine package extraction worker returned invalid data.',
      );
    }
    if (message[0] == 'error') {
      final kind = message[1];
      final description = message[2];
      if (kind == 'FormatException' && description is String) {
        throw FormatException(description);
      }
      throw StateError('Engine package extraction failed: $description');
    }
    if (message[0] != 'ok' || message[1] is! String || message[2] is! List) {
      throw StateError(
        'Engine package extraction worker returned invalid data.',
      );
    }
    final dependencies = <_ExtractionDependency>[];
    for (final item in message[2] as List) {
      if (item is! List ||
          item.length != 3 ||
          item[0] is! String ||
          item[1] is! int ||
          item[2] is! String) {
        throw StateError(
          'Engine package extraction worker returned an invalid inventory.',
        );
      }
      dependencies.add(
        _ExtractionDependency(
          path: item[0] as String,
          size: item[1] as int,
          sha256: item[2] as String,
        ),
      );
    }
    return _ExtractionWorkerResult(
      librarySha256: message[1] as String,
      dependencies: dependencies,
    );
  } finally {
    if (!exited.isCompleted) {
      await signalCancellationAndWait();
    }
    await messageSubscription.cancel();
    await errorSubscription.cancel();
    messages.close();
    errors.close();
  }
}

void _extractionWorkerEntryPoint(List<Object?> request) async {
  final sendPort = request[0] as SendPort;
  final params = request[1] as _ExtractionParams;
  final cancellationMessages = ReceivePort();
  var cancellationReceived = false;
  cancellationMessages.listen((_) => cancellationReceived = true);
  bool shouldCancel() =>
      cancellationReceived ||
      FileSystemEntity.typeSync(
            params.cancellationSignalPath,
            followLinks: false,
          ) ==
          FileSystemEntityType.directory;
  sendPort.send(<Object?>['started', cancellationMessages.sendPort]);
  try {
    final result = await _extractStagedPackageWorker(
      params,
      shouldCancel: shouldCancel,
    );
    sendPort.send(<Object?>[
      'ok',
      result.librarySha256,
      result.dependencies
          .map(
            (dependency) => <Object?>[
              dependency.path,
              dependency.size,
              dependency.sha256,
            ],
          )
          .toList(),
    ]);
  } on Object catch (error) {
    if (error is _EngineStageCancelled) {
      sendPort.send(<Object?>['cancelled']);
    } else {
      sendPort.send(<Object?>[
        'error',
        error is FormatException
            ? 'FormatException'
            : error.runtimeType.toString(),
        error is FormatException ? error.message.toString() : error.toString(),
      ]);
    }
  } finally {
    cancellationMessages.close();
  }
}

Future<_ExtractionWorkerResult> _extractStagedPackageWorker(
  _ExtractionParams params, {
  bool Function()? shouldCancel,
}) async {
  final fileStream = InputFileStream(params.packageFilePath);
  try {
    _throwIfExtractionCancelled(shouldCancel);
    _preflightZipStream(
      fileStream,
      maxArchiveEntries: params.maxArchiveEntries,
      maxUncompressedBytes: params.maxUncompressedBytes,
      engineLibraryFileName: params.engineLibraryFileName,
      shouldCancel: shouldCancel,
    );

    fileStream.position = 0;
    final archive = ZipDecoder().decodeStream(fileStream);
    _throwIfExtractionCancelled(shouldCancel);

    String? librarySha256;
    final dependencies = <_ExtractionDependency>[];

    for (final file in archive.files) {
      _throwIfExtractionCancelled(shouldCancel);
      final relativePath = _validatedArchivePath(file.name);
      final destinationPath = p.normalize(
        p.join(params.stagingDirectoryPath, relativePath),
      );

      if (!p.isWithin(params.stagingDirectoryPath, destinationPath) &&
          destinationPath != p.normalize(params.stagingDirectoryPath)) {
        throw const FormatException('Engine ZIP contains an unsafe path.');
      }

      if (file.isSymbolicLink || file.symbolicLink != null) {
        throw const FormatException('Engine ZIP contains a link entry.');
      }

      if (file.isDirectory) {
        await Directory(destinationPath).create(recursive: true);
        continue;
      }

      final parentDir = Directory(p.dirname(destinationPath));
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      final outFileStream = OutputFileStream(destinationPath);
      try {
        file.writeContent(
          _CancellationAwareOutputStream(
            outFileStream,
            shouldCancel: shouldCancel,
          ),
          freeMemory: true,
        );
      } finally {
        // Close both native handles before the caller can remove staging.
        try {
          outFileStream.closeSync();
        } finally {
          file.closeSync();
        }
      }

      _throwIfExtractionCancelled(shouldCancel);
      final stat = await FileStat.stat(destinationPath);
      final actualFile = File(destinationPath);
      final hash = await crypto.sha256
          .bind(
            actualFile.openRead().map((chunk) {
              _throwIfExtractionCancelled(shouldCancel);
              return chunk;
            }),
          )
          .single;
      final shaString = hash.toString().toLowerCase();

      if (_isExecutableDependency(relativePath)) {
        dependencies.add(
          _ExtractionDependency(
            path: relativePath.replaceAll(p.separator, '/'),
            size: stat.size,
            sha256: shaString,
          ),
        );
      }

      if (relativePath == params.engineLibraryFileName) {
        librarySha256 = shaString;
      }
    }

    _throwIfExtractionCancelled(shouldCancel);
    if (librarySha256 == null) {
      throw const FormatException(
        'Engine ZIP must contain a non-empty root libmpv-2.dll.',
      );
    }

    return _ExtractionWorkerResult(
      librarySha256: librarySha256,
      dependencies: dependencies,
    );
  } finally {
    fileStream.closeSync();
  }
}

void _throwIfExtractionCancelled(bool Function()? shouldCancel) {
  if (shouldCancel?.call() == true) {
    throw const _EngineStageCancelled();
  }
}

final class _CancellationAwareOutputStream extends OutputStream {
  _CancellationAwareOutputStream(this._delegate, {required this.shouldCancel})
    : super(byteOrder: _delegate.byteOrder);

  static const int _checkInterval = 128 * 1024;

  final OutputFileStream _delegate;
  final bool Function()? shouldCancel;
  int _nextCheckAt = 0;

  @override
  int get length => _delegate.length;

  @override
  bool get isOpen => _delegate.isOpen;

  void _checkCancellation() {
    if (_delegate.length < _nextCheckAt) return;
    _nextCheckAt = _delegate.length + _checkInterval;
    _throwIfExtractionCancelled(shouldCancel);
  }

  @override
  void clear() => _delegate.closeSync();

  @override
  Future<void> close() => _delegate.close();

  @override
  void closeSync() => _delegate.closeSync();

  @override
  void flush() {
    _checkCancellation();
    _delegate.flush();
  }

  @override
  void writeByte(int value) {
    _checkCancellation();
    _delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _checkCancellation();
    _delegate.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      _checkCancellation();
      final bytes = stream.readBytes(_checkInterval).toUint8List();
      if (bytes.isEmpty) break;
      _delegate.writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _delegate.subset(start, end);
}

void _preflightZipStream(
  InputStream stream, {
  required int maxArchiveEntries,
  required int maxUncompressedBytes,
  required String engineLibraryFileName,
  bool Function()? shouldCancel,
}) {
  final directory = ZipDirectory()..read(stream);
  final headers = directory.fileHeaders;
  final declaredCount = directory.totalCentralDirectoryEntries;
  if (headers.isEmpty ||
      declaredCount <= 0 ||
      declaredCount > maxArchiveEntries ||
      headers.length != declaredCount ||
      directory.totalCentralDirectoryEntriesOnThisDisk != declaredCount) {
    throw const FormatException('Engine ZIP has an invalid number of entries.');
  }

  final normalizedPaths = <String>{};
  final files = <String>{};
  final directories = <String>{};
  var totalUncompressed = 0;
  var hasRootLibrary = false;
  final reservedControlPaths = {
    EngineInstallationRepository.stageOwnershipMarkerFileName.toLowerCase(),
    EngineInstallationRepository.stageLeaseFileName.toLowerCase(),
    EngineInstallationRepository.stageCancellationDirectoryName.toLowerCase(),
    EngineInstallationRepository.engineOwnershipMarkerFileName.toLowerCase(),
  };
  for (final header in headers) {
    _throwIfExtractionCancelled(shouldCancel);
    final entry = header.file;
    if (entry == null || entry.filename != header.filename) {
      throw const FormatException('Engine ZIP has a malformed entry.');
    }
    final mode = (header.externalFileAttributes >> 16) & 0xffff;
    final type = mode & 0xf000;
    final unixMade = (header.versionMadeBy >> 8) == 3;
    if ((unixMade && type == 0xa000) ||
        (header.externalFileAttributes & 0x400) != 0) {
      throw const FormatException('Engine ZIP contains a link entry.');
    }

    final source = header.filename;
    final relativePath = _validatedArchivePath(source);
    final foldedPath = relativePath.toLowerCase();
    final archiveStylePath = relativePath
        .replaceAll(p.separator, '/')
        .toLowerCase();
    if (reservedControlPaths.any(
      (reservedPath) =>
          archiveStylePath == reservedPath ||
          archiveStylePath.startsWith('$reservedPath/'),
    )) {
      throw const FormatException(
        'Engine ZIP contains a reserved updater control path.',
      );
    }
    if (!normalizedPaths.add(foldedPath)) {
      throw const FormatException('Engine ZIP contains duplicate paths.');
    }
    final isDirectory = source.endsWith('/') || source.endsWith('\\');
    if (unixMade && type != 0 && type != 0x8000 && type != 0x4000) {
      throw const FormatException('Engine ZIP contains an unsupported entry.');
    }
    if ((type == 0x4000) != isDirectory && unixMade && type != 0) {
      throw const FormatException('Engine ZIP has inconsistent entry type.');
    }

    final size = entry.uncompressedSize;
    final compressedSize = entry.compressedSize;
    if (size < 0 || compressedSize < 0 || compressedSize > stream.length) {
      throw const FormatException('Engine ZIP contains an invalid file size.');
    }
    if (size > maxUncompressedBytes - totalUncompressed) {
      throw const FormatException(
        'Engine ZIP exceeds the extraction size limit.',
      );
    }
    totalUncompressed += size;

    if (isDirectory) {
      directories.add(foldedPath);
    } else {
      files.add(foldedPath);
      if (relativePath == engineLibraryFileName) {
        hasRootLibrary = size > 0;
      }
    }
  }
  if (!hasRootLibrary) {
    throw const FormatException(
      'Engine ZIP must contain a non-empty root libmpv-2.dll.',
    );
  }
  for (final filePath in files) {
    if (directories.contains(filePath)) {
      throw const FormatException(
        'Engine ZIP has a file and directory path collision.',
      );
    }
    var parent = p.dirname(filePath);
    while (parent != '.' && parent.isNotEmpty) {
      if (files.contains(parent)) {
        throw const FormatException('Engine ZIP has a file path collision.');
      }
      parent = p.dirname(parent);
    }
  }
}

String _validatedArchivePath(String source) {
  if (source.isEmpty || source.contains('\u0000') || source.contains('\\')) {
    throw const FormatException('Engine ZIP contains an unsafe path.');
  }
  final normalized = source.replaceAll('/', p.separator);
  if (p.isAbsolute(normalized) ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
      normalized.startsWith('\\')) {
    throw const FormatException('Engine ZIP contains an absolute path.');
  }
  final hasTrailingSlash = source.endsWith('/');
  final components = source.split('/');
  if (hasTrailingSlash) components.removeLast();
  if (components.isEmpty ||
      components.any(
        (component) =>
            component.isEmpty ||
            component == '.' ||
            component == '..' ||
            component.contains(':') ||
            component.endsWith('.') ||
            component.endsWith(' ') ||
            RegExp(r'[<>"|?*\x00-\x1f]').hasMatch(component) ||
            _isReservedWindowsName(component),
      )) {
    throw const FormatException('Engine ZIP contains an unsafe path.');
  }
  final result = components.join(p.separator);
  final normalizedResult = p.normalize(result);
  if (normalizedResult == '.' || p.isAbsolute(normalizedResult)) {
    throw const FormatException('Engine ZIP contains an unsafe path.');
  }
  return normalizedResult;
}

bool _isReservedWindowsName(String component) {
  final baseName = component.split('.').first.toUpperCase();
  return const {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  }.contains(baseName);
}
