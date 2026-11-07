import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mpvson/data/repositories/engine_installation_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/update_manifest.dart' show UpdatePlatform;
import 'package:mpvson/ui/player/views/update_status.dart';

/// Serves scripted bodies by URL so the updaters run their real state
/// machines without touching the network.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.routes);

  final Map<String, Object Function()> routes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final route = routes[request.url.toString()];
    if (route == null) {
      throw http.ClientException('No scripted response for ${request.url}');
    }
    final Object result = route();
    final bytes = result as List<int>;
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      contentLength: bytes.length,
    );
  }
}

Directory _tempDirectory(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A store lock may still be closing down on Windows.
    }
  });
  return dir;
}

const String _manifestUrl = 'https://updates.example.com/manifest.json';

String _appManifestBody(String bundleUrl, String sha256) => jsonEncode({
  'schemaVersion': 1,
  'version': '0.2.0',
  'engineVersion': '1.2.6',
  'artifacts': {
    'windows': {'url': bundleUrl, 'sha256': sha256},
  },
});

UpdateService _buildUpdateService(
  http.Client client,
  Directory supportDirectory, {
  Future<void> Function(String path)? opener,
}) {
  final service = UpdateService(
    manifestUri: Uri.parse(_manifestUrl),
    client: client,
    supportDirectoryProvider: () async => supportDirectory,
    platformProvider: () => UpdatePlatform.windows,
    currentVersion: '0.1.0',
    openDownloadLocationForTesting: opener,
    requestTimeoutForTesting: const Duration(seconds: 5),
    maxDownloadDurationForTesting: const Duration(minutes: 5),
  );
  addTearDown(service.dispose);
  return service;
}

const String _githubApiUrl =
    'https://api.github.com/repos/mpv-player/mpv/releases/latest';

String _githubStableBody(int size, String sha256) => jsonEncode({
  'tag_name': 'v0.40.1',
  'draft': false,
  'prerelease': false,
  'html_url': 'https://github.com/mpv-player/mpv/releases/tag/v0.40.1',
  'body': '',
  'assets': [
    {
      'name': 'libmpv-v0.40.1-x86_64-w64-mingw32-gpl.zip',
      'state': 'uploaded',
      'size': size,
      'digest': 'sha256:$sha256',
      'browser_download_url':
          'https://github.com/mpv-player/mpv/releases/download/v0.40.1/'
          'libmpv-v0.40.1-x86_64-w64-mingw32-gpl.zip',
    },
  ],
});

EngineUpdateService _buildEngineService(http.Client client, Directory store) {
  final service = EngineUpdateService(
    client: client,
    repository: EngineInstallationRepository(enginesDirectory: store),
    platformProvider: () => EngineUpdatePlatform.windows,
    appVersion: '0.1.0',
    supportedMediaKitVersion: '1.2.6',
    currentVersion: '0.0.0',
    requestTimeout: const Duration(seconds: 5),
    maxDownloadDuration: const Duration(minutes: 5),
  );
  addTearDown(service.dispose);
  return service;
}

void main() {
  test('a failed app update check reports the check failure kind', () async {
    final updates = _buildUpdateService(
      _ScriptedClient({}),
      _tempDirectory('mpvson-update-check-'),
    );

    await updates.check();

    expect(updates.status, 'error');
    expect(updates.failureKind, 'check');
    expect(updates.failedDuringDownload, isFalse);
    expect(updates.error, isNotNull);
  });

  test(
    'a failed app download reports the download kind and can be retried',
    () async {
      final bundle = utf8.encode('mpvson-test-bundle');
      final bundleSha = crypto.sha256.convert(bundle).toString();
      const bundleUrl = 'https://updates.example.com/mpvson-0.2.0.zip';
      var downloadAttempts = 0;
      final client = _ScriptedClient({
        _manifestUrl: () => utf8.encode(_appManifestBody(bundleUrl, bundleSha)),
        bundleUrl: () {
          downloadAttempts++;
          if (downloadAttempts == 1) {
            throw http.ClientException('connection reset');
          }
          return bundle;
        },
      });
      final updates = _buildUpdateService(
        client,
        _tempDirectory('mpvson-update-download-'),
      );

      await updates.check();
      expect(updates.status, 'available');

      await updates.download();
      expect(updates.status, 'error');
      expect(updates.failureKind, 'download');
      expect(updates.failedDuringDownload, isTrue);

      // The download error leaves the release selected, so retrying the
      // download must go straight back at it.
      await updates.download();
      expect(updates.status, 'ready');
      expect(updates.downloadPath, isNotNull);
      expect(updates.error, isNull);
      expect(downloadAttempts, 2);
    },
  );

  test(
    'a failed app apply step reports the apply kind, not the check kind',
    () async {
      final bundle = utf8.encode('mpvson-test-bundle');
      final bundleSha = crypto.sha256.convert(bundle).toString();
      const bundleUrl = 'https://updates.example.com/mpvson-0.2.0.zip';
      final client = _ScriptedClient({
        _manifestUrl: () => utf8.encode(_appManifestBody(bundleUrl, bundleSha)),
        bundleUrl: () => bundle,
      });
      final updates = _buildUpdateService(
        client,
        _tempDirectory('mpvson-update-apply-'),
        opener: (path) async {
          throw const FileSystemException('archive location is gone');
        },
      );

      await updates.check();
      await updates.download();
      expect(updates.status, 'ready');

      await updates.openDownload();

      expect(updates.status, 'error');
      expect(updates.failureKind, 'apply');
      expect(updates.failedDuringDownload, isFalse);
      expect(updates.error, isNotNull);
    },
  );

  test('a failed engine update check reports the check failure kind', () async {
    final engine = _buildEngineService(
      _ScriptedClient({}),
      _tempDirectory('mpvson-engine-check-'),
    );

    await engine.check();

    expect(engine.status, 'error');
    expect(engine.failureKind, 'check');
    expect(engine.failedDuringDownload, isFalse);
  });

  test(
    'a failed engine staging run reports the apply kind and can be retried',
    () async {
      // A valid download whose payload is not an archive: the staging step
      // fails while the download itself verified cleanly.
      final package = utf8.encode('this is definitely not a zip archive');
      final packageSha = crypto.sha256.convert(package).toString();
      var downloadAttempts = 0;
      final client = _ScriptedClient({
        _githubApiUrl: () =>
            utf8.encode(_githubStableBody(package.length, packageSha)),
        'https://github.com/mpv-player/mpv/releases/download/v0.40.1/'
            'libmpv-v0.40.1-x86_64-w64-mingw32-gpl.zip': () {
          downloadAttempts++;
          if (downloadAttempts > 1) {
            throw http.ClientException('connection reset');
          }
          return package;
        },
      });
      final engine = _buildEngineService(
        client,
        _tempDirectory('mpvson-engine-stage-'),
      );

      await engine.check();
      expect(engine.status, 'available');

      await engine.downloadAndStage();
      expect(engine.status, 'error');
      expect(engine.failureKind, 'apply');
      expect(engine.failedDuringDownload, isTrue);

      // The failed staging run kept the selected release, so retrying goes
      // straight back at the download instead of dead-ending in 'error'.
      await engine.downloadAndStage();
      expect(engine.status, 'error');
      expect(engine.failureKind, 'download');
      expect(downloadAttempts, 2);
    },
  );

  testWidgets('update status presentation labels each failure kind', (
    tester,
  ) async {
    final bundle = utf8.encode('mpvson-test-bundle');
    final bundleSha = crypto.sha256.convert(bundle).toString();
    const bundleUrl = 'https://updates.example.com/mpvson-0.2.0.zip';

    // Parking the services on real failures does real file I/O and starts
    // real timers, so it must run outside the test's fake async zone.
    late final UpdateService appCheckFailed;
    late final UpdateService appDownloadFailed;
    late final UpdateService appApplyFailed;
    late final EngineUpdateService engineCheckFailed;
    late final EngineUpdateService engineStagingFailed;
    await tester.runAsync(() async {
      // App service parked on a check failure.
      appCheckFailed = _buildUpdateService(
        _ScriptedClient({}),
        _tempDirectory('mpvson-map-check-'),
      );
      await appCheckFailed.check();

      // App service parked on a download failure.
      appDownloadFailed = _buildUpdateService(
        _ScriptedClient({
          _manifestUrl: () =>
              utf8.encode(_appManifestBody(bundleUrl, bundleSha)),
          bundleUrl: () => throw http.ClientException('connection reset'),
        }),
        _tempDirectory('mpvson-map-download-'),
      );
      await appDownloadFailed.check();
      await appDownloadFailed.download();

      // App service parked on an apply failure.
      appApplyFailed = _buildUpdateService(
        _ScriptedClient({
          _manifestUrl: () =>
              utf8.encode(_appManifestBody(bundleUrl, bundleSha)),
          bundleUrl: () => bundle,
        }),
        _tempDirectory('mpvson-map-apply-'),
        opener: (path) async {
          throw const FileSystemException('archive location is gone');
        },
      );
      await appApplyFailed.check();
      await appApplyFailed.download();
      await appApplyFailed.openDownload();

      // Engine service parked on a staging (apply) failure.
      final enginePackage = utf8.encode('this is definitely not a zip archive');
      final engineSha = crypto.sha256.convert(enginePackage).toString();
      engineCheckFailed = _buildEngineService(
        _ScriptedClient({}),
        _tempDirectory('mpvson-map-engine-check-'),
      );
      await engineCheckFailed.check();
      engineStagingFailed = _buildEngineService(
        _ScriptedClient({
          _githubApiUrl: () =>
              utf8.encode(_githubStableBody(enginePackage.length, engineSha)),
          'https://github.com/mpv-player/mpv/releases/download/v0.40.1/'
              'libmpv-v0.40.1-x86_64-w64-mingw32-gpl.zip': () =>
              enginePackage,
        }),
        _tempDirectory('mpvson-map-engine-stage-'),
      );
      await engineStagingFailed.check();
      await engineStagingFailed.downloadAndStage();
    });

    var labels = <String, String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            labels = {
              'appCheck': appUpdateStatusPresentation(
                context,
                appCheckFailed,
              ).$1,
              'appDownload': appUpdateStatusPresentation(
                context,
                appDownloadFailed,
              ).$1,
              'appApply': appUpdateStatusPresentation(
                context,
                appApplyFailed,
              ).$1,
              'engineCheck': engineUpdateStatusPresentation(
                context,
                engineCheckFailed,
              ).$1,
              'engineApply': engineUpdateStatusPresentation(
                context,
                engineStagingFailed,
              ).$1,
            };
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(labels['appCheck'], 'Check failed');
    expect(labels['appDownload'], 'Update failed');
    // The acceptance: an apply failure is no longer presented as a failed
    // update check.
    expect(labels['appApply'], 'Apply failed');
    expect(labels['engineCheck'], 'Check failed');
    expect(labels['engineApply'], 'Apply failed');
  });
}
