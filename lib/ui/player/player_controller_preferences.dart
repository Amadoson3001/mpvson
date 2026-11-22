part of 'player_controller.dart';

/// Volume, rate, and initial queue preference writes.
extension PlayerControllerPreferences on PlayerController {
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

  void _publishRate() {
    if (_notifierDisposed) return;
    final value = rate;
    if (rateListenable.value == value) return;
    rateListenable.value = value;
  }

  Future<void> setRate(double value) async {
    if (!_acceptsCommands) return;
    _transportCommandRevision++;
    final target = PlayerController._normalizeRate(value);
    _desiredRate = target;
    _rateRevision++;
    _rateWriteShouldSave = true;
    _publishRate();
    _notifyIfOpen();
    await _drainRateWrites();
  }

  Future<void> _applyInitialRate(double value, int revisionAtStart) async {
    if (_rateRevision != revisionAtStart || _desiredRate != null) return;
    _desiredRate = PlayerController._normalizeRate(value);
    _rateRevision++;
    _rateWriteShouldSave = false;
    _publishRate();
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
            _publishRate();
            _publishPosition(position);
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
          _publishRate();
          _publishPosition(position);
          _setError('Could not set playback speed: $exception');
        }
      }
    } finally {
      if (identical(_rateDrain, completion)) _rateDrain = null;
      if (!completion.isCompleted) completion.complete();
    }
  }
}
