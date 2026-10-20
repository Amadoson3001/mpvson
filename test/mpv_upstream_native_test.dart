import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/engine_installation_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/domain/updates/engine_update_channel.dart';
import 'package:path/path.dart' as p;

// This opt-in test downloads the real upstream build and never touches the
// user's engine store. Run after building the Windows release executable.
void main() {
  test(
    'opted-in mpv development source downloads, activates, renders and rolls back',
    () async {
      final executable = File(
        p.normalize(p.absolute('build/windows/x64/runner/Release/mpvson.exe')),
      );
      final media = File(p.normalize(p.absolute('test-output/smoke.mp4')));
      expect(await executable.exists(), isTrue, reason: 'Build Windows first.');
      expect(await media.exists(), isTrue, reason: 'Provide smoke.mp4 first.');
      final root = await Directory(
        p.normalize(p.absolute('test-output/mpv-upstream-native')),
      ).create(recursive: true);
      final run = await root.createTemp('run-');
      final store = Directory(p.join(run.path, 'engines'));
      final repository = EngineInstallationRepository(enginesDirectory: store);
      // A deliberately older identity than the bundled engine, so the updater
      // offers whatever package the upstream feed currently publishes.
      final updater = EngineUpdateService(
        repository: repository,
        currentVersion: '0.0.0',
      );
      final provenance =
          jsonDecode(
                File(
                  p.join('packaging', 'windows', 'engine-provenance.json'),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final bundledVersion =
          (provenance['engine']! as Map<String, Object?>)['version']! as String;

      Future<Map<String, dynamic>> smoke(String name) async {
        final output = await Directory(p.join(run.path, name)).create();
        final report = File(p.join(output.path, 'native-smoke.json'));
        final process = await Process.start(executable.path, [
          '--smoke-test=${media.path}',
          '--smoke-report=${report.path}',
          '--smoke-screenshot=${p.join(output.path, 'native-smoke.png')}',
          '--smoke-engine-store=${store.path}',
          '--smoke-fullscreen',
        ], workingDirectory: executable.parent.path);
        final stdoutResult = process.stdout.transform(utf8.decoder).join();
        final stderrResult = process.stderr.transform(utf8.decoder).join();
        final code = await process.exitCode.timeout(
          const Duration(seconds: 40),
          onTimeout: () {
            process.kill();
            throw StateError('Native smoke test timed out.');
          },
        );
        await File(
          p.join(output.path, 'stdout.log'),
        ).writeAsString(await stdoutResult);
        await File(
          p.join(output.path, 'stderr.log'),
        ).writeAsString(await stderrResult);
        expect(code, 0, reason: output.path);
        final result =
            jsonDecode(await report.readAsString()) as Map<String, dynamic>;
        expect(result['success'], isTrue);
        expect(result['visualCaptureSuccess'], isTrue);
        expect(
          result['engineLibraryPath'],
          result['rendererEngineLibraryPath'],
        );
        expect(result['paused'], isTrue);
        expect(
          result['engineVersionBeforeOpen'],
          isNot(contains('unavailable')),
        );
        return result;
      }

      try {
        expect(updater.configured, isTrue);
        expect(updater.usesOfficialMpvSource, isTrue);
        expect(
          await updater.setChannel(EngineUpdateChannel.development),
          isTrue,
        );
        await updater.check();
        expect(updater.status, 'available', reason: updater.error);
        final release = updater.release!;
        await File(p.join(run.path, 'upstream-release.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'source': updater.sourceLabel,
            'version': release.engineVersion,
            'url': release.downloadUri.toString(),
            'sha256': release.sha256,
            'size': release.sizeBytes,
          }),
        );
        await updater.downloadAndStage();
        expect(updater.status, 'readyToRestart', reason: updater.error);
        expect(updater.pendingVersion, release.engineVersion);

        final activated = await smoke('activated');
        expect(
          activated['engineLibraryPath'],
          p.join(store.path, release.engineVersion, 'libmpv-2.dll'),
        );
        // The development version records the commit in SemVer build metadata.
        final commit = release.engineVersion.split('+').last;
        expect(activated['engineVersion'], contains(commit));
        expect(
          activated['engineVersionBeforeOpen'],
          activated['engineVersion'],
        );
        expect(
          (await repository.loadSelection()).active?.version,
          release.engineVersion,
        );
        expect((await repository.loadSelection()).pending, isNull);

        await updater.initialize();
        expect(updater.canRollback, isTrue);
        await updater.scheduleRollback();
        final rollback = await smoke('bundled-rollback');
        expect(
          rollback['engineLibraryPath'],
          p.join(executable.parent.path, 'libmpv-2.dll'),
        );
        expect(
          rollback['engineVersion'],
          contains(bundledVersion),
          reason: 'Rollback must return to the engine bundled with the build.',
        );
        // ignore: avoid_print
        print('Live mpv evidence: ${run.path}');
      } finally {
        updater.dispose();
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('MPVSON_LIVE_MPV_TEST'),
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
