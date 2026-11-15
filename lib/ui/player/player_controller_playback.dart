part of 'player_controller.dart';

/// Opening a source, resume, and load-attempt identity.
extension PlayerControllerPlayback on PlayerController {
  Future<void> _openIndex(
    int index, {
    int? navigationCursor,
    bool play = true,
  }) async {
    if (!_acceptsCommands || index < 0 || index >= _queue.length) return;
    _isStopped = false;
    _syncCurrentProgress();
    final operation = ++_operation;
    var entry = _queue[index];
    final isMusic =
        MediaCatalog.kindFromExtension(entry.path) == MediaKind.audio;
    final isRestoringSession = !_engineHasMedia && _currentIndex == index;
    final isNearCompletion =
        entry.duration > const Duration(seconds: 5) &&
        entry.position >= entry.duration - const Duration(seconds: 3);
    if (!isRestoringSession &&
        entry.position > Duration.zero &&
        (isMusic || isNearCompletion)) {
      entry = entry.copyWith(position: Duration.zero);
      _queue[index] = entry;
    }
    _pendingNavigationEntryId = entry.id;
    _pendingNavigationCursor = navigationCursor;
    _currentIndex = index;
    _clearResume();
    _completionHandled = false;
    _markSourceDisplaced();
    _engineHasMedia = false;
    _engineEntryId = null;
    _error = null;
    _mediaKind = PlayerController._classifyMediaKind(
      entry: entry,
      snapshot: _playbackState,
    );
    final pending = _PendingOpen(
      operation: operation,
      entryId: entry.id,
      source: entry.path,
    );
    _pendingOpen = pending;
    _armLoadTimeout(pending);
    _metadata = MediaMetadata(title: entry.title, duration: entry.duration);
    _publishQueue();
    _playbackState = _playbackState.copyWith(
      isPlaying: false,
      isBuffering: true,
      position: entry.position,
      duration: entry.duration,
      completed: false,
      clearError: true,
      clearNativeSource: true,
      sourceLoaded: false,
    );
    _publishTransport();
    _notifyIfOpen();

    final localPath = _localPath(entry.path);
    if (localPath != null && !await File(localPath).exists()) {
      if (!_acceptsCommands || operation != _operation) return;
      _clearPendingNavigation(entry.id);
      _engineEntryId = null;
      _finishPendingOpen();
      _playbackState = _playbackState.copyWith(
        isBuffering: false,
        position: entry.position,
        duration: entry.duration,
      );
      _setError('File not found: ${entry.path}');
      await _ignorePlaybackFailure(_playback.stop);
      if (!_acceptsCommands || operation != _operation) return;
      _scheduleSave();
      return;
    }

    if (!_acceptsCommands || operation != _operation) return;

    try {
      await _playback.open(entry.path, play: play);
      if (!_isCurrentOpen(pending)) return;
      // The load may already be confirmed by the service's latest state, since
      // native events can arrive while open() is still awaiting.
      if (identical(_pendingOpen, pending)) {
        final state = _playback.state;
        switch (_classifyPendingSnapshot(pending, state)) {
          case _PendingLoadOutcome.confirmed:
            _confirmPendingOpen(pending, state.copyWith(isBuffering: false));
          case _PendingLoadOutcome.refused:
            final detail = state.error;
            _failPendingOpen(
              pending,
              detail == null || detail.isEmpty
                  ? 'Could not open ${entry.title}'
                  : 'Could not open ${entry.title}: $detail',
            );
          case _PendingLoadOutcome.stillLoading:
            // The engine reports the load when it is ready; the load timeout
            // covers an engine that never does.
            break;
        }
      }
    } on Object catch (exception) {
      if (!_isCurrentOpen(pending)) return;
      _failPendingOpen(pending, 'Could not open ${entry.title}: $exception');
      _diagnostics?.record(
        'playback.open',
        sourceId: entry.path,
        message: 'The engine refused to open the source',
        error: exception,
      );
    }
  }

  void _clearPendingNavigation(String entryId) {
    if (_pendingNavigationEntryId != entryId) return;
    _pendingNavigationEntryId = null;
    _pendingNavigationCursor = null;
  }

  /// Holds the pending resume target until the engine reports it.
  PlaybackSnapshot _applyResumeFloor(PlaybackSnapshot snapshot) {
    final floor = _resumeFloor;
    if (floor == null) return snapshot;
    if (snapshot.position >= floor) {
      _clearResumeFloor();
      return snapshot;
    }
    return snapshot.copyWith(position: floor);
  }

  /// Applies the engine state that belongs to the previous source while a load
  /// attempt is unresolved, so nothing from the old source reaches the view.
  void _applyLoadingSnapshot(PlaybackSnapshot snapshot) {
    final isStaleSource =
        snapshot.sourceStart > 0 &&
        (snapshot.sourceStart <= _displacedSourceStart ||
            (_activeSourceStart > 0 &&
                snapshot.sourceStart < _activeSourceStart));
    if (isStaleSource) {
      return;
    }
    final entry = current;
    final previous = _playbackState;
    _applySnapshot(
      snapshot.copyWith(
        isPlaying: false,
        isBuffering: true,
        position: entry?.position ?? previous.position,
        duration: entry?.duration ?? previous.duration,
        completed: false,
      ),
      notify: false,
    );
    if (snapshot.error != null && snapshot.error!.isNotEmpty) {
      _error = snapshot.error;
    }
    final changed =
        previous.isPlaying != isPlaying ||
        previous.volume != volume ||
        previous.rate != rate ||
        previous.shuffle != shuffle ||
        previous.audioTracks != audioTracks ||
        previous.subtitleTracks != subtitleTracks ||
        previous.currentAudioTrack != currentAudioTrack ||
        previous.currentSubtitleTrack != currentSubtitleTrack;
    if (changed) {
      // Views read the transport glyph from [transportListenable], so a loading
      // snapshot that changes transport state has to publish it as well.
      _publishTransport();
      _notifyIfOpen();
    }
  }

  /// Attributes one engine snapshot to the load attempt that is still pending.
  ///
  /// The identity the engine reports decides the outcome. An event from a
  /// displaced source is only ever loading state, so the old source's progress,
  /// completion or failure can never finish or fail the attempt that replaced
  /// it. Services that report no identity keep the request-boundary fallback.
  _PendingLoadOutcome _classifyPendingSnapshot(
    _PendingOpen pending,
    PlaybackSnapshot snapshot,
  ) {
    final hasError = snapshot.error != null && snapshot.error!.isNotEmpty;
    final attached = snapshot.nativeSource;
    if (attached != null) {
      if (!_isSourceOf(attached, pending.source)) {
        return _PendingLoadOutcome.stillLoading;
      }
      if (hasError) return _PendingLoadOutcome.refused;
      if (snapshot.sourceLoaded) return _PendingLoadOutcome.confirmed;
      if (snapshot.completed) {
        // The engine opened the requested source and reached its end before the
        // loading confirmation arrived: a source that is over, not a failure.
        return _PendingLoadOutcome.confirmed;
      }
      return _PendingLoadOutcome.stillLoading;
    }
    if (pending.boundary > 0 && snapshot.sourceStart != pending.boundary) {
      return _PendingLoadOutcome.stillLoading;
    }
    if (hasError) return _PendingLoadOutcome.refused;
    if (snapshot.sourceLoaded) return _PendingLoadOutcome.confirmed;
    if (snapshot.completed) return _PendingLoadOutcome.refused;
    return _PendingLoadOutcome.stillLoading;
  }

  /// Marks the attached source as displaced so its late events are dropped.
  void _markSourceDisplaced() {
    if (_activeSourceStart > _displacedSourceStart) {
      _displacedSourceStart = _activeSourceStart;
    }
    _seekPreview.setSource(null);
  }

  void _armLoadTimeout(_PendingOpen pending) {
    _loadTimer?.cancel();
    _loadTimer = Timer(PlayerController._loadTimeout, () {
      if (!identical(_pendingOpen, pending) || !_acceptsCommands) return;
      _failPendingOpen(
        pending,
        'Timed out waiting for ${_titleForEntry(pending.entryId)} to load',
      );
    });
  }

  void _finishPendingOpen({bool publish = true}) {
    _pendingOpen = null;
    _loadTimer?.cancel();
    _loadTimer = null;
    if (publish) _publishTransport();
  }

  void _cancelPendingOpen({required String reason}) {
    final pending = _pendingOpen;
    if (pending == null) return;
    _finishPendingOpen();
    _diagnostics?.record(
      'playback.cancel',
      sourceId: pending.source,
      message: 'Load attempt cancelled: $reason',
    );
  }

  /// The engine confirmed the requested source is open.
  void _confirmPendingOpen(_PendingOpen pending, PlaybackSnapshot snapshot) {
    if (snapshot.sourceStart > 0) pending.boundary = snapshot.sourceStart;
    _adoptEngineSource(
      entryId: pending.entryId,
      boundary: pending.boundary,
      duration: snapshot.duration,
    );
  }

  void _adoptEngineSource({
    required String entryId,
    required int boundary,
    required Duration duration,
  }) {
    final entry = _entryById(entryId);
    if (entry == null) {
      _finishPendingOpen();
      return;
    }
    // Mark the engine attached before clearing _pendingOpen so any listener
    // triggered by _publishTransport sees hasMedia == true and never misreads
    // a newly loaded track as an unloaded session needing prepareCurrentPaused.
    _engineHasMedia = true;
    _engineEntryId = entryId;
    _activeSourceStart = boundary;
    _finishPendingOpen(publish: false);
    final effectiveDuration = duration > Duration.zero
        ? duration
        : entry.duration;
    _mediaKind = PlayerController._classifyMediaKind(
      entry: entry,
      snapshot: _playbackState,
    );
    _metadata = _metadata.copyWith(
      title: entry.title,
      duration: effectiveDuration,
    );
    final saved =
        effectiveDuration > const Duration(seconds: 5) &&
            entry.position >= effectiveDuration - const Duration(seconds: 3)
        ? Duration.zero
        : entry.position;
    _diagnostics?.record(
      'playback.attached',
      sourceId: entry.path,
      message:
          'boundary $boundary, duration ${duration.inMilliseconds} ms, '
          'resume ${saved.inMilliseconds} ms',
    );
    _playbackState = _playbackState.copyWith(
      isPlaying: _playback.state.isPlaying,
      isBuffering: false,
      position: saved,
      duration: effectiveDuration,
      completed: false,
      clearError: true,
    );
    if (saved > Duration.zero) {
      _resumeFloor = saved;
      _resumeEntryId = entryId;
      _resumeSeekStarted = false;
      _resumeFloorTimer?.cancel();
      _resumeFloorTimer = Timer(
        PlayerController._resumeFloorGrace,
        _clearResumeFloor,
      );
    } else {
      _clearResume();
    }
    _recordNavigation(entryId);
    _recordHistory(entry, playedAt: DateTime.now());
    _syncCurrentProgress();
    _publishQueue();
    _publishTransport();
    _notifyIfOpen();
    _consumePendingResume();
    _syncCurrentProgress();
    _seekPreview.setSource(
      entry.path,
      isAudio: isAudio,
      isSeekable: isSeekable,
    );
    _scheduleSave();
    _updateProgressTimer();
  }

  void _failPendingOpen(_PendingOpen pending, String message) {
    if (!identical(_pendingOpen, pending)) return;
    _finishPendingOpen();
    _clearPendingNavigation(pending.entryId);
    _engineHasMedia = false;
    _engineEntryId = null;
    _activeSourceStart = pending.boundary;
    final entry = _entryById(pending.entryId);
    _playbackState = _playbackState.copyWith(
      isPlaying: false,
      isBuffering: false,
      position: entry?.position ?? _playbackState.position,
      duration: entry?.duration ?? _playbackState.duration,
    );
    _setError(message);
    _diagnostics?.record(
      'playback.open',
      sourceId: pending.source,
      message: message,
    );
    _scheduleSave();
  }

  void _consumePendingResume() {
    final target = _resumeFloor;
    if (target == null || _resumeSeekStarted) return;
    final end = _playbackState.duration;
    if (end <= Duration.zero) return;
    // Finishing within the last two seconds means the item was effectively
    // complete; restarting it is more useful than seeking to its very end.
    final resolved = target >= end - const Duration(seconds: 2)
        ? Duration.zero
        : PlayerController._clampPosition(target, end);
    final operation = _operation;
    final resumeGeneration = _resumeGeneration;
    if (resolved == Duration.zero) {
      _clearResume();
      return;
    }
    _resumeSeekStarted = true;
    unawaited(
      _playback
          .seek(resolved)
          .then((_) {
            if (!_acceptsCommands ||
                operation != _operation ||
                resumeGeneration != _resumeGeneration) {
              return;
            }
            _playbackState = _playbackState.copyWith(position: resolved);
            _notifyIfOpen();
            _syncCurrentProgress();
            _scheduleSave();
            unawaited(_writeProgressCheckpoint());
          })
          .catchError((Object exception) {
            if (!_acceptsCommands ||
                operation != _operation ||
                resumeGeneration != _resumeGeneration) {
              return;
            }
            // Keep the saved-position floor in place: the next engine tick
            // reports the freshly opened source at zero and would otherwise
            // overwrite the stored resume point before the grace timer expires.
            _setError('Could not resume playback position: $exception');
          }),
    );
  }

  void _clearResume() {
    _resumeGeneration++;
    _resumeFloor = null;
    _resumeEntryId = null;
    _resumeSeekStarted = false;
    _resumeFloorTimer?.cancel();
    _resumeFloorTimer = null;
  }

  void _clearResumeFloor() {
    _resumeGeneration++;
    _resumeFloor = null;
    _resumeFloorTimer?.cancel();
    _resumeFloorTimer = null;
  }
}
