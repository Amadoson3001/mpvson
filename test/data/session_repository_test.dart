import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/domain/models/session_progress.dart';
import 'package:path/path.dart' as p;

/// A repository rooted in a fresh temporary directory per test.
Future<SessionRepository> _repository({
  required Directory root,
  SessionEncoder? encoder,
}) async {
  final directory = Directory(p.join(root.path, 'mpvson'));
  final repository = SessionRepository(
    directory: directory,
    encoder: encoder ?? (session) async => jsonEncode(session.toJson()),
  );
  await repository.init();
  return repository;
}

File _sessionFile(Directory root) =>
    File(p.join(root.path, 'mpvson', 'session.json'));

File _backupFile(Directory root) =>
    File(p.join(root.path, 'mpvson', 'session.json.bak'));

File _progressFile(Directory root) =>
    File(p.join(root.path, 'mpvson', 'progress.json'));

PlaybackSession _session({String currentId = 'a'}) => PlaybackSession(
  queue: <MediaEntry>[
    MediaEntry.fromPath('C:/media/a.mp4', id: 'a'),
    MediaEntry.fromPath('C:/media/b.mp4', id: 'b'),
    // A third row so a test can distinguish which save reached disk by the
    // entry that is marked current.
    MediaEntry.fromPath('C:/media/c.mp4', id: currentId),
  ],
  currentId: currentId,
);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mpvson-session-test-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('SessionRepository load', () {
    test('returns null when nothing was stored', () async {
      final repository = await _repository(root: root);

      expect(await repository.load(), isNull);
      expect((await repository.loadDetailed()).note, isNull);
    });

    test('round-trips a saved session', () async {
      final repository = await _repository(root: root);
      await repository.save(_session());

      final loaded = await repository.load();

      expect(loaded, isNotNull);
      expect(loaded!.queue, hasLength(3));
      expect(loaded.currentId, 'a');
    });

    test('rejects a malformed primary and uses the backup', () async {
      await _sessionFile(root).parent.create(recursive: true);
      await _sessionFile(root).writeAsString('{ not json');
      await _backupFile(
        root,
      ).writeAsString(jsonEncode(_session(currentId: 'b').toJson()));

      final repository = await _repository(root: root);
      final result = await repository.loadDetailed();

      expect(result.primaryRejected, isTrue);
      expect(result.session, isNotNull);
      expect(result.session!.currentId, 'b');
      expect(result.note, contains('rejected'));
    });

    test('reports a rejected primary with no backup', () async {
      await _sessionFile(root).parent.create(recursive: true);
      await _sessionFile(root).writeAsString('{"queue": "not a list"}');

      final repository = await _repository(root: root);
      final result = await repository.loadDetailed();

      expect(result.primaryRejected, isTrue);
      expect(result.session, isNull);
      expect(result.note, contains('rejected'));
    });

    test(
      'a rejected primary does not consume the backup on the next save',
      () async {
        await _sessionFile(root).parent.create(recursive: true);
        await _sessionFile(root).writeAsString('{ not json');
        await _backupFile(
          root,
        ).writeAsString(jsonEncode(_session(currentId: 'b').toJson()));

        final repository = await _repository(root: root);
        final rejected = await repository.loadDetailed();
        expect(rejected.primaryRejected, isTrue);

        await repository.save(_session(currentId: 'a'));
        await repository.flush();

        // The damaged primary was replaced, and the good backup survived as
        // the recovery copy rather than being overwritten with the damaged
        // content that used to sit in the primary.
        final reloaded = await repository.loadDetailed();
        expect(reloaded.primaryRejected, isFalse);
        expect(reloaded.session!.currentId, 'a');
        final backupJson = jsonDecode(await _backupFile(root).readAsString());
        expect(
          PlaybackSession.fromJson(
            Map<String, Object?>.from(backupJson as Map),
          ).currentId,
          'b',
        );
      },
    );

    test('an ordinary save keeps the previous primary as the backup', () async {
      final repository = await _repository(root: root);
      await repository.save(_session(currentId: 'a'));
      await repository.flush();
      await repository.save(_session(currentId: 'b'));
      await repository.flush();

      expect((await repository.load())!.currentId, 'b');
      final backup = await _repository(root: root);
      final backupJson = jsonDecode(await _backupFile(root).readAsString());
      expect(
        PlaybackSession.fromJson(
          Map<String, Object?>.from(backupJson as Map),
        ).currentId,
        'a',
      );
      expect(await backup.load(), isNotNull);
    });
  });

  group('SessionRepository save coalescing', () {
    test('concurrent saves run in order and complete every caller', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final repository = SessionRepository(
        directory: Directory(p.join(root.path, 'mpvson')),
        encoder: (session) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return jsonEncode(session.toJson());
        },
      );
      await repository.init();

      final futures = <Future<void>>[
        for (var i = 0; i < 5; i++)
          repository.save(_session(currentId: 'entry-$i')),
      ];
      await Future.wait(futures);
      await repository.flush();

      expect(maxInFlight, 1);
      // The last queued session is the one that reached disk.
      expect((await repository.load())!.currentId, 'entry-4');
    });

    test('flush waits for a save queued behind an in-flight one', () async {
      final gate = Completer<void>();
      var writes = 0;
      final repository = SessionRepository(
        directory: Directory(p.join(root.path, 'mpvson')),
        encoder: (session) async {
          writes++;
          if (writes == 1) await gate.future;
          return jsonEncode(session.toJson());
        },
      );
      await repository.init();

      final first = repository.save(_session(currentId: 'a'));
      final second = repository.save(_session(currentId: 'b'));
      var flushed = false;
      final flush = repository.flush().then((_) => flushed = true);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(flushed, isFalse);

      gate.complete();
      await Future.wait(<Future<void>>[first, second, flush]);

      expect(flushed, isTrue);
      expect(writes, 2);
      expect((await repository.load())!.currentId, 'b');
    });

    test(
      'a save failure surfaces to its callers and does not wedge the queue',
      () async {
        var attempts = 0;
        final repository = SessionRepository(
          directory: Directory(p.join(root.path, 'mpvson')),
          encoder: (session) async {
            attempts++;
            if (attempts == 1) throw const SessionSaveException('disk full');
            return jsonEncode(session.toJson());
          },
        );
        await repository.init();

        await expectLater(
          repository.save(_session()),
          throwsA(isA<SessionSaveException>()),
        );

        await repository.save(_session(currentId: 'b'));
        await repository.flush();

        expect(attempts, 2);
        expect((await repository.load())!.currentId, 'b');
      },
    );

    test(
      'a scrubbed save rewrites the recovery copy with the same content',
      () async {
        final repository = await _repository(root: root);
        final withUrl = PlaybackSession(
          queue: <MediaEntry>[
            MediaEntry.fromPath('https://x.test/s.m3u8', id: 'stream-1'),
          ],
        );
        await repository.save(withUrl);
        await repository.flush();

        await repository.saveScrubbed(withUrl.withoutNetworkUrls());
        await repository.flush();

        final primary = jsonDecode(await _sessionFile(root).readAsString());
        final backup = jsonDecode(await _backupFile(root).readAsString());
        expect(primary, equals(backup));
        expect(jsonEncode(primary), isNot(contains('x.test')));
      },
    );
  });

  group('SessionRepository progress checkpoints', () {
    test('round-trips a checkpoint', () async {
      final repository = await _repository(root: root);

      await repository.saveProgress(
        const SessionProgress(
          revision: 4,
          entryId: 'a',
          position: Duration(seconds: 30),
          duration: Duration(seconds: 90),
        ),
      );
      await repository.flush();

      final loaded = await repository.loadProgress();
      expect(loaded!.revision, 4);
      expect(loaded.entryId, 'a');
      expect(loaded.position, const Duration(seconds: 30));
    });

    test(
      'a corrupt checkpoint is ignored rather than failing the load',
      () async {
        await _progressFile(root).parent.create(recursive: true);
        await _progressFile(root).writeAsString('{{{');

        final repository = await _repository(root: root);

        expect(await repository.loadProgress(), isNull);
      },
    );

    test('coalesced checkpoints keep only the latest', () async {
      final repository = await _repository(root: root);

      await Future.wait(<Future<void>>[
        for (var i = 1; i <= 4; i++)
          repository.saveProgress(
            SessionProgress(
              revision: i,
              entryId: 'a',
              position: Duration(seconds: i),
            ),
          ),
      ]);
      await repository.flush();

      expect((await repository.loadProgress())!.revision, 4);
    });
  });

  group('SessionRepository network scrubbing', () {
    test('removes stream URLs from the primary and the backup', () async {
      final repository = await _repository(root: root);
      await repository.save(
        PlaybackSession(
          queue: <MediaEntry>[
            MediaEntry.fromPath('https://x.test/s.m3u8', id: 'stream-1'),
          ],
          saveNetworkUrls: true,
        ),
      );
      await repository.flush();

      await repository.scrubNetworkUrls();

      expect(await _sessionFile(root).exists(), isTrue);
      expect(
        await _sessionFile(root).readAsString(),
        isNot(contains('x.test')),
      );
      expect(await _backupFile(root).readAsString(), isNot(contains('x.test')));
    });

    test('drops a checkpoint that names a stream', () async {
      final repository = await _repository(root: root);
      await repository.save(
        PlaybackSession(
          queue: <MediaEntry>[
            MediaEntry.fromPath('https://x.test/s.m3u8', id: 'stream-1'),
          ],
        ),
      );
      await repository.saveProgress(
        const SessionProgress(revision: 2, entryId: 'stream-1'),
      );
      await repository.flush();
      expect(await repository.loadProgress(), isNotNull);

      await repository.scrubNetworkUrls();

      final checkpoint = await repository.loadProgress();
      expect(checkpoint == null || checkpoint.isEmpty, isTrue);
    });

    test('concurrent scrubs run once', () async {
      var loads = 0;
      final repository = SessionRepository(
        directory: Directory(p.join(root.path, 'mpvson')),
        encoder: (session) async {
          loads++;
          return jsonEncode(session.toJson());
        },
      );
      await repository.init();

      await Future.wait(<Future<void>>[
        repository.scrubNetworkUrls(),
        repository.scrubNetworkUrls(),
        repository.scrubNetworkUrls(),
      ]);

      expect(loads, lessThan(3));
    });
  });
}
