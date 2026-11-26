part of 'player_controller.dart';

/// Engine snapshots, playback advancement, and published state.
extension PlayerControllerEngine on PlayerController {
  void addThumbnailSuspension(ThumbnailSuspensionReason reason) {
    if (_thumbnailSuspensionReasons.isEmpty) {
      _thumbnails?.suspend();
    }
    _thumbnailSuspensionReasons.add(reason);
  }

  void removeThumbnailSuspension(ThumbnailSuspensionReason reason) {
    _thumbnailSuspensionReasons.remove(reason);
    if (_thumbnailSuspensionReasons.isEmpty) {
      _thumbnails?.resume();
    }
  }

  void _handlePreviewExtractionStateChange(bool extracting) {
    if (_notifierDisposed || _isClosing || _isClosed) return;
    if (extracting) {
      addThumbnailSuspension(ThumbnailSuspensionReason.previewExtraction);
    } else {
      removeThumbnailSuspension(ThumbnailSuspensionReason.previewExtraction);
    }
  }

  Listenable get structureListenable => _structureNotifier;

  /// Interpolated playback position for display, updated on a display cadence.
  ///
  /// The engine reports the position about 15 times a second while audio is
  /// playing, in 50-90 ms jumps, which makes a control bound to
  /// [positionListenable] step visibly. [position] stays the engine value and
  /// remains the source of truth for playback logic.
  ValueNotifier<Duration> get displayPositionListenable =>
      _positionSmoother.position;

  /// The interpolated playback position. Intended for display only.
  Duration get displayPosition => _positionSmoother.position.value;

  /// Suspends display interpolation while the window is minimized or hidden.
  void setDisplayUpdatesSuspended(bool suspended) =>
      _positionSmoother.setSuspended(suspended);

  /// Reduces display updates to one per second while the window is unfocused.
  void setDisplayUpdatesLowPower(bool lowPower) =>
      _positionSmoother.setLowPower(lowPower);

  Player get player => _playback.player;

  VideoController get videoController => _playback.videoController;

  /// Aspect ratio reported by the native video controller, or `null` when
  /// unavailable or not yet initialized.
  double? get videoAspectRatio {
    try {
      final rect = _playback.videoController.rect.value;
      if (rect != null && rect.width > 1 && rect.height > 1) {
        return rect.width / rect.height;
      }
    } catch (_) {
      // Fake/test playback services do not implement a native VideoController.
    }
    return null;
  }

  VideoOutputPolicy get videoOutputPolicy => _playback.videoOutputPolicy;

  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    _playback.applyVideoOutputPolicy(policy);
  }

  bool get trimOnMinimize => _trimOnMinimize;

  void applyGraphicsSettings(GraphicsSettings settings) {
    final normalized = settings.normalized();
    _trimOnMinimize = normalized.trimOnMinimize;
    final playback = _playback;
    if (playback is GraphicsSettingsCapability) {
      (playback as GraphicsSettingsCapability).applyGraphicsSettings(
        normalized,
      );
    }
  }

  void applyStreamingPreferences({
    String? ytDlpPath,
    PreferredStreamQuality? preferredQuality,
  }) {
    _playback.streamingCoordinator.configureStreamingPreferences(
      ytDlpPath: ytDlpPath,
      preferredQuality: preferredQuality,
    );
  }

  List<MediaEntry> get queue => _queueSnapshot.entries;

  QueueSnapshot get queueSnapshot => _queueSnapshot;

  int get currentIndex => _currentIndex;

  MediaEntry? get current {
    final entry = _queueSnapshot.current;
    if (entry == null) return null;
    if (_engineHasMedia && _engineEntryId == entry.id) {
      return entry.copyWith(
        position: _playbackState.position,
        duration: _playbackState.duration > Duration.zero
            ? _playbackState.duration
            : entry.duration,
      );
    }
    return entry;
  }

  /// Whether the native engine currently has a source loaded.
  ///
  /// A restored queue can have a [current] entry while remaining stopped, so
  /// views should use this instead of inferring media presence from the queue.
  bool get hasMedia => _engineHasMedia;

  /// Whether playback has been explicitly stopped by the user.
  bool get isStopped => _isStopped;

  /// Whether a load attempt is still in flight.
  ///
  /// The player shows loading state from this flag rather than from a boolean
  /// that queue edits could clear, so an open that is superseded, undone or
  /// cancelled can never strand the player in a spinner.
  bool get isLoading => _pendingOpen != null;

  bool get isPlaying => _playbackState.isPlaying;

  bool get isBuffering => _playbackState.isBuffering || _pendingOpen != null;

  Duration get position => _playbackState.position;

  Duration get duration => _playbackState.duration;

  String? get error => _error;

  List<AudioTrack> get audioTracks => _playbackState.audioTracks;

  AudioTrack get currentAudioTrack => _playbackState.currentAudioTrack;

  List<VideoTrack> get videoTracks => _playbackState.videoTracks;

  List<PlaybackChapter> get chapters => chaptersListenable.value;

  bool get isAudio => _mediaKind == MediaKind.audio;

  bool get isVideo => _mediaKind == MediaKind.video;

  /// Current media metadata.
  MediaMetadata get metadata => _metadata;

  /// Alias for [metadata] returning current media metadata.
  MediaMetadata get currentMetadata => metadata;

  void updateMetadata(MediaMetadata metadata) {
    if (_metadata == metadata) return;
    _metadata = metadata;
    _publishTransport();
    _notifyIfOpen();
  }

  String get engineVersion => _playback.engineVersion;

  /// Shutdown phase, so controls can reflect a saving or blocked shutdown.
  ControllerClosingState get closingState => _closingState;

  bool get isClosing => _closingState != ControllerClosingState.running;

  TransportState get transport => transportListenable.value;
  TransportState get transportState => transportListenable.value;

  /// Thumbnail extraction and caching service, if configured.
  ThumbnailService? get thumbnails => _thumbnails;

  /// Trims disposable thumbnail cache and releases inactive working set.
  void trimMemory({bool includeVideo = false}) {
    _thumbnails?.trimMemory();
    MemoryTrimmer.trimWorkingSet();
    if (includeVideo) {
      final playback = _playback;
      if (playback is VideoMemoryCapability) {
        unawaited((playback as VideoMemoryCapability).trimVideoMemory());
      }
    }
  }

  /// Loads artwork independently of the active playback engine and position.
  Future<MediaThumbnail?> loadThumbnail(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  }) async {
    if (_isClosing) return null;
    try {
      return await _thumbnails?.load(entry, priority: priority);
    } on Object {
      // Artwork failure must not prevent playing or managing a queue item.
      return null;
    }
  }

  /// Returns a synchronously available provisional thumbnail, if cached.
  MediaThumbnail? peekThumbnail(MediaEntry entry) => _thumbnails?.peek(entry);

  /// Requests a reference-counted thumbnail handle that can be released on disposal.
  ThumbnailRequestHandle? requestThumbnail(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  }) {
    if (_isClosing) return null;
    return _thumbnails?.request(entry, priority: priority);
  }

  /// Captures the currently displayed video frame as JPEG bytes from the active engine.
  Future<Uint8List?> captureFrame() async {
    if (_isClosing || !_engineHasMedia || isAudio) return null;
    try {
      return await _playback.player.screenshot(format: 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  Future<void> openPaths(
    List<String> paths, {
    bool append = false,
    bool playNext = false,
    int initialIndex = 0,
  }) async {
    if (!_acceptsCommands) return;
    final importOperation = ++_importOperation;
    final playbackOperation = _operation;
    final transportRevision = _transportCommandRevision;
    final structureRevision = _queueStructureRevision;
    final sourcePaths = List<String>.of(paths);
    final stagedEntries = <MediaEntry>[];
    String? firstRejected;
    // Resolve history once; scanning it per staged path made opening a large
    // collection grow with the collection times the history length.
    final recentBySource = <String, MediaEntry>{
      for (final entry in _recent)
        MediaEntry.canonicalSource(entry.path): entry,
    };

    bool isCurrentImport() =>
        _acceptsCommands &&
        importOperation == _importOperation &&
        playbackOperation == _operation &&
        transportRevision == _transportCommandRevision &&
        structureRevision == _queueStructureRevision;

    // Validate and build entries off to the side. Yielding during validation
    // keeps a very large file drop responsive without exposing partial rows to
    // QueuePanel or to index-based controller commands.
    const batchSize = 100;
    for (var start = 0; start < sourcePaths.length; start += batchSize) {
      final end = min(start + batchSize, sourcePaths.length);
      for (var index = start; index < end; index++) {
        final validation = MediaSource.validate(sourcePaths[index]);
        if (!validation.isValid) {
          firstRejected ??= validation.error!;
          continue;
        }
        final source = MediaEntry.normalizeSourcePath(validation.source!);
        final canonicalSource = MediaEntry.canonicalSource(source);
        final recentEntry = recentBySource[canonicalSource];
        final entry = MediaEntry.fromPath(
          source,
          id: _newQueueIdForCanonical(canonicalSource),
        );
        final isMusic =
            MediaCatalog.kindFromExtension(source) == MediaKind.audio;
        stagedEntries.add(
          recentEntry == null
              ? entry
              : entry.copyWith(
                  position: isMusic ? Duration.zero : recentEntry.position,
                  duration: recentEntry.duration,
                  lastPlayed: recentEntry.lastPlayed,
                ),
        );
      }

      // Yield between batches so a large import stays responsive and callers
      // can cancel it before commit. A single small import remains synchronous
      // through staging, preserving the established transition-start behavior
      // (for example, clearing a prior error as soon as openPaths is invoked).
      if (end < sourcePaths.length) {
        await Future<void>.delayed(Duration.zero);
        if (!isCurrentImport()) return;
      }
    }

    if (stagedEntries.isEmpty) {
      if (firstRejected != null) {
        _error = firstRejected;
        _diagnostics?.record(
          'source.rejected',
          message: firstRejected,
          sourceId: sourcePaths.isEmpty ? null : sourcePaths.first,
        );
        _publishTransport();
        _notifyIfOpen();
      }
      return;
    }
    if (!isCurrentImport()) return;

    // Commit the staged queue in one synchronous section. Until here, the
    // previous source and its displayed queue remain fully usable.
    _syncCurrentProgress();
    if (!isCurrentImport()) return;
    _undo = null;
    final firstNewIndex = append
        ? (playNext && _currentIndex >= 0 && _currentIndex < _queue.length
              ? _currentIndex + 1
              : _queue.length)
        : 0;
    if (!append) {
      // Replacing a queue invalidates its pending load only after the new queue
      // has been validated and is ready to commit.
      _cancelPendingOpen(reason: 'replaced by a new queue');
      _markSourceDisplaced();
      _navigationHistory.clear();
      _navigationCursor = -1;
      _pendingNavigationEntryId = null;
      _pendingNavigationCursor = null;
      _shuffleRemaining.clear();
      _shuffleVisited.clear();
      _replaceQueueEntries(stagedEntries, currentIndex: -1);
      _engineHasMedia = false;
      _engineEntryId = null;
      _clearResume();
      _mediaKind = MediaKind.unknown;
      _metadata = MediaMetadata.empty;
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
    } else if (playNext &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length) {
      final insertIndex = _currentIndex + 1;
      _insertQueueEntries(insertIndex, stagedEntries);
      if (shuffle) {
        _prioritizeShuffleEntries(stagedEntries);
      }
    } else {
      final oldLength = _queue.length;
      _insertQueueEntries(oldLength, stagedEntries);
      if (shuffle) _prepareShuffleRemaining();
    }
    if (firstRejected != null) {
      _diagnostics?.record(
        'source.rejected',
        message: firstRejected,
        sourceId: sourcePaths.isEmpty ? null : sourcePaths.first,
      );
    }
    _error = null;

    if (!append || _currentIndex < 0) {
      final targetIndex = append
          ? firstNewIndex
          : (initialIndex >= 0 && initialIndex < stagedEntries.length
                ? initialIndex
                : 0);
      await playIndex(targetIndex);
    } else {
      _publishQueue();
      _scheduleSave();
      _notifyIfOpen();
    }
  }

  Future<void> addToQueue(List<String> paths) => openPaths(paths, append: true);

  Future<void> playNext(List<String> paths) =>
      openPaths(paths, append: true, playNext: true);

  /// Toggles mute and restores the last audible volume when unmuting.
  Future<void> toggleMute() => setVolume(volume > 0 ? 0 : _lastAudibleVolume);

  /// Applies an adaptive quality preset only when the session has not
  /// loaded or customized playback settings yet.
  Future<void> applyRecommendedQualityIfDefault(
    PlaybackQualityPreset preset,
  ) async {
    _recommendedQualityPreset = preset;
    if (!_acceptsCommands ||
        _hasRestoredPlaybackSettings ||
        _playbackSettingsRevision > 0 ||
        _playbackSettings.qualityPreset == preset) {
      return;
    }
    _playbackSettings = _playbackSettings.copyWith(qualityPreset: preset);
    _notifyIfOpen();
    if (_initialized) {
      await _applyPlaybackSettings(_playbackSettings);
    }
  }

  bool _shouldAutoPlayNext(MediaEntry nextEntry) {
    final kind = MediaCatalog.kindFromExtension(nextEntry.path);
    if (kind == MediaKind.audio) return _autoPlayNextAudio;
    if (kind == MediaKind.video) return _autoPlayNextVideo;
    if (_mediaKind == MediaKind.audio) return _autoPlayNextAudio;
    return _autoPlayNextVideo;
  }

  Future<void> _advance({required bool fromCompletion}) async {
    if (_queue.isEmpty || _currentIndex < 0) return;

    void resetCompletedProgress() {
      if (!fromCompletion ||
          _currentIndex < 0 ||
          _currentIndex >= _queue.length) {
        return;
      }
      _playbackState = _playbackState.copyWith(position: Duration.zero);
      _updateQueueProgress(
        _currentIndex,
        position: Duration.zero,
        duration: duration,
      );
    }

    if (fromCompletion && _repeatMode == PlayerRepeatMode.one) {
      resetCompletedProgress();
      await playIndex(_currentIndex);
      return;
    }
    final historyCursor = _findHistoryCursor(_navigationCursor + 1, step: 1);
    if (historyCursor >= 0) {
      final historyIndex =
          _queueIdToIndex[_navigationHistory[historyCursor]] ?? -1;
      if (historyIndex >= 0) {
        if (fromCompletion && !_shouldAutoPlayNext(_queue[historyIndex])) {
          await _stopAfterQueue();
          return;
        }
        resetCompletedProgress();
        await _openIndex(historyIndex, navigationCursor: historyCursor);
        return;
      }
    }

    final targetIndex = shuffle ? _takeShuffleNextIndex() : _currentIndex + 1;
    if (targetIndex == null) {
      await _stopAfterQueue();
      return;
    }
    final resolvedIndex = targetIndex >= _queue.length
        ? (_repeatMode == PlayerRepeatMode.all ? 0 : null)
        : targetIndex;
    if (resolvedIndex == null) {
      await _stopAfterQueue();
      return;
    }
    if (fromCompletion &&
        resolvedIndex >= 0 &&
        resolvedIndex < _queue.length &&
        !_shouldAutoPlayNext(_queue[resolvedIndex])) {
      if (shuffle &&
          targetIndex >= 0 &&
          targetIndex < _queue.length &&
          _queue[targetIndex].id != _currentQueueId) {
        _shuffleRemaining.add(_queue[targetIndex].id);
      }
      await _stopAfterQueue();
      return;
    }
    resetCompletedProgress();
    await playIndex(resolvedIndex);
  }

  Future<void> _stopAfterQueue() async {
    _isStopped = true;
    _markSourceDisplaced();
    _engineHasMedia = false;
    _engineEntryId = null;
    _clearResume();
    _playbackState = _playbackState.copyWith(
      isPlaying: false,
      isBuffering: false,
      position: duration,
      completed: true,
    );
    await _ignorePlaybackFailure(_playback.stop);
    _scheduleSave();
    _publishTransport();
    _notifyIfOpen();
  }

  int _findHistoryCursor(int start, {required int step}) {
    for (
      var cursor = start;
      cursor >= 0 && cursor < _navigationHistory.length;
      cursor += step
    ) {
      final id = _navigationHistory[cursor];
      if (_queueIdToIndex.containsKey(id)) return cursor;
    }
    return -1;
  }

  String? get _currentQueueId =>
      _currentIndex >= 0 && _currentIndex < _queue.length
      ? _queue[_currentIndex].id
      : null;

  void _recordNavigation(String entryId) {
    final requestedCursor = _pendingNavigationCursor;
    if (_pendingNavigationEntryId == entryId &&
        requestedCursor != null &&
        requestedCursor >= 0 &&
        requestedCursor < _navigationHistory.length &&
        _navigationHistory[requestedCursor] == entryId) {
      _navigationCursor = requestedCursor;
    } else if (_navigationCursor >= 0 &&
        _navigationCursor < _navigationHistory.length &&
        _navigationHistory[_navigationCursor] == entryId) {
      // Reopening the current item, including repeat-one, is not a new visit.
    } else {
      if (_navigationCursor + 1 < _navigationHistory.length) {
        _navigationHistory.removeRange(
          _navigationCursor + 1,
          _navigationHistory.length,
        );
      }
      _navigationHistory.add(entryId);
      _navigationCursor = _navigationHistory.length - 1;
      if (_navigationHistory.length >
          PlayerController._maximumNavigationHistory) {
        const trimCount = 1000;
        _navigationHistory.removeRange(0, trimCount);
        _navigationCursor -= trimCount;
      }
    }
    _clearPendingNavigation(entryId);
    if (shuffle) {
      _shuffleRemaining.remove(entryId);
      _shuffleVisited.add(entryId);
    }
  }

  void _removeNavigationEntry(String entryId) {
    final oldCursor = _navigationCursor;
    var removedBeforeCursor = 0;
    for (var index = _navigationHistory.length - 1; index >= 0; index--) {
      if (_navigationHistory[index] != entryId) continue;
      if (index <= oldCursor) removedBeforeCursor++;
      _navigationHistory.removeAt(index);
    }
    _navigationCursor = (oldCursor - removedBeforeCursor)
        .clamp(-1, _navigationHistory.length - 1)
        .toInt();
    _shuffleRemaining.remove(entryId);
    _shuffleVisited.remove(entryId);
  }

  void _handleSnapshot(PlaybackSnapshot snapshot) {
    if (!_acceptsCommands) return;

    // A displaced source keeps reporting position, completion and even errors
    // while the next source loads. Its events are dropped outright: every new
    // load attempt carries a boundary above every earlier one.
    if (snapshot.sourceStart > 0 &&
        snapshot.sourceStart <= _displacedSourceStart) {
      return;
    }

    final pending = _pendingOpen;
    if (pending != null) {
      if (pending.boundary == 0) {
        final playback = _playback;
        if (playback is MediaKitPlaybackService) {
          _capturePendingBoundary(
            pending,
            candidate: playback.requestedBoundary,
          );
        } else if (snapshot.sourceStart > _displacedSourceStart &&
            snapshot.sourceStart > _activeSourceStart) {
          _capturePendingBoundary(pending, candidate: snapshot.sourceStart);
        }
      }
      switch (_classifyPendingSnapshot(pending, snapshot)) {
        case _PendingLoadOutcome.confirmed:
          snapshot = snapshot.copyWith(isBuffering: false);
          _confirmPendingOpen(pending, snapshot);
        case _PendingLoadOutcome.refused:
          final detail = snapshot.error;
          _failPendingOpen(
            pending,
            detail == null || detail.isEmpty
                ? 'Could not open ${_titleForEntry(pending.entryId)}'
                : 'Could not open ${_titleForEntry(pending.entryId)}: $detail',
          );
          return;
        case _PendingLoadOutcome.stillLoading:
          _applyLoadingSnapshot(snapshot);
          return;
      }
    }

    // Progress is only trusted for the source the engine confirmed, so an event
    // produced for a previous source can never update the new one.
    final isStaleSource =
        _activeSourceStart > 0 &&
        (snapshot.sourceStart < _activeSourceStart ||
            (_engineHasMedia &&
                snapshot.nativeSource != null &&
                _engineEntryId != null &&
                snapshot.nativeSource !=
                    MediaEntry.canonicalSource(
                      _sourceForEntry(_engineEntryId!),
                    )));
    if (isStaleSource) return;

    if (!_engineHasMedia &&
        snapshot.sourceLoaded &&
        current != null &&
        snapshot.sourceStart >= _activeSourceStart &&
        _isSourceOf(snapshot.nativeSource, current!.path)) {
      // The engine finished a load after the view model stopped waiting for it
      // (a superseded, cancelled or timed-out attempt). The reported identity
      // must match the selected entry, so a displaced source cannot be adopted.
      _adoptEngineSource(
        entryId: current!.id,
        boundary: snapshot.sourceStart,
        duration: snapshot.duration,
      );
    }

    if (!_engineHasMedia && current != null) {
      snapshot = snapshot.copyWith(
        isPlaying: false,
        isBuffering: false,
        position: current!.position,
        duration: current!.duration,
        completed: false,
      );
    }

    final oldPlaying = _playbackState.isPlaying;
    final oldBuffering = _playbackState.isBuffering;
    final oldSeekable = _playbackState.isSeekable;
    final oldDuration = _playbackState.duration;
    final oldVolume = volume;
    final oldRate = _playbackState.rate;
    final oldShuffle = _playbackState.shuffle;
    final oldTracks = _playbackState.audioTracks;
    final oldSubtitles = _playbackState.subtitleTracks;
    final oldAudio = _playbackState.currentAudioTrack;
    final oldSubtitle = _playbackState.currentSubtitleTrack;
    final oldError = _error;
    final wasCompleted = _playbackState.completed;
    final oldStreamPlaybackState = _playbackState.streamPlaybackState;

    snapshot = _applyResumeFloor(snapshot);
    final shouldSurfaceError = _shouldSurfaceSnapshotError(snapshot);
    _applySnapshot(snapshot, notify: false);
    final titleChanged = _syncResolvedStreamTitle(snapshot);
    if (_desiredRate == null) {
      _confirmedRate = PlayerController._normalizeRate(snapshot.rate);
      _publishRate();
    }
    if (oldDuration != _playbackState.duration && _engineHasMedia) {
      // Duration is queue metadata and should refresh queue rows once when the
      // engine resolves it; ordinary position ticks stay on the timeline path.
      _syncCurrentProgress();
    }
    if (_desiredVolume == null) {
      _confirmedVolume = PlayerController._normalizeVolume(snapshot.volume);
      if (_confirmedVolume > 0) _lastAudibleVolume = _confirmedVolume;
      _publishVolume();
    }

    if (shouldSurfaceError) {
      _error = snapshot.error;
      _diagnostics?.record(
        'playback.engine',
        sourceId: _engineEntryId == null
            ? null
            : _sourceForEntry(_engineEntryId!),
        message: snapshot.error,
      );
    }
    if (!snapshot.completed) _completionHandled = false;
    if (current != null && _engineHasMedia) {
      _consumePendingResume();
    }
    if (!_isStopped &&
        snapshot.completed &&
        _engineHasMedia &&
        snapshot.sourceLoaded &&
        !wasCompleted &&
        !_completionHandled) {
      _completionHandled = true;
      unawaited(_advance(fromCompletion: true));
    }

    final oldKind = _mediaKind;
    _mediaKind = PlayerController._classifyMediaKind(
      entry: current,
      snapshot: snapshot,
    );
    if (current != null && _metadata.duration != duration) {
      _metadata = _metadata.copyWith(duration: duration);
    }

    final changed =
        titleChanged ||
        oldKind != _mediaKind ||
        oldPlaying != isPlaying ||
        oldBuffering != isBuffering ||
        oldSeekable != isSeekable ||
        oldDuration != duration ||
        oldVolume != volume ||
        oldRate != rate ||
        oldShuffle != shuffle ||
        oldTracks != audioTracks ||
        oldSubtitles != subtitleTracks ||
        oldAudio != currentAudioTrack ||
        oldSubtitle != currentSubtitleTrack ||
        oldError != _error ||
        snapshot.completed != wasCompleted ||
        oldStreamPlaybackState != snapshot.streamPlaybackState;

    _publishPosition(position);
    if (oldDuration != duration) {
      durationListenable.value = duration;
    }
    if (oldBuffering != isBuffering) {
      bufferingListenable.value = isBuffering;
      if (isBuffering) {
        addThumbnailSuspension(ThumbnailSuspensionReason.playbackBuffering);
        _seekPreview.onPlaybackBuffering(true);
      } else {
        removeThumbnailSuspension(ThumbnailSuspensionReason.playbackBuffering);
        _seekPreview.onPlaybackBuffering(false);
      }
    }
    if (oldSeekable != isSeekable) {
      _seekPreview.setSeekable(isSeekable);
    }
    if (oldKind != _mediaKind) {
      _seekPreview.setAudio(isAudio);
    }
    if (_engineHasMedia &&
        current != null &&
        MediaEntry.isNetworkUrl(current!.path) &&
        snapshot.streamPlaybackState.streamUrl.isNotEmpty &&
        oldStreamPlaybackState.streamUrl !=
            snapshot.streamPlaybackState.streamUrl) {
      _syncSeekPreviewSource(current!);
    }

    if (changed) {
      _publishTransport();
      _notifyIfOpen();
    }

    _updateProgressTimer();
  }

  /// Publishes an engine position to the timeline listeners and re-anchors the
  /// display interpolation on it.
  ///
  /// The engine value is the only authority on where playback is; the smoother
  /// derives the value the user sees from it.
  void _publishPosition(Duration position) {
    final duration = _playbackState.duration;
    _positionSmoother.update(
      reported: position,
      duration: duration,
      rate: _confirmedRate,
      advancing:
          _engineHasMedia &&
          isPlaying &&
          !isBuffering &&
          duration > Duration.zero &&
          position < duration,
    );
  }

  bool _isCurrentOpen(_PendingOpen pending) =>
      _acceptsCommands && identical(_pendingOpen, pending);

  /// Whether an engine source identity describes [source].
  ///
  /// A snapshot without an identity carries no contradicting evidence, so it is
  /// attributed to the requested source, which keeps platforms without native
  /// property observation behaving as before.
  bool _isSourceOf(String? nativeSource, String source) =>
      nativeSource == null ||
      nativeSource == MediaEntry.canonicalSource(source);

  void _applySnapshot(PlaybackSnapshot snapshot, {bool notify = false}) {
    final chaptersChanged = !listEquals(
      _playbackState.chapters,
      snapshot.chapters,
    );
    _playbackState = snapshot;
    if (chaptersChanged && !_notifierDisposed) {
      chaptersListenable.value = snapshot.chapters;
    }
    if (_shouldSurfaceSnapshotError(snapshot)) {
      _error = snapshot.error;
    }
    if (notify) _notifyIfOpen();
  }

  bool _shouldSurfaceSnapshotError(PlaybackSnapshot snapshot) {
    final error = snapshot.error;
    if (error == null || error.isEmpty) {
      _dismissedEngineError = null;
      _dismissedEngineErrorSourceStart = null;
      return false;
    }
    if (_dismissedEngineError == error &&
        _dismissedEngineErrorSourceStart == snapshot.sourceStart) {
      return false;
    }
    return true;
  }

  bool _syncResolvedStreamTitle(PlaybackSnapshot snapshot) {
    final rawTitle = snapshot.streamPlaybackState.resolvedTitle?.trim();
    if (rawTitle == null ||
        rawTitle.isEmpty ||
        _currentIndex < 0 ||
        _currentIndex >= _queue.length) {
      return false;
    }
    final entry = _queue[_currentIndex];
    if (!MediaEntry.isNetworkUrl(entry.path)) return false;
    if (entry.title == rawTitle ||
        entry.title != MediaEntry.titleFromPath(entry.path)) {
      return false;
    }
    final updated = entry.copyWith(title: rawTitle);
    _queue[_currentIndex] = updated;
    final recentIndex =
        _recentIndexById[updated.id] ??
        _recentIndexById[MediaEntry.canonicalSource(updated.path)] ??
        -1;
    if (recentIndex >= 0 && recentIndex < _recent.length) {
      _recent[recentIndex] = _recent[recentIndex].copyWith(title: rawTitle);
      _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
    }
    if (_currentQueueId == entry.id) {
      _metadata = _metadata.copyWith(title: rawTitle);
    }
    _publishQueue();
    _publishStructureIfChanged();
    return true;
  }

  void _updateQueueProgress(
    int index, {
    required Duration position,
    required Duration duration,
  }) {
    if (index < 0 || index >= _queue.length) return;
    final updated = _queue[index].copyWith(
      position: position,
      duration: duration,
    );
    if (updated.position == _queue[index].position &&
        updated.duration == _queue[index].duration) {
      return;
    }
    _queue[index] = updated;
    final recentIndex =
        _recentIndexById[updated.id] ??
        _recentIndexById[MediaEntry.canonicalSource(updated.path)] ??
        -1;
    if (recentIndex >= 0) {
      _recent[recentIndex] = _recent[recentIndex].copyWith(
        position: updated.position,
        duration: updated.duration,
      );
      _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
    }
    _updateQueueSnapshotProgress(index, updated);
  }

  MediaEntry? _entryById(String id) {
    final index = _queueIdToIndex[id];
    if (index != null && index >= 0 && index < _queue.length) {
      return _queue[index];
    }
    return null;
  }

  String _sourceForEntry(String id) => _entryById(id)?.path ?? '';

  String _titleForEntry(String id) =>
      _entryById(id)?.title ?? 'the selected source';

  String _newQueueIdForCanonical(String canonicalSource) {
    _queueIdCounter++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return '$timestamp-$_queueIdCounter-${canonicalSource.hashCode}';
  }

  String? _localPath(String source) {
    final trimmed = source.trim();
    if (MediaEntry.isNetworkUrl(trimmed)) {
      return null;
    }
    return MediaEntry.normalizeSourcePath(trimmed);
  }

  void _setError(String message) {
    if (!_acceptsCommands) return;
    _dismissedEngineError = null;
    _dismissedEngineErrorSourceStart = null;
    _error = message;
    _publishTransport();
    _notifyIfOpen();
  }

  void _clearError() {
    if (!_acceptsCommands || _error == null) return;
    _error = null;
    _publishTransport();
    _notifyIfOpen();
  }

  void _notifyIfOpen() {
    if (_notifierDisposed || _closingState != ControllerClosingState.running) {
      return;
    }
    _publishStructureIfChanged();
    _notifyListeners();
  }

  void _publishStructureIfChanged() {
    final entry = current;
    final firstRecent = recent.isEmpty ? null : recent.first.id;
    final next =
        '${entry?.id}|${entry?.path}|${entry?.title}|'
        '$hasMedia|$isVideo|$isAudio|$isStopped|${_error ?? ''}|'
        '${recent.length}|$firstRecent|${controlDensity.name}';
    if (next == _structureKey) return;
    _structureKey = next;
    _structureNotifier.markChanged();
  }

  bool get _acceptsCommands =>
      _closingState == ControllerClosingState.running && !_notifierDisposed;

  bool get _isClosing =>
      _closingState == ControllerClosingState.saving ||
      _closingState == ControllerClosingState.awaitingDecision ||
      _closingState == ControllerClosingState.releasing;

  bool get _isClosed => _closingState == ControllerClosingState.closed;
}
