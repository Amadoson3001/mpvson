import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:mpvson/data/repositories/engine_installation_repository.dart';
import 'package:mpvson/data/repositories/engine_update_preferences_repository.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/domain/updates/engine_selection.dart';
import 'package:mpvson/domain/updates/engine_update_channel.dart';
import 'package:mpvson/domain/updates/mpv_github_release.dart';

void main() {
  group('EngineUpdateService', () {
    test(
      'development channel is an explicit opt-in and verifies/stages its ZIP',
      () async {
        final package = _makePackage();
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-github-test-',
        );
        final client = _GithubClient(
          release: _githubReleaseJson(package: package),
          package: package,
        );
        final service = EngineUpdateService(
          client: client,
          repository: _repository(temp),
          preferencesRepository: EngineUpdatePreferencesRepository(
            storageDirectory: Directory(p.join(temp.path, 'updates')),
          ),
          currentVersion: '0.40.0',
          appVersion: '1.0.0',
          supportedMediaKitVersion: '1.2.6',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        expect(service.configured, isTrue);
        expect(service.usesOfficialMpvSource, isTrue);
        expect(service.channel, EngineUpdateChannel.stable);
        expect(service.sourceLabel, MpvGithubRelease.stableSourceLabel);
        expect(service.status, 'idle');
        expect(
          await service.setChannel(EngineUpdateChannel.development),
          isTrue,
        );
        expect(service.sourceLabel, MpvGithubRelease.sourceLabel);

        await service.check();

        expect(service.status, 'available');
        expect(
          service.release?.engineVersion,
          '0.41.0-dev.39050261656+g01e2533f3',
        );
        expect(
          service.release?.sha256,
          crypto.sha256.convert(package).toString(),
        );
        expect(client.apiRequestCount, 1);
        expect(client.apiHeaders?['Accept'], 'application/vnd.github+json');
        expect(client.apiHeaders?['User-Agent'], 'Mpvson/1.0.0');

        await service.downloadAndStage();

        expect(service.status, 'readyToRestart');
        expect(service.pendingVersion, '0.41.0-dev.39050261656+g01e2533f3');
        expect(client.downloadRequestCount, 1);
      },
    );

    test(
      'defaults to stable and reports a missing stable engine asset',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-stable-test-',
        );
        final client = _GithubClient(
          release: '{}',
          stableRelease: _githubStableReleaseJson(assets: const []),
          package: const <int>[],
        );
        final service = EngineUpdateService(
          client: client,
          repository: _repository(temp),
          currentVersion: '0.41.0-dev.39086651352+gfffe7a23a',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        expect(service.channel, EngineUpdateChannel.stable);
        expect(service.sourceLabel, MpvGithubRelease.stableSourceLabel);

        await service.check();

        expect(service.status, 'stableUnavailable');
        expect(service.error, isNull);
        expect(service.stableReleaseVersion, '0.41.0');
        expect(service.release, isNull);
        expect(client.stableApiRequestCount, 1);
        expect(client.developmentApiRequestCount, 0);
        expect(client.downloadRequestCount, 0);
      },
    );

    test('checks and stages a versioned stable Windows libmpv asset', () async {
      final package = _makePackage();
      final temp = await Directory.systemTemp.createTemp(
        'engine-update-stable-test-',
      );
      final client = _GithubClient(
        release: '{}',
        stableRelease: _githubStableReleaseJson(
          assets: [_githubStableAsset(package)],
        ),
        package: package,
      );
      final service = EngineUpdateService(
        client: client,
        repository: _repository(temp),
        currentVersion: '0.40.0',
        platformProvider: () => EngineUpdatePlatform.windows,
      );
      addTearDown(() async {
        service.dispose();
        await temp.delete(recursive: true);
      });

      await service.check();

      expect(service.status, 'available');
      expect(service.release?.engineVersion, '0.41.0');
      expect(
        service.release?.sha256,
        crypto.sha256.convert(package).toString(),
      );
      expect(
        service.release?.downloadUri.path,
        contains('/releases/download/v0.41.0/'),
      );
      expect(client.stableApiRequestCount, 1);

      await service.downloadAndStage();

      expect(service.status, 'readyToRestart');
      expect(service.pendingVersion, '0.41.0');
      expect(client.downloadRequestCount, 1);
    });

    test(
      'restores an explicitly saved development channel on initialization',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-channel-test-',
        );
        final preferences = EngineUpdatePreferencesRepository(
          storageDirectory: Directory(p.join(temp.path, 'updates')),
        );
        await preferences.saveChannel(EngineUpdateChannel.development);
        final service = EngineUpdateService(
          repository: _repository(temp),
          preferencesRepository: preferences,
          currentVersion: '0.41.0',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        await service.initialize();

        expect(service.channel, EngineUpdateChannel.development);
        expect(service.sourceLabel, MpvGithubRelease.sourceLabel);
      },
    );

    test(
      'does not switch channels while a stable-source check is in flight',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-channel-race-test-',
        );
        final apiGate = Completer<void>();
        final apiRequestStarted = Completer<void>();
        final client = _GithubClient(
          release: '{}',
          stableRelease: _githubStableReleaseJson(assets: const []),
          package: const <int>[],
          apiResponseGate: apiGate,
          apiRequestStarted: apiRequestStarted,
        );
        final service = EngineUpdateService(
          client: client,
          repository: _repository(temp),
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        final check = service.check();
        await apiRequestStarted.future;

        expect(
          await service.setChannel(EngineUpdateChannel.development),
          isFalse,
        );
        expect(service.channel, EngineUpdateChannel.stable);

        apiGate.complete();
        await check;

        expect(service.status, 'stableUnavailable');
        expect(service.channel, EngineUpdateChannel.stable);
        expect(client.developmentApiRequestCount, 0);
      },
    );

    test('does not race channel choices while saving a preference', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-update-channel-save-test-',
      );
      final storageLookupGate = Completer<void>();
      final storageLookupStarted = Completer<void>();
      final preferences = EngineUpdatePreferencesRepository(
        storageDirectoryProvider: () async {
          if (!storageLookupStarted.isCompleted) {
            storageLookupStarted.complete();
          }
          await storageLookupGate.future;
          return Directory(p.join(temp.path, 'updates'));
        },
      );
      final client = _GithubClient(release: '{}', package: const <int>[]);
      final service = EngineUpdateService(
        client: client,
        repository: _repository(temp),
        preferencesRepository: preferences,
        platformProvider: () => EngineUpdatePlatform.windows,
      );
      addTearDown(() async {
        service.dispose();
        await temp.delete(recursive: true);
      });

      final saving = service.setChannel(EngineUpdateChannel.development);
      await storageLookupStarted.future;

      expect(service.status, 'savingChannel');
      expect(await service.setChannel(EngineUpdateChannel.stable), isFalse);
      await service.check();
      expect(client.apiRequestCount, 0);

      storageLookupGate.complete();
      expect(await saving, isTrue);
      expect(service.channel, EngineUpdateChannel.development);
      expect(service.status, 'idle');
    });

    test(
      'does not switch channels while a development package downloads',
      () async {
        final package = _makePackage();
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-channel-race-test-',
        );
        final downloadGate = Completer<void>();
        final downloadRequestStarted = Completer<void>();
        final client = _GithubClient(
          release: _githubReleaseJson(package: package),
          package: package,
          downloadResponseGate: downloadGate,
          downloadRequestStarted: downloadRequestStarted,
        );
        final service = EngineUpdateService(
          client: client,
          repository: _repository(temp),
          currentVersion: '0.40.0',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });
        expect(
          await service.setChannel(EngineUpdateChannel.development),
          isTrue,
        );
        await service.check();
        expect(service.status, 'available');

        final download = service.downloadAndStage();
        await downloadRequestStarted.future;

        expect(await service.setChannel(EngineUpdateChannel.stable), isFalse);
        expect(service.channel, EngineUpdateChannel.development);

        downloadGate.complete();
        await download;

        expect(service.status, 'readyToRestart');
        expect(service.channel, EngineUpdateChannel.development);
        expect(client.stableApiRequestCount, 0);
      },
    );

    test(
      'rejects an invalid or incomplete development package asset',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-github-test-',
        );
        final client = _GithubClient(
          release: _githubReleaseJson(
            package: _makePackage(),
            digest: 'sha512:${List<String>.filled(64, 'a').join()}',
          ),
          package: _makePackage(),
        );
        final service = EngineUpdateService(
          client: client,
          repository: _repository(temp),
          currentVersion: '0.40.0',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        expect(
          await service.setChannel(EngineUpdateChannel.development),
          isTrue,
        );

        await service.check();

        expect(service.status, 'error');
        expect(service.error, contains('SHA-256'));
        expect(client.downloadRequestCount, 0);
      },
    );

    test('reports the GitHub API rate limit as a retryable error', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-update-github-test-',
      );
      final client = _GithubClient(
        release: '{}',
        package: const <int>[],
        rateLimited: true,
      );
      final service = EngineUpdateService(
        client: client,
        repository: _repository(temp),
        platformProvider: () => EngineUpdatePlatform.windows,
      );
      addTearDown(() async {
        service.dispose();
        await temp.delete(recursive: true);
      });

      expect(await service.setChannel(EngineUpdateChannel.development), isTrue);

      await service.check();

      expect(service.status, 'error');
      expect(service.error, contains('GitHub API rate limit'));
      expect(client.downloadRequestCount, 0);
    });

    test('rejects a GitHub artifact URL on a non-default HTTPS port', () async {
      final package = _makePackage();
      final name =
          'libmpv-v0.41.0-dev-g01e2533f3-39050261656-x86_64-w64-mingw32-gpl.zip';
      final temp = await Directory.systemTemp.createTemp(
        'engine-update-github-test-',
      );
      final client = _GithubClient(
        release: _githubReleaseJson(
          package: package,
          downloadUrlOverride:
              'https://github.com:444/mpv-player/mpv/releases/download/git-release/$name',
        ),
        package: package,
      );
      final service = EngineUpdateService(
        client: client,
        repository: _repository(temp),
        currentVersion: '0.40.0',
        platformProvider: () => EngineUpdatePlatform.windows,
      );
      addTearDown(() async {
        service.dispose();
        await temp.delete(recursive: true);
      });

      expect(await service.setChannel(EngineUpdateChannel.development), isTrue);

      await service.check();

      expect(service.status, 'error');
      expect(service.error, contains('outside the expected mpv release'));
      expect(client.downloadRequestCount, 0);
    });

    test(
      'accepts a valid Ed25519 signature over canonical payload JSON',
      () async {
        final package = _makePackage();
        final signed = await _signedManifest(package: package);
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final client = _FakeClient(manifest: signed.manifest, package: package);
        final service = _service(
          client: client,
          repository: _repository(temp),
          publicKeyBase64: signed.publicKeyBase64,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        await service.check();

        expect(service.status, 'available');
        expect(service.release?.engineVersion, '2.0.0');
        expect(client.requestCount, 1);
      },
    );

    test('rejects a manifest whose signed payload has changed', () async {
      final package = _makePackage();
      final signed = await _signedManifest(package: package);
      final decoded = jsonDecode(signed.manifest) as Map<String, Object?>;
      final payload = Map<String, Object?>.from(decoded['payload']! as Map);
      payload['engineVersion'] = '2.1.0';
      decoded['payload'] = payload;
      final temp = await Directory.systemTemp.createTemp('engine-update-test-');
      final client = _FakeClient(
        manifest: jsonEncode(decoded),
        package: package,
      );
      final service = _service(
        client: client,
        repository: _repository(temp),
        publicKeyBase64: signed.publicKeyBase64,
      );
      addTearDown(() async {
        service.dispose();
        await temp.delete(recursive: true);
      });

      await service.check();

      expect(service.status, 'error');
      expect(service.error, contains('signature'));
      expect(service.release, isNull);
    });

    test(
      'rejects a MediaKit mismatch and app versions outside the signed range',
      () async {
        final package = _makePackage();
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        addTearDown(() => temp.delete(recursive: true));

        final mediaKitFeed = await _signedManifest(
          package: package,
          mediaKitVersion: '1.2.7',
        );
        final mediaKitService = _service(
          client: _FakeClient(
            manifest: mediaKitFeed.manifest,
            package: package,
          ),
          repository: _repository(Directory(p.join(temp.path, 'media-kit'))),
          publicKeyBase64: mediaKitFeed.publicKeyBase64,
        );
        addTearDown(mediaKitService.dispose);
        await mediaKitService.check();
        expect(mediaKitService.status, 'error');
        expect(mediaKitService.error, contains('MediaKit'));

        final appFeed = await _signedManifest(
          package: package,
          maximumAppVersionExclusive: '1.0.0',
        );
        final appService = _service(
          client: _FakeClient(manifest: appFeed.manifest, package: package),
          repository: _repository(Directory(p.join(temp.path, 'app-version'))),
          publicKeyBase64: appFeed.publicKeyBase64,
          appVersion: '1.0.0',
        );
        addTearDown(appService.dispose);
        await appService.check();
        expect(appService.status, 'error');
        expect(appService.error, contains('below 1.0.0'));
      },
    );

    test('checks archive size and SHA-256 before staging', () async {
      final package = _makePackage();
      final temp = await Directory.systemTemp.createTemp('engine-update-test-');
      addTearDown(() => temp.delete(recursive: true));

      final hashFeed = await _signedManifest(
        package: package,
        sha256: List<String>.filled(64, '0').join(),
      );
      final hashService = _service(
        client: _FakeClient(manifest: hashFeed.manifest, package: package),
        repository: _repository(Directory(p.join(temp.path, 'hash'))),
        publicKeyBase64: hashFeed.publicKeyBase64,
      );
      addTearDown(hashService.dispose);
      await hashService.check();
      await hashService.downloadAndStage();
      expect(hashService.status, 'error');
      expect(hashService.error, contains('SHA-256'));
      expect(hashService.pendingVersion, isNull);

      final sizeFeed = await _signedManifest(
        package: package,
        sizeBytes: package.length + 1,
      );
      final sizeService = _service(
        client: _FakeClient(manifest: sizeFeed.manifest, package: package),
        repository: _repository(Directory(p.join(temp.path, 'size'))),
        publicKeyBase64: sizeFeed.publicKeyBase64,
      );
      addTearDown(sizeService.dispose);
      await sizeService.check();
      await sizeService.downloadAndStage();
      expect(sizeService.status, 'error');
      expect(sizeService.error, contains('size'));
    });

    test(
      'downloads and stages a package, then confirms it after boot',
      () async {
        final package = _makePackage();
        final signed = await _signedManifest(package: package);
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final repository = _repository(temp);
        final service = _service(
          client: _FakeClient(manifest: signed.manifest, package: package),
          repository: repository,
          publicKeyBase64: signed.publicKeyBase64,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        await service.initialize();
        await service.check();
        await service.downloadAndStage();

        expect(service.status, 'readyToRestart');
        expect(service.currentVersion, '1.0.0');
        expect(service.pendingVersion, '2.0.0');
        final selected = await service.selectEngineForBoot(
          bundledEnginePath: r'C:\app\libmpv-2.dll',
        );
        expect(selected.isPending, isTrue);
        expect(File(selected.libraryPath!).existsSync(), isTrue);

        await service.confirmPendingBoot();
        expect(service.currentVersion, '2.0.0');
        expect(service.pendingVersion, isNull);
        expect((await repository.loadSelection()).active?.version, '2.0.0');
      },
    );

    test('does not repeat an unconfirmed pending boot after a crash', () async {
      final temp = await Directory.systemTemp.createTemp('engine-update-test-');
      final repository = _repository(temp);
      final packageFile = await _writePackage(temp, _makePackage());
      addTearDown(() => temp.delete(recursive: true));

      await repository.stagePackage(version: '1.0.0', packageFile: packageFile);
      await repository.selectEngineForBoot();
      await repository.confirmPendingBoot();
      await repository.stagePackage(version: '2.0.0', packageFile: packageFile);

      final interruptedSelection = await repository.selectEngineForBoot();
      expect(interruptedSelection.version, '2.0.0');
      expect(interruptedSelection.isPending, isTrue);

      final service = _service(
        client: _FakeClient(manifest: '{}', package: const <int>[]),
        repository: repository,
        publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
      );
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.pendingVersion, '2.0.0');

      final rollback = await service.selectEngineForBoot(
        bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
      );

      expect(rollback.version, '1.0.0');
      expect(rollback.isPending, isFalse);
      expect(service.currentVersion, '1.0.0');
      expect(service.pendingVersion, isNull);
      final state = await repository.loadSelection();
      expect(state.active?.version, '1.0.0');
      expect(state.pending, isNull);
      expect(state.pendingBootInProgress, isFalse);
    });

    test(
      'demotes a failed confirmed engine and persists the previous version',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));

        await repository.stagePackage(
          version: '1.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();
        await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();

        final failedActive = await repository.selectEngineForBoot();
        expect(failedActive.version, '2.0.0');
        expect(failedActive.isPending, isFalse);
        final fallback = await repository.rejectBootSelection(
          failedActive,
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        );

        expect(fallback.version, '1.0.0');
        expect(fallback.isBundled, isFalse);
        final state = await repository.loadSelection();
        expect(state.active?.version, '1.0.0');
        expect(state.previous, isNull);
        expect((await repository.selectEngineForBoot()).version, '1.0.0');
      },
    );

    test(
      'confirmed rejection preserves a pending rollback selection',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-rollback-rejection-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));

        final first = await repository.stagePackage(
          version: '1.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();
        final second = await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();

        final selectionFile = File(
          p.join(
            (await repository.enginesDirectory).path,
            EngineInstallationRepository.selectionFileName,
          ),
        );
        await selectionFile.writeAsString(
          jsonEncode(
            EngineSelectionState(
              active: second,
              previous: first,
              pending: first,
              activeIsBundled: true,
              pendingRollback: true,
            ).toJson(),
          ),
          flush: true,
        );

        await repository.rejectBootSelection(
          const EngineBootSelection(
            libraryPath: r'C:\app\bundled\libmpv-2.dll',
            version: '0.41.0',
            isBundled: true,
            isPending: false,
          ),
        );
        expect((await repository.loadSelection()).pendingRollback, isTrue);

        await selectionFile.writeAsString(
          jsonEncode(
            EngineSelectionState(
              active: second,
              previous: first,
              pending: first,
              pendingRollback: true,
            ).toJson(),
          ),
          flush: true,
        );
        await repository.rejectBootSelection(
          EngineBootSelection(
            libraryPath: p.join(
              second.path,
              EngineInstallationRepository.engineLibraryFileName,
            ),
            version: second.version,
            isBundled: false,
            isPending: false,
          ),
        );

        final afterCustomRejection = await repository.loadSelection();
        expect(afterCustomRejection.pendingRollback, isTrue);
        expect(afterCustomRejection.active?.version, '1.0.0');
      },
    );

    test(
      'preserves the previous engine when a pending boot is rejected',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-repository-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));

        await repository.stagePackage(
          version: '1.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();
        await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();
        await repository.stagePackage(
          version: '3.0.0',
          packageFile: packageFile,
        );
        final failedPending = await repository.selectEngineForBoot();
        expect(failedPending.version, '3.0.0');
        expect(failedPending.isPending, isTrue);

        final activeFallback = await repository.rejectBootSelection(
          failedPending,
        );
        expect(activeFallback.version, '2.0.0');
        expect((await repository.loadSelection()).previous?.version, '1.0.0');

        final failedActive = await repository.selectEngineForBoot();
        final previousFallback = await repository.rejectBootSelection(
          failedActive,
        );

        expect(previousFallback.version, '1.0.0');
        expect((await repository.loadSelection()).active?.version, '1.0.0');
      },
    );

    test(
      'falls back when a staged DLL no longer matches its stored digest',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-repository-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));

        await repository.stagePackage(
          version: '1.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();
        await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();

        final root = await repository.enginesDirectory;
        await File(
          p.join(root.path, '2.0.0', 'libmpv-2.dll'),
        ).writeAsBytes(<int>[9, 9, 9, 9], flush: true);
        final selection = await repository.selectEngineForBoot();

        expect(selection.version, '1.0.0');
        expect((await repository.loadSelection()).active?.version, '1.0.0');
      },
    );

    test(
      'retains signed compatibility metadata and rejects it after app upgrade',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));

        final staged = await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
          mediaKitVersion: '1.2.6',
          minimumAppVersion: '2.0.0',
          maximumAppVersionExclusive: '3.0.0',
        );
        expect(staged.minimumAppVersion, '2.0.0');
        expect(staged.maximumAppVersionExclusive, '3.0.0');

        final compatibleService = _service(
          client: _FakeClient(manifest: '{}', package: const <int>[]),
          repository: repository,
          publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
          appVersion: '2.1.0',
        );
        addTearDown(compatibleService.dispose);
        final firstBoot = await compatibleService.selectEngineForBoot();
        expect(firstBoot.version, '2.0.0');
        await compatibleService.confirmPendingBoot();

        final upgradedAppService = _service(
          client: _FakeClient(manifest: '{}', package: const <int>[]),
          repository: repository,
          publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
          appVersion: '3.0.0',
        );
        addTearDown(upgradedAppService.dispose);
        final fallback = await upgradedAppService.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        );

        expect(fallback.isBundled, isTrue);
        expect(fallback.version, '1.0.0');
        expect(upgradedAppService.currentVersion, '1.0.0');
        expect((await repository.loadSelection()).activeIsBundled, isTrue);
      },
    );

    test(
      'queues custom rollback for next boot without changing current version',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));
        for (final version in ['1.0.0', '2.0.0']) {
          await repository.stagePackage(
            version: version,
            packageFile: packageFile,
          );
          await repository.selectEngineForBoot();
          await repository.confirmPendingBoot();
        }
        final service = _service(
          client: _FakeClient(manifest: '{}', package: const <int>[]),
          repository: repository,
          publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
        );
        addTearDown(service.dispose);
        await service.initialize();

        expect(service.currentVersion, '2.0.0');
        expect(service.canRollback, isTrue);
        expect(service.rollbackVersion, '1.0.0');
        expect(service.rollbackTargetIsBundled, isFalse);
        await service.scheduleRollback();

        expect(service.currentVersion, '2.0.0');
        expect(service.pendingVersion, '1.0.0');
        expect(service.pendingRollback, isTrue);
        expect(service.pendingBundled, isFalse);
        expect(service.canRollback, isFalse);
        final nextBoot = await service.selectEngineForBoot();
        expect(nextBoot.version, '1.0.0');
        await service.confirmPendingBoot();
        expect(service.currentVersion, '1.0.0');
        expect((await repository.loadSelection()).active?.version, '1.0.0');
      },
    );

    test(
      'queues bundled rollback and keeps bundled active despite retained previous',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));
        await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();
        final service = _service(
          client: _FakeClient(manifest: '{}', package: const <int>[]),
          repository: repository,
          publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
        );
        addTearDown(service.dispose);
        await service.initialize();

        expect(service.canRollback, isTrue);
        expect(service.rollbackVersion, '1.0.0');
        expect(service.rollbackTargetIsBundled, isTrue);
        await service.scheduleRollback(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        );
        expect(service.currentVersion, '2.0.0');
        expect(service.pendingVersion, '1.0.0');
        expect(service.pendingBundled, isTrue);
        expect(service.pendingRollback, isTrue);

        final bundled = await service.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        );
        expect(bundled.isBundled, isTrue);
        expect(bundled.isPending, isTrue);
        await service.confirmPendingBoot();
        expect(service.currentVersion, '1.0.0');
        final nextLaunch = await service.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        );
        expect(nextLaunch.isBundled, isTrue);
        expect((await repository.loadSelection()).previous?.version, '2.0.0');
      },
    );

    test(
      'active-engine rejection resets currentVersion to the bundled version',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));
        await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();
        final service = _service(
          client: _FakeClient(manifest: '{}', package: const <int>[]),
          repository: repository,
          publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
        );
        addTearDown(service.dispose);

        final failed = await service.selectEngineForBoot();
        expect(service.currentVersion, '2.0.0');
        final fallback = await service.rejectBootSelection(
          failed,
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        );

        expect(fallback.isBundled, isTrue);
        expect(fallback.version, '1.0.0');
        expect(service.currentVersion, '1.0.0');
        expect((await repository.loadSelection()).activeIsBundled, isTrue);
      },
    );

    test(
      'discarding a staged release permits downloading the same version again',
      () async {
        final package = _makePackage();
        final signed = await _signedManifest(package: package);
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final service = _service(
          client: _FakeClient(manifest: signed.manifest, package: package),
          repository: _repository(temp),
          publicKeyBase64: signed.publicKeyBase64,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });
        await service.check();
        await service.downloadAndStage();
        await service.discardPending();
        expect(service.pendingVersion, isNull);
        await service.check();
        await service.downloadAndStage();
        expect(service.status, 'readyToRestart');
        expect(service.pendingVersion, '2.0.0');
      },
    );

    test(
      'dispose during the final staging commit cannot retain a pending install',
      () async {
        final package = _makePackage();
        final signed = await _signedManifest(package: package);
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final enteredCommit = Completer<void>();
        final allowCommitToContinue = Completer<void>();
        final repository = EngineInstallationRepository(
          enginesDirectory: Directory(p.join(temp.path, 'engines')),
          beforeSelectionWriteForTesting: () async {
            if (!enteredCommit.isCompleted) enteredCommit.complete();
            await allowCommitToContinue.future;
          },
        );
        final service = _service(
          client: _FakeClient(manifest: signed.manifest, package: package),
          repository: repository,
          publicKeyBase64: signed.publicKeyBase64,
        );
        addTearDown(() async {
          service.dispose();
          if (!allowCommitToContinue.isCompleted) {
            allowCommitToContinue.complete();
          }
          await temp.delete(recursive: true);
        });

        await service.check();
        final download = service.downloadAndStage();
        await enteredCommit.future;
        service.dispose();
        allowCommitToContinue.complete();
        await download;

        final state = await repository.loadSelection();
        expect(state.pending, isNull);
        expect(
          Directory(
            p.join((await repository.enginesDirectory).path, '2.0.0'),
          ).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'Linux reports system managed and makes no network or storage changes',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final root = Directory(p.join(temp.path, 'engines'));
        final client = _FakeClient(manifest: '{}', package: const <int>[]);
        final service = _service(
          client: client,
          repository: EngineInstallationRepository(enginesDirectory: root),
          publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
          platform: EngineUpdatePlatform.linux,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        await service.initialize();
        await service.check();
        await service.downloadAndStage();

        expect(service.supportedPlatform, isTrue);
        expect(service.selfManaged, isFalse);
        expect(service.status, 'systemManaged');
        expect(client.requestCount, 0);
        expect(await root.exists(), isFalse);
      },
    );

    test(
      'dispose cancels a stalled manifest response without publishing an error',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final client = _StalledClient();
        final service = _service(
          client: client,
          repository: _repository(temp),
          publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        final check = service.check();
        await Future<void>.delayed(Duration.zero);
        service.dispose();
        await expectLater(check, completes);
        expect(service.error, isNull);
        await client.controller.close();
      },
    );

    test(
      'rejects a manifest body shorter than its declared Content-Length',
      () async {
        final package = _makePackage();
        final signed = await _signedManifest(package: package);
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final service = _service(
          client: _TruncatedManifestClient(
            manifest: signed.manifest,
            package: package,
          ),
          repository: _repository(temp),
          publicKeyBase64: signed.publicKeyBase64,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        await service.check();

        expect(service.status, 'error');
        expect(service.error, contains('declared length'));
        expect(service.release, isNull);
      },
    );

    test(
      'accepts a gzip response whose Content-Length is compressed',
      () async {
        final package = _makePackage();
        final signed = await _signedManifest(package: package);
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        final service = _service(
          client: _CompressedManifestClient(
            manifest: signed.manifest,
            package: package,
          ),
          repository: _repository(temp),
          publicKeyBase64: signed.publicKeyBase64,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        await service.check();

        expect(service.status, 'available');
        expect(service.error, isNull);
        expect(service.release?.engineVersion, '2.0.0');
      },
    );

    test(
      'runs a custom verifier even when the configured key is malformed',
      () async {
        final package = _makePackage();
        final signed = await _signedManifest(package: package);
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-test-',
        );
        List<int>? seenKey;
        var verifierCalls = 0;
        final service = EngineUpdateService(
          client: _FakeClient(manifest: signed.manifest, package: package),
          repository: _repository(temp),
          manifestUri: Uri.parse('https://updates.example.test/engine.json'),
          publicKeyBase64: 'not base64!',
          signatureVerifier:
              ({
                required List<int> message,
                required List<int> signature,
                required List<int> publicKey,
              }) async {
                verifierCalls++;
                seenKey = publicKey;
                return true;
              },
          currentVersion: '1.0.0',
          appVersion: '1.0.0',
          supportedMediaKitVersion: '1.2.6',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        await service.check();

        expect(verifierCalls, 1);
        expect(seenKey, isEmpty);
        expect(service.status, 'available');
        expect(service.release?.engineVersion, '2.0.0');
      },
    );
  });

  group('EngineInstallationRepository', () {
    test(
      'rejects an inventory rewritten to match a tampered engine library',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-inventory-anchor-test-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final repository = _repository(temp);
        final package = await _writePackage(temp, _makePackage());
        final record = await repository.stagePackage(
          version: '7.0.0',
          packageFile: package,
        );
        final changed = <int>[77];
        await File(
          p.join(record.path, 'libmpv-2.dll'),
        ).writeAsBytes(changed, flush: true);
        final marker = File(
          p.join(
            record.path,
            EngineInstallationRepository.engineOwnershipMarkerFileName,
          ),
        );
        final contents =
            jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
        final digest = crypto.sha256.convert(changed).toString();
        contents['sha256'] = digest;
        for (final name in <String>['inventory', 'dependencies']) {
          for (final dependency in contents[name] as List) {
            if ((dependency as Map)['path'] == 'libmpv-2.dll') {
              dependency['sha256'] = digest;
              dependency['size'] = changed.length;
            }
          }
        }
        await marker.writeAsString(jsonEncode(contents), flush: true);
        final selected = await repository.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
          bundledEngineVersion: '0.41.0',
        );
        expect(selected.isBundled, isTrue);
        expect((await repository.loadSelection()).pending, isNull);
      },
    );

    test(
      'serializes staging transactions across repository instances',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-repository-lock-test-',
        );
        final root = Directory(p.join(temp.path, 'engines'));
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));
        final enteredCommit = Completer<void>();
        final allowCommit = Completer<void>();
        final firstRepository = EngineInstallationRepository(
          enginesDirectory: root,
          beforeSelectionWriteForTesting: () async {
            if (!enteredCommit.isCompleted) enteredCommit.complete();
            await allowCommit.future;
          },
        );
        final secondRepository = EngineInstallationRepository(
          enginesDirectory: root,
        );

        final firstStage = firstRepository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await enteredCommit.future;
        final secondStage = secondRepository.stagePackage(
          version: '3.0.0',
          packageFile: packageFile,
        );
        allowCommit.complete();

        await firstStage;
        await expectLater(secondStage, throwsA(isA<StateError>()));
        final state = await firstRepository.loadSelection();
        expect(state.pending?.version, '2.0.0');
        expect(Directory(p.join(root.path, '3.0.0')).existsSync(), isFalse);
      },
    );

    test(
      'a failed attempt cannot delete a same-version retry committed afterward',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-stage-retry-race-test-',
        );
        final root = Directory(p.join(temp.path, 'engines'));
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));
        final cleanupEntered = Completer<void>();
        final allowCleanup = Completer<void>();
        final failingRepository = EngineInstallationRepository(
          enginesDirectory: root,
          beforeSelectionWriteForTesting: () async {
            throw StateError('simulated selection write failure');
          },
          beforeStageFailureCleanupForTesting: () async {
            if (!cleanupEntered.isCompleted) cleanupEntered.complete();
            await allowCleanup.future;
          },
        );
        final retryRepository = EngineInstallationRepository(
          enginesDirectory: root,
        );

        final failedStage = failingRepository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await cleanupEntered.future.timeout(const Duration(seconds: 5));
        EngineInstallRecord? retry;
        try {
          retry = await retryRepository.stagePackage(
            version: '2.0.0',
            packageFile: packageFile,
          );
        } finally {
          if (!allowCleanup.isCompleted) allowCleanup.complete();
        }

        final committed = retry;
        await expectLater(failedStage, throwsA(isA<StateError>()));
        final state = await retryRepository.loadSelection();
        expect(state.pending?.path, committed.path);
        expect(await Directory(committed.path).exists(), isTrue);
        expect(
          await File(
            p.join(
              committed.path,
              EngineInstallationRepository.engineOwnershipMarkerFileName,
            ),
          ).exists(),
          isTrue,
        );
      },
    );

    test(
      'sweeps interrupted attempts but preserves live and unowned staging paths',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-stage-sweep-test-',
        );
        final root = Directory(p.join(temp.path, 'engines'));
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));
        final extractionEntered = Completer<void>();
        final allowExtraction = Completer<void>();
        final liveRepository = EngineInstallationRepository(
          enginesDirectory: root,
          beforeExtractionForTesting: () async {
            if (!extractionEntered.isCompleted) extractionEntered.complete();
            await allowExtraction.future;
          },
        );
        final liveStage = liveRepository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await extractionEntered.future.timeout(const Duration(seconds: 5));
        final liveAttempt =
            (await root
                    .list(followLinks: false)
                    .where(
                      (entity) =>
                          p.basename(entity.path).startsWith('.staging-'),
                    )
                    .toList())
                .single;

        const interruptedId = '9a5b6c7d8e9f00112233445566778899';
        final interrupted = Directory(
          p.join(root.path, '.staging-$interruptedId'),
        );
        await interrupted.create(recursive: true);
        await File(
          p.join(
            interrupted.path,
            EngineInstallationRepository.stageOwnershipMarkerFileName,
          ),
        ).writeAsString(
          jsonEncode({
            'owner': EngineInstallationRepository.stageOwnershipMarkerOwner,
            'attemptId': interruptedId,
            'version': '1.5.0',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
        await File(
          p.join(
            interrupted.path,
            EngineInstallationRepository.stageLeaseFileName,
          ),
        ).writeAsString('', flush: true);

        const unownedId = '0123456789abcdef0123456789abcdef';
        final unowned = Directory(p.join(root.path, '.staging-$unownedId'));
        await unowned.create(recursive: true);
        final unownedFile = File(p.join(unowned.path, 'keep.txt'));
        await unownedFile.writeAsString('external staging data');

        try {
          final committedRepository = EngineInstallationRepository(
            enginesDirectory: root,
          );
          final committed = await committedRepository.stagePackage(
            version: '3.0.0',
            packageFile: packageFile,
          );

          expect(committed.version, '3.0.0');
          expect(await interrupted.exists(), isFalse);
          expect(await unownedFile.readAsString(), 'external staging data');
          expect(await Directory(liveAttempt.path).exists(), isTrue);
          final stagingDirectories = await root
              .list(followLinks: false)
              .where(
                (entity) => p.basename(entity.path).startsWith('.staging-'),
              )
              .toList();
          expect(stagingDirectories, hasLength(2));
        } finally {
          if (!allowExtraction.isCompleted) allowExtraction.complete();
        }

        await expectLater(liveStage, throwsA(isA<StateError>()));
        expect(await unownedFile.exists(), isTrue);
        final remainingStaging = await root
            .list(followLinks: false)
            .where((entity) => p.basename(entity.path).startsWith('.staging-'))
            .map((entity) => p.basename(entity.path))
            .toList();
        expect(remainingStaging, [p.basename(unowned.path)]);
        expect(remainingStaging, isNot(contains(p.basename(liveAttempt.path))));
      },
    );

    test(
      'sweeps an owned staging attempt left before its lease was created',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-stage-marker-sweep-test-',
        );
        final root = Directory(p.join(temp.path, 'engines'));
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));
        await root.create(recursive: true);

        const attemptId = 'fedcba9876543210fedcba9876543210';
        final attempt = Directory(p.join(root.path, '.staging-$attemptId'));
        await attempt.create(recursive: true);
        await File(
          p.join(
            attempt.path,
            EngineInstallationRepository.stageOwnershipMarkerFileName,
          ),
        ).writeAsString(
          jsonEncode({
            'owner': EngineInstallationRepository.stageOwnershipMarkerOwner,
            'attemptId': attemptId,
            'version': '1.5.0',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
        expect(
          await File(
            p.join(
              attempt.path,
              EngineInstallationRepository.stageLeaseFileName,
            ),
          ).exists(),
          isFalse,
        );

        const unownedId = '00112233445566778899aabbccddeeff';
        final unowned = Directory(p.join(root.path, '.staging-$unownedId'));
        await unowned.create(recursive: true);
        final unownedFile = File(p.join(unowned.path, 'keep.txt'));
        await unownedFile.writeAsString('external staging data');

        final repository = EngineInstallationRepository(enginesDirectory: root);
        final committed = await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );

        expect(committed.version, '2.0.0');
        expect(await attempt.exists(), isFalse);
        expect(await unownedFile.readAsString(), 'external staging data');
        expect(await unowned.exists(), isTrue);
      },
    );

    test('rejects oversized declared ZIP content before extraction', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-repository-test-',
      );
      final package = _mutateCentralDirectorySize(
        _makePackage(),
        'libmpv-2.dll',
        1025,
      );
      final packageFile = await _writePackage(temp, package);
      final repository = EngineInstallationRepository(
        enginesDirectory: Directory(p.join(temp.path, 'engines')),
        maxUncompressedBytes: 1024,
      );
      addTearDown(() => temp.delete(recursive: true));

      await expectLater(
        repository.stagePackage(version: '2.0.0', packageFile: packageFile),
        throwsA(isA<FormatException>()),
      );
      expect(
        Directory(
          p.join((await repository.enginesDirectory).path, '2.0.0'),
        ).existsSync(),
        isFalse,
      );
    });

    test('rejects Unix symlink metadata before archive decoding', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-repository-test-',
      );
      final package = _mutateCentralDirectoryMode(
        _makePackage(),
        'LICENSE.txt',
        0xa1ff,
      );
      final packageFile = await _writePackage(temp, package);
      final repository = _repository(temp);
      addTearDown(() => temp.delete(recursive: true));

      await expectLater(
        repository.stagePackage(version: '2.0.0', packageFile: packageFile),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects traversal paths and leaves no version directory', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-repository-test-',
      );
      final repository = _repository(temp);
      final packageFile = await _writePackage(
        temp,
        _makePackage(
          extraFiles: {
            '../outside.txt': [1, 2, 3],
          },
        ),
      );
      addTearDown(() => temp.delete(recursive: true));

      await expectLater(
        repository.stagePackage(version: '2.0.0', packageFile: packageFile),
        throwsA(isA<FormatException>()),
      );
      expect(
        Directory(
          p.join((await repository.enginesDirectory).path, '2.0.0'),
        ).existsSync(),
        isFalse,
      );
    });

    test(
      'rejects archive entries that collide with updater control files',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-control-entry-test-',
        );
        final repository = _repository(temp);
        addTearDown(() => temp.delete(recursive: true));
        const controlNames = [
          '.mpvson-engine-stage.json',
          '.mpvson-stage.lease',
          '.mpvson-stage-cancel',
          '.mpvson-engine.json',
          '.mpvson-engine.json/child.txt',
        ];

        for (var index = 0; index < controlNames.length; index++) {
          final packageFile = await _writePackage(
            temp,
            _makePackage(
              extraFiles: {
                controlNames[index]: [1],
              },
            ),
          );
          await expectLater(
            repository.stagePackage(
              version: '2.0.$index',
              packageFile: packageFile,
            ),
            throwsA(isA<FormatException>()),
          );
        }
      },
    );

    test(
      'drops selection records whose stored path escapes the engine root',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-repository-test-',
        );
        final repository = _repository(temp);
        addTearDown(() => temp.delete(recursive: true));
        await repository.initialize();
        final root = await repository.enginesDirectory;
        final outside = p.join(root.path, '..', 'outside', '1.0.0');
        await File(
          p.join(root.path, EngineInstallationRepository.selectionFileName),
        ).writeAsString(
          jsonEncode({
            'schemaVersion': 1,
            'active': {
              'version': '1.0.0',
              'path': outside,
              'sha256': List<String>.filled(64, '0').join(),
            },
            'previous': null,
            'pending': null,
            'pendingBootInProgress': false,
          }),
        );

        final state = await repository.loadSelection();

        expect(state.active, isNull);
      },
    );

    test(
      'removes a renamed package when selection persistence fails',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-repository-test-',
        );
        final root = Directory(p.join(temp.path, 'engines'));
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));
        final failingRepository = EngineInstallationRepository(
          enginesDirectory: root,
          beforeSelectionWriteForTesting: () async {
            throw StateError('simulated selection write failure');
          },
        );

        await expectLater(
          failingRepository.stagePackage(
            version: '2.0.0',
            packageFile: packageFile,
          ),
          throwsA(isA<StateError>()),
        );
        expect(Directory(p.join(root.path, '2.0.0')).existsSync(), isFalse);

        final retryRepository = EngineInstallationRepository(
          enginesDirectory: root,
        );
        final staged = await retryRepository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        expect(staged.version, '2.0.0');
        expect(Directory(staged.path).existsSync(), isTrue);
      },
    );

    test(
      'keeps the official source when only the custom manifest is set',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-config-test-',
        );
        final service = EngineUpdateService(
          client: _FakeClient(manifest: '{}', package: const <int>[]),
          repository: _repository(temp),
          manifestUri: Uri.parse('https://updates.example.test/engine.json'),
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        expect(service.configured, isTrue);
        expect(service.usesOfficialMpvSource, isTrue);
        expect(service.sourceLabel, MpvGithubRelease.stableSourceLabel);
        expect(service.status, 'idle');
        expect(service.configurationError, isNull);
        expect(service.configurationWarning, contains('public key'));
      },
    );

    test('keeps the official source when only the custom key is set', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-update-config-test-',
      );
      final service = EngineUpdateService(
        client: _FakeClient(manifest: '{}', package: const <int>[]),
        repository: _repository(temp),
        publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
        platformProvider: () => EngineUpdatePlatform.windows,
      );
      addTearDown(() async {
        service.dispose();
        await temp.delete(recursive: true);
      });

      expect(service.configured, isTrue);
      expect(service.usesOfficialMpvSource, isTrue);
      expect(service.sourceLabel, MpvGithubRelease.stableSourceLabel);
      expect(service.status, 'idle');
      expect(service.configurationWarning, contains('manifest URL'));
    });

    test('uses a complete custom feed without warnings', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-update-config-test-',
      );
      final service = EngineUpdateService(
        client: _FakeClient(manifest: '{}', package: const <int>[]),
        repository: _repository(temp),
        manifestUri: Uri.parse('https://updates.example.test/engine.json'),
        publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
        platformProvider: () => EngineUpdatePlatform.windows,
      );
      addTearDown(() async {
        service.dispose();
        await temp.delete(recursive: true);
      });

      expect(service.configured, isTrue);
      expect(service.usesOfficialMpvSource, isFalse);
      expect(service.sourceLabel, 'Custom signed feed');
      expect(service.status, 'idle');
      expect(service.configurationWarning, isNull);
      expect(service.configurationError, isNull);
    });

    test(
      'reports an invalid custom feed instead of failing silently',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-config-test-',
        );
        final insecure = EngineUpdateService(
          client: _FakeClient(manifest: '{}', package: const <int>[]),
          repository: _repository(temp),
          manifestUri: Uri.parse('http://updates.example.test/engine.json'),
          publicKeyBase64: base64Encode(List<int>.filled(32, 1)),
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(() async {
          insecure.dispose();
          await temp.delete(recursive: true);
        });

        expect(insecure.configured, isFalse);
        expect(insecure.usesOfficialMpvSource, isFalse);
        expect(insecure.status, 'unconfigured');
        expect(insecure.configurationError, contains('HTTPS'));

        await insecure.initialize();
        expect(insecure.status, 'unconfigured');
        expect(insecure.error, contains('HTTPS'));

        final badKey = EngineUpdateService(
          client: _FakeClient(manifest: '{}', package: const <int>[]),
          repository: _repository(temp),
          manifestUri: Uri.parse('https://updates.example.test/engine.json'),
          publicKeyBase64: 'not base64!',
          platformProvider: () => EngineUpdatePlatform.windows,
        );
        addTearDown(badKey.dispose);

        expect(badKey.configured, isFalse);
        expect(badKey.configurationError, contains('base64'));
      },
    );

    test('leaves an unowned engine directory untouched when staging', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-store-ownership-test-',
      );
      final repository = _repository(temp);
      final packageFile = await _writePackage(temp, _makePackage());
      addTearDown(() => temp.delete(recursive: true));

      final engines = await repository.enginesDirectory;
      final requestedVersion = Directory(p.join(engines.path, '2.0.0'));
      await requestedVersion.create(recursive: true);
      final userFile = File(p.join(requestedVersion.path, 'keep-me.txt'));
      await userFile.writeAsString('user data');

      await expectLater(
        repository.stagePackage(version: '2.0.0', packageFile: packageFile),
        throwsA(isA<FileSystemException>()),
      );

      expect(
        await userFile.exists(),
        isTrue,
        reason: 'a directory this updater does not own must survive staging',
      );
      expect(
        await File(p.join(requestedVersion.path, 'keep-me.txt')).readAsString(),
        'user data',
      );
    });

    test(
      'fails closed when an owned install has a malformed inventory',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-store-inventory-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));

        final installed = await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.rejectPendingBoot();

        final marker = File(
          p.join(
            installed.path,
            EngineInstallationRepository.engineOwnershipMarkerFileName,
          ),
        );
        final markerJson = jsonDecode(await marker.readAsString()) as Map;
        markerJson['dependencies'] = <Object?>['malformed inventory row'];
        await marker.writeAsString(jsonEncode(markerJson), flush: true);

        await expectLater(
          repository.stagePackage(version: '2.0.0', packageFile: packageFile),
          throwsA(isA<FileSystemException>()),
        );

        expect(
          await File(p.join(installed.path, 'libmpv-2.dll')).exists(),
          isTrue,
        );
        expect(
          (jsonDecode(await marker.readAsString()) as Map)['dependencies'],
          <Object?>['malformed inventory row'],
        );
      },
    );

    test(
      'replaces an owned unreferenced engine directory when staging',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-store-ownership-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));

        await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.rejectPendingBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        );

        final engines = await repository.enginesDirectory;
        final ownedDirectory = Directory(p.join(engines.path, '2.0.0'));
        expect(
          await File(
            p.join(
              ownedDirectory.path,
              EngineInstallationRepository.engineOwnershipMarkerFileName,
            ),
          ).exists(),
          isTrue,
          reason: 'the updater records durable ownership when it installs',
        );

        final staged = await repository.stagePackage(
          version: '2.0.0',
          packageFile: packageFile,
        );

        expect(staged.version, '2.0.0');
        expect(Directory(staged.path).existsSync(), isTrue);
      },
    );

    test(
      'recovers a usable backup when the primary selection is unusable',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-selection-recovery-test-',
        );
        final repository = _repository(temp);
        final packageFile = await _writePackage(temp, _makePackage());
        addTearDown(() => temp.delete(recursive: true));

        await repository.stagePackage(
          version: '1.0.0',
          packageFile: packageFile,
        );
        await repository.selectEngineForBoot();
        await repository.confirmPendingBoot();

        final engines = await repository.enginesDirectory;
        final selection = File(
          p.join(engines.path, EngineInstallationRepository.selectionFileName),
        );
        // An interrupted write leaves the previous selection beside the primary.
        await File(
          '${selection.path}.bak',
        ).writeAsString(await selection.readAsString(), flush: true);
        // The primary still parses, but its record points at a directory that is
        // gone, so only the backup can name a usable engine.
        final decoded =
            jsonDecode(await selection.readAsString()) as Map<String, Object?>;
        final active = (decoded['active'] as Map).cast<String, Object?>();
        active['path'] = p.join(engines.path, 'missing');
        active['version'] = '9.9.9';
        await selection.writeAsString(jsonEncode(decoded), flush: true);

        final recovered = await repository.loadSelection();

        expect(recovered.active?.version, '1.0.0');
        expect(recovered.previous, isNull);
      },
    );

    test('backup recovery never proposes a rejected boot attempt', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-selection-recovery-test-',
      );
      final repository = _repository(temp);
      final packageFile = await _writePackage(temp, _makePackage());
      addTearDown(() => temp.delete(recursive: true));

      await repository.stagePackage(version: '2.0.0', packageFile: packageFile);
      final engines = await repository.enginesDirectory;
      final selection = File(
        p.join(engines.path, EngineInstallationRepository.selectionFileName),
      );
      // The staged engine before its boot attempt ran, kept as the copy an
      // interrupted write would leave behind.
      final preBoot = await selection.readAsString();
      await repository.selectEngineForBoot();
      await repository.rejectPendingBoot(
        bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
      );
      await File('${selection.path}.bak').writeAsString(preBoot, flush: true);
      await selection.writeAsString('{ not json', flush: true);

      final recovered = await repository.loadSelection();
      expect(recovered.pending, isNull);

      final boot = await repository.selectEngineForBoot(
        bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        bundledEngineVersion: '0.41.0',
      );
      expect(boot.isBundled, isTrue);
      expect(boot.version, '0.41.0');
    });

    test('keeps an explicit bundled selection during recovery', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-selection-recovery-test-',
      );
      final repository = _repository(temp);
      final packageFile = await _writePackage(temp, _makePackage());
      addTearDown(() => temp.delete(recursive: true));

      final staged = await repository.stagePackage(
        version: '2.0.0',
        packageFile: packageFile,
      );
      await repository.selectEngineForBoot();
      await repository.confirmPendingBoot();
      final rejected = await repository.rejectBootSelection(
        EngineBootSelection(
          libraryPath: p.join(
            staged.path,
            EngineInstallationRepository.engineLibraryFileName,
          ),
          version: staged.version,
          isBundled: false,
          isPending: false,
        ),
        bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
      );
      expect(rejected.isBundled, isTrue);

      final engines = await repository.enginesDirectory;
      final selection = File(
        p.join(engines.path, EngineInstallationRepository.selectionFileName),
      );
      // The explicit bundled decision survives even when the backup still
      // remembers the engine this startup rejected.
      await selection.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'pendingBootInProgress': false,
          'activeIsBundled': true,
          'lastRejectedVersion': '2.0.0',
        }),
        flush: true,
      );

      final recovered = await repository.loadSelection();
      expect(recovered.active, isNull);
      expect(recovered.activeIsBundled, isTrue);

      final boot = await repository.selectEngineForBoot(
        bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
        bundledEngineVersion: '0.41.0',
      );
      expect(boot.isBundled, isTrue);
      expect(boot.version, '0.41.0');
    });

    test(
      'streams download directly to temporary file and clears it after staging',
      () async {
        final package = _makePackage(
          extraFiles: {
            'avcodec-60.dll': [5, 6, 7, 8],
          },
        );
        final temp = await Directory.systemTemp.createTemp(
          'engine-update-stream-test-',
        );
        final manifest = await _signedManifest(
          package: package,
          engineVersion: '2.5.0',
        );
        final client = _FakeClient(
          manifest: manifest.manifest,
          package: package,
        );
        final repo = _repository(temp);
        final service = _service(
          client: client,
          repository: repo,
          publicKeyBase64: manifest.publicKeyBase64,
        );
        addTearDown(() async {
          service.dispose();
          await temp.delete(recursive: true);
        });

        await service.check();
        expect(service.status, 'available');

        await service.downloadAndStage();
        expect(service.status, 'readyToRestart');
        expect(service.pendingVersion, '2.5.0');

        final stagingTempDir = Directory(
          p.join(temp.path, 'engines', '.staging'),
        );
        if (await stagingTempDir.exists()) {
          final leftoverFiles = await stagingTempDir.list().toList();
          expect(leftoverFiles, isEmpty);
        }
      },
    );

    test(
      'extracts package incrementally in worker isolate and preserves safety preflights',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-isolate-test-',
        );
        final repo = _repository(temp);
        addTearDown(() => temp.delete(recursive: true));

        final packageBytes = _makePackage(
          extraFiles: {
            'sub/helper.dll': [1, 2, 3],
          },
        );
        final packageFile = await _writePackage(temp, packageBytes);

        final record = await repo.stagePackage(
          version: '3.0.0',
          packageFile: packageFile,
        );
        expect(record.version, '3.0.0');

        final installedDir = Directory(record.path);
        expect(await installedDir.exists(), isTrue);
        expect(
          await File(p.join(record.path, 'libmpv-2.dll')).exists(),
          isTrue,
        );
        expect(
          await File(p.join(record.path, 'sub', 'helper.dll')).exists(),
          isTrue,
        );
      },
    );

    test('cancels the extraction isolate before staging cleanup', () async {
      final temp = await Directory.systemTemp.createTemp(
        'engine-extraction-cancel-test-',
      );
      final repository = _repository(temp);
      addTearDown(() => temp.delete(recursive: true));
      final packageFile = await _writeLargeStreamedPackage(
        temp,
        payloadBytes: 32 * 1024 * 1024,
      );
      var cancellationPolls = 0;

      await expectLater(
        repository.stagePackage(
          version: '6.0.0',
          packageFile: packageFile,
          shouldCancel: () => ++cancellationPolls >= 7,
        ),
        throwsA(isA<Exception>()),
      );

      final root = await repository.enginesDirectory;
      expect(Directory(p.join(root.path, '6.0.0')).existsSync(), isFalse);
      expect(
        await root
            .list(followLinks: false)
            .where((entity) => p.basename(entity.path).startsWith('.staging-'))
            .toList(),
        isEmpty,
      );
    });

    test(
      'extracts a large file-backed ZIP entry within the declared bound',
      () async {
        const payloadBytes = int.fromEnvironment(
          'MPVSON_ENGINE_STRESS_BYTES',
          defaultValue: 32 * 1024 * 1024,
        );
        expect(payloadBytes, inInclusiveRange(1, 511 * 1024 * 1024));
        final temp = await Directory.systemTemp.createTemp(
          'engine-large-archive-test-',
        );
        final repository = EngineInstallationRepository(
          enginesDirectory: Directory(p.join(temp.path, 'engines')),
          maxUncompressedBytes: payloadBytes + 1024 * 1024,
        );
        addTearDown(() => temp.delete(recursive: true));
        final packageFile = await _writeLargeStreamedPackage(
          temp,
          payloadBytes: payloadBytes,
        );
        final currentRssBefore = ProcessInfo.currentRss;
        final maxRssBefore = ProcessInfo.maxRss;
        var sampledPeakRss = currentRssBefore;
        final sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
          final current = ProcessInfo.currentRss;
          if (current > sampledPeakRss) sampledPeakRss = current;
        });
        late final EngineInstallRecord record;
        try {
          record = await repository.stagePackage(
            version: '6.1.0',
            packageFile: packageFile,
          );
        } finally {
          sampler.cancel();
        }
        final currentRssAfter = ProcessInfo.currentRss;
        final maxRssAfter = ProcessInfo.maxRss;
        // ignore: avoid_print
        print(
          'Observational ${payloadBytes ~/ (1024 * 1024)} MiB engine extraction RSS (bytes): '
          'current $currentRssBefore -> $currentRssAfter; '
          'sampled peak $sampledPeakRss, delta ${sampledPeakRss - currentRssBefore}; '
          'peak $maxRssBefore -> $maxRssAfter. '
          'This is a local observation, not a memory limit guarantee.',
        );

        final extracted = File(p.join(record.path, 'runtime.bin'));
        expect(await extracted.length(), payloadBytes);
        expect(
          await File(p.join(record.path, 'libmpv-2.dll')).length(),
          greaterThan(0),
        );
      },
    );

    test(
      'protects boot attempt across processes with lease lock, token, and crash recovery',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-boot-lease-test-',
        );
        final enginesDir = Directory(p.join(temp.path, 'engines'));
        final repo1 = EngineInstallationRepository(
          enginesDirectory: enginesDir,
          bootLeaseTimeout: const Duration(milliseconds: 200),
        );
        final repo2 = EngineInstallationRepository(
          enginesDirectory: enginesDir,
          bootLeaseTimeout: const Duration(milliseconds: 200),
        );
        addTearDown(() => temp.delete(recursive: true));

        final packageBytes = _makePackage();
        final packageFile = await _writePackage(temp, packageBytes);
        await repo1.stagePackage(version: '4.0.0', packageFile: packageFile);

        final boot1 = await repo1.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
          bundledEngineVersion: '0.41.0',
        );
        expect(boot1.isPending, isTrue);
        expect(boot1.version, '4.0.0');

        final stateDuringBoot = await repo1.loadSelection();
        expect(stateDuringBoot.pendingBootInProgress, isTrue);
        expect(stateDuringBoot.bootAttemptToken, isNotNull);

        final boot2 = await repo2.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
          bundledEngineVersion: '0.41.0',
        );
        expect(boot2.isBundled, isTrue);

        final stateAfterConcurrent = await repo1.loadSelection();
        expect(stateAfterConcurrent.pendingBootInProgress, isTrue);
        expect(stateAfterConcurrent.pending?.version, '4.0.0');
        expect(
          stateAfterConcurrent.bootAttemptToken,
          stateDuringBoot.bootAttemptToken,
        );

        expect(() => repo2.confirmPendingBoot(), throwsStateError);
        expect(() => repo2.rejectPendingBoot(), throwsStateError);

        await repo1.simulateCrashForTesting();

        final bootAfterCrash = await repo2.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
          bundledEngineVersion: '0.41.0',
        );
        expect(bootAfterCrash.isBundled, isTrue);

        final stateAfterCrash = await repo2.loadSelection();
        expect(stateAfterCrash.pendingBootInProgress, isFalse);
        expect(stateAfterCrash.lastRejectedVersion, '4.0.0');
      },
    );

    test(
      'verifies runtime inventory and rejects dependencies modified or missing',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'engine-runtime-verify-test-',
        );
        final repo = _repository(temp);
        addTearDown(() => temp.delete(recursive: true));

        final packageBytes = _makePackage(
          extraFiles: {
            'avcodec-60.dll': [10, 20, 30, 40],
            'sub/swscale-7.dll': [50, 60, 70],
          },
        );
        final packageFile = await _writePackage(temp, packageBytes);
        final record = await repo.stagePackage(
          version: '5.0.0',
          packageFile: packageFile,
        );

        final markerFile = File(p.join(record.path, '.mpvson-engine.json'));
        expect(await markerFile.exists(), isTrue);
        final markerJson = jsonDecode(await markerFile.readAsString()) as Map;
        final dependencies = markerJson['dependencies'] as List;
        expect(dependencies.length, greaterThanOrEqualTo(3));

        final bootValid = await repo.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
          bundledEngineVersion: '0.41.0',
        );
        expect(bootValid.isPending, isTrue);
        expect(bootValid.version, '5.0.0');
        await repo.confirmPendingBoot();

        final depFile = File(p.join(record.path, 'avcodec-60.dll'));
        await depFile.writeAsBytes([99, 99, 99, 99], flush: true);

        final bootTampered = await repo.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
          bundledEngineVersion: '0.41.0',
        );
        expect(bootTampered.isBundled, isTrue);

        await depFile.writeAsBytes([10, 20, 30, 40], flush: true);

        final subDepFile = File(p.join(record.path, 'sub', 'swscale-7.dll'));
        await subDepFile.delete();

        final bootMissing = await repo.selectEngineForBoot(
          bundledEnginePath: r'C:\app\bundled\libmpv-2.dll',
          bundledEngineVersion: '0.41.0',
        );
        expect(bootMissing.isBundled, isTrue);
      },
    );
  });
}

EngineUpdateService _service({
  required http.Client client,
  required EngineInstallationRepository repository,
  required String publicKeyBase64,
  EngineUpdatePlatform platform = EngineUpdatePlatform.windows,
  String appVersion = '1.0.0',
}) {
  return EngineUpdateService(
    client: client,
    repository: repository,
    manifestUri: Uri.parse('https://updates.example.test/engine.json'),
    publicKeyBase64: publicKeyBase64,
    currentVersion: '1.0.0',
    appVersion: appVersion,
    supportedMediaKitVersion: '1.2.6',
    platformProvider: () => platform,
  );
}

EngineInstallationRepository _repository(Directory parent) {
  return EngineInstallationRepository(
    enginesDirectory: Directory(p.join(parent.path, 'engines')),
  );
}

String _githubReleaseJson({
  required List<int> package,
  String name =
      'libmpv-v0.41.0-dev-g01e2533f3-39050261656-x86_64-w64-mingw32-gpl.zip',
  String? digest,
  int? size,
  String state = 'uploaded',
  String? downloadUrlOverride,
}) {
  final packageHash = crypto.sha256.convert(package).toString();
  return jsonEncode({
    'tag_name': 'git-release',
    'draft': false,
    'prerelease': true,
    'html_url': 'https://github.com/mpv-player/mpv/releases/tag/git-release',
    'body': 'Development build from mpv CI.',
    'assets': [
      {
        'name':
            'libmpv-v0.41.0-dev-g01e2533f3-39050261656-aarch64-w64-mingw32-gpl.zip',
        'state': 'uploaded',
        'size': package.length,
        'digest': 'sha256:$packageHash',
        'browser_download_url':
            'https://github.com/mpv-player/mpv/releases/download/git-release/libmpv-v0.41.0-dev-g01e2533f3-39050261656-aarch64-w64-mingw32-gpl.zip',
      },
      {
        'name': name,
        'state': state,
        'size': size ?? package.length,
        'digest': digest ?? 'sha256:$packageHash',
        'browser_download_url':
            downloadUrlOverride ??
            'https://github.com/mpv-player/mpv/releases/download/git-release/$name',
      },
    ],
  });
}

String _githubStableReleaseJson({
  required List<Map<String, Object?>> assets,
  String tag = 'v0.41.0',
}) {
  return jsonEncode({
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'html_url': 'https://github.com/mpv-player/mpv/releases/tag/$tag',
    'body': 'Stable mpv release.',
    'assets': assets,
  });
}

Map<String, Object?> _githubStableAsset(List<int> package) {
  final name = 'libmpv-v0.41.0-x86_64-w64-mingw32-gpl.zip';
  final packageHash = crypto.sha256.convert(package).toString();
  return {
    'name': name,
    'state': 'uploaded',
    'size': package.length,
    'digest': 'sha256:$packageHash',
    'browser_download_url':
        'https://github.com/mpv-player/mpv/releases/download/v0.41.0/$name',
  };
}

List<int> _makePackage({Map<String, List<int>> extraFiles = const {}}) {
  final archive = Archive()
    ..addFile(ArchiveFile('libmpv-2.dll', 4, <int>[1, 2, 3, 4]))
    ..addFile(ArchiveFile('LICENSE.txt', 3, <int>[76, 73, 67]));
  for (final entry in extraFiles.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

List<int> _mutateCentralDirectorySize(
  List<int> source,
  String targetName,
  int declaredSize,
) {
  final bytes = List<int>.from(source);
  final nameBytes = utf8.encode(targetName);
  for (var index = 0; index + 46 <= bytes.length; index++) {
    if (bytes[index] != 0x50 ||
        bytes[index + 1] != 0x4b ||
        bytes[index + 2] != 0x01 ||
        bytes[index + 3] != 0x02) {
      continue;
    }
    final nameLength = bytes[index + 28] | (bytes[index + 29] << 8);
    if (nameLength != nameBytes.length ||
        index + 46 + nameLength > bytes.length) {
      continue;
    }
    var matches = true;
    for (var nameIndex = 0; nameIndex < nameBytes.length; nameIndex++) {
      if (bytes[index + 46 + nameIndex] != nameBytes[nameIndex]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    for (var byteIndex = 0; byteIndex < 4; byteIndex++) {
      bytes[index + 24 + byteIndex] = (declaredSize >> (byteIndex * 8)) & 0xff;
    }
    return bytes;
  }
  throw StateError('ZIP central directory entry not found: $targetName');
}

List<int> _mutateCentralDirectoryMode(
  List<int> source,
  String targetName,
  int unixMode,
) {
  final bytes = List<int>.from(source);
  final nameBytes = utf8.encode(targetName);
  for (var index = 0; index + 46 <= bytes.length; index++) {
    if (bytes[index] != 0x50 ||
        bytes[index + 1] != 0x4b ||
        bytes[index + 2] != 0x01 ||
        bytes[index + 3] != 0x02) {
      continue;
    }
    final nameLength = bytes[index + 28] | (bytes[index + 29] << 8);
    if (nameLength != nameBytes.length ||
        index + 46 + nameLength > bytes.length) {
      continue;
    }
    var matches = true;
    for (var nameIndex = 0; nameIndex < nameBytes.length; nameIndex++) {
      if (bytes[index + 46 + nameIndex] != nameBytes[nameIndex]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    // Central directory stores creator OS at offset 4 and external attributes
    // at offset 38. The high mode bits are meaningful for Unix entries.
    bytes[index + 4] = 20;
    bytes[index + 5] = 3;
    bytes[index + 38] = 0;
    bytes[index + 39] = 0;
    bytes[index + 40] = (unixMode >> 8) & 0xff;
    bytes[index + 41] = unixMode & 0xff;
    return bytes;
  }
  throw StateError('ZIP central directory entry not found: $targetName');
}

Future<File> _writePackage(Directory directory, List<int> bytes) async {
  final file = File(p.join(directory.path, 'package.zip'));
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<File> _writeLargeStreamedPackage(
  Directory directory, {
  required int payloadBytes,
}) async {
  final sourceDirectory = Directory(p.join(directory.path, 'large-package'));
  await sourceDirectory.create(recursive: true);
  final library = File(p.join(sourceDirectory.path, 'libmpv-2.dll'));
  await library.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
  final payload = File(p.join(sourceDirectory.path, 'runtime.bin'));
  final payloadHandle = await payload.open(mode: FileMode.write);
  try {
    await payloadHandle.truncate(payloadBytes);
  } finally {
    await payloadHandle.close();
  }

  final package = File(p.join(directory.path, 'large-package.zip'));
  final encoder = ZipFileEncoder();
  encoder.create(package.path, level: ZipFileEncoder.store);
  await encoder.addFile(library, 'libmpv-2.dll');
  await encoder.addFile(payload, 'runtime.bin');
  await encoder.close();
  return package;
}

Future<_SignedManifest> _signedManifest({
  required List<int> package,
  String engineVersion = '2.0.0',
  String mediaKitVersion = '1.2.6',
  String minimumAppVersion = '0.1.0',
  String? maximumAppVersionExclusive,
  String? sha256,
  int? sizeBytes,
}) async {
  final payload = <String, Object?>{
    'engineVersion': engineVersion,
    'notes': 'Engine package for tests.',
    'mediaKitVersion': mediaKitVersion,
    'minimumAppVersion': minimumAppVersion,
    'maximumAppVersionExclusive': ?maximumAppVersionExclusive,
    'artifacts': {
      'windows': {
        'url': 'https://updates.example.test/engine.zip',
        'sha256': sha256 ?? crypto.sha256.convert(package).toString(),
        'size': sizeBytes ?? package.length,
      },
    },
  };
  final canonicalPayload = utf8.encode(jsonEncode(_sortJson(payload)));
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final signature = await algorithm.sign(canonicalPayload, keyPair: keyPair);
  return _SignedManifest(
    manifest: jsonEncode({
      'schemaVersion': 1,
      'payload': payload,
      'signature': base64Encode(signature.bytes),
    }),
    publicKeyBase64: base64Encode(publicKey.bytes),
  );
}

Object? _sortJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _sortJson(value[key]),
    };
  }
  if (value is List) return value.map(_sortJson).toList(growable: false);
  return value;
}

class _SignedManifest {
  const _SignedManifest({
    required this.manifest,
    required this.publicKeyBase64,
  });

  final String manifest;
  final String publicKeyBase64;
}

class _FakeClient extends http.BaseClient {
  _FakeClient({required this.manifest, required this.package});

  final String manifest;
  final List<int> package;
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    final isManifest = request.url.path.endsWith('engine.json');
    final body = isManifest ? utf8.encode(manifest) : package;
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      HttpStatus.ok,
      contentLength: body.length,
    );
  }
}

class _TruncatedManifestClient extends _FakeClient {
  _TruncatedManifestClient({required super.manifest, required super.package});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await super.send(request);
    if (!request.url.path.endsWith('engine.json')) return response;
    return http.StreamedResponse(
      response.stream,
      response.statusCode,
      contentLength: response.contentLength! + 16,
    );
  }
}

class _CompressedManifestClient extends _FakeClient {
  _CompressedManifestClient({required super.manifest, required super.package});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await super.send(request);
    if (!request.url.path.endsWith('engine.json')) return response;
    // package:http yields the decompressed bytes while the response keeps the
    // compressed Content-Length and content-encoding header.
    final compressedLength = gzip.encode(utf8.encode(manifest)).length;
    return http.StreamedResponse(
      response.stream,
      response.statusCode,
      contentLength: compressedLength,
      headers: <String, String>{'content-encoding': 'gzip'},
    );
  }
}

class _GithubClient extends http.BaseClient {
  _GithubClient({
    required this.release,
    required this.package,
    this.stableRelease,
    this.rateLimited = false,
    this.apiResponseGate,
    this.apiRequestStarted,
    this.downloadResponseGate,
    this.downloadRequestStarted,
  });

  final String release;
  final String? stableRelease;
  final List<int> package;
  final bool rateLimited;
  final Completer<void>? apiResponseGate;
  final Completer<void>? apiRequestStarted;
  final Completer<void>? downloadResponseGate;
  final Completer<void>? downloadRequestStarted;
  int apiRequestCount = 0;
  int stableApiRequestCount = 0;
  int developmentApiRequestCount = 0;
  int downloadRequestCount = 0;
  Map<String, String>? apiHeaders;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final stableRequest = request.url == MpvGithubRelease.latestStableApiUri;
    if (stableRequest || request.url == MpvGithubRelease.apiUri) {
      apiRequestCount++;
      if (stableRequest) {
        stableApiRequestCount++;
      } else {
        developmentApiRequestCount++;
      }
      apiHeaders = Map<String, String>.from(request.headers);
      _signal(apiRequestStarted);
      if (apiResponseGate != null) await apiResponseGate!.future;
      if (rateLimited) {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          HttpStatus.forbidden,
          headers: const {'x-ratelimit-remaining': '0'},
        );
      }
      final bytes = utf8.encode(
        stableRequest ? stableRelease ?? release : release,
      );
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        HttpStatus.ok,
        contentLength: bytes.length,
      );
    }
    if (request.url.host == 'github.com' &&
        request.url.path.startsWith('/mpv-player/mpv/releases/download/')) {
      downloadRequestCount++;
      _signal(downloadRequestStarted);
      if (downloadResponseGate != null) {
        await downloadResponseGate!.future;
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(package),
        HttpStatus.ok,
        contentLength: package.length,
      );
    }
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      HttpStatus.notFound,
    );
  }

  void _signal(Completer<void>? completer) {
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}

class _StalledClient extends http.BaseClient {
  final StreamController<List<int>> controller = StreamController<List<int>>(
    sync: true,
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(controller.stream, HttpStatus.ok);
  }
}
