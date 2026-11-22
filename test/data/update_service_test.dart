import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/services/process_runner.dart';
import 'package:mpvson/data/services/update_applier.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';
import 'package:path/path.dart' as p;

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

    test(
      'falls back to direct latest update-manifest.json on GitHub API 403/429 rate limit',
      () async {
        final hash = sha256.convert(utf8.encode('setup-exe')).toString();
        for (final statusCode in <int>[403, 429]) {
          final client = MockClient((request) async {
            if (request.url.host == 'api.github.com') {
              return http.Response('rate limit exceeded', statusCode);
            }
            if (request.url.toString() ==
                'https://github.com/Amadoson3001/mpvson/releases/latest/download/update-manifest.json') {
              return http.Response(
                manifestJson(version: '0.2.0', sha256Hex: hash),
                200,
              );
            }
            return http.Response('unexpected ${request.url}', 500);
          });

          final service = UpdateService(
            client: client,
            platformProvider: () => UpdatePlatform.windows,
            installMode: AppInstallMode.windowsInstaller,
            currentVersion: '0.1.0',
          );
          addTearDown(service.dispose);

          await service.check();
          expect(service.status, 'available');
          expect(service.release?.version, '0.2.0');
          expect(service.release?.sha256, hash);
        }
      },
    );

    test(
      'preserves GitHub release body notes when manifest notes are generic',
      () async {
        final hash = sha256.convert(utf8.encode('setup-exe')).toString();
        final client = MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'tag_name': 'v0.2.0',
                'draft': false,
                'prerelease': false,
                'html_url':
                    'https://github.com/Amadoson3001/mpvson/releases/tag/v0.2.0',
                'body': '- Seamless auto-updater\n- Streaming fixes',
                'assets': <Map<String, Object?>>[
                  <String, Object?>{
                    'name': 'update-manifest.json',
                    'state': 'uploaded',
                    'browser_download_url':
                        'https://github.com/Amadoson3001/mpvson/releases/download/v0.2.0/update-manifest.json',
                  },
                  <String, Object?>{
                    'name': 'MpvsonSetup.exe',
                    'state': 'uploaded',
                    'digest': 'sha256:$hash',
                    'browser_download_url':
                        'https://github.com/Amadoson3001/mpvson/releases/download/v0.2.0/MpvsonSetup.exe',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'version': '0.2.0',
              'notes': 'Mpvson 0.2.0',
              'engineVersion': '0.42.0',
              'releaseUrl':
                  'https://github.com/Amadoson3001/mpvson/releases/tag/v0.2.0',
              'artifacts': <String, Object?>{
                'windows': <String, Object?>{
                  'url':
                      'https://github.com/Amadoson3001/mpvson/releases/download/v0.2.0/MpvsonSetup.exe',
                  'sha256': hash,
                },
                'linux': <String, Object?>{
                  'url':
                      'https://github.com/Amadoson3001/mpvson/releases/download/v0.2.0/mpvson-linux-x64.tar.gz',
                  'sha256': hash,
                },
              },
            }),
            200,
          );
        });

        final service = UpdateService(
          client: client,
          platformProvider: () => UpdatePlatform.windows,
          installMode: AppInstallMode.windowsInstaller,
          currentVersion: '0.1.0',
        );
        addTearDown(service.dispose);

        await service.check();
        expect(service.status, 'available');
        expect(
          service.release?.notes,
          '- Seamless auto-updater\n- Streaming fixes',
        );
      },
    );

    test(
      'downloadAndInstall launches silent Inno Setup installer and enters installing state',
      () async {
        final supportDir = await createSupportDir();
        final payload = utf8.encode('fake-installer-bytes');
        final hash = sha256.convert(payload).toString();
        final runner = _FakeProcessRunner();

        final client = MockClient((request) async {
          if (request.url.host == 'api.github.com') {
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
          installMode: AppInstallMode.windowsInstaller,
          isWindowsProvider: () => true,
          processRunner: runner,
          currentVersion: '0.1.0',
        );
        addTearDown(service.dispose);

        await service.check();
        expect(service.supportsAutoInstall, isTrue);

        final launched = await service.downloadAndInstall();
        expect(launched, isTrue);
        expect(service.status, 'installing');
        expect(runner.starts, hasLength(1));
        final call = runner.starts.single;
        expect(call.executable, service.downloadPath);
        expect(
          call.arguments,
          containsAllInOrder(<String>[
            '/SILENT',
            '/SP-',
            '/SUPPRESSMSGBOXES',
            '/NORESTART',
            '/NOCLOSEAPPLICATIONS',
            '/AUTOUPDATE=1',
          ]),
        );
        // A cancelled or stalled close must not be overridden by a forced
        // termination of the running player.
        expect(call.arguments, isNot(contains('/FORCECLOSEAPPLICATIONS')));
        expect(call.mode, ProcessStartMode.detached);
      },
    );

    test(
      'downloadAndInstall stages portable zip and launches PowerShell swapper',
      () async {
        final supportDir = await createSupportDir();
        final installDir = await createSupportDir();
        final exeFile = File(p.join(installDir.path, 'mpvson.exe'))
          ..writeAsStringSync('old-exe');
        final zipBytes = _buildTestZip(<String, List<int>>{
          ..._windowsBundleFixture(),
          'mpvson.exe': utf8.encode('new-exe'),
          'data/app.so': utf8.encode('new-app-so'),
        });
        final hash = sha256.convert(zipBytes).toString();
        final runner = _FakeProcessRunner();

        final client = MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              githubReleaseJson(
                tag: 'v0.2.0',
                assetName: 'mpvson-windows-x64.zip',
                digestHex: hash,
              ),
              200,
            );
          }
          return http.Response.bytes(
            zipBytes,
            200,
            headers: <String, String>{'content-length': '${zipBytes.length}'},
          );
        });

        final service = UpdateService(
          client: client,
          supportDirectoryProvider: () async => supportDir,
          platformProvider: () => UpdatePlatform.windows,
          installMode: AppInstallMode.windowsPortable,
          preferInstaller: false,
          isWindowsProvider: () => true,
          executablePathProvider: () => exeFile.path,
          processRunner: runner,
          currentVersion: '0.1.0',
        );
        addTearDown(service.dispose);

        await service.check();
        final launched = await service.downloadAndInstall();
        expect(launched, isTrue);
        expect(service.status, 'installing');
        expect(runner.starts, hasLength(1));
        final call = runner.starts.single;
        expect(call.executable, 'powershell.exe');
        expect(call.mode, ProcessStartMode.detached);
        expect(
          call.arguments,
          containsAll(<String>[
            '-WaitPid',
            '-StageDir',
            '-TargetDir',
            installDir.path,
            '-AppExe',
            exeFile.path,
            '-ErrorLog',
          ]),
        );
      },
    );

    test(
      'retry after failed download succeeds via downloadAndInstall',
      () async {
        final supportDir = await createSupportDir();
        final payload = utf8.encode('good-installer-bytes');
        final hash = sha256.convert(payload).toString();
        var attempt = 0;
        final runner = _FakeProcessRunner();

        final client = MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              githubReleaseJson(
                tag: 'v0.2.0',
                assetName: 'MpvsonSetup.exe',
                digestHex: hash,
              ),
              200,
            );
          }
          attempt++;
          if (attempt == 1) {
            return http.Response('server error', 502);
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
          installMode: AppInstallMode.windowsInstaller,
          isWindowsProvider: () => true,
          processRunner: runner,
          currentVersion: '0.1.0',
        );
        addTearDown(service.dispose);

        await service.check();
        expect(await service.downloadAndInstall(), isFalse);
        expect(service.status, 'error');
        expect(service.failedDuringDownload, isTrue);

        expect(await service.downloadAndInstall(), isTrue);
        expect(service.status, 'installing');
        expect(runner.starts, hasLength(1));
      },
    );
  });

  group('UpdateService guarded restart handoff', () {
    Future<UpdateService> stagedInstallerService(
      Directory supportDir,
      List<String> launched, {
      Future<void> Function(String path)? launcher,
      AppInstallMode mode = AppInstallMode.windowsInstaller,
    }) async {
      final payload = utf8.encode('installer-exe-bytes');
      final hash = sha256.convert(payload).toString();
      final client = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
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
        installMode: mode,
        isWindowsProvider: () => true,
        installerLauncher: launcher ?? (path) async => launched.add(path),
        currentVersion: '0.1.0',
      );
      addTearDown(service.dispose);
      await service.check();
      await service.download();
      if (mode == AppInstallMode.windowsInstaller) {
        expect(await service.prepareInstall(), isTrue);
      }
      return service;
    }

    test('a portable copy keeps an installer as a manual download', () async {
      final supportDir = await createSupportDir();
      final launched = <String>[];
      final service = await stagedInstallerService(
        supportDir,
        launched,
        mode: AppInstallMode.windowsPortable,
      );

      expect(service.status, 'ready');
      expect(service.supportsAutoInstall, isFalse);
      expect(service.canInstallDownloaded, isFalse);
      expect(service.requestRestart(), isFalse);
      expect(await service.launchPreparedInstall(), isFalse);
      expect(launched, isEmpty);
    });

    test(
      'cancelling a pending restart launches nothing and keeps the package',
      () async {
        final supportDir = await createSupportDir();
        final launched = <String>[];
        final service = await stagedInstallerService(supportDir, launched);

        service.requestRestart();
        expect(service.restartRequested, isTrue);
        service.cancelRestart();

        expect(service.restartRequested, isFalse);
        expect(await service.launchPreparedInstall(), isFalse);
        expect(launched, isEmpty);
        expect(service.status, 'ready');
        expect(service.installPrepared, isTrue);
      },
    );

    test(
      'a prepared install is launched only after the restart is armed',
      () async {
        final supportDir = await createSupportDir();
        final launched = <String>[];
        final service = await stagedInstallerService(supportDir, launched);

        expect(service.installPrepared, isTrue);
        expect(service.restartRequested, isFalse);
        expect(await service.launchPreparedInstall(), isFalse);
        expect(launched, isEmpty);

        service.requestRestart();
        expect(await service.launchPreparedInstall(), isTrue);
        expect(launched, <String>[service.downloadPath!]);
        expect(service.status, 'installing');
        expect(service.installPrepared, isFalse);
      },
    );

    test('a failed launch keeps the prepared package for retry', () async {
      final supportDir = await createSupportDir();
      final launched = <String>[];
      var fail = true;
      final service = await stagedInstallerService(
        supportDir,
        launched,
        launcher: (path) async {
          if (fail) throw const FileSystemException('Blocked by AV');
          launched.add(path);
        },
      );

      service.requestRestart();
      expect(await service.launchPreparedInstall(), isFalse);
      expect(service.status, 'error');
      expect(service.failureKind, 'apply');
      expect(service.installPrepared, isTrue);
      expect(service.restartRequested, isTrue);

      fail = false;
      expect(await service.launchPreparedInstall(), isTrue);
      expect(launched, <String>[service.downloadPath!]);
    });
  });

  group('UpdateApplier archive staging', () {
    test(
      'stageZipArchive extracts valid bundle and rejects traversal or missing exe',
      () async {
        final workDir = await createSupportDir();
        final validZip = File(p.join(workDir.path, 'valid.zip'))
          ..writeAsBytesSync(
            _buildTestZip(<String, List<int>>{..._windowsBundleFixture()}),
          );
        final stageDir = Directory(p.join(workDir.path, 'stage-valid'));
        await stageZipArchive(archiveFile: validZip, stagingDir: stageDir);
        expect(File(p.join(stageDir.path, 'mpvson.exe')).existsSync(), isTrue);
        expect(
          File(p.join(stageDir.path, 'data', 'icudtl.dat')).existsSync(),
          isTrue,
        );

        final traversalZip = File(p.join(workDir.path, 'evil.zip'))
          ..writeAsBytesSync(
            _buildTestZip(<String, List<int>>{
              '../evil.exe': utf8.encode('bad'),
            }),
          );
        await expectLater(
          stageZipArchive(
            archiveFile: traversalZip,
            stagingDir: Directory(p.join(workDir.path, 'stage-evil')),
          ),
          throwsFormatException,
        );

        final noExeZip = File(p.join(workDir.path, 'noexe.zip'))
          ..writeAsBytesSync(
            _buildTestZip(<String, List<int>>{'README.txt': utf8.encode('hi')}),
          );
        await expectLater(
          stageZipArchive(
            archiveFile: noExeZip,
            stagingDir: Directory(p.join(workDir.path, 'stage-noexe')),
          ),
          throwsFormatException,
        );
        final incompleteZip = File(p.join(workDir.path, 'incomplete.zip'))
          ..writeAsBytesSync(
            _buildTestZip({
              'mpvson.exe': [1],
            }),
          );
        await expectLater(
          stageZipArchive(
            archiveFile: incompleteZip,
            stagingDir: Directory(p.join(workDir.path, 'stage-incomplete')),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'stageTarGzArchive extracts valid Linux bundle with relative symlink and rejects escapes',
      () async {
        final workDir = await createSupportDir();
        final validTarGz = File(p.join(workDir.path, 'valid.tar.gz'))
          ..writeAsBytesSync(
            _buildTestTarGz(
              files: <String, List<int>>{
                './mpvson': utf8.encode('elf-bin'),
                './lib/libflutter_linux_gtk.so': [1],
                './data/icudtl.dat': [1],
                './dev.mpvson.mpvson.desktop': [1],
                './lib/libapp.so.1': utf8.encode('so-bytes'),
              },
              symlinks: <String, String>{'./lib/libapp.so': 'libapp.so.1'},
            ),
          );
        final stageDir = Directory(p.join(workDir.path, 'stage-linux'));
        await stageTarGzArchive(archiveFile: validTarGz, stagingDir: stageDir);
        expect(File(p.join(stageDir.path, 'mpvson')).existsSync(), isTrue);
        expect(
          File(p.join(stageDir.path, 'lib', 'libapp.so.1')).existsSync(),
          isTrue,
        );
        expect(
          Link(p.join(stageDir.path, 'lib', 'libapp.so')).existsSync(),
          isTrue,
        );

        final escapeTarGz = File(p.join(workDir.path, 'escape.tar.gz'))
          ..writeAsBytesSync(
            _buildTestTarGz(
              files: <String, List<int>>{'./mpvson': utf8.encode('elf-bin')},
              symlinks: <String, String>{'./lib/bad': '../../../etc/passwd'},
            ),
          );
        await expectLater(
          stageTarGzArchive(
            archiveFile: escapeTarGz,
            stagingDir: Directory(p.join(workDir.path, 'stage-escape')),
          ),
          throwsFormatException,
        );
      },
    );
  });
}

Map<String, List<int>> _windowsBundleFixture() => {
  'mpvson.exe': [1],
  'flutter_windows.dll': [1],
  'libmpv-2.dll': [1],
  'data/icudtl.dat': [1],
  'data/app.so': [1],
  'engine-provenance.json': [1],
};

List<int> _buildTestZip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

List<int> _buildTestTarGz({
  required Map<String, List<int>> files,
  Map<String, String> symlinks = const <String, String>{},
}) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  for (final link in symlinks.entries) {
    archive.addFile(ArchiveFile.symlink(link.key, link.value));
  }
  final tarBytes = TarEncoder().encode(archive);
  return GZipEncoder().encode(tarBytes);
}

final class _StartCall {
  const _StartCall({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.mode,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final ProcessStartMode mode;
}

final class _FakeProcessRunner extends ProcessRunner {
  final List<_StartCall> starts = <_StartCall>[];

  @override
  Future<ProcessExecutionResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
    Duration? timeout,
  }) async => const ProcessExecutionResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
    elapsed: Duration.zero,
  );

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    starts.add(
      _StartCall(
        executable: executable,
        arguments: List<String>.from(arguments),
        workingDirectory: workingDirectory,
        mode: mode,
      ),
    );
    return _FakeProcess();
  }
}

final class _FakeProcess implements Process {
  @override
  Future<int> get exitCode async => 0;

  @override
  int get pid => 12345;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
