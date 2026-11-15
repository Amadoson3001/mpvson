part of 'player_controller.dart';

/// Session restore, persistence, and shutdown.
extension PlayerControllerSession on PlayerController {
  /// Whether stream URLs are written to local session files. Off by default.
  bool get saveNetworkUrls => _saveNetworkUrls;

  /// Loads saved queue/history without opening or playing the last source.
  Future<void> initialize() async {
    if (_initialized || _initializing || !_acceptsCommands) return;
    final queueRevisionAtStart = _queueStructureRevision;
    final operationAtStart = _operation;
    final importOperationAtStart = _importOperation;
    final volumeRevisionAtStart = _volumeRevision;
    final rateRevisionAtStart = _rateRevision;
    final shuffleRevisionAtStart = _shufflePreferenceRevision;
    final repeatRevisionAtStart = _repeatPreferenceRevision;
    final saveNetworkUrlsRevisionAtStart = _saveNetworkUrlsRevision;
    final autoPlayNextVideoRevisionAtStart = _autoPlayNextVideoRevision;
    final autoPlayNextAudioRevisionAtStart = _autoPlayNextAudioRevision;
    final controlDensityRevisionAtStart = _controlDensityRevision;
    final playbackSettingsRevisionAtStart = _playbackSettingsRevision;
    _initializing = true;
    try {
      final result = await _sessions.loadDetailed();
      if (!_acceptsCommands) return;
      _initialized = true;
      final loaded = result.session;
      var migrate = result.primaryRejected;
      if (loaded != null && loaded.needsMigration) {
        // Version 1 files predate the consent and revision fields, so they are
        // rewritten in the current schema after loading.
        migrate = true;
      }
      final sessionQueueUnchanged =
          _queueStructureRevision == queueRevisionAtStart &&
          _operation == operationAtStart &&
          _importOperation == importOperationAtStart;
      var restoredSessionQueue = false;
      if (loaded != null) {
        final scrubbed = loaded.saveNetworkUrls
            ? loaded
            : loaded.withoutNetworkUrls();
        if (!loaded.saveNetworkUrls && loaded.hasNetworkEntries) {
          migrate = true;
        }
        final restoreQueue = sessionQueueUnchanged && _queue.isEmpty;
        restoredSessionQueue = restoreQueue;
        if (restoreQueue) {
          _queue
            ..clear()
            ..addAll(scrubbed.queue);
          _queueIdToIndex.clear();
          _rebuildQueueIndex(0);
          _currentIndex = scrubbed.currentIndex;
          if (_queue.isNotEmpty) _queueStructureRevision++;
        }
        if (sessionQueueUnchanged) {
          _recent
            ..clear()
            ..addAll(_canonicalizeRecent(scrubbed.recent));
          _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
          _rebuildRecentEntryIndices();
        }
        if (_repeatPreferenceRevision == repeatRevisionAtStart) {
          _repeatMode = PlayerRepeatMode.fromString(scrubbed.repeatMode);
        }
        if (_shufflePreferenceRevision == shuffleRevisionAtStart) {
          _shuffleEnabled = scrubbed.shuffle;
        }
        if (_controlDensityRevision == controlDensityRevisionAtStart) {
          _controlDensity = scrubbed.controlDensity;
        }
        _hasRestoredPlaybackSettings = true;
        if (_playbackSettingsRevision == playbackSettingsRevisionAtStart) {
          _playbackSettings = scrubbed.playbackSettings.normalized();
        }
        if (_saveNetworkUrlsRevision == saveNetworkUrlsRevisionAtStart) {
          _saveNetworkUrls = scrubbed.saveNetworkUrls;
        }
        if (_autoPlayNextVideoRevision == autoPlayNextVideoRevisionAtStart) {
          _autoPlayNextVideo = scrubbed.autoPlayNextVideo;
        }
        if (_autoPlayNextAudioRevision == autoPlayNextAudioRevisionAtStart) {
          _autoPlayNextAudio = scrubbed.autoPlayNextAudio;
        }
        _progressRevision = max(_progressRevision, scrubbed.progressRevision);
        // The queue snapshot still describes the previous session here, so the
        // restored row must be read directly instead of through `current`.
        MediaEntry? restoredCurrent;
        if (restoreQueue &&
            _currentIndex >= 0 &&
            _currentIndex < _queue.length) {
          restoredCurrent = _queue[_currentIndex];
        }
        final restoredVolume = _volumeRevision == volumeRevisionAtStart
            ? scrubbed.volume
            : _playbackState.volume;
        final restoredRate = _rateRevision == rateRevisionAtStart
            ? scrubbed.rate
            : _playbackState.rate;
        _playbackState = restoreQueue
            ? _playbackState.copyWith(
                volume: restoredVolume,
                rate: restoredRate,
                shuffle: _shuffleEnabled,
                isPlaying: false,
                isBuffering: false,
                position: restoredCurrent?.position ?? Duration.zero,
                duration: restoredCurrent?.duration ?? Duration.zero,
                completed: false,
                clearNativeSource: true,
                sourceLoaded: false,
              )
            : _playbackState.copyWith(
                volume: restoredVolume,
                rate: restoredRate,
                shuffle: _shuffleEnabled,
              );
        if (restoreQueue) {
          _mediaKind = PlayerController._classifyMediaKind(
            entry: restoredCurrent,
            snapshot: _playbackState,
          );
          _metadata = restoredCurrent == null
              ? MediaMetadata.empty
              : MediaMetadata(
                  title: restoredCurrent.title,
                  duration: restoredCurrent.duration,
                );
        }
        if (_volumeRevision == volumeRevisionAtStart) {
          _lastAudibleVolume = scrubbed.volume > 0
              ? PlayerController._normalizeVolume(scrubbed.volume)
              : 100;
        }
      }

      // A checkpoint written after the last full save is newer than the session
      // and wins; an older or unusable checkpoint is ignored. Read it even when
      // recovery rejects the primary so URL-shaped ids can still be scrubbed.
      final checkpointQueueRevision = _queueStructureRevision;
      final checkpointOperation = _operation;
      final checkpointImportOperation = _importOperation;
      final checkpoint = await _sessions.loadProgress();
      if (!_acceptsCommands) return;
      final checkpointStillMatchesQueue =
          _queueStructureRevision == checkpointQueueRevision &&
          _operation == checkpointOperation &&
          _importOperation == checkpointImportOperation;
      if (sessionQueueUnchanged &&
          checkpointStillMatchesQueue &&
          (loaded == null || !result.primaryRejected)) {
        await _applyProgressCheckpoint(
          checkpoint,
          sessionRevision: loaded?.progressRevision ?? 0,
        );
        if (!_acceptsCommands) return;
      }
      if (result.note != null) {
        _diagnostics?.record('session.load', message: result.note);
      }
      if (!_acceptsCommands) return;

      // Publish the restored queue before applying engine settings: the volume,
      // rate and shuffle writes can emit snapshots immediately, and those
      // snapshots must see the restored row so they cannot reset its saved
      // position to zero.
      _publishQueue();
      // These values are independent of a loaded source, so applying them here
      // restores the user's settings while leaving the queue stopped.
      final startupSettings = Completer<void>();
      _startupPreferenceDrain = startupSettings.future;
      try {
        await Future.wait<void>([
          setVolume(volume, scheduleSave: false),
          _applyInitialRate(rate, rateRevisionAtStart),
          _applyInitialQueuePreferences(
            shuffleRevisionAtStart: shuffleRevisionAtStart,
            repeatRevisionAtStart: repeatRevisionAtStart,
          ),
        ]);
      } finally {
        if (identical(_startupPreferenceDrain, startupSettings.future)) {
          _startupPreferenceDrain = null;
        }
        if (!startupSettings.isCompleted) startupSettings.complete();
      }
      if (!_acceptsCommands) return;
      if (restoredSessionQueue &&
          _currentIndex >= 0 &&
          _queueStructureRevision == checkpointQueueRevision &&
          _operation == checkpointOperation &&
          _importOperation == checkpointImportOperation) {
        _navigationHistory
          ..clear()
          ..add(_queue[_currentIndex].id);
        _navigationCursor = 0;
        if (shuffle) _resetShuffleCycle();
      }
      if (loaded == null &&
          _playbackSettingsRevision == playbackSettingsRevisionAtStart &&
          _recommendedQualityPreset != null &&
          _playbackSettings.qualityPreset != _recommendedQualityPreset) {
        _playbackSettings = _playbackSettings.copyWith(
          qualityPreset: _recommendedQualityPreset,
        );
      }
      unawaited(_applyPlaybackSettings(_playbackSettings));
      _publishTransport();
      _publishPlaybackMode();
      _notifyIfOpen();

      if (migrate) {
        // A migrated session without consent may still have a stream progress
        // checkpoint. Scrub it and the recovery copy before initialization
        // returns, then persist the normalized in-memory session.
        if (!_saveNetworkUrls) {
          await _sessions.scrubNetworkUrls();
          if (!_acceptsCommands) return;
        }
        await _runCoalescedSave(scrubBackup: !_saveNetworkUrls);
        if (!_acceptsCommands) return;
      } else if (!_saveNetworkUrls &&
          _checkpointNeedsUrlScrub(checkpoint, loaded)) {
        // A clean queue can still have an old URL-shaped checkpoint id from a
        // previous release. Remove it once without rewriting valid local
        // checkpoints on every launch.
        await _sessions.scrubNetworkUrls();
        if (!_acceptsCommands) return;
      }
    } on Object catch (exception) {
      _setError('Could not restore the playback session: $exception');
    } finally {
      _initializing = false;
    }
  }

  Future<void> _applyProgressCheckpoint(
    SessionProgress? checkpoint, {
    required int sessionRevision,
  }) async {
    if (checkpoint == null || checkpoint.entryId == null) return;
    if (checkpoint.revision < sessionRevision) return;
    final id = checkpoint.entryId!;
    var applied = false;
    final queueIndex = _queueIdToIndex[id] ?? -1;
    if (queueIndex >= 0) {
      _queue[queueIndex] = _queue[queueIndex].copyWith(
        position: checkpoint.position,
        duration: checkpoint.duration > Duration.zero
            ? checkpoint.duration
            : _queue[queueIndex].duration,
      );
      applied = true;
    }
    final recentIndex = _recentIndexById[id] ?? -1;
    if (recentIndex >= 0) {
      _recent[recentIndex] = _recent[recentIndex].copyWith(
        position: checkpoint.position,
        duration: checkpoint.duration > Duration.zero
            ? checkpoint.duration
            : _recent[recentIndex].duration,
      );
      applied = true;
    }
    if (!applied) return;
    _progressRevision = max(_progressRevision, checkpoint.revision);
    if (queueIndex == _currentIndex && queueIndex >= 0) {
      _playbackState = _playbackState.copyWith(
        position: checkpoint.position,
        duration: checkpoint.duration > Duration.zero
            ? checkpoint.duration
            : _playbackState.duration,
      );
    }
  }

  bool _checkpointNeedsUrlScrub(
    SessionProgress? checkpoint,
    PlaybackSession? session,
  ) {
    final entryId = checkpoint?.entryId;
    if (entryId == null) return false;
    if (MediaEntry.isNetworkUrl(entryId)) return true;
    if (session == null) return true;
    for (final entry in <MediaEntry>[...session.queue, ...session.recent]) {
      if (entry.id == entryId) return MediaEntry.isNetworkUrl(entry.path);
    }
    return true;
  }

  Future<void> saveSession({bool scrubBackup = false}) async {
    if (!_initialized) return;
    _syncCurrentProgress();
    final active = current;
    final session = PlaybackSession(
      queue: List<MediaEntry>.unmodifiable(_queue),
      recent: _unmodifiableRecent,
      currentId: active?.id,
      volume: volume,
      rate: rate,
      shuffle: shuffle,
      repeatMode: _repeatMode.value,
      controlDensity: _controlDensity,
      playbackSettings: _playbackSettings,
      saveNetworkUrls: _saveNetworkUrls,
      autoPlayNextVideo: _autoPlayNextVideo,
      autoPlayNextAudio: _autoPlayNextAudio,
      progressRevision: _progressRevision,
    );
    final stored = _saveNetworkUrls ? session : session.withoutNetworkUrls();
    try {
      if (scrubBackup || !_saveNetworkUrls) {
        await _sessions.saveScrubbed(stored);
      } else {
        await _sessions.save(stored);
      }
    } on Object catch (exception) {
      if (!_isClosing) {
        _setError('Could not save the playback session: $exception');
      }
      if (exception is SessionSaveException) {
        rethrow;
      }
      throw SessionSaveException(
        'Could not save the playback session: $exception',
        exception,
      );
    }
  }

  /// Enables or disables persistence of stream URLs.
  ///
  /// Disabling the setting scrubs every file this application owns, so URLs that
  /// were stored earlier are removed from the primary, the recovery copy and the
  /// checkpoint while local-file history is retained.
  Future<void> setSaveNetworkUrls(bool value) async {
    if (!_acceptsCommands || _saveNetworkUrls == value) return;
    _saveNetworkUrls = value;
    _saveNetworkUrlsRevision++;
    _notifyIfOpen();
    if (!value) {
      try {
        _recent.removeWhere((entry) => MediaEntry.isNetworkUrl(entry.path));
        _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
        _rebuildRecentEntryIndices();
        _progressTimer?.cancel();
        _progressTimer = null;
        // Let any write that captured the old consent setting finish before
        // the repository scrubs the files it could have populated.
        await _runCoalescedSave(scrubBackup: true);
        await _checkpointDrain?.future;
        await _sessions.flush();
        await _sessions.scrubNetworkUrls();
      } on Object catch (exception) {
        _diagnostics?.record(
          'session.scrub',
          message: 'Could not remove stored stream URLs',
          error: exception,
        );
        _setError('Could not remove stored stream URLs: $exception');
      }
    }
    // A later enable may have completed while the opt-out scrub was running.
    // Persist the latest consent state after that scrub, not the captured one.
    if (_saveNetworkUrls) await _runCoalescedSave();
    _updateProgressTimer();
  }

  /// Stops playback, saves state, releases streams and disposes libmpv.
  ///
  /// Repeated calls share one shutdown. While a failed save awaits a decision
  /// the callers join that decision instead of opening a second prompt;
  /// `discard: true`/`force: true` always completes the shutdown.
  Future<void> close({bool discard = false, bool force = false}) {
    if (_closingState == ControllerClosingState.closed) {
      return Future<void>.value();
    }
    if (discard || force) _discardOnClose = true;

    if (_closingState == ControllerClosingState.awaitingDecision) {
      if (_discardOnClose) return _discardPendingClose();
      return _pendingDecision?.future ?? _releaseFuture ?? Future<void>.value();
    }
    if (_closingState == ControllerClosingState.releasing) {
      return _releaseAndFinish();
    }
    final inFlight = _closeFuture;
    if (inFlight != null) return inFlight;
    final future = _runCloseAttempt();
    _closeFuture = future;
    return future;
  }

  /// Retries a failed shutdown save, used by the "Retry" prompt action.
  Future<void> retryClose() async {
    final decision = _pendingDecision;
    _pendingDecision = null;
    if (_closingState == ControllerClosingState.awaitingDecision) {
      _closingState = ControllerClosingState.running;
    }
    _closeFuture = null;
    _discardOnClose = false;
    try {
      await close();
    } finally {
      if (decision != null && !decision.isCompleted) decision.complete();
    }
  }

  /// Cancels a failed shutdown and restores a usable controller.
  void cancelClose() {
    final decision = _pendingDecision;
    _pendingDecision = null;
    _closeFuture = null;
    _discardOnClose = false;
    _closingState = ControllerClosingState.running;
    _error = null;
    _scheduleSave();
    _notifyIfOpen();
    if (_shufflePreferenceRevision != _appliedShufflePreferenceRevision ||
        _repeatPreferenceRevision != _appliedRepeatPreferenceRevision) {
      unawaited(_drainQueuePreferences());
    }
    if (decision != null && !decision.isCompleted) decision.complete();
  }

  Future<void> _runCloseAttempt() async {
    _closingState = ControllerClosingState.saving;
    _operation++;
    _saveTimer?.cancel();
    _saveTimer = null;
    _progressTimer?.cancel();
    _progressTimer = null;
    _loadTimer?.cancel();
    _loadTimer = null;
    _resumeFloorTimer?.cancel();
    _resumeFloorTimer = null;
    try {
      await _startupPreferenceDrain;
      await _volumeDrain?.future;
      await _rateDrain?.future;
      await _queuePreferenceDrain;
      if (!_discardOnClose && _initialized && _engineHasMedia) {
        await _writeProgressCheckpoint(whileClosing: true);
      }
      await _drainPersistence();

      if (!_discardOnClose) {
        await saveSession();
        await _sessions.flush();
      }
      await _releaseAndFinish();
    } on Object catch (exception) {
      if (_isClosed || _notifierDisposed) rethrow;
      if (_discardOnClose) {
        // Discarding promises a shutdown even when persistence failed. The
        // release path treats the remaining writes as best effort.
        _releaseFuture = null;
        await _releaseAndFinish();
        return;
      }
      _closingState = ControllerClosingState.awaitingDecision;
      _pendingDecision = Completer<void>();
      _closeFuture = null;
      if (exception is SessionSaveException) rethrow;
      throw SessionSaveException(
        'Could not finish saving the playback session: $exception',
        exception,
      );
    }
  }

  Future<void> _discardPendingClose() async {
    final decision = _pendingDecision;
    _pendingDecision = null;
    _closingState = ControllerClosingState.running;
    _discardOnClose = true;
    final future = _releaseAndFinish();
    _closeFuture = future;
    try {
      await future;
    } finally {
      if (decision != null && !decision.isCompleted) decision.complete();
    }
  }

  Future<void> _releaseAndFinish() {
    final existing = _releaseFuture;
    if (existing != null) return existing;
    final future = _performRelease();
    _releaseFuture = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error) {
          // Let a later discard close retry a release that failed before it
          // could reach the engine teardown.
          if (identical(_releaseFuture, future)) _releaseFuture = null;
        },
      ),
    );
    return future;
  }

  Future<void> _performRelease() async {
    _closingState = ControllerClosingState.releasing;
    _pendingOpen = null;
    try {
      await _drainPersistence();
    } on Object {
      // A failed flush must not strand shutdown before the engine is released.
    }
    try {
      await _stateSubscription?.cancel();
    } on Object {
      // Continue disposing libmpv even if stream cancellation fails.
    }
    _stateSubscription = null;
    try {
      await _thumbnails?.dispose();
    } on Object {
      // Release playback even if a thumbnail request could not be cancelled.
    }
    try {
      await _seekPreview.dispose();
    } on Object {
      // Release playback even if preview disposal fails.
    }
    try {
      await _playback.dispose();
    } on Object {
      // Teardown should not prevent the native window from closing.
    }
    _closingState = ControllerClosingState.closed;
    _disposeNotifier();
  }

  /// Releases the internal listenables exactly once.
  ///
  /// Kept separate from [dispose] because a shutdown that reached the closed
  /// phase releases them before the widget tree is torn down.
  void _disposeNotifier() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    _positionSmoother.dispose();
    positionListenable.dispose();
    durationListenable.dispose();
    bufferingListenable.dispose();
    seekableListenable.dispose();
    chaptersListenable.dispose();
    queueListenable.dispose();
    transportListenable.dispose();
    volumeListenable.dispose();
    playbackModeListenable.dispose();
    _structureNotifier.dispose();
  }

  /// Debounces a full-session save after structural or settings changes.
  void _scheduleSave() {
    if (!_acceptsCommands || _saveTimer != null) return;
    _saveTimer = Timer(PlayerController._saveDelay, () {
      _saveTimer = null;
      unawaited(_runCoalescedSave());
    });
  }

  /// Keeps one active save and one latest pending save.
  Future<void> _runCoalescedSave({bool scrubBackup = false}) async {
    if (scrubBackup) _scrubBackupOnSave = true;
    if (_saveInFlight) {
      _saveRequested = true;
      await _saveDrain?.future;
      return;
    }
    _saveInFlight = true;
    final drain = Completer<void>();
    _saveDrain = drain;
    try {
      do {
        _saveRequested = false;
        final shouldScrub = _scrubBackupOnSave;
        _scrubBackupOnSave = false;
        try {
          await saveSession(scrubBackup: shouldScrub);
        } on Object catch (exception) {
          if (!_isClosing) {
            _diagnostics?.record(
              'session.save',
              message: 'A background session save failed',
              error: exception,
            );
          }
        }
      } while (_saveRequested && _acceptsCommands);
    } finally {
      _saveInFlight = false;
      if (identical(_saveDrain, drain)) _saveDrain = null;
      if (!drain.isCompleted) drain.complete();
    }
  }

  Future<void> _drainPersistence({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final drains = <Future<void>>[
        if (_saveDrain != null) _saveDrain!.future,
        if (_checkpointDrain != null) _checkpointDrain!.future,
      ];
      if (drains.isNotEmpty) {
        await Future.wait(drains).timeout(timeout);
      }
    } catch (_) {}
    try {
      await _sessions.flush().timeout(timeout);
    } catch (_) {}
  }

  void _updateProgressTimer() {
    final shouldRun = _acceptsCommands && _engineHasMedia && isPlaying;
    if (shouldRun) {
      _progressTimer ??= Timer.periodic(
        PlayerController._progressCheckpointInterval,
        (_) => unawaited(_writeProgressCheckpoint()),
      );
    } else if (_progressTimer != null) {
      _progressTimer!.cancel();
      _progressTimer = null;
      unawaited(_writeProgressCheckpoint());
    }
  }

  /// Writes the small progress checkpoint, coalescing overlapping writes.
  Future<void> _writeProgressCheckpoint({bool whileClosing = false}) async {
    if (_engineEntryId == null) return;
    if (_checkpointInFlight) {
      _checkpointRequested = true;
      return;
    }
    if (!_initialized || (_isClosing && !whileClosing)) return;
    _checkpointInFlight = true;
    final drain = Completer<void>();
    _checkpointDrain = drain;
    try {
      do {
        _checkpointRequested = false;
        final activeId = _engineEntryId;
        if (activeId == null) break;
        final activeEntry = _entryById(activeId);
        if (activeEntry != null &&
            !_saveNetworkUrls &&
            MediaEntry.isNetworkUrl(activeEntry.path)) {
          continue;
        }
        final progress = SessionProgress(
          revision: ++_progressRevision,
          entryId: activeId,
          position: _playbackState.position,
          duration: _playbackState.duration,
        );
        try {
          await _sessions.saveProgress(progress);
        } on Object catch (exception) {
          _diagnostics?.record(
            'session.checkpoint',
            message: 'A progress checkpoint could not be written',
            error: exception,
          );
        }
      } while (_checkpointRequested);
    } finally {
      _checkpointInFlight = false;
      if (identical(_checkpointDrain, drain)) _checkpointDrain = null;
      if (!drain.isCompleted) drain.complete();
    }
  }

  Future<void> _cancelAndDisposePlayback() async {
    try {
      await _thumbnails?.dispose();
    } on Object {
      // The native thumbnail extractor must still be released even if its
      // teardown reports a problem; playback disposal continues below.
    }
    try {
      await _seekPreview.dispose();
    } on Object {
      // Continue disposing playback if preview teardown fails.
    }
    try {
      await _stateSubscription?.cancel();
    } on Object {
      // Continue disposing libmpv even if stream cancellation fails.
    }
    _stateSubscription = null;
    try {
      await _playback.dispose();
    } on Object {
      // Synchronous ChangeNotifier disposal cannot report asynchronous teardown.
    }
  }
}
