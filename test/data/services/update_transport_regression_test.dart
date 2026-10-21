import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/repositories/engine_installation_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';

void main() {
  for (final compressedArtifact in [false, true]) {
    test(
      'accepts decoded gzip ${compressedArtifact ? 'bundles' : 'manifests'}',
      () async {
        final directory = await Directory.systemTemp.createTemp('update-gzip-');
        final artifact = utf8.encode('verified desktop bundle' * 40);
        final manifest = utf8.encode(
          jsonEncode({
            'schemaVersion': 1,
            'version': '0.2.0',
            'engineVersion': '0.41.0',
            'artifacts': {
              'windows': {
                'url': 'https://example.org/app.zip',
                'sha256': sha256.convert(artifact).toString(),
              },
            },
          }),
        );
        final client = MockClient.streaming((request, _) async {
          final isManifest = request.url.path == '/manifest.json';
          final bytes = isManifest ? manifest : artifact;
          final encoded = isManifest || compressedArtifact;
          // IOClient yields decoded bytes and retains the wire headers.
          return http.StreamedResponse(
            Stream.value(bytes),
            HttpStatus.ok,
            contentLength: encoded ? gzip.encode(bytes).length : bytes.length,
            headers: encoded ? {'content-encoding': 'gzip'} : {},
          );
        });
        final service = UpdateService(
          manifestUri: Uri.parse('https://example.org/manifest.json'),
          client: client,
          supportDirectoryProvider: () async => directory,
          platformProvider: () => UpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          client.close();
          await directory.delete(recursive: true);
        });

        await service.check();
        expect(service.status, 'available', reason: service.error);
        await service.download();
        expect(service.status, 'ready', reason: service.error);
        expect(await File(service.downloadPath!).readAsBytes(), artifact);
      },
    );
  }

  for (final wrongSize in [false, true]) {
    test(
      'gzip engine download ${wrongSize ? 'rejects a wrong decoded size' : 'verifies and stages decoded bytes'}',
      () async {
        final directory = await Directory.systemTemp.createTemp('engine-gzip-');
        final package = ZipEncoder().encode(
          Archive()..addFile(ArchiveFile('libmpv-2.dll', 4, [1, 2, 3, 4])),
        );
        final manifest = utf8.encode(
          jsonEncode({
            'schemaVersion': 1,
            'signature': base64Encode(List<int>.filled(64, 0)),
            'payload': {
              'engineVersion': '0.42.0',
              'mediaKitVersion': '1.2.6',
              'minimumAppVersion': '0.1.0',
              'artifacts': {
                'windows': {
                  'url': 'https://example.org/engine.zip',
                  'sha256': sha256.convert(package).toString(),
                  'size': package.length + (wrongSize ? 1 : 0),
                },
              },
            },
          }),
        );
        final client = MockClient.streaming((request, _) async {
          final bytes = request.url.path == '/manifest.json'
              ? manifest
              : package;
          return http.StreamedResponse(
            Stream.value(bytes),
            HttpStatus.ok,
            contentLength: gzip.encode(bytes).length,
            headers: {'content-encoding': 'gzip'},
          );
        });
        final repository = EngineInstallationRepository(
          enginesDirectory: directory,
        );
        final service = EngineUpdateService(
          manifestUri: Uri.parse('https://example.org/manifest.json'),
          client: client,
          repository: repository,
          signatureVerifier:
              ({
                required message,
                required signature,
                required publicKey,
              }) async => true,
          currentVersion: '0.41.0',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          client.close();
          await directory.delete(recursive: true);
        });

        await service.check();
        expect(service.status, 'available', reason: service.error);
        await service.downloadAndStage();
        if (wrongSize) {
          expect(service.status, 'error');
          expect(service.error, contains('size'));
          expect((await repository.loadSelection()).pending, isNull);
        } else {
          expect(service.status, 'readyToRestart', reason: service.error);
          expect((await repository.loadSelection()).pending?.version, '0.42.0');
        }
      },
    );
  }

  test(
    'disposal finishes a check waiting for response headers and cancels a late body',
    () async {
      final started = Completer<void>();
      final response = Completer<http.StreamedResponse>();
      final bodyCancelled = Completer<void>();
      final body = StreamController<List<int>>(
        onCancel: () {
          if (!bodyCancelled.isCompleted) bodyCancelled.complete();
        },
      );
      final client = MockClient.streaming((_, _) {
        started.complete();
        return response.future;
      });
      final service = UpdateService(
        manifestUri: Uri.parse('https://example.org/manifest.json'),
        client: client,
        requestTimeoutForTesting: const Duration(seconds: 2),
      );
      addTearDown(() async {
        service.dispose();
        if (!response.isCompleted) {
          response.complete(http.StreamedResponse(body.stream, HttpStatus.ok));
        }
        client.close();
        await body.close();
      });

      final check = service.check();
      await started.future;
      service.dispose();
      final finishedPromptly = await check
          .then((_) => true)
          .timeout(const Duration(milliseconds: 200), onTimeout: () => false);
      response.complete(http.StreamedResponse(body.stream, HttpStatus.ok));
      await check;
      await bodyCancelled.future.timeout(const Duration(seconds: 1));
      expect(finishedPromptly, isTrue);
      expect(service.error, isNull);
    },
  );
}
