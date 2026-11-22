import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_applier.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/views/update_center_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  Future<Directory> createTempDir() async {
    final dir = await Directory.systemTemp.createTemp('mpvson-update-ui-');
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
        'notes': '- Improved auto-updater\n- Bug fixes',
        'engineVersion': '0.42.0',
        'releaseUrl': 'https://example.org/releases/$version',
        'artifacts': <String, Object?>{
          'windows': <String, Object?>{
            'url': 'https://example.org/MpvsonSetup.exe',
            'sha256': sha256Hex,
          },
          'linux': <String, Object?>{
            'url': 'https://example.org/mpvson-linux-x64.tar.gz',
            'sha256': sha256Hex,
          },
        },
      });

  Widget buildDialogHost({
    required UpdateService updates,
    required EngineUpdateService engineUpdates,
  }) => MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(
      body: UpdateCenterDialog(
        updates: updates,
        engineUpdates: engineUpdates,
        engineVersion: '0.42.0',
      ),
    ),
  );

  Future<void> waitUntilNotBusy(
    WidgetTester tester,
    UpdateService updates,
  ) async {
    for (var i = 0; i < 100 && updates.busy; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();
  }

  /// Stands in for the desktop lifecycle, which is the only production caller
  /// allowed to launch a prepared package after the save decision is settled.
  Future<void> armAndLaunch(WidgetTester tester, UpdateService updates) async {
    await tester.runAsync(updates.launchPreparedInstall);
    await tester.pump();
    await waitUntilNotBusy(tester, updates);
  }

  group('UpdateCenterDialog application update flow', () {
    testWidgets(
      'shows Update & restart when available and transitions to Installing on tap',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final supportDir = (await tester.runAsync(createTempDir))!;
        final payload = utf8.encode('installer-exe-bytes');
        final hash = sha256.convert(payload).toString();
        final launchedPaths = <String>[];

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

        final updates = UpdateService(
          manifestUri: Uri.parse('https://example.org/manifest.json'),
          client: client,
          supportDirectoryProvider: () async => supportDir,
          platformProvider: () => UpdatePlatform.windows,
          installMode: AppInstallMode.windowsInstaller,
          isWindowsProvider: () => true,
          installerLauncher: (path) async => launchedPaths.add(path),
          currentVersion: '0.1.0',
        );
        final engineUpdates = EngineUpdateService(
          appVersion: '0.1.0',
          currentVersion: '0.42.0',
          supportedMediaKitVersion: '1.2.6',
        );
        addTearDown(() {
          updates.dispose();
          engineUpdates.dispose();
        });

        await tester.runAsync(updates.check);
        await tester.pumpWidget(
          buildDialogHost(updates: updates, engineUpdates: engineUpdates),
        );
        await tester.pump();

        expect(find.text('Update & restart'), findsOneWidget);

        await tester.ensureVisible(find.text('Update & restart'));
        await tester.pump();
        await tester.tap(find.text('Update & restart'));
        await tester.pump();
        await waitUntilNotBusy(tester, updates);

        // The dialog only downloads, verifies, stages and records the intent.
        // No installer may run before the desktop lifecycle approves closing.
        expect(launchedPaths, isEmpty);
        expect(updates.status, 'ready');
        expect(updates.installPrepared, isTrue);
        expect(updates.restartRequested, isTrue);

        await armAndLaunch(tester, updates);

        expect(launchedPaths, hasLength(1));
        expect(updates.status, 'installing');
        expect(updates.restartRequested, isFalse);
        expect(find.text('Installing…'), findsOneWidget);

        final button = tester.widget<FilledButton>(
          find.ancestor(
            of: find.text('Installing…'),
            matching: find.byType(FilledButton),
          ),
        );
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'shows Retry update when download fails and Retry install + Show in folder when apply fails',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final supportDir = (await tester.runAsync(createTempDir))!;
        final payload = utf8.encode('installer-exe-bytes');
        final hash = sha256.convert(payload).toString();
        var failDownload = true;
        var failInstall = true;

        final client = MockClient((request) async {
          if (request.url.path == '/manifest.json') {
            return http.Response(
              manifestJson(version: '0.2.0', sha256Hex: hash),
              200,
            );
          }
          if (failDownload) {
            return http.Response('download error', 500);
          }
          return http.Response.bytes(
            payload,
            200,
            headers: <String, String>{'content-length': '${payload.length}'},
          );
        });

        final updates = UpdateService(
          manifestUri: Uri.parse('https://example.org/manifest.json'),
          client: client,
          supportDirectoryProvider: () async => supportDir,
          platformProvider: () => UpdatePlatform.windows,
          installMode: AppInstallMode.windowsInstaller,
          isWindowsProvider: () => true,
          installerLauncher: (path) async {
            if (failInstall) {
              throw const FileSystemException('Blocked by AV');
            }
          },
          currentVersion: '0.1.0',
        );
        final engineUpdates = EngineUpdateService(
          appVersion: '0.1.0',
          currentVersion: '0.42.0',
          supportedMediaKitVersion: '1.2.6',
        );
        addTearDown(() {
          updates.dispose();
          engineUpdates.dispose();
        });

        await tester.runAsync(() async {
          await updates.check();
          await updates.download();
        });
        expect(updates.status, 'error');
        expect(updates.failedDuringDownload, isTrue);

        await tester.pumpWidget(
          buildDialogHost(updates: updates, engineUpdates: engineUpdates),
        );
        await tester.pump();

        expect(find.text('Retry update'), findsOneWidget);

        // Retry download -> verifies and stages, but does not launch anything.
        failDownload = false;
        await tester.ensureVisible(find.text('Retry update'));
        await tester.pump();
        await tester.tap(find.text('Retry update'));
        await tester.pump();
        await waitUntilNotBusy(tester, updates);

        expect(updates.status, 'ready');
        expect(updates.installPrepared, isTrue);
        expect(updates.restartRequested, isTrue);

        // The lifecycle launch fails; the verified package stays for retry.
        await armAndLaunch(tester, updates);
        expect(updates.status, 'error');
        expect(updates.failureKind, 'apply');
        expect(find.text('Retry install'), findsOneWidget);
        expect(find.text('Show in folder'), findsOneWidget);

        // Retrying re-arms the prepared package; the launch now succeeds.
        failInstall = false;
        await tester.ensureVisible(find.text('Retry install'));
        await tester.pump();
        await tester.tap(find.text('Retry install'));
        await tester.pump();
        expect(updates.restartRequested, isTrue);

        await armAndLaunch(tester, updates);
        expect(updates.status, 'installing');
        expect(find.text('Installing…'), findsOneWidget);
      },
    );
  });
}
