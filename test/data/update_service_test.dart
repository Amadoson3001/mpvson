import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';

void main() {
  Future<Directory> createSupportDir() async {
    final dir = await Directory.systemTemp.createTemp('mpvson-update-svc-');
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
    return dir;
  }

  String manifestJson({required String version, required String sha256Hex}) =>
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'version': version,
        'notes': 'Release $version',
        'engineVersion': '0.42.0',
        'releaseUrl': 'https://example.org/releases/$version',
        'artifacts': <String, Object?>{
          'windows': <String, Object?>{
            'url': 'https://example.org/downloads/mpvson-$version.zip',
            'sha256': sha256Hex,
          },
          'linux': <String, Object?>{
            'url': 'https://example.org/downloads/mpvson-$version.tar.gz',
            'sha256': sha256Hex,
          },
        },
      });

  String githubReleaseJson({
    required String tag,
    required String assetName,
    String? digestHex,
    bool includeChecksums = false,
  }) => jsonEncode(<String, Object?>{
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'html_url': 'https://github.com/Amadoson3001/mpvson/releases/tag/$tag',
    'body': 'Release notes for $tag',
    'assets': <Map<String, Object?>>[
      <String, Object?>{
        'name': assetName,
        'state': 'uploaded',
        if (digestHex != null) 'digest': 'sha256:$digestHex',
        'browser_download_url':
            'https://github.com/Amadoson3001/mpvson/releases/download/$tag/$assetName',
      },
      if (includeChecksums)
        <String, Object?>{
          'name': 'SHA256SUMS',
          'state': 'uploaded',
          'browser_download_url':
              'https://github.com/Amadoson3001/mpvson/releases/download/$tag/SHA256SUMS',
        },
    ],
  });

  group('UpdateService', () {
    test(
      'reports unconfigured only when both manifest and GitHub are disabled',
      () async {
        final service = UpdateService(
          useGitHubReleases: false,
          platformProvider: () => UpdatePlatform.windows,
        );
        addTearDown(service.dispose);

        expect(service.configured, isFalse);
        expect(service.status, 'unconfigured');
        await service.check();
        expect(service.status, 'unconfigured');
      },
    );

    test(
      'uses official GitHub Releases by default and verifies installer launch',
      () async {
        final supportDir = await createSupportDir();
        final payload = utf8.encode('fake-installer-exe-bytes');
        final hash = sha256.convert(payload).toString();
        final launchedPaths = <String>[];

        final client = MockClient((request) async {
          if (request.url.toString() ==
              'https://api.github.com/repos/Amadoson3001/mpvson/releases/latest') {
            return http.Response(
              githubReleaseJson(
                tag: 'v0.2.0',
                assetName: 'MpvsonSetup.exe',
                digestHex: hash,
              ),
              200,
            );
          }
          return http.Response.bytes(
            payload,
            200,
            headers: <String, String>{'content-length': '${payload.length}'},
          );
        });

        final service = UpdateService(
          client: client,
          supportDirectoryProvider: () async => supportDir,
          platformProvider: () => UpdatePlatform.windows,
          preferInstaller: true,
          isWindowsProvider: () => true,
          installerLauncher: (path) async => launchedPaths.add(path),
          currentVersion: '0.1.0',
        );
        addTearDown(service.dispose);

        expect(service.configured, isTrue);
        expect(service.usesOfficialGitHubSource, isTrue);

        await service.check();
        expect(service.status, 'available');
        expect(service.release?.version, '0.2.0');

        await service.download();
        expect(service.status, 'ready');
        expect(service.canLaunchInstaller, isTrue);

        final launched = await service.launchInstaller();
        expect(launched, isTrue);
        expect(launchedPaths, <String>[service.downloadPath!]);
      },
    );

    test(
      'GitHub release resolves SHA-256 from SHA256SUMS when digest is omitted',
      () async {
        final payload = utf8.encode('portable-zip-bytes');
        final hash = sha256.convert(payload).toString();
        final client = MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              githubReleaseJson(
                tag: 'v0.3.0',
                assetName: 'mpvson-windows-x64.zip',
                includeChecksums: true,
              ),
              200,
            );
          }
          return http.Response('$hash  mpvson-windows-x64.zip\n', 200);
        });

        final service = UpdateService(
          client: client,
          platformProvider: () => UpdatePlatform.windows,
          preferInstaller: false,
          currentVersion: '0.1.0',
        );
        addTearDown(service.dispose);

        await service.check();
        expect(service.status, 'available');
        expect(service.release?.sha256, hash);
      },
    );

    test('silent check keeps idle status on offline/HTTP failure', () async {
      final client = MockClient((_) async => http.Response('Not Found', 404));
      final service = UpdateService(
        client: client,
        platformProvider: () => UpdatePlatform.windows,
        currentVersion: '0.1.0',
      );
      addTearDown(service.dispose);

      await service.check(silent: true);
      expect(service.status, 'idle');
      expect(service.error, isNull);

      await service.check(silent: false);
      expect(service.status, 'error');
      expect(service.error, isNotNull);
    });

    test(
      'reports upToDate when remote version matches currentVersion',
      () async {
        final hash = sha256.convert(utf8.encode('payload')).toString();
        final client = MockClient((request) async {
          return http.Response(
            manifestJson(version: '0.1.0', sha256Hex: hash),
            200,
          );
        });
        final service = UpdateService(
          manifestUri: Uri.parse('https://example.org/manifest.json'),
          client: client,
          currentVersion: '0.1.0',
          platformProvider: () => UpdatePlatform.windows,
        );
        addTearDown(service.dispose);

        await service.check();
        expect(service.status, 'upToDate');
        expect(service.release?.version, '0.1.0');
      },
    );

    test('checks, downloads, and verifies a newer release bundle', () async {
      final supportDir = await createSupportDir();
      final payload = utf8.encode('verified-release-archive-bytes');
      final hash = sha256.convert(payload).toString();
      final client = MockClient((request) async {
        if (request.url.path == '/manifest.json') {
          return http.Response(
            manifestJson(version: '0.2.0', sha256Hex: hash),
            200,
          );
        }
        return http.Response.bytes(
          payload,
          200,
          headers: <String, String>{'content-length': '${payload.length}'},
        );
      });

      final service = UpdateService(
        manifestUri: Uri.parse('https://example.org/manifest.json'),
        client: client,
        supportDirectoryProvider: () async => supportDir,
        platformProvider: () => UpdatePlatform.windows,
        currentVersion: '0.1.0',
      );
      addTearDown(service.dispose);

      await service.check();
      expect(service.status, 'available');
      expect(service.release?.version, '0.2.0');

      await service.download();
      expect(service.status, 'ready');
      expect(service.progress, 1.0);
      expect(service.downloadPath, isNotNull);
      expect(File(service.downloadPath!).readAsBytesSync(), payload);
    });

    test('rejects downloaded bundle when SHA-256 does not match', () async {
      final supportDir = await createSupportDir();
      final expectedHash = sha256.convert(utf8.encode('good')).toString();
      final client = MockClient((request) async {
        if (request.url.path == '/manifest.json') {
          return http.Response(
            manifestJson(version: '0.2.0', sha256Hex: expectedHash),
            200,
          );
        }
        final badBytes = utf8.encode('tampered');
        return http.Response.bytes(
          badBytes,
          200,
          headers: <String, String>{'content-length': '${badBytes.length}'},
        );
      });

      final service = UpdateService(
        manifestUri: Uri.parse('https://example.org/manifest.json'),
        client: client,
        supportDirectoryProvider: () async => supportDir,
        platformProvider: () => UpdatePlatform.windows,
        currentVersion: '0.1.0',
      );
      addTearDown(service.dispose);

      await service.check();
      await service.download();

      expect(service.status, 'error');
      expect(service.failedDuringDownload, isTrue);
      expect(service.error, contains('SHA-256'));
      expect(service.downloadPath, isNull);
    });
  });
}
