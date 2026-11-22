part of 'main.dart';

class _DesktopLifecycle extends WindowListener {
  _DesktopLifecycle({
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.navigatorKey,
    this.appPreferences,
    this.onBeforePreferencesDispose,
    this.libraryRepository,
    this.libraryPlaybackTracker,
    this.mediaProbeService,
    this.desktopIntegration,
  });

  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final GlobalKey<NavigatorState> navigatorKey;
  final AppPreferencesRepository? appPreferences;
  final VoidCallback? onBeforePreferencesDispose;
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
          // A pending update stays verified but nothing is installed.
          controller.cancelClose();
          updates.cancelRestart();
          _closing = false;
          return;
      }
    }
    await _releaseServices(discard: true, applyUpdate: true);
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
    } on Object catch (error) {
      if (updates.restartRequested) {
        return SessionSaveException(
          'Could not prepare Mpvson to restart.',
          error,
        );
      }
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

  Future<void> _releaseServices({
    bool discard = false,
    bool applyUpdate = false,
  }) async {
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
      onBeforePreferencesDispose?.call();
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
      engineUpdates.dispose();
    } on Object {
      // Best-effort engine updates release.
    }
    try {
      if (applyUpdate && updates.restartRequested) {
        await updates.launchPreparedInstall();
      }
    } finally {
      try {
        updates.dispose();
      } on Object {
        // The window still needs to close.
      }
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
