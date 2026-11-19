part of 'player_controller.dart';

/// Transport commands, volume, rate, and playback preferences.
extension PlayerControllerTransport on PlayerController {
  SeekPreviewService get seekPreview => _seekPreview;

  bool get isSeekable => _playbackState.isSeekable;

  double get volume => _desiredVolume ?? _playbackState.volume;

  double get rate => _desiredRate ?? _playbackState.rate;

  bool get shuffle => _shuffleEnabled;

  /// Current repeat mode as a string ('off', 'all', 'one') for backwards compatibility.
  String get repeatMode => _repeatMode.value;

  /// Strongly typed current repeat mode.
  PlayerRepeatMode get playerRepeatMode => _repeatMode;

  ControlDensity get controlDensity => _controlDensity;

  bool get autoPlayNextVideo => _autoPlayNextVideo;

  bool get autoPlayNextAudio => _autoPlayNextAudio;

  PlaybackSettings get playbackSettings => _playbackSettings;

  String? get playbackSettingsError => _playbackSettingsError;

  List<SubtitleTrack> get subtitleTracks => _playbackState.subtitleTracks;

  SubtitleTrack get currentSubtitleTrack => _playbackState.currentSubtitleTrack;

  Future<void> playIndex(int index) => _openIndex(index);

  /// Selects a stream rendition (or Auto) for the active network stream.
  Future<void> selectStreamQuality(StreamRendition rendition) async {
    await _playback.selectQuality(rendition);
  }

  /// Retries opening the current queue entry after a transient or stream interruption.
  Future<void> retryCurrentStream() async {
    final entry = current;
    if (entry != null) {
      _clearError();
      await _openIndex(_currentIndex, play: true);
    }
  }

  /// Loads the restored current entry without starting playback so the player
  /// can present its paused frame instead of a resume placeholder.
  Future<void> prepareCurrentPaused() async {
    if (!_acceptsCommands ||
        _engineHasMedia ||
        isLoading ||
        _isStopped ||
        _error != null) {
      return;
    }
    final entry = current;
    if (entry == null ||
        MediaEntry.isNetworkUrl(entry.path) ||
        !MediaCatalog.kindFromExtension(entry.path).isVideo) {
      return;
    }
    await _openIndex(_currentIndex, play: false);
  }

  Future<void> stop() async {
    if (!_acceptsCommands || current == null) return;
    _isStopped = true;
    _completionHandled = true;
    _transportCommandRevision++;
    _updateQueueProgress(
      _currentIndex,
      position: Duration.zero,
      duration: duration,
    );
    unawaited(_writeProgressCheckpoint());
    _operation++;
    _cancelPendingOpen(reason: 'playback stopped');
    _clearPendingNavigation(current!.id);
    _clearResume();
    _markSourceDisplaced();
    _engineHasMedia = false;
    _engineEntryId = null;
    _playbackState = _playbackState.copyWith(
      isPlaying: false,
      isBuffering: false,
      position: Duration.zero,
      clearNativeSource: true,
      sourceLoaded: false,
    );
    final stopping = _ignorePlaybackFailure(_playback.stop);
    _seekPreview.setSource(null);
    _publishPosition(Duration.zero);
    _publishTransport();
    _notifyIfOpen();
    _scheduleSave();
    await stopping;
    // The engine may have been released while the stop drained; touching the
    // thumbnail caches afterwards would use torn-down services.
    if (_acceptsCommands) trimMemory();
  }

  /// Stops playback and dismisses the now-playing item.
  ///
  /// The queue is kept, so ending a listening session does not discard entries
  /// the user queued up; another entry can be started from the queue panel.
  Future<void> closePlayer() async {
    if (!_acceptsCommands || current == null) return;
    await stop();
    if (!_acceptsCommands || _currentIndex < 0) return;
    _operation++;
    _currentIndex = -1;
    _engineHasMedia = false;
    _engineEntryId = null;
    _clearResume();
    _mediaKind = MediaKind.unknown;
    _metadata = MediaMetadata.empty;
    _navigationHistory.clear();
    _navigationCursor = -1;
    _pendingNavigationEntryId = null;
    _pendingNavigationCursor = null;
    if (shuffle) _resetShuffleCycle();
    _publishQueue();
    _playbackState = _playbackState.copyWith(
      isPlaying: false,
      isBuffering: false,
      position: Duration.zero,
      duration: Duration.zero,
      completed: false,
      clearError: true,
      clearNativeSource: true,
      sourceLoaded: false,
    );
    _publishTransport();
    _notifyIfOpen();
    _scheduleSave();
  }

  Future<void> togglePlayPause() async {
    if (!_acceptsCommands) return;
    _transportCommandRevision++;
    if (isLoading) return;
    if (current == null) {
      if (_queue.isNotEmpty) {
        await playIndex(0);
      }
      return;
    }
    if (isPlaying) {
      await _runPlaybackCommand(_playback.pause);
    } else if (!_engineHasMedia) {
      _isStopped = false;
      await playIndex(_currentIndex);
    } else {
      _isStopped = false;
      await _runPlaybackCommand(_playback.play);
    }
  }

  Future<void> seek(Duration position) async {
    if (!_acceptsCommands) return;
    if (isLoading || _pendingNavigationEntryId != null) return;
    _transportCommandRevision++;
    final seekRevision = ++_seekRevision;
    if (current == null) return;
    final entryId = current!.id;
    final operation = _operation;
    final target = PlayerController._clampPosition(position, duration);
    if (!_engineHasMedia) {
      // A restored, stopped item has no engine position to change, so the saved
      // progress is updated directly and survives the next launch.
      _playbackState = _playbackState.copyWith(position: target);
      _publishPosition(target);
      _updateQueueProgress(
        _currentIndex,
        position: target,
        duration: current!.duration,
      );
      _notifyIfOpen();
      _scheduleSave();
      await _writeProgressCheckpoint();
      return;
    }
    _clearResume();
    try {
      await _playback.seek(target);
      if (!_acceptsCommands ||
          seekRevision != _seekRevision ||
          operation != _operation ||
          current?.id != entryId ||
          !_engineHasMedia ||
          _engineEntryId != entryId) {
        return;
      }
      _playbackState = _playbackState.copyWith(position: target);
      _publishPosition(target);
      _syncCurrentProgress();
      _notifyIfOpen();
      _scheduleSave();
    } on Object catch (exception) {
      if (_acceptsCommands &&
          seekRevision == _seekRevision &&
          operation == _operation &&
          current?.id == entryId &&
          _engineHasMedia &&
          _engineEntryId == entryId) {
        _setError('Could not seek: $exception');
      }
    }
  }

  Future<void> seekRelative(Duration delta) => seek(position + delta);

  void _publishVolume() {
    if (_notifierDisposed) return;
    final value = volume;
    if (volumeListenable.value == value) return;
    volumeListenable.value = value;
  }

  Future<void> setVolume(double value, {bool scheduleSave = true}) async {
    if (!_acceptsCommands) return;
    final target = PlayerController._normalizeVolume(value);
    final previous = volume;
    if (target > 0) {
      _lastAudibleVolume = target;
    } else if (previous > 0) {
      _lastAudibleVolume = previous;
    }
    _desiredVolume = target;
    _volumeRevision++;
    _publishVolume();
    if (scheduleSave) _scheduleSave();
    final pendingWrite = _drainVolumeWrites();
    _notifyIfOpen();
    await pendingWrite;
  }

  /// Changes volume relative to the latest requested value, even while a
  /// native volume write is still in flight.
  Future<void> adjustVolume(double delta) => setVolume(volume + delta);

  Future<void> _drainVolumeWrites() {
    final activeDrain = _volumeDrain;
    if (activeDrain != null) return activeDrain.future;

    final completion = Completer<void>();
    _volumeDrain = completion;
    unawaited(_writeVolumeDrain(completion));
    return completion.future;
  }

  Future<void> _writeVolumeDrain(Completer<void> completion) async {
    try {
      while (!_isClosed && _appliedVolumeRevision < _volumeRevision) {
        final revision = _volumeRevision;
        final target = _desiredVolume ?? _playbackState.volume;
        try {
          await _playback.setVolume(target);
          _confirmedVolume = target;
          if (revision == _volumeRevision) {
            _appliedVolumeRevision = revision;
          }
        } on Object catch (exception) {
          if (revision == _volumeRevision) {
            _desiredVolume = _confirmedVolume;
            _publishVolume();
            if (_confirmedVolume > 0) {
              _lastAudibleVolume = _confirmedVolume;
            }
            _appliedVolumeRevision = revision;
            _scheduleSave();
            _setError('Could not set volume: $exception');
          }
        }
      }
    } finally {
      if (identical(_volumeDrain, completion)) _volumeDrain = null;
      if (!completion.isCompleted) completion.complete();
    }
  }

  Future<void> setRate(double value) async {
    if (!_acceptsCommands) return;
    _transportCommandRevision++;
    final target = PlayerController._normalizeRate(value);
    _desiredRate = target;
    _rateRevision++;
    _rateWriteShouldSave = true;
    _notifyIfOpen();
    await _drainRateWrites();
  }

  Future<void> _applyInitialRate(double value, int revisionAtStart) async {
    if (_rateRevision != revisionAtStart || _desiredRate != null) return;
    _desiredRate = PlayerController._normalizeRate(value);
    _rateRevision++;
    _rateWriteShouldSave = false;
    await _drainRateWrites();
  }

  Future<void> _applyInitialQueuePreferences({
    required int shuffleRevisionAtStart,
    required int repeatRevisionAtStart,
  }) async {
    if (!_acceptsCommands) return;
    if (_shufflePreferenceRevision == shuffleRevisionAtStart &&
        _shuffleEnabled != _confirmedShuffle) {
      _shufflePreferenceRevision++;
      _shufflePreferenceSequence = ++_queuePreferenceSequence;
    }
    if (_repeatPreferenceRevision == repeatRevisionAtStart &&
        _repeatMode != _confirmedRepeatMode) {
      _repeatPreferenceRevision++;
      _repeatPreferenceSequence = ++_queuePreferenceSequence;
    }
    if (_shufflePreferenceRevision != _appliedShufflePreferenceRevision ||
        _repeatPreferenceRevision != _appliedRepeatPreferenceRevision) {
      await _drainQueuePreferences();
    }
  }

  Future<void> _drainRateWrites() {
    final activeDrain = _rateDrain;
    if (activeDrain != null) return activeDrain.future;

    final completion = Completer<void>();
    _rateDrain = completion;
    unawaited(_writeRateDrain(completion));
    return completion.future;
  }

  Future<void> _writeRateDrain(Completer<void> completion) async {
    try {
      while (!_isClosed && _appliedRateRevision < _rateRevision) {
        final revision = _rateRevision;
        final target = _desiredRate ?? _playbackState.rate;
        try {
          await _playback.setRate(target);
          _confirmedRate = target;
          if (revision == _rateRevision) {
            _desiredRate = null;
            _appliedRateRevision = revision;
            _playbackState = _playbackState.copyWith(rate: target);
            if (_rateWriteShouldSave) _scheduleSave();
            _notifyIfOpen();
          }
        } on Object catch (exception) {
          if (revision != _rateRevision) {
            _appliedRateRevision = revision;
            continue;
          }
          _desiredRate = null;
          _appliedRateRevision = revision;
          _playbackState = _playbackState.copyWith(rate: _confirmedRate);
          _setError('Could not set playback speed: $exception');
        }
      }
    } finally {
      if (identical(_rateDrain, completion)) _rateDrain = null;
      if (!completion.isCompleted) completion.complete();
    }
  }

  Future<void> next() async {
    if (!_acceptsCommands) return;
    _transportCommandRevision++;
    if (_queue.isEmpty || _currentIndex < 0) return;
    final nextHistoryCursor = _findHistoryCursor(
      _navigationCursor + 1,
      step: 1,
    );
    if (nextHistoryCursor >= 0) {
      final index =
          _queueIdToIndex[_navigationHistory[nextHistoryCursor]] ?? -1;
      if (index >= 0) {
        await _openIndex(index, navigationCursor: nextHistoryCursor);
        return;
      }
    }
    await _advance(fromCompletion: false);
  }

  Future<void> previous() async {
    if (!_acceptsCommands) return;
    _transportCommandRevision++;
    if (_queue.isEmpty || _currentIndex < 0) return;

    final isOpeningOrUnconfirmed =
        isLoading ||
        _pendingNavigationEntryId != null ||
        _engineEntryId == null ||
        _engineEntryId != current?.id;

    if (!isOpeningOrUnconfirmed && position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }

    final int startHistoryCursor;
    if (isOpeningOrUnconfirmed) {
      if (_pendingNavigationCursor != null) {
        startHistoryCursor = _pendingNavigationCursor! - 1;
      } else {
        startHistoryCursor = _navigationCursor;
      }
    } else {
      startHistoryCursor = _navigationCursor - 1;
    }

    final previousHistoryCursor = _findHistoryCursor(
      startHistoryCursor,
      step: -1,
    );
    if (previousHistoryCursor >= 0) {
      final index =
          _queueIdToIndex[_navigationHistory[previousHistoryCursor]] ?? -1;
      if (index >= 0) {
        if (isOpeningOrUnconfirmed) {
          _cancelPendingOpen(reason: 'navigated previous');
        }
        await _openIndex(index, navigationCursor: previousHistoryCursor);
        return;
      }
    }

    if (_currentIndex > 0) {
      if (isOpeningOrUnconfirmed) {
        _cancelPendingOpen(reason: 'navigated previous');
      }
      await playIndex(_currentIndex - 1);
      return;
    }
    if (_repeatMode == PlayerRepeatMode.all && !shuffle) {
      if (isOpeningOrUnconfirmed) {
        _cancelPendingOpen(reason: 'navigated previous');
      }
      await playIndex((_currentIndex - 1 + _queue.length) % _queue.length);
      return;
    }

    if (!isOpeningOrUnconfirmed) {
      await seek(Duration.zero);
    }
  }

  Future<void> toggleShuffle() => setShuffle(!shuffle);

  Future<void> setShuffle(bool target) {
    if (!_acceptsCommands) return Future<void>.value();
    if (target == shuffle) return Future<void>.value();
    _transportCommandRevision++;
    _setShuffleIntent(target);
    _shufflePreferenceRevision++;
    _shufflePreferenceSequence = ++_queuePreferenceSequence;
    _scheduleSave();
    _publishPlaybackMode();
    _notifyIfOpen();
    return _drainQueuePreferences();
  }

  Future<void> cycleRepeat() => setPlayerRepeatMode(switch (_repeatMode) {
    PlayerRepeatMode.off => PlayerRepeatMode.all,
    PlayerRepeatMode.all => PlayerRepeatMode.one,
    PlayerRepeatMode.one => PlayerRepeatMode.off,
  });

  /// Sets repeat mode using either a [PlayerRepeatMode] or string ('off', 'all', 'one').
  Future<void> setRepeatMode(Object mode) {
    final PlayerRepeatMode targetMode;
    if (mode is PlayerRepeatMode) {
      targetMode = mode;
    } else if (mode is String && const {'off', 'all', 'one'}.contains(mode)) {
      targetMode = PlayerRepeatMode.fromString(mode);
    } else {
      return Future<void>.value();
    }
    if (!_acceptsCommands || targetMode == _repeatMode) {
      return Future<void>.value();
    }
    _transportCommandRevision++;
    _repeatMode = targetMode;
    _repeatPreferenceRevision++;
    _repeatPreferenceSequence = ++_queuePreferenceSequence;
    _scheduleSave();
    _publishPlaybackMode();
    _notifyIfOpen();
    return _drainQueuePreferences();
  }

  /// Strongly typed alias for [setRepeatMode].
  Future<void> setPlayerRepeatMode(PlayerRepeatMode mode) =>
      setRepeatMode(mode);

  void _setShuffleIntent(bool target) {
    if (_shuffleEnabled == target) return;
    _shuffleEnabled = target;
    if (target) {
      if (_navigationCursor >= 0 &&
          _navigationCursor < _navigationHistory.length - 1) {
        _navigationHistory.removeRange(
          _navigationCursor + 1,
          _navigationHistory.length,
        );
      }
      _resetShuffleCycle();
    } else {
      _shuffleRemaining.clear();
      _shuffleVisited.clear();
    }
    _playbackState = _playbackState.copyWith(shuffle: target);
  }

  Future<void> _drainQueuePreferences() {
    final active = _queuePreferenceDrain;
    if (active != null) return active;
    late final Future<void> drain;
    drain = Future<void>.microtask(_writeQueuePreferences).whenComplete(() {
      if (!identical(_queuePreferenceDrain, drain)) return;
      _queuePreferenceDrain = null;
      if (_acceptsCommands &&
          (_shufflePreferenceRevision != _appliedShufflePreferenceRevision ||
              _repeatPreferenceRevision != _appliedRepeatPreferenceRevision)) {
        unawaited(_drainQueuePreferences());
      }
    });
    _queuePreferenceDrain = drain;
    return drain;
  }

  Future<void> _writeQueuePreferences() async {
    while (_acceptsCommands) {
      final shufflePending =
          _shufflePreferenceRevision != _appliedShufflePreferenceRevision;
      final repeatPending =
          _repeatPreferenceRevision != _appliedRepeatPreferenceRevision;
      if (!shufflePending && !repeatPending) return;

      final writeShuffle =
          shufflePending &&
          (!repeatPending ||
              _shufflePreferenceSequence <= _repeatPreferenceSequence);
      if (writeShuffle) {
        final revision = _shufflePreferenceRevision;
        final target = _shuffleEnabled;
        try {
          await _playback.setShuffle(target);
        } on Object catch (exception) {
          if (!_acceptsCommands) return;
          if (revision != _shufflePreferenceRevision) {
            _appliedShufflePreferenceRevision = revision;
            continue;
          }
          _setShuffleIntent(_confirmedShuffle);
          _shufflePreferenceRevision++;
          _appliedShufflePreferenceRevision = _shufflePreferenceRevision;
          _scheduleSave();
          _publishPlaybackMode();
          _setError('Could not change shuffle: $exception');
          continue;
        }
        if (!_acceptsCommands) return;
        _confirmedShuffle = target;
        _appliedShufflePreferenceRevision = revision;
        continue;
      }

      final revision = _repeatPreferenceRevision;
      final target = _repeatMode.value;
      try {
        await _playback.setRepeatMode(target);
      } on Object catch (exception) {
        if (!_acceptsCommands) return;
        if (revision != _repeatPreferenceRevision) {
          _appliedRepeatPreferenceRevision = revision;
          continue;
        }
        _repeatMode = _confirmedRepeatMode;
        _repeatPreferenceRevision++;
        _appliedRepeatPreferenceRevision = _repeatPreferenceRevision;
        _scheduleSave();
        _publishPlaybackMode();
        _setError('Could not change repeat mode: $exception');
        continue;
      }
      if (!_acceptsCommands) return;
      _confirmedRepeatMode = _repeatMode;
      _appliedRepeatPreferenceRevision = revision;
    }
  }

  /// Changes the player's control density and schedules the session update.
  void setControlDensity(ControlDensity value) {
    if (!_acceptsCommands || _controlDensity == value) return;
    _controlDensity = value;
    _controlDensityRevision++;
    _scheduleSave();
    _notifyIfOpen();
  }

  /// Sets whether the next video starts automatically when playback ends.
  void setAutoPlayNextVideo(bool value) {
    if (!_acceptsCommands || _autoPlayNextVideo == value) return;
    _autoPlayNextVideo = value;
    _autoPlayNextVideoRevision++;
    _scheduleSave();
    _notifyIfOpen();
  }

  /// Sets whether the next audio track starts automatically when playback ends.
  void setAutoPlayNextAudio(bool value) {
    if (!_acceptsCommands || _autoPlayNextAudio == value) return;
    _autoPlayNextAudio = value;
    _autoPlayNextAudioRevision++;
    _scheduleSave();
    _notifyIfOpen();
  }

  /// Saves bounded playback preferences and applies them to native mpv.
  Future<void> setPlaybackSettings(PlaybackSettings value) async {
    if (!_acceptsCommands) return;
    final target = value.normalized();
    if (_playbackSettings == target && _playbackSettingsError == null) return;
    _playbackSettings = target;
    _playbackSettingsError = null;
    _playbackSettingsRevision++;
    _scheduleSave();
    _notifyIfOpen();
    await _applyPlaybackSettings(target);
  }

  Future<void> _applyPlaybackSettings(PlaybackSettings settings) async {
    final revision = ++_playbackSettingsApplyRevision;
    final PlaybackSettingsCapability? capability =
        _playback is PlaybackSettingsCapability
        ? _playback as PlaybackSettingsCapability
        : null;
    if (capability == null) return;
    try {
      final result = await capability.applyPlaybackSettings(settings);
      if (!_acceptsCommands || revision != _playbackSettingsApplyRevision) {
        return;
      }
      if (result.superseded) return;
      _playbackSettingsError = result.succeeded
          ? null
          : result.reason ?? 'mpv could not confirm all playback settings.';
    } on Object catch (error) {
      if (!_acceptsCommands || revision != _playbackSettingsApplyRevision) {
        return;
      }
      _playbackSettingsError = 'Could not apply playback settings: $error';
    }
    _notifyIfOpen();
  }

  Future<void> setAudioTrack(AudioTrack track) async {
    if (!_acceptsCommands) {
      return;
    }
    final operation = _operation;
    try {
      await _playback.setAudioTrack(track);
      if (!_acceptsCommands || operation != _operation) return;
      _playbackState = _playbackState.copyWith(currentAudioTrack: track);
      _notifyIfOpen();
    } on Object catch (exception) {
      if (_acceptsCommands && operation == _operation) {
        _setError('Could not change audio track: $exception');
      }
    }
  }

  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    if (!_acceptsCommands) return;
    final operation = _operation;
    try {
      await _playback.setSubtitleTrack(track);
      if (!_acceptsCommands || operation != _operation) return;
      _playbackState = _playbackState.copyWith(currentSubtitleTrack: track);
      _notifyIfOpen();
    } on Object catch (exception) {
      if (_acceptsCommands && operation == _operation) {
        _setError('Could not change subtitles: $exception');
      }
    }
  }

  Future<void> loadSubtitle(String path) async {
    if (!_acceptsCommands) return;
    final operation = _operation;
    final localPath = _localPath(path);
    final localExists = localPath == null || await File(localPath).exists();
    if (!_acceptsCommands || operation != _operation) return;
    if (!localExists) {
      _setError('Subtitle file not found: $path');
      return;
    }
    try {
      await _playback.loadSubtitle(path);
      if (!_acceptsCommands || operation != _operation) return;
      _notifyIfOpen();
    } on Object catch (exception) {
      if (_acceptsCommands && operation == _operation) {
        _setError('Could not load subtitles: $exception');
      }
    }
  }

  int? _takeShuffleNextIndex() {
    if (_queue.isEmpty) return null;
    _prepareShuffleRemaining();
    if (_shuffleRemaining.isEmpty) {
      if (_repeatMode != PlayerRepeatMode.all) return null;
      _shuffleVisited.clear();
      final currentId = _currentQueueId;
      if (currentId != null) _shuffleVisited.add(currentId);
      _shuffleRemaining
        ..clear()
        ..addAll(_queue.map((entry) => entry.id).where((id) => id != currentId))
        ..shuffle(_random);
      if (_shuffleRemaining.isEmpty && currentId != null) {
        return _queueIdToIndex[currentId] ?? -1;
      }
    }
    if (_shuffleRemaining.isEmpty) return null;
    final nextId = _shuffleRemaining.removeLast();
    return _queueIdToIndex[nextId] ?? -1;
  }

  void _prepareShuffleRemaining() {
    final currentId = _currentQueueId;
    _shuffleRemaining.removeWhere(
      (id) =>
          !_queueIdToIndex.containsKey(id) ||
          id == currentId ||
          _shuffleVisited.contains(id),
    );
    final remainingIds = _shuffleRemaining.toSet();
    final added = _queue
        .map((entry) => entry.id)
        .where(
          (id) =>
              id != currentId &&
              !_shuffleVisited.contains(id) &&
              !remainingIds.contains(id),
        )
        .toList();
    added.shuffle(_random);
    _shuffleRemaining.addAll(added);
  }

  void _prioritizeShuffleEntries(Iterable<MediaEntry> entries) {
    // `_takeShuffleNextIndex` pops from the end of `_shuffleRemaining`, so append
    // prioritized entries in reverse order for immediate next playback.
    for (final entry in entries.toList().reversed) {
      _shuffleVisited.remove(entry.id);
      _shuffleRemaining.remove(entry.id);
      _shuffleRemaining.add(entry.id);
    }
  }

  void _resetShuffleCycle() {
    _shuffleVisited.clear();
    final currentId = _currentQueueId;
    if (currentId != null) _shuffleVisited.add(currentId);
    _shuffleRemaining
      ..clear()
      ..addAll(_queue.map((entry) => entry.id).where((id) => id != currentId))
      ..shuffle(_random);
  }

  void _publishPlaybackMode() {
    if (_notifierDisposed) return;
    final next = PlaybackMode(shuffle: _shuffleEnabled, repeat: _repeatMode);
    if (playbackModeListenable.value != next) {
      playbackModeListenable.value = next;
    }
  }

  void _publishTransport() {
    if (_notifierDisposed) return;
    final buffering = isBuffering;
    if (bufferingListenable.value != buffering) {
      bufferingListenable.value = buffering;
    }
    transportListenable.value = TransportState(
      isPlaying: isPlaying,
      isBuffering: buffering,
      isLoading: isLoading,
      hasMedia: _engineHasMedia,
      completed: _playbackState.completed,
      error: _error,
      streamPlaybackState: _playbackState.streamPlaybackState,
    );
    _updateProgressTimer();
  }

  Future<void> _runPlaybackCommand(Future<void> Function() command) async {
    try {
      await command();
    } on Object catch (exception) {
      _setError('Playback command failed: $exception');
    }
  }

  Future<void> _ignorePlaybackFailure(Future<void> Function() command) async {
    try {
      await command();
    } on Object catch (exception) {
      if (!_isClosed) _error ??= 'Playback engine unavailable: $exception';
    }
  }
}
