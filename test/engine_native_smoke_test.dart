import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/repositories/engine_installation_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:path/path.dart' as p;

import '../tool/create_engine_manifest.dart' as release_tool;

// Opt in after a release build. Uses only an isolated store under test-output.
// The package contains the existing tested runtime. Synthetic release labels
// exercise selection and rollback; the report retains the actual mpv version.
void main() {
  test(
    'signed staging, native activation, recovery and rollback use one engine',
    () async {
      final executable = File(
        p.normalize(p.absolute('build/windows/x64/runner/Release/mpvson.exe')),
      );
      final media = File(p.normalize(p.absolute('test-output/smoke.mp4')));
      expect(await executable.exists(), isTrue, reason: 'Build Windows first.');
      expect(await media.exists(), isTrue, reason: 'Provide smoke.mp4 first.');
      final root = await Directory(
        p.normalize(p.absolute('test-output/engine-native')),
      ).create(recursive: true);
      final run = await root.createTemp('run-');
      final store = Directory(p.join(run.path, 'engines'));
      final repository = EngineInstallationRepository(enginesDirectory: store);
      final seedDirectory = await Directory.systemTemp.createTemp(
        'mpvson-key-',
      );
      final seed = File(p.join(seedDirectory.path, 'seed'));
      await seed.writeAsBytes(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      );

      Future<void> stage(String version, {bool invalidLibrary = false}) async {
        final archive = Archive();
        for (final name in [
          'libmpv-2.dll',
          'd3dcompiler_47.dll',
          'libEGL.dll',
          'libGLESv2.dll',
          'vk_swiftshader.dll',
          'vulkan-1.dll',
          'zlib.dll',
          'THIRD_PARTY.txt',
        ]) {
          final file = File(p.join(executable.parent.path, name));
          if (!await file.exists()) continue;
          final bytes = invalidLibrary && name == 'libmpv-2.dll'
              ? utf8.encode('Deliberately invalid native library fixture')
              : await file.readAsBytes();
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
        }
        final package = File(p.join(run.path, 'engine-$version.zip'));
        final bytes = ZipEncoder().encode(archive);
        await package.writeAsBytes(bytes);
        String? publicKey;
        final manifest = await release_tool.createEngineManifest(
          engineZip: package,
          engineUri: Uri.parse('https://engine.test/package.zip'),
          engineVersion: version,
          mediaKitVersion: '1.2.6',
          minimumAppVersion: '0.1.0',
          notes: 'Local native selection test, using the bundled runtime.',
          signingKeyFile: seed,
          onPublicKey: (value) => publicKey = value,
        );
        final client = MockClient((request) async {
          return request.url.path == '/manifest.json'
              ? http.Response(jsonEncode(manifest), 200)
              : http.Response.bytes(bytes, 200);
        });
        final updater = EngineUpdateService(
          repository: repository,
          client: client,
          manifestUri: Uri.parse('https://engine.test/manifest.json'),
          publicKeyBase64: publicKey,
          currentVersion: '0.0.0',
        );
        try {
          await updater.check();
          expect(updater.status, 'available', reason: updater.error);
          await updater.downloadAndStage();
          expect(updater.status, 'readyToRestart', reason: updater.error);
        } finally {
          updater.dispose();
          client.close();
        }
      }

      Future<Map<String, dynamic>> smoke(String name) async {
        final output = await Directory(p.join(run.path, name)).create();
        final report = File(p.join(output.path, 'native-smoke.json'));
        final process = await Process.start(executable.path, [
          '--smoke-test=${media.path}',
          '--smoke-report=${report.path}',
          '--smoke-screenshot=${p.join(output.path, 'native-smoke.png')}',
          '--smoke-engine-store=${store.path}',
        ], workingDirectory: executable.parent.path);
        final stdoutResult = process.stdout.transform(utf8.decoder).join();
        final stderrResult = process.stderr.transform(utf8.decoder).join();
        final code = await process.exitCode.timeout(
          // Recovery can start two native processes and verify both runtimes.
          // On a cold Windows run the fallback child produced a successful
          // report after the old single-process budget had already expired.
          const Duration(seconds: 60),
          onTimeout: () {
            process.kill();
            throw StateError('Native smoke test "$name" exceeded 60 seconds.');
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
        return result;
      }

      try {
        await stage('0.36.1');
        final activated = await smoke('activated');
        expect(
          activated['engineLibraryPath'],
          p.join(store.path, '0.36.1', 'libmpv-2.dll'),
        );
        expect((await repository.loadSelection()).active?.version, '0.36.1');
        expect((await repository.loadSelection()).pending, isNull);

        await stage('0.36.2', invalidLibrary: true);
        final recovered = await smoke('invalid-engine-recovery');
        expect(recovered['engineLibraryPath'], activated['engineLibraryPath']);
        expect((await repository.loadSelection()).pending, isNull);

        final updater = EngineUpdateService(
          repository: repository,
          currentVersion: '0.36.0',
        );
        try {
          await updater.initialize();
          expect(updater.canRollback, isTrue);
          await updater.scheduleRollback();
          final rolledBack = await smoke('bundled-rollback');
          expect(
            rolledBack['engineLibraryPath'],
            p.join(executable.parent.path, 'libmpv-2.dll'),
          );
        } finally {
          updater.dispose();
        }
      } finally {
        await seedDirectory.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('MPVSON_NATIVE_ENGINE_SMOKE'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
