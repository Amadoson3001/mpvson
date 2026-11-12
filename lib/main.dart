import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/repositories/app_preferences_repository.dart';
import 'data/repositories/media_library_repository.dart';
import 'data/repositories/media_library_repository_impl.dart';
import 'data/repositories/session_repository.dart';
import 'data/services/desktop_integration_service.dart';
import 'data/services/desktop_integration_service_impl.dart';
import 'data/services/diagnostic_log.dart';
import 'data/services/engine_update_service.dart';
import 'data/services/gpu_info_service.dart';
import 'data/services/media_probe_service.dart';
import 'data/services/media_probe_service_impl.dart';
import 'data/services/library_playback_tracker.dart';
import 'data/services/open_request_coordinator.dart';
import 'data/services/playback_service.dart';
import 'data/services/thumbnail_service.dart';
import 'data/services/update_service.dart';
import 'domain/models/graphics_settings.dart';
import 'domain/models/open_request.dart';
import 'domain/updates/bundled_engine.dart';
import 'domain/updates/engine_selection.dart';
import 'ui/core/app_theme.dart';
import 'ui/core/components/app_dialog.dart';
import 'ui/player/player_controller.dart';
import 'ui/player/views/open_preference_dialog.dart';

const WindowOptions _windowOptions = WindowOptions(
  size: Size(1240, 780),
  minimumSize: Size(720, 480),
  center: true,
  title: 'Mpvson',
  titleBarStyle: TitleBarStyle.normal,
);

const String _supportedMediaKitVersion = '1.2.6';

Future<EngineBootSelection?> _tryBundledEngineAfterBootFailure(
  EngineUpdateService engineUpdates, {
  required String? bundledEnginePath,
  required List<String> arguments,
}) async {
  if (bundledEnginePath == null) return null;
  final bundledFile = File(bundledEnginePath);
  if (!await bundledFile.exists()) return null;
  final bundled = EngineBootSelection(
    libraryPath: bundledEnginePath,
    version: bundledEngineVersion,
    isBundled: true,
    isPending: false,
  );
  return _initializeMediaKitWithFallbacks(
    engineUpdates,
    bundled,
    bundledEnginePath: bundledEnginePath,
    arguments: arguments,
  );
}

Future<EngineBootSelection> _initializeMediaKitWithFallbacks(
  EngineUpdateService engineUpdates,
  EngineBootSelection initial, {
  required String? bundledEnginePath,
  required List<String> arguments,
}) async {
  try {
    if (Platform.isWindows) {
      const channel = MethodChannel('mpvson/engine');
      final loadedPath = await channel.invokeMethod<String>('libraryPath');
      if (loadedPath != null &&
          loadedPath.isNotEmpty &&
          loadedPath != initial.libraryPath) {
        // A hot restart keeps the native engine module loaded for the whole
        // process and it cannot switch libraries. Keep the engine that is
        // already loaded and leave the staged package queued for the next
        // full launch instead of failing startup.
        await engineUpdates.abandonPendingBootAttempt();
        MediaKit.ensureInitialized(libmpv: loadedPath);
        final loadedVersion =
            bundledEnginePath != null && p.equals(loadedPath, bundledEnginePath)
            ? bundledEngineVersion
            : p.basename(p.dirname(loadedPath));
        return EngineBootSelection(
          libraryPath: loadedPath,
          version: loadedVersion,
          isBundled:
              bundledEnginePath != null &&
              p.equals(loadedPath, bundledEnginePath),
          isPending: false,
        );
      }
      await channel.invokeMethod<void>('configure', initial.libraryPath);
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
  await Process.start(
    Platform.resolvedExecutable,
    [
      ...arguments.where((value) => !value.startsWith('--engine-recovery=')),
      '--engine-recovery=${recoveryCount + 1}',
    ],
    workingDirectory: File(Platform.resolvedExecutable).parent.path,
    mode: ProcessStartMode.detached,
  );
  exit(0);
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 8 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 100;

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
    try {
      engineSelection = await _tryBundledEngineAfterBootFailure(
        engineUpdates,
        bundledEnginePath: bundledEnginePath,
        arguments: arguments,
      );
      if (engineSelection != null) {
        startupError = null;
      }
    } on Object catch (fallbackError) {
      startupError ??= fallbackError;
    }
  }

  final windowError = await windowInitFuture;
  startupError ??= windowError;

  if (startupError != null) {
    engineUpdates.dispose();
    runApp(_StartupFailureApp(error: startupError.toString()));
    await _showFallbackWindow();
    return;
  }

  PlayerController? controller;
  PlaybackService? playback;
  final updates = UpdateService(currentVersion: currentVersion);
  Object? controllerError;
  final diagnostics = FileDiagnosticLog();
  try {
    playback = PlaybackService(diagnostics: diagnostics);
    controller = PlayerController(
      playback: playback,
      thumbnails: MediaKitThumbnailService(diagnostics: diagnostics),
      sessions: SessionRepository(),
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
    runApp(_StartupFailureApp(error: controllerError.toString()));
    await _showFallbackWindow();
    return;
  }

  final readyController = controller;
  final readyPlayback = playback!;
  final readyUpdates = updates;
  final selectedEngine = engineSelection;

  try {
    final appPreferences = AppPreferencesRepository();
    await appPreferences.load();
    final graphicsSettings = appPreferences.graphicsSettings;
    readyController.applyGraphicsSettings(graphicsSettings);

    final mediaProbeService = MediaProbeServiceImpl();
    // The library is optional: a path-provider failure degrades to an in-memory
    // library instead of blocking playback startup.
    String? libraryDatabasePath;
    try {
      final supportDir = await getApplicationSupportDirectory();
      libraryDatabasePath = p.join(supportDir.path, 'media_library.db');
    } on Object catch (error) {
      diagnostics.record('startup.library_path', error: error);
    }
    final libraryRepository = MediaLibraryRepositoryImpl(
      databasePath: libraryDatabasePath,
      inMemory: libraryDatabasePath == null,
      probeService: mediaProbeService,
    );
    final libraryPlaybackTracker = LibraryPlaybackTracker(
      controller: readyController,
      repository: libraryRepository,
    );
    unawaited(
      _initializeBackgroundService('media library', () async {
        await libraryRepository.initialize();
      }),
    );

    final navigatorKey = GlobalKey<NavigatorState>();

    Future<void>? initialization;
    Future<void> waitUntilReady() {
      final active = initialization;
      if (active != null) return active;
      late final Future<void> attempt;
      attempt =
          (() async {
            await readyController.initialize();
            await WidgetsBinding.instance.endOfFrame;
          })().catchError((Object error, StackTrace stack) {
            if (identical(initialization, attempt)) initialization = null;
            Error.throwWithStackTrace(error, stack);
          });
      initialization = attempt;
      return attempt;
    }

    final openCoordinator = OpenRequestCoordinator(
      ready: waitUntilReady,
      preferences: appPreferences,
      isPlaybackActive: () =>
          readyController.isPlaying ||
          readyController.hasMedia ||
          readyController.current != null,
      executePlaybackCommand:
          ({required List<String> paths, required bool playNow}) async {
            await readyController.openPaths(paths, append: !playNow);
          },
      showPreferenceDialog: () async {
        final context = navigatorKey.currentState?.context;
        if (context == null || !context.mounted) return null;
        return OpenPreferenceDialog.show(context);
      },
    );

    final desktopIntegration = DesktopIntegrationServiceImpl(
      controller: readyController,
      openRequestCoordinator: openCoordinator,
      preferences: appPreferences,
      mediaProbeService: mediaProbeService,
      libraryRepository: libraryRepository,
    );
    if (graphicsSettings.preferredGpu == GpuPreferenceMode.automatic) {
      unawaited(
        desktopIntegration.isOnAcPower().then((onAcPower) {
          diagnostics.record(
            'gpu.preference',
            message: graphicsSettings
                .resolvePreferredGpu(onAcPower: onAcPower)
                .name,
          );
        }),
      );
    }
    unawaited(
      _initializeBackgroundService('desktop integration', () async {
        await desktopIntegration.initialize();
      }),
    );

    final lifecycle = _DesktopLifecycle(
      controller: readyController,
      updates: readyUpdates,
      engineUpdates: engineUpdates,
      engineLibraryPath: engineSelection?.libraryPath,
      navigatorKey: navigatorKey,
      appPreferences: appPreferences,
      libraryRepository: libraryRepository,
      libraryPlaybackTracker: libraryPlaybackTracker,
      mediaProbeService: mediaProbeService,
      desktopIntegration: desktopIntegration,
    );
    windowManager.addListener(lifecycle);
    try {
      await windowManager.setPreventClose(true);
    } on Object catch (error) {
      // Close interception owns the guarded shutdown; without it, surface the
      // failure instead of running with an unguarded window.
      await lifecycle._releaseServices(discard: true);
      runApp(_StartupFailureApp(error: error.toString()));
      await _showFallbackWindow();
      return;
    }

    // Mount the real UI frame instantly
    runApp(
      MpvsonApp(
        navigatorKey: navigatorKey,
        openCoordinator: openCoordinator,
        controller: readyController,
        updates: readyUpdates,
        engineUpdates: engineUpdates,
        desktopWindow: true,
        appPreferences: appPreferences,
        libraryRepository: libraryRepository,
        desktopIntegration: desktopIntegration,
      ),
    );
    try {
      await windowManager.show();
      await windowManager.focus();
    } on Object catch (error) {
      diagnostics.record('startup.window_show', error: error);
    }

    // The adapter probe creates a D3D11 device; keep it off the startup path.
    unawaited(GpuInfoService().recordSnapshot(diagnostics));

    // Engine staging confirmation, native event observation, and update initialization
    // run concurrently without delaying the initial UI frame.
    if (selectedEngine?.isPending ?? false) {
      try {
        final platform = readyPlayback.player.platform;
        if (platform is NativePlayer) {
          // Construction alone does not prove the staged engine works: native
          // creation and initialization run asynchronously. Confirm only after
          // they succeed, within a bounded wait; a failed or stalled engine
          // stays unconfirmed so the next launch can recover it.
          await platform.future?.timeout(const Duration(seconds: 15));
        }
        await engineUpdates.confirmPendingBoot();
      } on Object catch (error) {
        stderr.writeln('Could not commit the staged playback engine: $error');
      }
    }
    unawaited(engineUpdates.initialize());
    unawaited(readyPlayback.prepare());

    unawaited(
      waitUntilReady().catchError((Object error, StackTrace stack) {
        stderr.writeln('Could not restore the playback session: $error');
      }),
    );

    final isEnqueue = arguments.contains('--enqueue');
    final paths = arguments.where((argument) => !argument.startsWith('--'));
    if (paths.isNotEmpty) {
      final origin = OpenOrigin.startupArgs;
      final intent = isEnqueue ? OpenIntent.enqueue : OpenIntent.normal;
      unawaited(
        openCoordinator.handleOpenRequest(
          OpenRequest(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            sources: paths.toList(growable: false),
            intent: intent,
            origin: origin,
          ),
        ),
      );
    }
  } catch (error, stack) {
    debugPrint('Fatal error during app startup: $error\n$stack');
    readyUpdates.dispose();
    engineUpdates.dispose();
    readyController.dispose();
    runApp(_StartupFailureApp(error: error.toString()));
    await _showFallbackWindow();
    return;
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

Future<void> _initializeBackgroundService(
  String serviceName,
  Future<void> Function() initialize,
) async {
  try {
    await initialize();
  } on Object catch (error, stackTrace) {
    stderr.writeln('Could not initialize $serviceName: $error');
    stderr.writeln(stackTrace);
  }
}

class _DesktopLifecycle extends WindowListener {
  _DesktopLifecycle({
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.engineLibraryPath,
    required this.navigatorKey,
    this.appPreferences,
    this.libraryRepository,
    this.libraryPlaybackTracker,
    this.mediaProbeService,
    this.desktopIntegration,
  });

  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final String? engineLibraryPath;
  final GlobalKey<NavigatorState> navigatorKey;
  final AppPreferencesRepository? appPreferences;
  final MediaLibraryRepository? libraryRepository;
  final LibraryPlaybackTracker? libraryPlaybackTracker;
  final MediaProbeService? mediaProbeService;
  final DesktopIntegrationService? desktopIntegration;
  bool _closing = false;
  bool _servicesReleased = false;

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
      try {
        await appPreferences?.flush();
      } on Object catch (error) {
        throw SessionSaveException('Could not save desktop settings.', error);
      }
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
    final context = navigatorKey.currentState?.context;
    if (context == null || !context.mounted) {
      // Without a window to ask through, closing without saving is the only
      // outcome that cannot trap the user in an unsaved session.
      return _ClosePromptAction.closeWithoutSaving;
    }
    return showDialog<_ClosePromptAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SessionSaveErrorDialog(error: error.message),
    );
  }

  Future<void> _releaseServices({bool discard = false}) async {
    if (_servicesReleased) return;
    _servicesReleased = true;
    windowManager.removeListener(this);
    try {
      libraryPlaybackTracker?.dispose();
    } on Object {
      // Best-effort playback tracker release.
    }
    try {
      desktopIntegration?.dispose();
    } on Object {
      // Best-effort desktop integration release.
    }
    try {
      await libraryRepository?.dispose();
    } on Object {
      // Best-effort library repository release.
    }
    try {
      mediaProbeService?.dispose();
    } on Object {
      // Best-effort probe service release.
    }
    // The preferences repository is a ChangeNotifier; releasing it here
    // detaches the app's listeners. The guard above keeps a retry or a
    // re-entered close path from disposing it twice.
    try {
      appPreferences?.dispose();
    } on Object {
      // Best-effort preferences release.
    }
    try {
      await controller.close(discard: discard);
    } on Object {
      // Preserve the window-close path even if a platform teardown fails.
    }
    try {
      updates.dispose();
    } on Object {
      // Best-effort updates release.
    }
    try {
      engineUpdates.dispose();
    } on Object {
      // Best-effort engine updates release.
    }
  }

  Future<void> _finishWindowClose() async {
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } on Object {
      await windowManager.destroy();
    }
  }
}

enum _ClosePromptAction { retry, closeWithoutSaving, cancel }

class _SessionSaveErrorDialog extends StatelessWidget {
  const _SessionSaveErrorDialog({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      maxWidth: 528,
      title: const Text('Could not save playback session'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mpvson was unable to save your current session state. You can retry saving, close without saving your progress, or cancel to keep the player open.',
            style: TextStyle(
              color: context.palette.secondaryText,
              fontSize: AppType.small,
            ),
          ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              error,
              style: TextStyle(
                color: context.palette.mutedText,
                fontSize: AppType.caption,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_ClosePromptAction.cancel),
          child: Text(
            'Cancel',
            style: TextStyle(color: context.palette.mutedText),
          ),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_ClosePromptAction.closeWithoutSaving),
          child: Text(
            'Close without saving',
            style: TextStyle(color: context.palette.danger),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.palette.accent,
            foregroundColor: context.palette.deepBackground,
          ),
          onPressed: () => Navigator.of(context).pop(_ClosePromptAction.retry),
          child: const Text('Retry'),
        ),
      ],
    );
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
                    'Mpvson could not start',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'A required startup component could not be initialized. Check that the bundled libmpv runtime is present and compatible.',
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
