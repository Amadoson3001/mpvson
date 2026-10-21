import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/repositories/engine_installation_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/domain/updates/engine_selection.dart';

void main() {
  for (final rollback in [false, true]) {
    test(
      '${rollback ? 'rollback' : 'discard'} excludes duplicate operations and checks',
      () async {
        final repository = _DeferredRepository();
        var requests = 0;
        final client = MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        });
        final service = EngineUpdateService(
          repository: repository,
          client: client,
          currentVersion: '0.41.0',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() {
          service.dispose();
          client.close();
        });
        Future<void> perform() =>
            rollback ? service.scheduleRollback() : service.discardPending();
        final first = perform();
        await repository.started.future;
        final second = perform();
        await service.check();
        repository.release.complete();
        await Future.wait([first, second]);

        expect(repository.operations, 1);
        expect(requests, 0);
      },
    );
  }
}

class _DeferredRepository extends EngineInstallationRepository {
  final started = Completer<void>();
  final release = Completer<void>();
  int operations = 0;

  Future<void> _wait() async {
    operations++;
    if (!started.isCompleted) started.complete();
    await release.future;
  }

  @override
  Future<void> discardPending() => _wait();

  @override
  Future<EngineSelectionState> loadSelection() async =>
      const EngineSelectionState();

  @override
  Future<EngineBootSelection> scheduleRollback({
    String? bundledEnginePath,
    String? bundledEngineVersion,
    bool Function(EngineInstallRecord)? isCompatible,
  }) async {
    await _wait();
    return const EngineBootSelection(
      libraryPath: null,
      version: '0.40.0',
      isBundled: true,
      isPending: true,
    );
  }
}
