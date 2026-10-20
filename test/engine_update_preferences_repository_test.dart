import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:mpvson/data/repositories/engine_update_preferences_repository.dart';
import 'package:mpvson/domain/updates/engine_update_channel.dart';

void main() {
  group('EngineUpdatePreferencesRepository', () {
    late Directory temporaryDirectory;
    late Directory storageDirectory;
    late EngineUpdatePreferencesRepository repository;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'engine-update-preferences-test-',
      );
      storageDirectory = Directory(p.join(temporaryDirectory.path, 'updates'));
      repository = EngineUpdatePreferencesRepository(
        storageDirectory: storageDirectory,
      );
    });

    tearDown(() async {
      await temporaryDirectory.delete(recursive: true);
    });

    test(
      'defaults to stable and restores an explicit development choice',
      () async {
        expect(await repository.loadChannel(), EngineUpdateChannel.stable);

        await repository.saveChannel(EngineUpdateChannel.development);

        final nextLaunch = EngineUpdatePreferencesRepository(
          storageDirectory: storageDirectory,
        );
        expect(await nextLaunch.loadChannel(), EngineUpdateChannel.development);
      },
    );

    test('falls back to stable for a damaged preference file', () async {
      await storageDirectory.create(recursive: true);
      await File(
        p.join(
          storageDirectory.path,
          EngineUpdatePreferencesRepository.fileName,
        ),
      ).writeAsString('{broken');

      expect(await repository.loadChannel(), EngineUpdateChannel.stable);
    });

    test(
      'falls back to stable when the preference file exceeds 4 KiB',
      () async {
        await storageDirectory.create(recursive: true);
        await File(
          p.join(
            storageDirectory.path,
            EngineUpdatePreferencesRepository.fileName,
          ),
        ).writeAsString(' ' * (4 * 1024 + 1));

        expect(await repository.loadChannel(), EngineUpdateChannel.stable);
      },
    );
  });
}
