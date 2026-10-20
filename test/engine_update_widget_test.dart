import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Test fakes keep user-facing constructor names instead of private field names.
// ignore_for_file: prefer_initializing_formals
import 'package:mpvson/data/services/engine_update_service.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/engine_release.dart';
import 'package:mpvson/domain/updates/engine_update_channel.dart';
import 'package:mpvson/domain/updates/release_info.dart';
import 'package:mpvson/ui/core/app_theme.dart';
import 'package:mpvson/ui/player/views/update_center_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!const bool.fromEnvironment('MPVSON_CAPTURE_UI')) return;
    final fonts = <String, String>{
      if (Platform.isWindows) 'Segoe UI': r'C:\Windows\Fonts\segoeui.ttf',
    };
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) {
      fonts['MaterialIcons'] =
          '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf';
    }
    for (final font in fonts.entries) {
      final file = File(font.value);
      if (!await file.exists()) continue;
      final loader = FontLoader(
        font.key,
      )..addFont(file.readAsBytes().then((bytes) => bytes.buffer.asByteData()));
      await loader.load();
    }
  });
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('application package action only downloads the app update', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'available');
    final engine = _FakeEngineUpdates(status: 'available');

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();

      final action = find.text('Download package');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(app.downloadCalls, 1);
      expect(engine.stageCalls, 0);
      expect(engine.checkCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('engine staging action only stages the playback engine', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'available');
    final engine = _FakeEngineUpdates(
      status: 'available',
      sourceLabel: 'Custom signed feed',
      usesOfficialMpvSource: false,
    );

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();

      expect(find.text('Source: Custom signed feed'), findsOneWidget);
      expect(find.text('Engine version 0.40.0 is available.'), findsOneWidget);
      final stageAction = find.text('Download and stage');
      await tester.ensureVisible(stageAction);
      await tester.tap(stageAction);
      await tester.pumpAndSettle();

      expect(engine.stageCalls, 1);
      expect(app.downloadCalls, 0);
      expect(app.checkCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('stable source reports when no compatible package exists', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'unconfigured');
    final engine = _FakeEngineUpdates(
      status: 'idle',
      sourceLabel: 'Official mpv stable releases',
      usesOfficialMpvSource: true,
      stableReleaseVersion: '0.41.0',
      checkResultStatus: 'stableUnavailable',
    );

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Playback engine')).dy,
        lessThan(tester.getTopLeft(find.text('Application')).dy),
      );
      expect(find.text('Source: Official mpv stable releases'), findsOneWidget);
      expect(find.text('Update channel'), findsOneWidget);
      expect(find.text('Stable'), findsOneWidget);
      expect(find.text('Development'), findsOneWidget);
      expect(find.text('Not configured'), findsOneWidget);
      expect(
        find.text('Engine update checks are not configured for this build.'),
        findsNothing,
      );
      final checkAction = find.text('Check for engine updates');
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: checkAction,
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(checkAction);
      await tester.tap(checkAction);
      await tester.pumpAndSettle();

      expect(engine.checkCalls, 1);
      expect(find.text('Stable package unavailable'), findsOneWidget);
      expect(
        find.text(
          'mpv 0.41.0 does not publish a compatible Windows libmpv package. Mpvson will keep using the currently loaded engine.',
        ),
        findsOneWidget,
      );
      expect(find.text('Download and stage'), findsNothing);
      expect(app.checkCalls, 0);
      expect(app.downloadCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('development channel requires opt-in and identifies its build', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'unconfigured');
    final engine = _FakeEngineUpdates(
      status: 'idle',
      sourceLabel: 'Official mpv stable releases',
      usesOfficialMpvSource: true,
      checkResultStatus: 'available',
    );

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();

      expect(engine.channel, EngineUpdateChannel.stable);
      final development = find.text('Development');
      await tester.ensureVisible(development);
      await tester.tap(development);
      await tester.pumpAndSettle();

      expect(engine.channel, EngineUpdateChannel.development);
      expect(
        find.text('Source: Official mpv development builds'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Development follows mpv master. mpv marks these builds as untested.',
        ),
        findsOneWidget,
      );

      final checkAction = find.text('Check for engine updates');
      await tester.ensureVisible(checkAction);
      await tester.tap(checkAction);
      await tester.pumpAndSettle();

      expect(
        find.text('Upstream mpv development build 0.40.0 is available.'),
        findsOneWidget,
      );
      expect(find.text('Download and stage'), findsOneWidget);
      expect(app.checkCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('pending engine locks the channel chooser with an explanation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'unconfigured');
    final engine = _FakeEngineUpdates(
      status: 'readyToRestart',
      pendingVersion: '0.40.0',
    );

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();

      expect(
        find.text('Discard the pending engine to change channels.'),
        findsOneWidget,
      );
      final chooser = tester.widget<SegmentedButton<EngineUpdateChannel>>(
        find.byType(SegmentedButton<EngineUpdateChannel>),
      );
      expect(chooser.onSelectionChanged, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('engine package staging error is shown without app action', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'available');
    final engine = _FakeEngineUpdates(
      status: 'available',
      stageError: 'Engine package failed its SHA-256 integrity check.',
    );

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();
      final stageAction = find.text('Download and stage');
      await tester.ensureVisible(stageAction);
      await tester.tap(stageAction);
      await tester.pumpAndSettle();

      expect(engine.stageCalls, 1);
      expect(find.text('Update failed'), findsOneWidget);
      expect(
        find.text('Engine package failed its SHA-256 integrity check.'),
        findsOneWidget,
      );
      expect(app.checkCalls, 0);
      expect(app.downloadCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('Linux directs engine updates to the system package manager', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'unconfigured');
    final engine = _FakeEngineUpdates(
      status: 'available',
      canRollback: true,
      sourceLabel: 'System-managed engine',
      usesOfficialMpvSource: false,
    );

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'On Linux, the system package manager owns libmpv. Update it through your distribution.',
        ),
        findsOneWidget,
      );
      expect(find.text('Source: System-managed engine'), findsOneWidget);
      expect(find.text('Download and stage'), findsNothing);
      expect(find.text('Check engine status'), findsNothing);
      expect(find.text('Roll back engine'), findsNothing);
      expect(engine.checkCalls, 0);
      expect(engine.stageCalls, 0);
      expect(engine.rollbackCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('staged engine keeps loaded and pending versions distinct', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'unconfigured');
    final engine = _FakeEngineUpdates(
      status: 'readyToRestart',
      pendingVersion: '0.40.0',
    );

    try {
      await tester.pumpWidget(
        _dialog(app, engine, loadedVersion: 'libmpv test 0.39.0'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Loaded engine version libmpv test 0.39.0'),
        findsOneWidget,
      );
      expect(find.text('Staged version 0.40.0'), findsOneWidget);
      expect(
        find.text(
          'Restart Mpvson to activate the staged engine. The player currently has libmpv test 0.39.0 loaded.',
        ),
        findsOneWidget,
      );

      final discardAction = find.text('Discard pending engine');
      await tester.ensureVisible(discardAction);
      await tester.tap(discardAction);
      await tester.pumpAndSettle();

      expect(engine.discardCalls, 1);
      expect(app.downloadCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('bundled engine rollback queues only the engine target', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'available');
    final engine = _FakeEngineUpdates(
      status: 'upToDate',
      canRollback: true,
      rollbackVersion: '0.36.0',
      rollbackTargetIsBundled: true,
    );

    try {
      await tester.pumpWidget(
        _dialog(app, engine, loadedVersion: 'libmpv test 0.39.0'),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Select the bundled engine (version 0.36.0) for the next restart. The currently loaded engine (libmpv test 0.39.0) stays active until then.',
        ),
        findsOneWidget,
      );
      final rollbackAction = find.text('Roll back engine');
      await tester.ensureVisible(rollbackAction);
      await tester.tap(rollbackAction);
      await tester.pumpAndSettle();

      expect(engine.rollbackCalls, 1);
      expect(engine.stageCalls, 0);
      expect(engine.discardCalls, 0);
      expect(engine.checkCalls, 0);
      expect(app.downloadCalls, 0);
      expect(app.checkCalls, 0);
      expect(
        find.text('Loaded engine version libmpv test 0.39.0'),
        findsOneWidget,
      );
      expect(engine.pendingBundled, isTrue);
      expect(engine.pendingRollback, isTrue);
      expect(
        find.text(
          'Bundled engine version 0.36.0 selected for the next restart.',
        ),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('custom rollback is queued, not described as a new download', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    final app = _FakeAppUpdates(status: 'available');
    final engine = _FakeEngineUpdates(
      status: 'upToDate',
      canRollback: true,
      rollbackVersion: '0.38.0',
    );

    try {
      await tester.pumpWidget(
        _dialog(app, engine, loadedVersion: 'libmpv test 0.39.0'),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Select the previous compatible engine (version 0.38.0) for the next restart.',
        ),
        findsOneWidget,
      );
      final rollbackAction = find.text('Roll back engine');
      await tester.ensureVisible(rollbackAction);
      await tester.tap(rollbackAction);
      await tester.pumpAndSettle();

      expect(engine.rollbackCalls, 1);
      expect(app.downloadCalls, 0);
      expect(app.checkCalls, 0);
      expect(engine.pendingRollback, isTrue);
      expect(engine.pendingBundled, isFalse);
      expect(
        find.text(
          'Rollback to engine version 0.38.0 selected for the next restart.',
        ),
        findsOneWidget,
      );
      expect(find.text('Staged version 0.38.0'), findsNothing);
      expect(
        find.text(
          'Restart Mpvson to roll back to engine version 0.38.0. The player currently has libmpv test 0.39.0 loaded.',
        ),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('update actions remain reachable at 1.5 text scale', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    final app = _FakeAppUpdates(status: 'available');
    final engine = _FakeEngineUpdates(status: 'available');

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();
      await _capturePreview(tester, 'available-1_5x-top');

      final appAction = find.text('Download package');
      await tester.ensureVisible(appAction);
      await tester.tap(appAction);
      await tester.pumpAndSettle();
      expect(app.downloadCalls, 1);

      final engineAction = find.text('Download and stage');
      await tester.ensureVisible(engineAction);
      await _capturePreview(tester, 'available-1_5x-engine-action');
      await tester.tap(engineAction);
      await tester.pumpAndSettle();

      expect(engine.stageCalls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('ready app package and long hash wrap at 2x text scale', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(720, 480);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    final app = _FakeAppUpdates(status: 'ready');
    final engine = _FakeEngineUpdates(status: 'unconfigured');
    const sha =
        'SHA-256  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    try {
      await tester.pumpWidget(_dialog(app, engine));
      await tester.pumpAndSettle();
      await _capturePreview(tester, 'ready-app-2x-top');

      final hashText = find.text(sha);
      expect(hashText, findsOneWidget);
      final hashEditable = tester
          .state<EditableTextState>(
            find.descendant(
              of: find.byType(SelectableText),
              matching: find.byType(EditableText),
            ),
          )
          .renderEditable;
      final lines = hashEditable
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: sha.length),
          )
          .map((box) => box.top)
          .toSet();
      expect(lines.length, greaterThan(1));
      expect(tester.takeException(), isNull);

      final openAction = find.text('Open package');
      await tester.ensureVisible(openAction);
      await _capturePreview(tester, 'ready-app-2x-action');
      await tester.tap(openAction);
      await tester.pumpAndSettle();

      expect(app.openCalls, 1);
      expect(app.downloadCalls, 0);
      expect(engine.stageCalls, 0);
      expect(engine.checkCalls, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      engine.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

Widget _dialog(
  _FakeAppUpdates app,
  _FakeEngineUpdates engine, {
  String loadedVersion = 'libmpv test 0.40.0',
}) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(
    body: RepaintBoundary(
      key: const ValueKey('engine-updates-capture'),
      child: UpdateCenterDialog(
        updates: app,
        engineUpdates: engine,
        engineVersion: loadedVersion,
      ),
    ),
  ),
);

Future<void> _capturePreview(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('MPVSON_CAPTURE_UI')) return;
  await tester.pump(const Duration(milliseconds: 140));
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('engine-updates-capture')),
  );
  await tester.runAsync<void>(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('test-output/engine-updates/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

class _FakeAppUpdates extends UpdateService {
  _FakeAppUpdates({required String status})
    : _status = status,
      super(currentVersion: '1.2.0');

  final String _status;
  int checkCalls = 0;
  int downloadCalls = 0;
  int openCalls = 0;

  @override
  bool get configured => _status != 'unconfigured';

  @override
  String get status => _status;

  @override
  ReleaseInfo? get release => ReleaseInfo(
    version: '1.3.0',
    notes: 'Playback fixes.',
    engineVersion: 'libmpv 0.40.0',
    downloadUri: Uri(
      scheme: 'https',
      host: 'downloads.example',
      path: '/mpvson.zip',
    ),
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );

  @override
  Future<void> check() async {
    checkCalls++;
  }

  @override
  Future<void> download() async {
    downloadCalls++;
  }

  @override
  Future<void> openDownload() async {
    openCalls++;
  }
}

class _FakeEngineUpdates extends EngineUpdateService {
  _FakeEngineUpdates({
    required String status,
    String? pendingVersion,
    bool canRollback = false,
    String? rollbackVersion,
    bool pendingBundled = false,
    bool rollbackTargetIsBundled = false,
    String sourceLabel = 'Official mpv stable releases',
    bool usesOfficialMpvSource = true,
    EngineUpdateChannel channel = EngineUpdateChannel.stable,
    String? stableReleaseVersion,
    String? checkResultStatus,
    String? stageError,
  }) : _status = status,
       _pendingVersion = pendingVersion,
       _canRollback = canRollback,
       _rollbackVersion = rollbackVersion,
       _pendingBundled = pendingBundled,
       _rollbackTargetIsBundled = rollbackTargetIsBundled,
       _sourceLabel = sourceLabel,
       _usesOfficialMpvSource = usesOfficialMpvSource,
       _channel = channel,
       _stableReleaseVersion = stableReleaseVersion,
       _checkResultStatus = checkResultStatus,
       _stageError = stageError,
       _pendingRollback = false,
       super(
         currentVersion: '0.39.0',
         platformProvider: () => EngineUpdatePlatform.windows,
       );

  String _status;
  String? _pendingVersion;
  bool _canRollback;
  final String? _rollbackVersion;
  bool _pendingBundled;
  final bool _rollbackTargetIsBundled;
  final String _sourceLabel;
  final bool _usesOfficialMpvSource;
  EngineUpdateChannel _channel;
  final String? _stableReleaseVersion;
  final String? _checkResultStatus;
  final String? _stageError;
  bool _pendingRollback;
  String? _error;
  int checkCalls = 0;
  int stageCalls = 0;
  int discardCalls = 0;
  int rollbackCalls = 0;

  @override
  bool get configured => _status != 'unconfigured';

  @override
  bool get supportedPlatform => true;

  @override
  bool get selfManaged => true;

  @override
  String get status => _status;

  @override
  double get progress => 0;

  @override
  String? get error => _error;

  @override
  String get sourceLabel => !_usesOfficialMpvSource
      ? _sourceLabel
      : _channel == EngineUpdateChannel.stable
      ? 'Official mpv stable releases'
      : 'Official mpv development builds';

  @override
  bool get usesOfficialMpvSource => _usesOfficialMpvSource;

  @override
  EngineUpdateChannel get channel => _channel;

  @override
  String? get stableReleaseVersion => _stableReleaseVersion;

  @override
  EngineRelease? get release => EngineRelease(
    engineVersion: '0.40.0',
    notes: 'Playback fixes.',
    mediaKitVersion: '1.2.6',
    minimumAppVersion: '1.0.0',
    maximumAppVersionExclusive: null,
    downloadUri: Uri(
      scheme: 'https',
      host: 'downloads.example',
      path: '/libmpv.zip',
    ),
    sha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    sizeBytes: 128,
  );

  @override
  String get currentVersion => '0.39.0';

  @override
  String? get pendingVersion => _pendingVersion;

  @override
  bool get canRollback => _canRollback;

  @override
  String? get rollbackVersion => _rollbackVersion;

  @override
  bool get pendingBundled => _pendingBundled;

  @override
  bool get pendingRollback => _pendingRollback;

  @override
  bool get rollbackTargetIsBundled => _rollbackTargetIsBundled;

  @override
  Future<void> check() async {
    checkCalls++;
    if (_checkResultStatus case final nextStatus?) {
      _status = nextStatus;
      notifyListeners();
    }
  }

  @override
  Future<bool> setChannel(EngineUpdateChannel channel) async {
    if (!_usesOfficialMpvSource) return false;
    _channel = channel;
    _status = 'idle';
    notifyListeners();
    return true;
  }

  @override
  Future<void> downloadAndStage() async {
    stageCalls++;
    if (_stageError case final message?) {
      _error = message;
      _status = 'error';
      notifyListeners();
    }
  }

  @override
  Future<void> discardPending() async {
    discardCalls++;
  }

  @override
  Future<void> scheduleRollback({String? bundledEnginePath}) async {
    rollbackCalls++;
    _pendingVersion = _rollbackVersion;
    _pendingBundled = _rollbackTargetIsBundled;
    _pendingRollback = true;
    _canRollback = false;
    _status = 'readyToRestart';
    notifyListeners();
  }
}
