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
import 'data/repositories/database/library_database.dart';
import 'data/repositories/media_library_repository.dart';
import 'data/repositories/media_library_repository_impl.dart';
import 'data/repositories/session_repository.dart';
import 'data/services/desktop_integration_service.dart';
import 'data/services/desktop_integration_service_impl.dart';
import 'data/services/diagnostic_log.dart';
import 'data/services/engine_update_service.dart';
import 'data/services/media_probe_service.dart';
import 'data/services/media_probe_service_impl.dart';
import 'data/services/open_request_coordinator.dart';
import 'data/services/playback_service.dart';
import 'data/services/thumbnail_service.dart';
import 'data/services/update_service.dart';
import 'domain/models/open_request.dart';
import 'domain/updates/bundled_engine.dart';
import 'domain/updates/engine_selection.dart';
import 'ui/core/app_theme.dart';
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

  final appPreferences = AppPreferencesRepository();
  await appPreferences.load();

  final mediaProbeService = MediaProbeServiceImpl();
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = File(p.join(supportDir.path, 'media_library.db'));
  final libraryDb = await LibraryDatabase.open(path: dbFile.path);
  final libraryRepository = MediaLibraryRepositoryImpl(
    database: libraryDb,
    probeService: mediaProbeService,
  );
  unawaited(
    _initializeBackgroundService('media library', () async {
      await libraryRepository.initialize();
    }),
  );

  final navigatorKey = GlobalKey<NavigatorState>();

  final openCoordinator = OpenRequestCoordinator(
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
  );
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
    mediaProbeService: mediaProbeService,
    desktopIntegration: desktopIntegration,
  );
  await windowManager.setPreventClose(true);
  windowManager.addListener(lifecycle);

  // Mount the real UI frame instantly
  runApp(
    MpvsonApp(
      navigatorKey: navigatorKey,
      controller: readyController,
      updates: readyUpdates,
      engineUpdates: engineUpdates,
      desktopWindow: true,
      appPreferences: appPreferences,
      libraryRepository: libraryRepository,
      desktopIntegration: desktopIntegration,
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

  final isEnqueue = arguments.contains('--enqueue');
  final paths = arguments.where((argument) => !argument.startsWith('--'));
  if (paths.isNotEmpty) {
    await readyController.initialize().timeout(const Duration(seconds: 20));
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
  final MediaProbeService? mediaProbeService;
  final DesktopIntegrationService? desktopIntegration;
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
    windowManager.removeListener(this);
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
