import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/semantic_version.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';
import 'package:path/path.dart' as p;

void main() {
  group('SemanticVersion', () {
    test('compares prereleases using SemVer precedence', () {
      const ordered = <String>[
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      for (var index = 0; index < ordered.length - 1; index++) {
        expect(
          SemanticVersion.parse(
            ordered[index],
          ).compareTo(SemanticVersion.parse(ordered[index + 1])),
          lessThan(0),
          reason: '${ordered[index]} should come before ${ordered[index + 1]}',
        );
      }
    });

    test('ignores build metadata and rejects leading zeroes', () {
      expect(
        SemanticVersion.parse(
          '2.1.3+build.4',
        ).compareTo(SemanticVersion.parse('2.1.3+other')),
        0,
      );
      expect(() => SemanticVersion.parse('01.2.3'), throwsFormatException);
      expect(() => SemanticVersion.parse('1.2.3-rc.01'), throwsFormatException);
    });
  });

  group('UpdateManifest', () {
    test('selects the artifact for the requested target', () {
      final manifest = UpdateManifest.parse(
        jsonEncode(_manifest()),
        platform: UpdatePlatform.linux,
      );
      expect(manifest.release.downloadUri.path, '/app-linux.tar.gz');
      expect(manifest.release.sha256, _repeat('a', 64));

      final windows = UpdateManifest.parse(
        jsonEncode(_manifest()),
        platform: UpdatePlatform.windows,
      );
      expect(windows.release.downloadUri.path, '/app-windows.zip');
    });

    test('rejects malformed schema, target, URL, version, and digest', () {
      final cases = <Map<String, Object?>>[];
      final badSchema = _manifest()..['schemaVersion'] = 2;
      cases.add(badSchema);
      final missingLinux = _manifest()..['artifacts'] = <String, Object?>{};
      cases.add(missingLinux);
      final badVersion = _manifest()..['version'] = '1.02.0';
      cases.add(badVersion);
      final badHash = _manifest();
      (badHash['artifacts']! as Map<String, Object?>)['linux'] =
          <String, Object?>{'url': 'https://example.org/app', 'sha256': 'xyz'};
      cases.add(badHash);
      final insecure = _manifest();
      (insecure['artifacts']!
          as Map<String, Object?>)['linux'] = <String, Object?>{
        'url': 'http://example.org/app',
        'sha256': _repeat('a', 64),
      };
      cases.add(insecure);

      for (final malformed in cases) {
        expect(
          () => UpdateManifest.parse(
            jsonEncode(malformed),
            platform: UpdatePlatform.linux,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => UpdateManifest.parse('{', platform: UpdatePlatform.linux),
        throwsFormatException,
      );
    });

    test('rejects a non-SemVer engine version', () {
      final malformed = _manifest()..['engineVersion'] = 'latest';
      expect(
        () => UpdateManifest.parse(
          jsonEncode(malformed),
          platform: UpdatePlatform.windows,
        ),
        throwsFormatException,
      );
    });
  });

  group('UpdateService', () {
    late Directory supportDirectory;
    final clients = <http.Client>[];
    final services = <UpdateService>[];

    setUp(() async {
      supportDirectory = await Directory.systemTemp.createTemp(
        'mpvson-update-test-',
      );
    });

    tearDown(() async {
      for (final service in services) {
        service.dispose();
      }
      services.clear();
      for (final client in clients) {
        client.close();
      }
      clients.clear();
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });

    test(
      'reports a readable unconfigured state without making a request',
      () async {
        final client = MockClient((_) async {
          fail('An unconfigured service must not make HTTP requests.');
        });
        clients.add(client);
        final service = UpdateService(client: client);
        services.add(service);

        expect(service.configured, isFalse);
        expect(service.status, 'unconfigured');
        await service.check();
        expect(service.status, 'unconfigured');
        expect(service.error, isNull);
      },
    );

    test('downloads, verifies, and opens only the verified archive', () async {
      final manifestUri = Uri.parse('https://example.org/update.json');
      final artifactUri = Uri.parse('https://example.org/app-linux.tar.gz');
      final artifactBytes = utf8.encode('whole desktop bundle');
      final artifactHash = sha256.convert(artifactBytes).toString();
      var openedPath = '';
      final client = MockClient((request) async {
        if (request.url == manifestUri) {
          return http.Response(
            jsonEncode(_manifest(hash: artifactHash)),
            HttpStatus.ok,
          );
        }
        if (request.url == artifactUri) {
          return http.Response.bytes(artifactBytes, HttpStatus.ok);
        }
        return http.Response('', HttpStatus.notFound);
      });
      clients.add(client);
      final service = UpdateService(
        manifestUri: manifestUri,
        client: client,
        supportDirectoryProvider: () async => supportDirectory,
        platformProvider: () => UpdatePlatform.linux,
        openDownloadLocationForTesting: (path) async => openedPath = path,
      );
      services.add(service);

      await service.check();
      expect(service.status, 'available');
      expect(service.release?.downloadUri, artifactUri);
      await service.download();

      expect(service.status, 'ready');
      expect(service.progress, 1);
      final path = service.downloadPath;
      expect(path, isNotNull);
      final verifiedPath = path!;
      expect(verifiedPath, endsWith('.tar.gz'));
      expect(await File(verifiedPath).readAsBytes(), artifactBytes);
      await service.openDownload();
      expect(openedPath, verifiedPath);
      expect(service.status, 'ready');
    });

    test(
      'removes the private partial artifact after an integrity failure',
      () async {
        final manifestUri = Uri.parse('https://example.org/update.json');
        final artifactUri = Uri.parse('https://example.org/app-linux.tar.gz');
        final client = MockClient((request) async {
          if (request.url == manifestUri) {
            return http.Response(
              jsonEncode(_manifest(hash: _repeat('0', 64))),
              HttpStatus.ok,
            );
          }
          if (request.url == artifactUri) {
            return http.Response.bytes(
              utf8.encode('corrupted bundle'),
              HttpStatus.ok,
            );
          }
          return http.Response('', HttpStatus.notFound);
        });
        clients.add(client);
        final service = UpdateService(
          manifestUri: manifestUri,
          client: client,
          supportDirectoryProvider: () async => supportDirectory,
          platformProvider: () => UpdatePlatform.linux,
        );
        services.add(service);

        await service.check();
        await service.download();

        expect(service.status, 'error');
        expect(service.error, contains('SHA-256'));
        expect(service.downloadPath, isNull);
        final files = await Directory(
          '${supportDirectory.path}${Platform.pathSeparator}updates',
        ).list().toList();
        expect(files.whereType<File>(), isEmpty);
      },
    );

    test('rejects an HTTPS manifest redirect to HTTP', () async {
      final manifestUri = Uri.parse('https://example.org/update.json');
      final client = MockClient((request) async {
        expect(request.url, manifestUri);
        return http.Response(
          '',
          HttpStatus.found,
          headers: {'location': 'http://attacker.example/update.json'},
        );
      });
      clients.add(client);
      final service = UpdateService(manifestUri: manifestUri, client: client);
      services.add(service);

      await service.check();

      expect(service.status, 'error');
      expect(service.error, contains('HTTPS'));
    });

    test(
      'rejects a configured HTTP manifest URL before contacting the host',
      () async {
        final client = MockClient((_) async {
          fail('An insecure manifest URL must not be requested.');
        });
        clients.add(client);
        final service = UpdateService(
          manifestUri: Uri.parse('http://example.org/update.json'),
          client: client,
        );
        services.add(service);

        await service.check();

        expect(service.status, 'error');
        expect(service.error, contains('HTTPS'));
      },
    );

    test(
      'cancels active request and removes partial download on stream timeout',
      () async {
        final manifestUri = Uri.parse('https://example.org/update.json');
        final artifactUri = Uri.parse('https://example.org/app-linux.tar.gz');
        final streamController = StreamController<List<int>>();
        http.BaseRequest? capturedRequest;

        final client = MockClient.streaming((request, bodyStream) async {
          if (request.url == manifestUri) {
            return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode(_manifest()))),
              HttpStatus.ok,
            );
          }
          if (request.url == artifactUri) {
            capturedRequest = request;
            return http.StreamedResponse(
              streamController.stream,
              HttpStatus.ok,
              contentLength: 100,
            );
          }
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.notFound,
          );
        });
        clients.add(client);

        final service = UpdateService(
          manifestUri: manifestUri,
          client: client,
          supportDirectoryProvider: () async => supportDirectory,
          platformProvider: () => UpdatePlatform.linux,
          requestTimeoutForTesting: const Duration(milliseconds: 50),
        );
        services.add(service);

        await service.check();
        expect(service.status, 'available');

        final downloadFuture = service.download();
        streamController.add(utf8.encode('partial data'));

        await downloadFuture;
        expect(service.status, 'error');
        expect(service.error, contains('timed out'));

        expect(capturedRequest, isA<http.AbortableRequest>());
        final abortable = capturedRequest as http.AbortableRequest;
        expect(abortable.abortTrigger, completes);

        final updatesDir = Directory(p.join(supportDirectory.path, 'updates'));
        final files = await updatesDir.list().toList();
        final partFiles = files.where((f) => f.path.endsWith('.part'));
        expect(partFiles, isEmpty);

        await streamController.close();
      },
    );

    test(
      'aborts in-flight request, cancels stream, and deletes partial file on disposal',
      () async {
        final manifestUri = Uri.parse('https://example.org/update.json');
        final artifactUri = Uri.parse('https://example.org/app-linux.tar.gz');
        final streamController = StreamController<List<int>>();
        http.BaseRequest? capturedRequest;

        final client = MockClient.streaming((request, bodyStream) async {
          if (request.url == manifestUri) {
            return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode(_manifest()))),
              HttpStatus.ok,
            );
          }
          if (request.url == artifactUri) {
            capturedRequest = request;
            return http.StreamedResponse(
              streamController.stream,
              HttpStatus.ok,
              contentLength: 1000,
            );
          }
          return http.StreamedResponse(
            const Stream.empty(),
            HttpStatus.notFound,
          );
        });
        clients.add(client);

        final service = UpdateService(
          manifestUri: manifestUri,
          client: client,
          supportDirectoryProvider: () async => supportDirectory,
          platformProvider: () => UpdatePlatform.linux,
          requestTimeoutForTesting: const Duration(seconds: 10),
        );
        services.add(service);

        await service.check();
        expect(service.status, 'available');

        final downloadFuture = service.download();
        streamController.add(utf8.encode('part1'));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final updatesDir = Directory(p.join(supportDirectory.path, 'updates'));
        final filesBefore = await updatesDir.list().toList();
        expect(filesBefore.any((f) => f.path.endsWith('.part')), isTrue);

        expect(capturedRequest, isA<http.AbortableRequest>());
        final abortable = capturedRequest as http.AbortableRequest;

        service.dispose();
        expect(abortable.abortTrigger, completes);

        await downloadFuture;
        expect(service.status, isNot('ready'));

        final filesAfter = await updatesDir.list().toList();
        expect(filesAfter.where((f) => f.path.endsWith('.part')), isEmpty);
        expect(filesAfter.where((f) => f.path.endsWith('.tar.gz')), isEmpty);

        await streamController.close();
      },
    );

    test(
      'persists ownership records in updates.json and reuses matching cached bundle',
      () async {
        final manifestUri = Uri.parse('https://example.org/update.json');
        final artifactUri = Uri.parse('https://example.org/app-linux.tar.gz');
        final artifactBytes = utf8.encode('verified desktop binary bundle');
        final artifactHash = sha256.convert(artifactBytes).toString();
        var downloadRequestCount = 0;

        final client = MockClient((request) async {
          if (request.url == manifestUri) {
            return http.Response(
              jsonEncode(_manifest(hash: artifactHash)),
              HttpStatus.ok,
            );
          }
          if (request.url == artifactUri) {
            downloadRequestCount++;
            return http.Response.bytes(artifactBytes, HttpStatus.ok);
          }
          return http.Response('', HttpStatus.notFound);
        });
        clients.add(client);

        final service1 = UpdateService(
          manifestUri: manifestUri,
          client: client,
          supportDirectoryProvider: () async => supportDirectory,
          platformProvider: () => UpdatePlatform.linux,
        );
        services.add(service1);

        await service1.check();
        await service1.download();
        expect(service1.status, 'ready');
        final downloadedPath = service1.downloadPath;
        expect(downloadedPath, isNotNull);
        expect(downloadRequestCount, 1);

        final updatesRecordFile = File(
          p.join(supportDirectory.path, 'updates', 'updates.json'),
        );
        expect(await updatesRecordFile.exists(), isTrue);
        final recordJson = jsonDecode(await updatesRecordFile.readAsString());
        expect(recordJson['version'], 1);
        final records = recordJson['records'] as List<dynamic>;
        expect(records.length, 1);
        expect(records.first['version'], '0.2.0');
        expect(records.first['sha256'], artifactHash);
        expect(records.first['fileSizeBytes'], artifactBytes.length);

        final noDownloadClient = MockClient((request) async {
          if (request.url == manifestUri) {
            return http.Response(
              jsonEncode(_manifest(hash: artifactHash)),
              HttpStatus.ok,
            );
          }
          fail(
            'Should not request artifact when a verified cached bundle exists.',
          );
        });
        clients.add(noDownloadClient);

        final service2 = UpdateService(
          manifestUri: manifestUri,
          client: noDownloadClient,
          supportDirectoryProvider: () async => supportDirectory,
          platformProvider: () => UpdatePlatform.linux,
        );
        services.add(service2);

        await service2.check();
        expect(service2.status, 'available');

        await service2.download();
        expect(service2.status, 'ready');
        expect(service2.downloadPath, downloadedPath);
        expect(downloadRequestCount, 1);
      },
    );

    test(
      'retains only current and previous verified archive and preserves unrelated files',
      () async {
        final manifestUri = Uri.parse('https://example.org/update.json');
        final bytesV1 = utf8.encode('version 0.2.0 bundle');
        final hashV1 = sha256.convert(bytesV1).toString();
        final bytesV2 = utf8.encode('version 0.3.0 bundle');
        final hashV2 = sha256.convert(bytesV2).toString();
        final bytesV3 = utf8.encode('version 0.4.0 bundle');
        final hashV3 = sha256.convert(bytesV3).toString();

        var currentManifestVersion = '0.2.0';
        var currentManifestHash = hashV1;
        var currentArtifactUri = Uri.parse(
          'https://example.org/app-0.2.0.tar.gz',
        );

        final client = MockClient((request) async {
          if (request.url == manifestUri) {
            return http.Response(
              jsonEncode(
                _manifest(
                  version: currentManifestVersion,
                  hash: currentManifestHash,
                  artifactUrl: currentArtifactUri.toString(),
                ),
              ),
              HttpStatus.ok,
            );
          }
          if (request.url ==
              Uri.parse('https://example.org/app-0.2.0.tar.gz')) {
            return http.Response.bytes(bytesV1, HttpStatus.ok);
          }
          if (request.url ==
              Uri.parse('https://example.org/app-0.3.0.tar.gz')) {
            return http.Response.bytes(bytesV2, HttpStatus.ok);
          }
          if (request.url ==
              Uri.parse('https://example.org/app-0.4.0.tar.gz')) {
            return http.Response.bytes(bytesV3, HttpStatus.ok);
          }
          return http.Response('', HttpStatus.notFound);
        });
        clients.add(client);

        final service = UpdateService(
          manifestUri: manifestUri,
          client: client,
          supportDirectoryProvider: () async => supportDirectory,
          platformProvider: () => UpdatePlatform.linux,
        );
        services.add(service);

        // Download V1
        await service.check();
        await service.download();
        final pathV1 = service.downloadPath!;
        expect(await File(pathV1).exists(), isTrue);

        // Download V2
        currentManifestVersion = '0.3.0';
        currentManifestHash = hashV2;
        currentArtifactUri = Uri.parse('https://example.org/app-0.3.0.tar.gz');
        await service.check();
        await service.download();
        final pathV2 = service.downloadPath!;
        expect(await File(pathV2).exists(), isTrue);
        expect(await File(pathV1).exists(), isTrue);

        // Create unrelated files in updates directory
        final updatesDir = Directory(p.join(supportDirectory.path, 'updates'));
        final unrelatedFile = File(p.join(updatesDir.path, 'unrelated.txt'));
        await unrelatedFile.writeAsString('important user notes');
        final unrelatedSubDir = Directory(
          p.join(updatesDir.path, 'custom_sub'),
        );
        await unrelatedSubDir.create();
        final unrelatedSubFile = File(p.join(unrelatedSubDir.path, 'data.bin'));
        await unrelatedSubFile.writeAsBytes([9, 8, 7]);

        // Download V3
        currentManifestVersion = '0.4.0';
        currentManifestHash = hashV3;
        currentArtifactUri = Uri.parse('https://example.org/app-0.4.0.tar.gz');
        await service.check();
        await service.download();
        final pathV3 = service.downloadPath!;
        expect(await File(pathV3).exists(), isTrue);

        // Archive retention: Current (V3) and previous (V2) retained; V1 pruned
        expect(await File(pathV1).exists(), isFalse);
        expect(await File(pathV2).exists(), isTrue);
        expect(await File(pathV3).exists(), isTrue);

        // Unrelated files remain completely intact
        expect(await unrelatedFile.exists(), isTrue);
        expect(await unrelatedFile.readAsString(), 'important user notes');
        expect(await unrelatedSubFile.exists(), isTrue);

        // Verify updates.json records only V2 and V3
        final updatesRecordFile = File(p.join(updatesDir.path, 'updates.json'));
        final recordJson = jsonDecode(await updatesRecordFile.readAsString());
        final records = (recordJson['records'] as List<dynamic>)
            .map((r) => r['version'])
            .toList();
        expect(records, containsAll(['0.3.0', '0.4.0']));
        expect(records, isNot(contains('0.2.0')));
      },
    );

    test(
      'leaves modified tracked files intact during pruning safety check',
      () async {
        final manifestUri = Uri.parse('https://example.org/update.json');
        final bytesV1 = utf8.encode('version 0.2.0 bundle');
        final hashV1 = sha256.convert(bytesV1).toString();
        final bytesV2 = utf8.encode('version 0.3.0 bundle');
        final hashV2 = sha256.convert(bytesV2).toString();
        final bytesV3 = utf8.encode('version 0.4.0 bundle');
        final hashV3 = sha256.convert(bytesV3).toString();

        var currentManifestVersion = '0.2.0';
        var currentManifestHash = hashV1;
        var currentArtifactUri = Uri.parse(
          'https://example.org/app-0.2.0.tar.gz',
        );

        final client = MockClient((request) async {
          if (request.url == manifestUri) {
            return http.Response(
              jsonEncode(
                _manifest(
                  version: currentManifestVersion,
                  hash: currentManifestHash,
                  artifactUrl: currentArtifactUri.toString(),
                ),
              ),
              HttpStatus.ok,
            );
          }
          if (request.url ==
              Uri.parse('https://example.org/app-0.2.0.tar.gz')) {
            return http.Response.bytes(bytesV1, HttpStatus.ok);
          }
          if (request.url ==
              Uri.parse('https://example.org/app-0.3.0.tar.gz')) {
            return http.Response.bytes(bytesV2, HttpStatus.ok);
          }
          if (request.url ==
              Uri.parse('https://example.org/app-0.4.0.tar.gz')) {
            return http.Response.bytes(bytesV3, HttpStatus.ok);
          }
          return http.Response('', HttpStatus.notFound);
        });
        clients.add(client);

        final service = UpdateService(
          manifestUri: manifestUri,
          client: client,
          supportDirectoryProvider: () async => supportDirectory,
          platformProvider: () => UpdatePlatform.linux,
        );
        services.add(service);

        // Download V1 and V2
        await service.check();
        await service.download();
        final pathV1 = service.downloadPath!;

        currentManifestVersion = '0.3.0';
        currentManifestHash = hashV2;
        currentArtifactUri = Uri.parse('https://example.org/app-0.3.0.tar.gz');
        await service.check();
        await service.download();

        // Tamper with V1 file on disk
        await File(pathV1).writeAsString('tampered content');

        // Download V3 (which would normally prune V1)
        currentManifestVersion = '0.4.0';
        currentManifestHash = hashV3;
        currentArtifactUri = Uri.parse('https://example.org/app-0.4.0.tar.gz');
        await service.check();
        await service.download();

        // Safety check: V1 was modified, so it must NOT be deleted
        expect(await File(pathV1).exists(), isTrue);
        expect(await File(pathV1).readAsString(), 'tampered content');
      },
    );
  });
}

Map<String, Object?> _manifest({
  String? hash,
  String version = '0.2.0',
  String? artifactUrl,
}) {
  final artifactHash = hash ?? _repeat('a', 64);
  final url = artifactUrl ?? 'https://example.org/app-linux.tar.gz';
  return <String, Object?>{
    'schemaVersion': 1,
    'version': version,
    'notes': 'Test release',
    'engineVersion': '0.40.0',
    'releaseUrl': 'https://example.org/releases/$version',
    'artifacts': <String, Object?>{
      'windows': <String, Object?>{
        'url': 'https://example.org/app-windows.zip',
        'sha256': artifactHash,
      },
      'linux': <String, Object?>{'url': url, 'sha256': artifactHash},
    },
  };
}

String _repeat(String value, int count) => List.filled(count, value).join();
