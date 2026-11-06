import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/views/update_center_dialog.dart';

import '../support/app_harness.dart';
import '../support/audit_helpers.dart';
import '../support/screenshot.dart';

const bool _shotsEnabled = bool.fromEnvironment('SHOTS');

void main() {
  setUpAll(loadAppFonts);

  testWidgets('update dialog screenshots', (tester) async {
    configureView(tester, size: const Size(800, 700));
    final engineUpdates = EngineUpdateService(
      appVersion: '0.1.0',
      supportedMediaKitVersion: '1.2.6',
    );
    addTearDown(engineUpdates.dispose);

    final busy = await _downloadingService(tester);
    for (final dark in [true, false]) {
      await tester.pumpWidget(
        _host(dark: dark, updates: busy, engineUpdates: engineUpdates),
      );
      await settle(tester);
      await capture(tester, '${dark ? 'dark' : 'light'}_update_busy');
    }

    final unconfigured = UpdateService(currentVersion: '0.1.0');
    addTearDown(unconfigured.dispose);
    for (final dark in [true, false]) {
      await tester.pumpWidget(
        _host(dark: dark, updates: unconfigured, engineUpdates: engineUpdates),
      );
      await settle(tester);
      await capture(tester, '${dark ? 'dark' : 'light'}_update_unconfigured');
    }
  }, skip: !_shotsEnabled);

  testWidgets('update dialog keeps layout and font at compact text scale', (
    tester,
  ) async {
    configureView(tester, size: const Size(720, 480), textScale: 1.5);
    final updates = await _downloadingService(tester);
    final problems = <String>[];

    for (final dark in [true, false]) {
      final engineUpdates = EngineUpdateService(
        appVersion: '0.1.0',
        supportedMediaKitVersion: '1.2.6',
      );
      problems.addAll(
        await auditStep(tester, dark ? 'dark' : 'light', () async {
          await tester.pumpWidget(
            _host(dark: dark, updates: updates, engineUpdates: engineUpdates),
          );
          await settle(tester);
        }),
      );
      engineUpdates.dispose();
    }

    expect(problems.toSet().toList(), isEmpty, reason: problems.join('\n'));
  });
}

Widget _host({
  required bool dark,
  required UpdateService updates,
  required EngineUpdateService engineUpdates,
}) {
  final theme = dark ? AppTheme.darkTheme() : AppTheme.lightTheme();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      body: RepaintBoundary(
        key: screenshotKey,
        child: Center(
          child: UpdateCenterDialog(
            updates: updates,
            engineUpdates: engineUpdates,
            engineVersion: 'v0.42.0',
          ),
        ),
      ),
    ),
  );
}

Future<UpdateService> _downloadingService(WidgetTester tester) async {
  final directory = await tester.runAsync(
    () => Directory.systemTemp.createTemp('mpvson_update_dialog_'),
  );
  final client = _DownloadingClient();
  final service = UpdateService(
    manifestUri: Uri.parse('https://updates.test/manifest.json'),
    client: client,
    currentVersion: '0.1.0',
    supportDirectoryProvider: () async => directory!,
    platformProvider: () => UpdatePlatform.windows,
  );

  await tester.runAsync(() async {
    await service.check();
    unawaited(service.download());
    client.emit(40);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });

  addTearDown(() async {
    service.dispose();
    client.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      await directory!.delete(recursive: true);
    } on FileSystemException {
      // The OS can hold the partial download briefly; temp cleanup is best effort.
    }
  });
  return service;
}

class _DownloadingClient extends http.BaseClient {
  final _download = StreamController<List<int>>();

  void emit(int bytes) => _download.add(List<int>.filled(bytes, 0));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/manifest.json')) {
      final body = utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'version': '0.2.0',
          'engineVersion': '0.42.0',
          'notes': '* Faster startup\n* Smoother seeking',
          'artifacts': {
            'windows': {
              'url': 'https://updates.test/Mpvson-0.2.0.zip',
              'sha256': 'a' * 64,
            },
            'linux': {
              'url': 'https://updates.test/Mpvson-0.2.0.tar.gz',
              'sha256': 'b' * 64,
            },
          },
        }),
      );
      return http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: body.length,
      );
    }
    return http.StreamedResponse(_download.stream, 200, contentLength: 100);
  }

  @override
  void close() {
    if (!_download.isClosed) _download.close();
    super.close();
  }
}
