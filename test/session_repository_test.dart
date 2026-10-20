import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/control_density.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/domain/models/session_progress.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mpvson-session-test-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('serializes queue identity, history and stopped resume state', () async {
    final repository = SessionRepository(directory: directory);
    final source = '${directory.path}/movie.mkv';
    final session = PlaybackSession(
      queue: <MediaEntry>[
        MediaEntry(
          id: 'queue-a',
          path: source,
          title: 'movie.mkv',
          position: const Duration(seconds: 12),
          duration: const Duration(minutes: 4),
          lastPlayed: DateTime.utc(2026, 10, 15),
        ),
        MediaEntry(
          id: 'queue-b',
          path: source,
          title: 'movie.mkv',
          lastPlayed: DateTime.utc(2026, 10, 15),
        ),
      ],
      recent: <MediaEntry>[
        MediaEntry(
          id: MediaEntry.canonicalSource(source),
          path: source,
          title: 'movie.mkv',
          position: const Duration(seconds: 12),
          duration: const Duration(minutes: 4),
          lastPlayed: DateTime.utc(2026, 10, 15),
        ),
      ],
      currentId: 'queue-b',
      volume: 42,
      rate: 1.25,
      shuffle: true,
      repeatMode: 'all',
      controlDensity: ControlDensity.normal,
    );

    await repository.save(session);
    final loaded = await repository.load();

    expect(loaded, isNotNull);
    expect(loaded!.queue.map((entry) => entry.id), <String>[
      'queue-a',
      'queue-b',
    ]);
    expect(loaded.currentIndex, 1);
    expect(loaded.queue.first.position, const Duration(seconds: 12));
    expect(loaded.recent.single.id, MediaEntry.canonicalSource(source));
    expect(loaded.volume, 42);
    expect(loaded.rate, 1.25);
    expect(loaded.shuffle, isTrue);
    expect(loaded.repeatMode, 'all');
    expect(loaded.controlDensity, ControlDensity.normal);
    expect(loaded.toJson()['controlDensity'], 'normal');
  });

  test(
    'scrubbing stream URLs cleans the primary, the recovery copy and the checkpoint',
    () async {
      final repository = SessionRepository(directory: directory);
      final localPath = MediaEntry.normalizeSourcePath(
        '${directory.path}/movie.mkv',
      );
      final streamPath = 'https://media.example/live.m3u8?token=abc';
      final session = PlaybackSession(
        queue: <MediaEntry>[
          MediaEntry.fromPath('${directory.path}/movie.mkv', id: 'queue-local'),
          MediaEntry.fromPath(streamPath, id: 'queue-stream'),
        ],
        recent: <MediaEntry>[
          MediaEntry.fromPath(
            streamPath,
            id: 'queue-stream',
          ).copyWith(id: MediaEntry.canonicalSource(streamPath)),
        ],
        currentId: 'queue-stream',
        saveNetworkUrls: true,
      );

      // Two saves leave the stream URLs in both the primary and the recovery
      // copy, which is what makes them recoverable in the first place.
      await repository.save(session);
      await repository.save(session);
      await repository.saveProgress(
        const SessionProgress(
          revision: 4,
          entryId: 'queue-stream',
          position: Duration(seconds: 30),
        ),
      );

      final primary = File(p.join(directory.path, 'session.json'));
      final backup = File(p.join(directory.path, 'session.json.bak'));
      final checkpoint = File(p.join(directory.path, 'progress.json'));
      expect(await primary.readAsString(), contains('media.example'));
      expect(await backup.readAsString(), contains('media.example'));

      await repository.scrubNetworkUrls();

      for (final file in <File>[primary, backup, checkpoint]) {
        expect(
          await file.readAsString(),
          isNot(contains('media.example')),
          reason: '${p.basename(file.path)} must not keep a stored stream URL',
        );
      }
      final scrubbed = await repository.load();
      expect(scrubbed!.queue.map((entry) => entry.id), <String>['queue-local']);
      expect(scrubbed.queue.single.path, localPath);
      expect(scrubbed.recent, isEmpty);
      expect(
        await repository.loadProgress(),
        isNull,
        reason: 'A position that belongs to a removed stream is dropped',
      );
    },
  );

  test(
    'scrub waits for active and queued saves before cleaning every copy',
    () async {
      const streamUrl =
          'https://media.example/live.m3u8?token=SCRUB_RACE_SECRET';
      final localPath = '${directory.path}/movie.mkv';
      final local = MediaEntry.fromPath(localPath, id: 'queue-local');
      final stream = MediaEntry.fromPath(streamUrl, id: 'queue-stream');
      final session = PlaybackSession(
        queue: <MediaEntry>[local, stream],
        recent: <MediaEntry>[stream],
        currentId: stream.id,
        saveNetworkUrls: true,
      );
      final encoderStarted = Completer<void>();
      final releaseEncoder = Completer<void>();
      var encodeCount = 0;
      final repository = SessionRepository(
        directory: directory,
        encoder: (value) async {
          encodeCount++;
          if (encodeCount == 3) {
            encoderStarted.complete();
            await releaseEncoder.future;
          }
          return jsonEncode(value.toJson());
        },
      );

      await repository.save(session);
      await repository.save(session);
      await repository.saveProgress(
        const SessionProgress(
          revision: 4,
          entryId: 'queue-stream',
          position: Duration(seconds: 30),
        ),
      );
      final activeSave = repository.save(session);
      await encoderStarted.future;
      final queuedSave = repository.save(session);

      var scrubFinished = false;
      final scrubbing = repository.scrubNetworkUrls().then((_) {
        scrubFinished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        scrubFinished,
        isFalse,
        reason: 'A scrub must wait for writes that could recreate old URLs',
      );

      releaseEncoder.complete();
      await Future.wait<void>(<Future<void>>[
        activeSave,
        queuedSave,
        scrubbing,
      ]);

      for (final name in <String>[
        'session.json',
        'session.json.bak',
        'progress.json',
      ]) {
        final contents = await File(
          p.join(directory.path, name),
        ).readAsString();
        expect(contents, isNot(contains('SCRUB_RACE_SECRET')));
        expect(contents, isNot(contains('media.example')));
      }
      final scrubbed = await repository.load();
      expect(scrubbed!.queue.map((entry) => entry.id), <String>['queue-local']);
      expect(scrubbed.queue.single.path, local.path);
      expect(await repository.loadProgress(), isNull);
    },
  );

  test('scrubbing keeps the resume position of a local file', () async {
    final repository = SessionRepository(directory: directory);
    final session = PlaybackSession(
      queue: <MediaEntry>[
        MediaEntry.fromPath('${directory.path}/movie.mkv', id: 'queue-local'),
        MediaEntry.fromPath(
          'https://media.example/live.m3u8',
          id: 'queue-stream',
        ),
      ],
      currentId: 'queue-local',
      saveNetworkUrls: true,
    );
    await repository.save(session);
    await repository.saveProgress(
      const SessionProgress(
        revision: 2,
        entryId: 'queue-local',
        position: Duration(seconds: 45),
        duration: Duration(minutes: 3),
      ),
    );

    await repository.scrubNetworkUrls();

    expect(
      (await repository.loadProgress())?.position,
      const Duration(seconds: 45),
      reason: 'Removing stream URLs must not lose local playback progress',
    );
  });

  test('control density defaults to compact for legacy or malformed data', () {
    final legacy = PlaybackSession.fromJson(<String, Object?>{
      'queue': <Object?>[],
      'recent': <Object?>[],
    });
    expect(legacy.controlDensity, ControlDensity.compact);

    for (final persistedValue in <Object?>['wide', 3, true, null]) {
      final session = PlaybackSession.fromJson(<String, Object?>{
        'queue': <Object?>[],
        'recent': <Object?>[],
        'controlDensity': persistedValue,
      });
      expect(session.controlDensity, ControlDensity.compact);
    }
  });

  test('loads backup after an interrupted or corrupt primary write', () async {
    final repository = SessionRepository(directory: directory);
    final recovered = PlaybackSession(
      queue: <MediaEntry>[
        MediaEntry(
          id: 'backup-entry',
          path: '${directory.path}/backup.mp4',
          title: 'backup.mp4',
          lastPlayed: DateTime.utc(2026, 10, 15),
        ),
      ],
      currentId: 'backup-entry',
    );
    await directory.create(recursive: true);
    final backup = File('${directory.path}/session.json.bak');
    final primary = File('${directory.path}/session.json');
    await backup.writeAsString(jsonEncode(recovered.toJson()));
    await primary.writeAsString('{corrupt');

    final loaded = await repository.load();

    expect(loaded?.currentId, 'backup-entry');
    expect(
      loaded?.queue.single.path,
      MediaEntry.normalizeSourcePath('${directory.path}/backup.mp4'),
    );

    await primary.delete();
    final loadedAfterInterruptedRename = await repository.load();
    expect(loadedAfterInterruptedRename?.currentId, 'backup-entry');
    expect(await backup.exists(), isTrue);
  });

  test(
    'missing and corrupt session files recover to an empty session',
    () async {
      final repository = SessionRepository(directory: directory);

      expect(await repository.load(), isNull);
      await directory.create(recursive: true);
      await File('${directory.path}/session.json').writeAsString('{broken');
      expect(await repository.load(), isNull);
    },
  );

  test('concurrent saves are serialized and leave a valid session', () async {
    final repository = SessionRepository(directory: directory);
    PlaybackSession sessionWith(String id) => PlaybackSession(
      queue: <MediaEntry>[
        MediaEntry(
          id: id,
          path: '${directory.path}/$id.mp4',
          title: '$id.mp4',
          lastPlayed: DateTime.utc(2026, 10, 15),
        ),
      ],
      currentId: id,
    );

    await Future.wait<void>(<Future<void>>[
      repository.save(sessionWith('first')),
      repository.save(sessionWith('second')),
    ]);

    expect((await repository.load())?.currentId, 'second');
  });

  test(
    'separate repositories serialize saves and retain a recovery backup',
    () async {
      PlaybackSession sessionWith(String prefix) {
        final queue = List<MediaEntry>.generate(
          700,
          (index) => MediaEntry(
            id: '$prefix-$index',
            path: '${directory.path}/$prefix-$index.mp4',
            title: '$prefix-$index.mp4',
            lastPlayed: DateTime.utc(2026, 10, 15),
          ),
        );
        return PlaybackSession(queue: queue, currentId: '$prefix-0');
      }

      final first = SessionRepository(directory: directory);
      final second = SessionRepository(directory: directory);
      await Future.wait<void>(<Future<void>>[
        first.save(sessionWith('first')),
        second.save(sessionWith('second')),
      ]);

      final loaded = await first.load();
      expect(loaded, isNotNull);
      expect(<String>{'first-0', 'second-0'}, contains(loaded!.currentId));
      expect(loaded.queue, hasLength(700));

      final backupFile = File('${directory.path}/session.json.bak');
      expect(await backupFile.exists(), isTrue);
      final backupJson = jsonDecode(await backupFile.readAsString()) as Map;
      final backup = PlaybackSession.fromJson(
        Map<String, Object?>.from(backupJson),
      );
      expect(<String>{'first-0', 'second-0'}, contains(backup.currentId));
      expect(backup.queue, hasLength(700));
    },
  );

  test(
    'throws typed SessionSaveException when save fails due to filesystem error',
    () async {
      final fileAsDir = File('${directory.path}/file_not_dir');
      await fileAsDir.writeAsString('not a directory');
      final repository = SessionRepository(
        directory: Directory(fileAsDir.path),
      );

      expect(
        repository.save(const PlaybackSession()),
        throwsA(isA<SessionSaveException>()),
      );
    },
  );

  test(
    'rejects structurally invalid primary roots and uses the backup',
    () async {
      final repository = SessionRepository(directory: directory);
      await directory.create(recursive: true);
      final backup = File('${directory.path}/session.json.bak');
      final primary = File('${directory.path}/session.json');
      await backup.writeAsString(
        jsonEncode(_sessionWith(directory, 'backup-entry').toJson()),
      );

      const invalidPrimaries = <String>[
        '[1, 2, 3]',
        '{"queue": {"a": 1}, "recent": []}',
        '{"queue": [], "recent": "nope"}',
        '{"queue": []}',
        '{"version": "one", "queue": [], "recent": []}',
        '{"version": 0, "queue": [], "recent": []}',
        '{"version": 1.5, "queue": [], "recent": []}',
      ];
      for (final payload in invalidPrimaries) {
        await primary.writeAsString(payload);
        final loaded = await repository.load();
        expect(loaded?.currentId, 'backup-entry', reason: 'primary: $payload');
      }

      // A rejected primary with a rejected backup must not throw or invent a
      // session; it reports that there is nothing usable to restore.
      await backup.writeAsString('{broken');
      expect(await repository.load(), isNull);
    },
  );

  test('a future session version falls back to the backup', () async {
    final repository = SessionRepository(directory: directory);
    await directory.create(recursive: true);
    final backup = File('${directory.path}/session.json.bak');
    final primary = File('${directory.path}/session.json');
    await backup.writeAsString(
      jsonEncode(_sessionWith(directory, 'backup-entry').toJson()),
    );
    await primary.writeAsString(
      jsonEncode(<String, Object?>{
        'version': 99,
        'queue': <Object?>[],
        'recent': <Object?>[],
      }),
    );

    final loaded = await repository.loadDetailed();
    expect(loaded.session?.currentId, 'backup-entry');
    expect(loaded.primaryRejected, isTrue);

    await primary.delete();
    expect((await repository.load())?.currentId, 'backup-entry');
  });

  test('a non-finite session version falls back to the backup', () async {
    final repository = SessionRepository(directory: directory);
    await directory.create(recursive: true);
    final backup = File(p.join(directory.path, 'session.json.bak'));
    final primary = File(p.join(directory.path, 'session.json'));
    await backup.writeAsString(
      jsonEncode(_sessionWith(directory, 'backup-entry').toJson()),
    );
    await primary.writeAsString(
      '{"version": 1e999, "queue": [], "recent": []}',
    );

    final loaded = await repository.loadDetailed();
    expect(loaded.session?.currentId, 'backup-entry');
    expect(loaded.primaryRejected, isTrue);

    // A non-finite progress revision is unusable metadata, not a reason to
    // reject an otherwise valid session.
    await primary.writeAsString(
      '{"version": 2, "progressRevision": 1e999, '
      '"queue": [], "recent": []}',
    );
    final recovered = await repository.loadDetailed();
    expect(recovered.primaryRejected, isFalse);
    expect(recovered.session, isNotNull);
    expect(recovered.session!.progressRevision, 0);
  });

  test(
    'keeps valid rows and skips unusable rows in a malformed session',
    () async {
      final repository = SessionRepository(directory: directory);
      await directory.create(recursive: true);
      final recoveredPath = '${directory.path}/recovered.mp4';
      final recentPath = '${directory.path}/recent.mp4';
      await File('${directory.path}/session.json').writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'queue': <Object?>[
            'not-a-row',
            42,
            <String, Object?>{},
            <String, Object?>{'path': '   '},
            <String, Object?>{'path': 7},
            <String, Object?>{
              'id': 7,
              'path': recoveredPath,
              'title': false,
              'lastPlayed': 7,
              'positionMs': 'soon',
              'durationMs': <String, Object?>{},
            },
          ],
          'recent': <Object?>[
            <String, Object?>{
              'id': 'recent-entry',
              'path': recentPath,
              'title': 'recent.mp4',
              'lastPlayed': '2026-10-15T00:00:00.000Z',
            },
          ],
        }),
      );

      final loaded = await repository.load();

      expect(loaded, isNotNull);
      expect(loaded!.queue, hasLength(1));
      final recovered = loaded.queue.single;
      expect(recovered.path, MediaEntry.normalizeSourcePath(recoveredPath));
      expect(recovered.id, MediaEntry.canonicalSource(recoveredPath));
      expect(recovered.title, 'recovered.mp4');
      expect(recovered.position, Duration.zero);
      expect(recovered.duration, Duration.zero);
      expect(recovered.lastPlayed, DateTime.fromMillisecondsSinceEpoch(0));
      expect(loaded.recent.single.id, 'recent-entry');
      expect(loaded.recent.single.title, 'recent.mp4');
      expect(loaded.recent.single.lastPlayed, DateTime.utc(2026, 10, 15));
    },
  );

  test('recovers wrong-typed entry fields instead of discarding the row', () {
    final path = '${directory.path}/clip.mkv';
    final entry = MediaEntry.fromJson(<String, Object?>{
      'id': <String>['not-an-id'],
      'path': path,
      'title': 3,
      'positionMs': null,
      'durationMs': 'long',
      'lastPlayed': 42,
    });

    expect(entry.path, path);
    expect(entry.id, MediaEntry.canonicalSource(path));
    expect(entry.title, MediaEntry.titleFromPath(path));
    expect(entry.position, Duration.zero);
    expect(entry.duration, Duration.zero);
    expect(entry.lastPlayed, DateTime.fromMillisecondsSinceEpoch(0));
  });

  test('clamps overflowing stored position and duration numbers', () async {
    final repository = SessionRepository(directory: directory);
    await directory.create(recursive: true);
    final path = '${directory.path}/overflow.mp4';
    await File('${directory.path}/session.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'queue': <Object?>[
          <String, Object?>{
            'id': 'double-overflow',
            'path': path,
            'positionMs': 1e30,
            'durationMs': 1e30,
          },
          <String, Object?>{
            'id': 'int-overflow',
            'path': path,
            'positionMs': 9223372036854775807,
            'durationMs': -1e30,
          },
        ],
        'recent': <Object?>[],
      }),
    );

    final loaded = await repository.load();

    expect(loaded, isNotNull);
    expect(loaded!.queue, hasLength(2));
    const limit = Duration(milliseconds: MediaEntry.maximumStoredMilliseconds);
    expect(loaded.queue.first.position, limit);
    expect(loaded.queue.first.duration, limit);
    expect(loaded.queue.last.position, limit);
    expect(loaded.queue.last.duration, Duration.zero);
  });

  test('accepts a structurally valid empty session as primary', () async {
    final repository = SessionRepository(directory: directory);
    await directory.create(recursive: true);
    final primary = File('${directory.path}/session.json');
    await primary.writeAsString(
      jsonEncode(<String, Object?>{
        'version': PlaybackSession.schemaVersion,
        'queue': <Object?>[],
        'recent': <Object?>[],
        'currentId': null,
      }),
    );

    final loaded = await repository.load();
    expect(loaded, isNotNull);
    expect(loaded!.queue, isEmpty);
    expect(loaded.recent, isEmpty);
    expect(loaded.currentId, isNull);
    expect(loaded.currentIndex, -1);

    // Version-less legacy files are still version 1.
    await primary.writeAsString(
      jsonEncode(<String, Object?>{
        'queue': <Object?>[],
        'recent': <Object?>[],
      }),
    );
    final legacy = await repository.load();
    expect(legacy, isNotNull);
    expect(legacy!.queue, isEmpty);
    expect(legacy.currentId, isNull);
  });

  test(
    'bounds session lock acquisition while another process holds it',
    () async {
      final repository = SessionRepository(
        directory: directory,
        lockTimeout: const Duration(milliseconds: 250),
      );
      await directory.create(recursive: true);
      final lockFile = File('${directory.path}/session.lock');
      final holder = await _LockHolder.acquire(lockFile);
      if (holder == null) {
        fail('Could not hold the session lock for the test');
      }

      final session = _sessionWith(directory, 'after-release');
      try {
        await expectLater(
          repository.save(session),
          throwsA(
            isA<SessionSaveException>().having(
              (error) => error.message,
              'message',
              contains('Timed out waiting for the session lock'),
            ),
          ),
        );
      } finally {
        await holder.release();
      }

      await repository.save(session);
      expect((await repository.load())?.currentId, 'after-release');
    },
  );

  test(
    'coalesces rapid saves to one active operation and at most one pending snapshot',
    () async {
      var encodeCalls = 0;
      final repository = SessionRepository(
        directory: directory,
        encoder: (session) async {
          encodeCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return jsonEncode(session.toJson());
        },
      );

      final save1 = repository.save(_sessionWith(directory, 'session-1'));
      // Fire saves 2, 3, and 4 while save1 is active.
      final save2 = repository.save(_sessionWith(directory, 'session-2'));
      final save3 = repository.save(_sessionWith(directory, 'session-3'));
      final save4 = repository.save(_sessionWith(directory, 'session-4'));

      await Future.wait<void>(<Future<void>>[save1, save2, save3, save4]);

      // Exactly 2 encoding operations: save1 (active), then save4 (the coalesced pending snapshot).
      expect(encodeCalls, 2);
      expect((await repository.load())?.currentId, 'session-4');
    },
  );

  test(
    'encodes session JSON in background isolate using default isolate encoder',
    () async {
      final repository = SessionRepository(directory: directory);
      final queue = List<MediaEntry>.generate(
        1000,
        (i) => MediaEntry(
          id: 'entry-$i',
          path: '${directory.path}/video-$i.mp4',
          title: 'Video $i',
          duration: Duration(minutes: i + 1),
          lastPlayed: DateTime.utc(2026, 10, 15),
        ),
      );
      final session = PlaybackSession(queue: queue, currentId: 'entry-500');

      await repository.save(session);
      final loaded = await repository.load();

      expect(loaded, isNotNull);
      expect(loaded!.queue.length, 1000);
      expect(loaded.currentId, 'entry-500');
    },
  );

  test(
    'coalesces progress saves to one active write and at most one pending checkpoint',
    () async {
      final repository = SessionRepository(directory: directory);
      await repository.init();

      final c1 = repository.saveProgress(
        const SessionProgress(
          revision: 1,
          entryId: 'e1',
          position: Duration(seconds: 1),
        ),
      );
      final c2 = repository.saveProgress(
        const SessionProgress(
          revision: 2,
          entryId: 'e1',
          position: Duration(seconds: 2),
        ),
      );
      final c3 = repository.saveProgress(
        const SessionProgress(
          revision: 3,
          entryId: 'e1',
          position: Duration(seconds: 3),
        ),
      );

      await Future.wait<void>(<Future<void>>[c1, c2, c3]);

      final loaded = await repository.loadProgress();
      expect(loaded, isNotNull);
      expect(loaded!.revision, 3);
      expect(loaded.position, const Duration(seconds: 3));
    },
  );

  test(
    'progress checkpoint is atomic and does not modify session.json',
    () async {
      final repository = SessionRepository(directory: directory);
      final session = _sessionWith(directory, 'saved-session');
      await repository.save(session);

      final sessionFile = File('${directory.path}/session.json');
      final sessionContentBefore = await sessionFile.readAsString();

      await repository.saveProgress(
        const SessionProgress(
          revision: 10,
          entryId: 'saved-session',
          position: Duration(seconds: 30),
          duration: Duration(minutes: 5),
        ),
      );

      final sessionContentAfter = await sessionFile.readAsString();
      expect(sessionContentAfter, equals(sessionContentBefore));

      final progress = await repository.loadProgress();
      expect(progress?.position, const Duration(seconds: 30));
      expect(progress?.revision, 10);
    },
  );

  test(
    'isolate session parsing parses valid session and preserves SessionFormatException on malformed json or schema to recover backup',
    () async {
      final repository = SessionRepository(directory: directory);
      final backupSession = PlaybackSession(
        queue: <MediaEntry>[
          MediaEntry(
            id: 'backup-entry',
            path: '${directory.path}/backup.mp4',
            title: 'backup.mp4',
            lastPlayed: DateTime.utc(2026, 10, 15),
          ),
        ],
        currentId: 'backup-entry',
      );
      await directory.create(recursive: true);
      final backup = File('${directory.path}/session.json.bak');
      final primary = File('${directory.path}/session.json');
      await backup.writeAsString(jsonEncode(backupSession.toJson()));

      // 1. Valid primary parses via isolate.
      final validPrimarySession = PlaybackSession(
        queue: <MediaEntry>[
          MediaEntry(
            id: 'primary-entry',
            path: '${directory.path}/primary.mp4',
            title: 'primary.mp4',
            lastPlayed: DateTime.utc(2026, 10, 16),
          ),
        ],
        currentId: 'primary-entry',
      );
      await primary.writeAsString(jsonEncode(validPrimarySession.toJson()));
      final detailedValid = await repository.loadDetailed();
      expect(detailedValid.primaryRejected, isFalse);
      expect(detailedValid.session?.currentId, 'primary-entry');

      // 2. Corrupt JSON in primary preserves SessionFormatException and recovers from backup.
      await primary.writeAsString('{not-valid-json');
      final detailedCorruptJson = await repository.loadDetailed();
      expect(detailedCorruptJson.primaryRejected, isTrue);
      expect(detailedCorruptJson.session?.currentId, 'backup-entry');
      expect(
        detailedCorruptJson.note,
        contains('The stored session was rejected'),
      );

      // 3. Invalid schema (e.g. non-object or invalid version) preserves SessionFormatException and recovers from backup.
      await primary.writeAsString(
        jsonEncode(<String, Object?>{'version': 'invalid_version'}),
      );
      final detailedInvalidSchema = await repository.loadDetailed();
      expect(detailedInvalidSchema.primaryRejected, isTrue);
      expect(detailedInvalidSchema.session?.currentId, 'backup-entry');
    },
  );
}

PlaybackSession _sessionWith(Directory directory, String id) {
  return PlaybackSession(
    queue: <MediaEntry>[
      MediaEntry(
        id: id,
        path: '${directory.path}/$id.mp4',
        title: '$id.mp4',
        lastPlayed: DateTime.utc(2026, 10, 15),
      ),
    ],
    currentId: id,
  );
}

/// Holds an exclusive OS lock on a session lock file for one test.
///
/// POSIX record locks are process-scoped, so a second handle in this test
/// process does not contend on Linux. A child Dart VM exercises the real
/// cross-process lock on every platform, with an in-process fallback for
/// platforms whose locks are handle-scoped.
class _LockHolder {
  _LockHolder._process(this._process, this._script) : _handle = null;
  _LockHolder._inProcess(this._handle) : _process = null, _script = null;

  final Process? _process;
  final File? _script;
  final RandomAccessFile? _handle;

  static Future<_LockHolder?> acquire(File lockFile) async {
    final dart = _dartExecutable();
    if (dart != null) {
      try {
        return await _spawn(dart, lockFile);
      } on Object {
        // Fall through to the in-process attempt below.
      }
    }
    return _acquireInProcess(lockFile);
  }

  static Future<_LockHolder> _spawn(String dart, File lockFile) async {
    final script = File(p.join(lockFile.parent.path, 'lock_holder.dart'));
    await script.writeAsString(_holderScript);
    final process = await Process.start(dart, <String>[
      script.path,
      lockFile.path,
    ]);
    final ready = Completer<void>();
    final errors = StringBuffer();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim() == 'locked' && !ready.isCompleted) ready.complete();
        });
    process.stderr.transform(utf8.decoder).listen(errors.write);
    try {
      await ready.future.timeout(const Duration(seconds: 30));
    } on Object {
      process.kill();
      await process.exitCode;
      throw StateError('The lock holder failed to start: $errors');
    }
    return _LockHolder._process(process, script);
  }

  static Future<_LockHolder?> _acquireInProcess(File lockFile) async {
    final first = await lockFile.open(mode: FileMode.append);
    await first.lock(FileLock.exclusive);
    final second = await lockFile.open(mode: FileMode.append);
    try {
      await second.lock(FileLock.exclusive);
    } on FileSystemException {
      await second.close();
      return _LockHolder._inProcess(first);
    }
    // Same-process locks do not contend here: releasing is the only option.
    await second.close();
    await first.unlock();
    await first.close();
    return null;
  }

  Future<void> release() async {
    final process = _process;
    if (process != null) {
      process.kill();
      await process.exitCode;
      final script = _script;
      if (script != null && await script.exists()) await script.delete();
      return;
    }
    final handle = _handle;
    if (handle == null) return;
    try {
      await handle.unlock();
    } on Object {
      // Closing the handle releases the OS lock.
    }
    await handle.close();
  }
}

String? _dartExecutable() {
  final resolved = File(Platform.resolvedExecutable);
  if (p.basenameWithoutExtension(resolved.path).toLowerCase() == 'dart') {
    return resolved.path;
  }
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  final candidates = <String>[];
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    candidates.add(
      p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', executableName),
    );
  }
  var directory = resolved.parent;
  for (var depth = 0; depth < 6; depth++) {
    candidates.add(p.join(directory.path, 'dart-sdk', 'bin', executableName));
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) return file.path;
  }
  return null;
}

const String _holderScript = r'''
import 'dart:io';

Future<void> main(List<String> args) async {
  final handle = await File(args[0]).open(mode: FileMode.append);
  await handle.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdout.flush();
  // Bounded hold so an abandoned holder process exits on its own.
  await Future<void>.delayed(const Duration(minutes: 2));
  await handle.unlock();
  await handle.close();
}
''';
