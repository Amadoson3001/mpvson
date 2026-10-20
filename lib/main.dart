import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/repositories/engine_installation_repository.dart';
import 'data/repositories/session_repository.dart';
import 'data/services/diagnostic_log.dart';
import 'data/services/engine_update_service.dart';
import 'data/services/playback_service.dart';
import 'data/services/thumbnail_service.dart';
import 'data/services/update_service.dart';
import 'domain/updates/bundled_engine.dart';
import 'domain/updates/engine_selection.dart';
import 'ui/core/app_theme.dart';
import 'ui/player/player_controller.dart';
import 'verification/playback_benchmark.dart';

const WindowOptions _windowOptions = WindowOptions(
  size: Size(1240, 780),
  minimumSize: Size(720, 480),
  center: true,
  title: 'Mpvson',
  titleBarStyle: TitleBarStyle.normal,
);

const String _supportedMediaKitVersion = '1.2.6';

Future<EngineBootSelection> _initializeMediaKitWithFallbacks(
  EngineUpdateService engineUpdates,
  EngineBootSelection initial, {
  required String? bundledEnginePath,
  required List<String> arguments,
}) async {
  try {
    if (Platform.isWindows) {
      await const MethodChannel(
        'mpvson/engine',
      ).invokeMethod<void>('configure', initial.libraryPath);
    }
    MediaKit.ensureInitialized(libmpv: initial.libraryPath);
    return initial;
  } on Object {
    if (engineUpdates.selfManaged && !initial.isBundled) {
      await _recoverEngineProcess(
        engineUpdates,
        initial,
        bundledEnginePath: bundledEnginePath,
        arguments: arguments,
      );
    }
    rethrow;
  }
}

Future<Never> _recoverEngineProcess(
  EngineUpdateService engineUpdates,
  EngineBootSelection failed, {
  required String? bundledEnginePath,
  required List<String> arguments,
}) async {
  var recoveryCount = 0;
  for (final argument in arguments) {
    if (argument.startsWith('--engine-recovery=')) {
      recoveryCount = int.tryParse(argument.split('=').last) ?? 0;
    }
  }
  if (recoveryCount >= 3) {
    throw StateError('The playback engine recovery limit was reached.');
  }
  await engineUpdates.rejectBootSelection(
    failed,
    bundledEnginePath: bundledEnginePath,
  );
  engineUpdates.dispose();
  try {
    await windowManager.ensureInitialized();
    await windowManager.hide();
  } on Object {
    // A library failure may happen before the desktop window is ready.
  }
  // MediaKit and its native initializers retain process-wide bindings. A fresh
  // process ensures every player and rendering call uses the fallback module.
  final verifying = arguments.any((value) => value.startsWith('--smoke-test='));
  final child = await Process.start(
    Platform.resolvedExecutable,
    [
      ...arguments.where((value) => !value.startsWith('--engine-recovery=')),
      '--engine-recovery=${recoveryCount + 1}',
    ],
    workingDirectory: File(Platform.resolvedExecutable).parent.path,
    mode: verifying ? ProcessStartMode.normal : ProcessStartMode.detached,
  );
  if (!verifying) exit(0);
  final output = stdout.addStream(child.stdout);
  final errors = stderr.addStream(child.stderr);
  final code = await child.exitCode;
  await Future.wait([output, errors]);
  exit(code);
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 16 * 1024 * 1024;
  final smoke = _SmokeOptions.parse(arguments);

  final versionFuture = () async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } on Object {
      return '0.1.0';
    }
  }();

  final windowInitFuture = () async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(_windowOptions);
    } on Object catch (error) {
      return error;
    }
    return null;
  }();

  final currentVersion = await versionFuture;

  final bundledEnginePath = Platform.isWindows
      ? p.join(File(Platform.resolvedExecutable).parent.path, 'libmpv-2.dll')
      : null;
  final engineUpdates = EngineUpdateService(
    repository: smoke == null
        ? null
        : EngineInstallationRepository(
            enginesDirectory: Directory(
              smoke.engineStorePath ??
                  p.join(File(smoke.reportPath).parent.path, '.smoke-engines'),
            ),
          ),
    appVersion: currentVersion,
    currentVersion: bundledEngineVersion,
    supportedMediaKitVersion: _supportedMediaKitVersion,
  );
  EngineBootSelection? engineSelection;

  Object? startupError;
  try {
    engineSelection = await engineUpdates.selectEngineForBoot(
      bundledEnginePath: bundledEnginePath,
    );
    engineSelection = await _initializeMediaKitWithFallbacks(
      engineUpdates,
      engineSelection,
      bundledEnginePath: bundledEnginePath,
      arguments: arguments,
    );
  } on Object catch (error) {
    startupError = error;
  }

  final windowError = await windowInitFuture;
  startupError ??= windowError;

  if (startupError != null) {
    engineUpdates.dispose();
    if (smoke != null) {
      final report = <String, Object?>{
        'success': false,
        'error':
            'Could not initialize the desktop playback engine: $startupError',
      };
      if (smoke.screenshotPath != null) {
        report['screenshotPath'] = smoke.screenshotPath;
        report['visualCaptureSuccess'] = false;
        report['screenshotError'] = 'Capture skipped because startup failed.';
      }
      await _writeSmokeReport(smoke.reportPath, report);
      exit(1);
    }
    runApp(_StartupFailureApp(error: startupError.toString()));
    await _showFallbackWindow();
    return;
  }

  PlayerController? controller;
  PlaybackService? playback;
  final updates = UpdateService(currentVersion: currentVersion);
  Object? controllerError;
  final sessionDirectory = smoke == null
      ? null
      : _smokeSessionDirectory(smoke.reportPath);
  final diagnostics = FileDiagnosticLog(directory: sessionDirectory);
  try {
    playback = PlaybackService(diagnostics: diagnostics);
    controller = PlayerController(
      playback: playback,
      thumbnails: MediaKitThumbnailService(
        cacheDirectory: sessionDirectory == null
            ? null
            : Directory(p.join(sessionDirectory.path, 'thumbnails')),
        diagnostics: diagnostics,
      ),
      sessions: SessionRepository(directory: sessionDirectory),
      diagnostics: diagnostics,
    );
    controllerError = null;
  } on Object catch (error) {
    controllerError = error;
    if (controller != null) {
      try {
        await controller
            .close(discard: true)
            .timeout(const Duration(seconds: 3));
      } on Object {
        // Preserve the original engine/controller failure.
      }
    } else {
      try {
        await playback?.dispose().timeout(const Duration(seconds: 3));
      } on Object {
        // Preserve the original engine/controller failure.
      }
    }
    controller = null;
    playback = null;

    final failedSelection = engineSelection;
    if (failedSelection == null ||
        !engineUpdates.selfManaged ||
        failedSelection.isBundled) {
      // The bundled fallback failed. Show the startup error below.
    } else {
      await _recoverEngineProcess(
        engineUpdates,
        failedSelection,
        bundledEnginePath: bundledEnginePath,
        arguments: arguments,
      );
    }
  }

  if (controllerError != null || controller == null) {
    updates.dispose();
    engineUpdates.dispose();
    if (smoke != null) {
      await _writeSmokeReport(smoke.reportPath, <String, Object?>{
        'success': false,
        'error':
            'Could not initialize the playback controller: $controllerError',
        if (smoke.screenshotPath != null) ...<String, Object?>{
          'screenshotPath': smoke.screenshotPath,
          'visualCaptureSuccess': false,
          'screenshotError':
              'Capture skipped because controller startup failed.',
        },
      });
      exit(1);
    }
    runApp(_StartupFailureApp(error: controllerError.toString()));
    await _showFallbackWindow();
    return;
  }

  final readyController = controller;
  final readyPlayback = playback!;
  final readyUpdates = updates;
  final selectedEngine = engineSelection;

  final screenshotKey = GlobalKey();
  final lifecycle = _DesktopLifecycle(
    controller: readyController,
    updates: readyUpdates,
    engineUpdates: engineUpdates,
    engineLibraryPath: engineSelection?.libraryPath,
    screenshotKey: screenshotKey,
  );
  await windowManager.setPreventClose(true);
  windowManager.addListener(lifecycle);

  // Mount the real UI frame instantly
  runApp(
    RepaintBoundary(
      key: screenshotKey,
      child: MpvsonApp(
        controller: readyController,
        updates: readyUpdates,
        engineUpdates: engineUpdates,
        desktopWindow: true,
      ),
    ),
  );
  await windowManager.show();
  await windowManager.focus();

  // Engine staging confirmation, native event observation, and update initialization
  // run concurrently without delaying the initial UI frame.
  if (selectedEngine?.isPending ?? false) {
    try {
      await engineUpdates.confirmPendingBoot();
    } on Object catch (error) {
      stderr.writeln('Could not commit the staged playback engine: $error');
    }
  }
  unawaited(engineUpdates.initialize());
  unawaited(readyPlayback.prepare());

  if (smoke != null) {
    await readyController.initialize().timeout(const Duration(seconds: 20));
    unawaited(
      _runSmokeTest(
        smoke,
        readyController,
        lifecycle,
        screenshotKey,
        diagnostics: diagnostics,
      ),
    );
    return;
  }

  final paths = arguments.where(
    (argument) =>
        !argument.startsWith('--smoke-test=') &&
        !argument.startsWith('--smoke-report=') &&
        !argument.startsWith('--smoke-screenshot=') &&
        !argument.startsWith('--'),
  );
  if (paths.isNotEmpty) {
    await readyController.initialize().timeout(const Duration(seconds: 20));
    unawaited(readyController.openPaths(paths.toList(growable: false)));
  } else {
    unawaited(readyController.initialize());
  }
}

Future<void> _showFallbackWindow() async {
  try {
    await windowManager.show();
    await windowManager.focus();
  } on Object {
    // If the window plugin itself failed, Flutter's fallback still remains
    // available to the platform runner rather than masking the startup error.
  }
}

class _DesktopLifecycle extends WindowListener {
  _DesktopLifecycle({
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.engineLibraryPath,
    required this.screenshotKey,
  });

  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final String? engineLibraryPath;
  final GlobalKey screenshotKey;
  bool _closing = false;

  @override
  void onWindowClose() {
    unawaited(closeWindow());
  }

  Future<void> closeWindow() async {
    if (_closing) return;
    _closing = true;
    var failure = await _attemptClose();
    while (failure != null) {
      switch (await _promptForSaveFailure(failure)) {
        case _ClosePromptAction.retry:
          failure = await _attemptClose();
        case _ClosePromptAction.closeWithoutSaving:
          failure = null;
        case _ClosePromptAction.cancel:
        case null:
          // Keep the player open: the shutdown is cancelled from every phase.
          controller.cancelClose();
          _closing = false;
          return;
      }
    }
    await _releaseServices(discard: true);
    await _finishWindowClose();
  }

  /// Runs one shutdown attempt, reporting a save failure instead of throwing.
  Future<SessionSaveException?> _attemptClose() async {
    try {
      if (controller.closingState == ControllerClosingState.awaitingDecision) {
        // A previous attempt parked the controller in its decision phase; only
        // an explicit retry starts a new save.
        await controller.retryClose();
      } else {
        await controller.close();
      }
      return null;
    } on SessionSaveException catch (error) {
      return error;
    } on Object {
      // Continue disposing other services if an unexpected error occurs.
      return null;
    }
  }

  /// Asks the user how to continue when the session could not be saved.
  Future<_ClosePromptAction?> _promptForSaveFailure(
    SessionSaveException error,
  ) async {
    final navigator = _findNavigator();
    if (navigator == null || !navigator.mounted) {
      // Without a window to ask through, closing without saving is the only
      // outcome that cannot trap the user in an unsaved session.
      return _ClosePromptAction.closeWithoutSaving;
    }
    return showDialog<_ClosePromptAction>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (context) => _SessionSaveErrorDialog(error: error.message),
    );
  }

  Future<void> prepareSmokeShutdown() async {
    if (_closing) return;
    _closing = true;
    await _releaseServices(discard: true);
  }

  Future<void> destroySmokeWindow() async {
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  Future<void> _releaseServices({bool discard = false}) async {
    windowManager.removeListener(this);
    try {
      await controller.close(discard: discard);
    } on Object {
      // Preserve the window-close path even if a platform teardown fails.
    }
    updates.dispose();
    engineUpdates.dispose();
  }

  Future<void> _finishWindowClose() async {
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } on Object {
      await windowManager.destroy();
    }
  }

  NavigatorState? _findNavigator() {
    final context = screenshotKey.currentContext;
    if (context is! Element) return null;
    NavigatorState? navigator;
    void search(Element e) {
      if (navigator != null) return;
      if (e is StatefulElement && e.state is NavigatorState) {
        navigator = e.state as NavigatorState;
        return;
      }
      e.visitChildElements(search);
    }

    search(context);
    return navigator;
  }
}

enum _ClosePromptAction { retry, closeWithoutSaving, cancel }

class _SessionSaveErrorDialog extends StatelessWidget {
  const _SessionSaveErrorDialog({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: AppTheme.border),
      ),
      title: const Text(
        'Could not save playback session',
        style: TextStyle(color: AppTheme.primaryText, fontSize: 18),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Mpvson was unable to save your current session state. You can retry saving, close without saving your progress, or cancel to keep the player open.',
              style: TextStyle(color: AppTheme.secondaryText, fontSize: 14),
            ),
            if (error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                error,
                style: const TextStyle(color: AppTheme.mutedText, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_ClosePromptAction.cancel),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppTheme.mutedText),
          ),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_ClosePromptAction.closeWithoutSaving),
          child: const Text(
            'Close without saving',
            style: TextStyle(color: AppTheme.danger),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.accent,
            foregroundColor: AppTheme.deepBackground,
          ),
          onPressed: () => Navigator.of(context).pop(_ClosePromptAction.retry),
          child: const Text('Retry'),
        ),
      ],
    );
  }
}

Directory _smokeSessionDirectory(String reportPath) {
  final reportParent = File(reportPath).parent.path;
  final uniqueName =
      '.mpvson-smoke-session-${DateTime.now().microsecondsSinceEpoch}';
  return Directory(p.join(reportParent, uniqueName));
}

class _SmokeOptions {
  const _SmokeOptions({
    required this.mediaPath,
    required this.reportPath,
    this.screenshotPath,
    this.verifyFullscreen = false,
    this.engineStorePath,
    this.benchmarkCycles = 0,
    this.benchmarkReportPath,
    this.benchmarkQueuePath,
    this.benchmarkWarmupMs = 5000,
  });

  final String mediaPath;
  final String reportPath;
  final String? screenshotPath;
  final bool verifyFullscreen;
  final String? engineStorePath;
  final int benchmarkCycles;
  final String? benchmarkReportPath;
  final String? benchmarkQueuePath;
  final int benchmarkWarmupMs;

  static _SmokeOptions? parse(List<String> arguments) {
    String? mediaPath;
    String? reportPath;
    String? screenshotPath;
    String? engineStorePath;
    var benchmarkCycles = 0;
    String? benchmarkReportPath;
    String? benchmarkQueuePath;
    var benchmarkWarmupMs = 5000;
    for (final argument in arguments) {
      if (argument.startsWith('--smoke-test=')) {
        mediaPath = argument.substring('--smoke-test='.length).trim();
      } else if (argument.startsWith('--smoke-report=')) {
        reportPath = argument.substring('--smoke-report='.length).trim();
      } else if (argument.startsWith('--smoke-screenshot=')) {
        screenshotPath = argument
            .substring('--smoke-screenshot='.length)
            .trim();
      } else if (argument.startsWith('--smoke-engine-store=')) {
        engineStorePath = argument.substring('--smoke-engine-store='.length);
      } else if (argument.startsWith('--benchmark-cycles=')) {
        benchmarkCycles =
            int.tryParse(
              argument.substring('--benchmark-cycles='.length).trim(),
            ) ??
            0;
      } else if (argument.startsWith('--benchmark-report=')) {
        benchmarkReportPath = argument
            .substring('--benchmark-report='.length)
            .trim();
      } else if (argument.startsWith('--benchmark-queue=')) {
        benchmarkQueuePath = argument
            .substring('--benchmark-queue='.length)
            .trim();
      } else if (argument.startsWith('--benchmark-warmup-ms=')) {
        benchmarkWarmupMs = int.parse(
          argument.substring('--benchmark-warmup-ms='.length),
        );
      }
    }
    if (mediaPath == null && reportPath == null && screenshotPath == null) {
      return null;
    }
    return _SmokeOptions(
      mediaPath: mediaPath ?? '',
      reportPath: reportPath == null || reportPath.isEmpty
          ? defaultSmokeReportPath
          : reportPath,
      screenshotPath: screenshotPath == null || screenshotPath.isEmpty
          ? null
          : screenshotPath,
      verifyFullscreen: arguments.contains('--smoke-fullscreen'),
      engineStorePath: engineStorePath,
      benchmarkCycles: benchmarkCycles,
      benchmarkReportPath: benchmarkReportPath,
      benchmarkQueuePath: benchmarkQueuePath,
      benchmarkWarmupMs: benchmarkWarmupMs.clamp(1000, 60000),
    );
  }
}

const String defaultSmokeReportPath = 'mpvson-smoke-report.json';

Future<void> _runSmokeTest(
  _SmokeOptions options,
  PlayerController controller,
  _DesktopLifecycle lifecycle,
  GlobalKey screenshotKey, {
  DiagnosticSink? diagnostics,
}) async {
  final result = <String, Object?>{
    'success': false,
    'path': options.mediaPath,
    'engineVersion': controller.engineVersion,
    'engineVersionBeforeOpen': controller.engineVersion,
    'engineLibraryPath': lifecycle.engineLibraryPath,
  };
  if (options.screenshotPath != null) {
    result['screenshotPath'] = options.screenshotPath;
    result['visualCaptureSuccess'] = false;
  }
  var success = false;
  final smokeDeadline = Duration(
    seconds: options.benchmarkCycles > 0
        ? 120 + options.benchmarkCycles * 3
        : options.verifyFullscreen
        ? 20
        : 14,
  );
  final watchdog = Timer(smokeDeadline, () async {
    result['error'] =
        'Smoke test exceeded its ${smokeDeadline.inSeconds} second deadline.';
    await _writeSmokeReport(options.reportPath, result);
    exit(1);
  });

  try {
    if (Platform.isWindows) {
      final rendererPath = await const MethodChannel(
        'mpvson/engine',
      ).invokeMethod<String>('libraryPath');
      result['rendererEngineLibraryPath'] = rendererPath;
      if (rendererPath == null ||
          !p.equals(
            p.normalize(p.absolute(rendererPath)),
            p.normalize(p.absolute(lifecycle.engineLibraryPath!)),
          )) {
        throw StateError('The renderer and player selected different engines.');
      }
    }
    if (options.mediaPath.isEmpty) {
      throw ArgumentError('Provide a media path with --smoke-test=<path>.');
    }
    await controller.setVolume(0);
    await controller.openPaths(<String>[options.mediaPath]);
    await _waitFor(
      () => controller.duration > Duration.zero && controller.isPlaying,
      timeout: const Duration(seconds: 10),
      describe: () => _describePlayback(controller),
    );
    final duration = controller.duration;
    final engineVersion = controller.engineVersion;
    if (engineVersion.contains('unavailable')) {
      throw StateError('libmpv did not report its native version.');
    }

    final targetMs = min(
      duration.inMilliseconds ~/ 3,
      1000,
    ).clamp(100, 1000).toInt();
    final target = Duration(milliseconds: targetMs);
    await controller.seek(target);
    final thresholdMs = targetMs - min(300, targetMs ~/ 2);
    await _waitFor(
      () => controller.player.state.position.inMilliseconds >= thresholdMs,
      timeout: const Duration(seconds: 3),
    );
    final actualPosition = controller.player.state.position;
    if (options.verifyFullscreen) {
      await windowManager.setFullScreen(true);
      if (!await windowManager.isFullScreen()) {
        throw StateError('Native fullscreen was not entered.');
      }
      result['nativeFullscreen'] = true;
      await _waitFor(
        () => _fullscreenUiHidden(screenshotKey),
        timeout: const Duration(seconds: 6),
        describe: () =>
            'fullscreen controls opacity=${_controlsRenderedOpacity(screenshotKey)}, '
            'UI hidden=${_fullscreenUiHidden(screenshotKey)}; '
            '${_describePlayback(controller)}',
      );
      result['fullscreenControlsHidden'] = true;
      result['fullscreenControlsRenderedOpacity'] = _controlsRenderedOpacity(
        screenshotKey,
      );
      result['fullscreenCursorConfiguredHidden'] = true;
      if (options.screenshotPath case final screenshot?) {
        final fullscreenPath = p.join(
          p.dirname(screenshot),
          'fullscreen-hidden.png',
        );
        await _captureScreenshot(screenshotKey, fullscreenPath);
        result['fullscreenScreenshotPath'] = fullscreenPath;
      }
      await windowManager.setFullScreen(false);
      await _waitFor(
        () => _controlsRenderedOpacity(screenshotKey) == 1,
        timeout: const Duration(seconds: 2),
      );
    }
    await controller.togglePlayPause();
    await _waitFor(
      () => !controller.player.state.playing,
      timeout: const Duration(seconds: 3),
    );

    if (options.screenshotPath != null) {
      try {
        await controller.videoController.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 3),
        );
        await _captureScreenshot(screenshotKey, options.screenshotPath!);
        result['visualCaptureSuccess'] = true;
      } on Object catch (error) {
        result['screenshotError'] = error.toString();
      }
    }

    if (options.benchmarkCycles > 0) {
      final queuePath = options.benchmarkQueuePath;
      if (queuePath == null) {
        throw ArgumentError(
          'Provide --benchmark-queue=<JSON file> for a representative workload.',
        );
      }
      final decoded = jsonDecode(await File(queuePath).readAsString());
      if (decoded is! List ||
          decoded.isEmpty ||
          decoded.any((value) => value is! String)) {
        throw const FormatException(
          'Benchmark queue must contain media path strings.',
        );
      }
      final benchmark = await runPlaybackBenchmark(
        controller: controller,
        rootKey: screenshotKey,
        cycles: options.benchmarkCycles,
        sources: decoded.cast<String>(),
        warmup: Duration(milliseconds: options.benchmarkWarmupMs),
        progressPath:
            '${options.benchmarkReportPath ?? options.reportPath}.progress.json',
      );
      result['benchmark'] = benchmark;
      if (options.benchmarkReportPath != null) {
        final file = File(options.benchmarkReportPath!);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(benchmark),
          flush: true,
        );
      }
      if (controller.isPlaying) await controller.togglePlayPause();
    }

    result
      ..['success'] = true
      ..['durationMs'] = duration.inMilliseconds
      ..['positionMs'] = actualPosition.inMilliseconds
      ..['engineVersion'] = engineVersion
      ..['paused'] = true;
    success = true;
  } on Object catch (error) {
    result['error'] = error.toString();
    result['engineVersion'] = controller.engineVersion;
    result['durationMs'] = controller.duration.inMilliseconds;
    result['positionMs'] = controller.position.inMilliseconds;
    if (options.screenshotPath != null) {
      result['screenshotError'] =
          'Capture skipped because playback verification failed.';
    }
  }

  watchdog.cancel();
  try {
    // The report is the release gate artifact; make sure the diagnostic
    // records that explain it land on disk before the process exits.
    await diagnostics?.flush().timeout(const Duration(seconds: 3));
  } on Object {
    // A diagnostic flush failure must not fail the smoke run.
  }
  var servicesReleased = false;
  try {
    await lifecycle.prepareSmokeShutdown().timeout(const Duration(seconds: 3));
    servicesReleased = true;
  } on Object catch (error) {
    result['success'] = false;
    result['error'] =
        '${result['error'] ?? 'Smoke test passed playback checks.'} Service shutdown failed: $error';
    success = false;
  }
  await _writeSmokeReport(options.reportPath, result);
  if (servicesReleased) {
    try {
      await lifecycle.destroySmokeWindow().timeout(const Duration(seconds: 2));
    } on Object catch (error) {
      result['success'] = false;
      result['error'] =
          '${result['error'] ?? 'Smoke test passed playback checks.'} Window shutdown failed: $error';
      success = false;
      await _writeSmokeReport(options.reportPath, result);
    }
  }
  exit(success ? 0 : 1);
}

bool _fullscreenUiHidden(GlobalKey screenshotKey) {
  var controlsHidden = false;
  var cursorHidden = false;
  void inspect(Element element) {
    final widget = element.widget;
    if (widget is AnimatedOpacity &&
        widget.key == const ValueKey('player-controls-visibility')) {
      final renderObject = element.findRenderObject();
      controlsHidden =
          widget.opacity == 0 &&
          renderObject is RenderAnimatedOpacity &&
          renderObject.opacity.value == 0;
    }
    if (widget is MouseRegion &&
        widget.key == const ValueKey('video-surface')) {
      cursorHidden = widget.cursor == SystemMouseCursors.none;
    }
    element.visitChildElements(inspect);
  }

  final context = screenshotKey.currentContext;
  if (context is Element) inspect(context);
  return controlsHidden && cursorHidden;
}

double? _controlsRenderedOpacity(GlobalKey screenshotKey) {
  double? opacity;
  void inspect(Element element) {
    if (element.widget.key == const ValueKey('player-controls-visibility')) {
      final renderObject = element.findRenderObject();
      if (renderObject is RenderAnimatedOpacity) {
        opacity = renderObject.opacity.value;
      }
    }
    element.visitChildElements(inspect);
  }

  final context = screenshotKey.currentContext;
  if (context is Element) inspect(context);
  return opacity;
}

Future<void> _waitFor(
  bool Function() condition, {
  required Duration timeout,
  String Function()? describe,
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed >= timeout) {
      final detail = describe?.call();
      throw TimeoutException(
        detail == null || detail.isEmpty
            ? 'Timed out waiting for native playback state.'
            : 'Timed out waiting for native playback state: $detail',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Describes the playback state a smoke check was waiting for, so a failed
/// report says which side never delivered instead of only that it timed out.
String _describePlayback(PlayerController controller) {
  final engine = controller.player.state;
  return 'controller{duration=${controller.duration.inMilliseconds} ms, '
      'position=${controller.position.inMilliseconds} ms, '
      'playing=${controller.isPlaying}, loading=${controller.isLoading}, '
      'hasMedia=${controller.hasMedia}, '
      'completed=${controller.transport.completed}, '
      'error=${controller.error}} '
      'engine{duration=${engine.duration.inMilliseconds} ms, '
      'position=${engine.position.inMilliseconds} ms, '
      'playing=${engine.playing}, completed=${engine.completed}}';
}

Future<void> _writeSmokeReport(
  String reportPath,
  Map<String, Object?> report,
) async {
  try {
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
  } on Object catch (error) {
    stderr.writeln('Could not write smoke report to $reportPath: $error');
  }
}

Future<void> _captureScreenshot(GlobalKey key, String screenshotPath) async {
  await WidgetsBinding.instance.endOfFrame;
  final renderObject = key.currentContext?.findRenderObject();
  if (renderObject is! RenderRepaintBoundary) {
    throw StateError('The application repaint boundary is not available.');
  }
  final image = await renderObject.toImage(pixelRatio: 1);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Flutter returned no PNG image data.');
    final file = File(screenshotPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  } finally {
    image.dispose();
  }
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mpvson',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Mpvson could not start playback',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'The native media engine could not be initialized. Check that the bundled libmpv runtime is present and compatible.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  SelectableText(error),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
