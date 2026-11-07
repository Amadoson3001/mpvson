import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/engine_installation_repository.dart';
import 'package:mpvson/domain/updates/engine_selection.dart';
import 'package:path/path.dart' as p;

const String _version = '0.42.0';
const String _bundledVersion = '0.41.0';

Future<Directory> _createStore() async {
  final root = await Directory.systemTemp.createTemp('mpvson-engine-test-');
  addTearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on Object {
      // A still-open lease handle may keep the directory alive on Windows.
    }
  });
  final engineDir = Directory(p.join(root.path, _version));
  await engineDir.create(recursive: true);
  final bytes = List<int>.generate(8192, (index) => (index * 31) % 251);
  final library = File(p.join(engineDir.path, 'libmpv-2.dll'));
  await library.writeAsBytes(bytes);
  final digest = sha256.convert(bytes).toString();
  final inventory = [
    {'path': 'libmpv-2.dll', 'size': bytes.length, 'sha256': digest},
  ];
  await File(p.join(engineDir.path, '.mpvson-engine.json')).writeAsString(
    jsonEncode({
      'owner': 'mpvson-engine-updater',
      'version': _version,
      'attemptId': 'test-attempt',
      'sha256': digest,
      'installedAt': DateTime.now().toUtc().toIso8601String(),
      'inventory': inventory,
      'dependencies': inventory,
    }),
    flush: true,
  );
  await File(p.join(root.path, 'engine-selection.json')).writeAsString(
    jsonEncode(
      EngineSelectionState(
        pending: EngineInstallRecord(
          version: _version,
          path: engineDir.path,
          sha256: digest,
          mediaKitVersion: '1.2.6',
          minimumAppVersion: '0.0.0',
        ),
      ).toJson(),
    ),
    flush: true,
  );
  return root;
}

Future<EngineBootSelection> _select(EngineInstallationRepository repository) {
  return repository.selectEngineForBoot(
    bundledEnginePath: null,
    bundledEngineVersion: _bundledVersion,
    isCompatible: (_) => true,
  );
}

void main() {
  test('an interrupted boot is retried once, then rolled back', () async {
    final root = await _createStore();

    final first = EngineInstallationRepository(enginesDirectory: root);
    final firstBoot = await _select(first);
    expect(firstBoot.isPending, isTrue);
    expect(firstBoot.version, _version);
    await first.simulateCrashForTesting();

    final second = EngineInstallationRepository(enginesDirectory: root);
    final secondBoot = await _select(second);
    expect(secondBoot.isPending, isTrue);
    expect(secondBoot.version, _version);
    final retried = await second.loadSelection();
    expect(retried.interruptedBootAttempts, 1);
    expect(retried.pendingBootInProgress, isTrue);
    await second.simulateCrashForTesting();

    final third = EngineInstallationRepository(enginesDirectory: root);
    final thirdBoot = await _select(third);
    expect(thirdBoot.isPending, isFalse);
    expect(thirdBoot.isBundled, isFalse);
    final rejected = await third.loadSelection();
    expect(rejected.pending, isNull);
    expect(rejected.lastRejectedVersion, _version);
  });

  test('a hot restart adopts its own in-process boot attempt', () async {
    final root = await _createStore();

    final firstIsolate = EngineInstallationRepository(enginesDirectory: root);
    await _select(firstIsolate);

    final secondIsolate = EngineInstallationRepository(enginesDirectory: root);
    final watch = Stopwatch()..start();
    final adopted = await _select(secondIsolate);
    expect(adopted.isPending, isTrue);
    expect(adopted.version, _version);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

    await secondIsolate.confirmPendingBoot();
    final state = await secondIsolate.loadSelection();
    expect(state.active?.version, _version);
    expect(state.pending, isNull);
    expect(state.pendingBootInProgress, isFalse);
    expect(state.lastRejectedVersion, isNull);

    await firstIsolate.simulateCrashForTesting();
  });

  test('abandoning the boot attempt keeps the package staged', () async {
    final root = await _createStore();

    final repository = EngineInstallationRepository(enginesDirectory: root);
    await _select(repository);
    await repository.abandonPendingBootAttempt();

    final abandoned = await repository.loadSelection();
    expect(abandoned.pending?.version, _version);
    expect(abandoned.pendingBootInProgress, isFalse);
    expect(abandoned.lastRejectedVersion, isNull);

    final next = EngineInstallationRepository(enginesDirectory: root);
    final boot = await _select(next);
    expect(boot.isPending, isTrue);
    expect(boot.version, _version);
  });

  group('store lock contention', () {
    /// True when two handles inside this process can contend for the same
    /// lock file.
    ///
    /// On Windows the OS lock (LockFileEx) belongs to the handle, so a second
    /// open in this test process contends exactly like a second process. POSIX
    /// record locks (fcntl) belong to the process, so in-process simulation is
    /// impossible there and the tests below are Windows-only.
    final bool canSimulateForeignHolder = Platform.isWindows;

    Future<Directory> createEmptyStore() async {
      final root = await Directory.systemTemp.createTemp('mpvson-engine-lock-');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } on Object {
          // A still-open handle may keep the directory alive on Windows.
        }
      });
      return root;
    }

    File lockMarkerFor(Directory root) =>
        File(p.join(root.path, EngineInstallationRepository.storeLockFileName));

    test(
      'a foreign holder keeps the store busy instead of sharing the lock',
      () async {
        if (!canSimulateForeignHolder) return;
        final root = await createEmptyStore();
        final lockMarker = lockMarkerFor(root);
        final foreign = await lockMarker.open(mode: FileMode.write);
        await foreign.lock(FileLock.exclusive);

        final repository = EngineInstallationRepository(
          enginesDirectory: root,
          storeLockTimeout: const Duration(milliseconds: 200),
        );
        await expectLater(
          repository.discardPending(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Engine store is busy'),
            ),
          ),
        );

        expect(
          lockMarker.existsSync(),
          isTrue,
          reason:
              'the failed acquisition must not remove the shared lock marker',
        );
        await foreign.unlock();
        await foreign.close();
      },
    );

    test('the operation proceeds once the foreign holder releases', () async {
      if (!canSimulateForeignHolder) return;
      final root = await createEmptyStore();
      final lockMarker = lockMarkerFor(root);
      final foreign = await lockMarker.open(mode: FileMode.write);
      await foreign.lock(FileLock.exclusive);

      final repository = EngineInstallationRepository(enginesDirectory: root);
      final operation = repository.discardPending();
      // Give the repository time to reach the contended acquisition before the
      // foreign holder lets go.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await foreign.unlock();
      await foreign.close();

      await operation.timeout(const Duration(seconds: 5));

      expect(
        lockMarker.existsSync(),
        isTrue,
        reason: 'the release flow must never delete the lock marker',
      );
    });

    test('completed operations leave the lock marker in place', () async {
      final root = await createEmptyStore();
      final repository = EngineInstallationRepository(enginesDirectory: root);
      await repository.discardPending();

      expect(
        lockMarkerFor(root).existsSync(),
        isTrue,
        reason:
            'the lock marker is long-lived; deleting it on release would '
            'break mutual exclusion with waiters on the old inode',
      );
    });
  });
}
