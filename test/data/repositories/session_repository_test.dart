import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:path/path.dart' as p;

class _FailingCommitRepository extends SessionRepository {
  _FailingCommitRepository({required super.directory, super.encoder});

  bool failCommit = false;

  @override
  Future<void> commitTemporary(File temporary, File target) async {
    if (failCommit) {
      throw const FileSystemException('injected commit failure');
    }
    return super.commitTemporary(temporary, target);
  }
}

String _sessionJson(double volume) =>
    jsonEncode(PlaybackSession(volume: volume).toJson());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late _FailingCommitRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mpvson-session-');
    repository = _FailingCommitRepository(
      directory: directory,
      encoder: (session) => jsonEncode(session.toJson()),
    );
  });

  tearDown(() async {
    await repository.flush();
    await directory.delete(recursive: true);
  });

  File primary() => File(p.join(directory.path, 'session.json'));
  File backup() => File(p.join(directory.path, 'session.json.bak'));

  test('a failed repair keeps the known-good backup recoverable', () async {
    await backup().writeAsString(_sessionJson(42));
    await primary().writeAsString('{corrupt');

    final loaded = await repository.loadDetailed();
    expect(loaded.primaryRejected, isTrue);
    expect(loaded.session?.volume, 42);

    repository.failCommit = true;
    await expectLater(
      repository.save(const PlaybackSession(volume: 77)),
      throwsA(isA<SessionSaveException>()),
    );

    expect(await backup().exists(), isTrue);
    final recovered = await SessionRepository(directory: directory).load();
    expect(recovered?.volume, 42);
  });

  test('a failed ordinary save keeps both primary and backup', () async {
    await primary().writeAsString(_sessionJson(10));
    await backup().writeAsString(_sessionJson(5));
    expect((await repository.load())?.volume, 10);

    repository.failCommit = true;
    await expectLater(
      repository.save(const PlaybackSession(volume: 77)),
      throwsA(isA<SessionSaveException>()),
    );

    expect(await primary().exists(), isTrue);
    expect(await backup().exists(), isTrue);
    final reread = await SessionRepository(directory: directory).load();
    expect(reread?.volume, 10);
    final backupContent =
        jsonDecode(await backup().readAsString()) as Map<String, Object?>;
    // The previous primary was promoted before the commit; rollback must not
    // consume it, so both copies still describe the last complete session.
    expect(backupContent['volume'], 10);
  });

  test('a successful repair commits and restores normal promotion', () async {
    await backup().writeAsString(_sessionJson(42));
    await primary().writeAsString('{corrupt');
    expect((await repository.loadDetailed()).primaryRejected, isTrue);

    await repository.save(const PlaybackSession(volume: 77));
    expect((await repository.load())?.volume, 77);

    await repository.save(const PlaybackSession(volume: 88));
    final backupContent =
        jsonDecode(await backup().readAsString()) as Map<String, Object?>;
    expect(backupContent['volume'], 77);
    expect((await repository.load())?.volume, 88);
  });
}
