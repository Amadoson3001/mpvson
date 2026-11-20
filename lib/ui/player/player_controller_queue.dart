part of 'player_controller.dart';

/// Queue edits, history, and the structural queue snapshot.
extension PlayerControllerQueue on PlayerController {
  void _rebuildQueueIndex([int startIndex = 0]) {
    final start = startIndex.clamp(0, _queue.length);
    for (var i = start; i < _queue.length; i++) {
      _queueIdToIndex[_queue[i].id] = i;
    }
  }

  List<MediaEntry> get recent => _unmodifiableRecent;

  bool get canUndo => _undo != null;

  Future<void> removeAt(int index) async {
    if (!_acceptsCommands || index < 0 || index >= _queue.length) return;
    _syncCurrentProgress();
    final removedEntry = _queue[index];
    final oldCurrentId = current?.id;
    final opening = _pendingOpen;
    final wasActive = isPlaying || opening != null;
    final removedCurrent = index == _currentIndex;
    final removedOpening = opening?.entryId == removedEntry.id;
    final willEmptyQueue = _queue.length == 1;
    final displacedActiveSource =
        removedCurrent || removedOpening || willEmptyQueue;
    _undo = _QueueUndo.single(
      entry: removedEntry,
      index: index,
      previousCurrentId: oldCurrentId,
      wasPlaying: wasActive,
      displacedActiveSource: displacedActiveSource,
      displacedCurrent: removedCurrent,
    );
    _queueStructureRevision++;
    _queue.removeAt(index);
    _queueIdToIndex.remove(removedEntry.id);
    _rebuildQueueIndex(index);
    _removeNavigationEntry(removedEntry.id);

    if (_queue.isEmpty) {
      _cancelPendingOpen(reason: 'queue emptied');
      _markSourceDisplaced();
      _currentIndex = -1;
      _clearResume();
      _engineHasMedia = false;
      _engineEntryId = null;
      _mediaKind = MediaKind.unknown;
      _metadata = MediaMetadata.empty;
      _playbackState = _playbackState.copyWith(
        isPlaying: false,
        isBuffering: false,
        position: Duration.zero,
        duration: Duration.zero,
        completed: false,
        clearNativeSource: true,
        sourceLoaded: false,
      );
      _publishTransport();
      _notifyIfOpen();
      await _ignorePlaybackFailure(_playback.stop);
      if (!_acceptsCommands) return;
    } else if (removedCurrent || removedOpening) {
      final nextIndex = min(index, _queue.length - 1);
      _currentIndex = nextIndex;
      if (wasActive) {
        await playIndex(nextIndex);
        return;
      }
      _cancelPendingOpen(reason: 'current item removed');
      _markSourceDisplaced();
      _clearResume();
      _engineHasMedia = false;
      _engineEntryId = null;
      _mediaKind = MediaKind.unknown;
      _metadata = MediaMetadata.empty;
      _playbackState = _playbackState.copyWith(
        isPlaying: false,
        isBuffering: false,
        position: _queue[nextIndex].position,
        duration: _queue[nextIndex].duration,
        completed: false,
        clearNativeSource: true,
        sourceLoaded: false,
      );
      _publishTransport();
      _notifyIfOpen();
      await _ignorePlaybackFailure(_playback.stop);
      if (!_acceptsCommands) return;
    } else if (index < _currentIndex) {
      _currentIndex--;
    }

    // Queue-only edits keep the unfinished load of another item alive, so no
    // transition, no loading state and no engine command is touched here.
    _publishQueue();
    _scheduleSave();
    _notifyIfOpen();
  }

  /// Moves a queue entry to [newIndex], the destination Flutter's
  /// `ReorderableListView.onReorderItem` reports: it is already expressed in the
  /// list that remains after the dragged entry is lifted out, so callers must
  /// not adjust it again.
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (!_acceptsCommands ||
        oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex >= _queue.length) {
      return;
    }
    if (oldIndex == newIndex) return;
    _undo = null;
    final currentId = current?.id;
    _queueStructureRevision++;
    final entry = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, entry);
    _rebuildQueueIndex(min(oldIndex, newIndex));
    _currentIndex = currentId == null ? -1 : (_queueIdToIndex[currentId] ?? -1);
    if (_navigationCursor >= 0 &&
        _navigationCursor < _navigationHistory.length - 1) {
      _navigationHistory.removeRange(
        _navigationCursor + 1,
        _navigationHistory.length,
      );
    }
    if (shuffle &&
        _currentIndex >= 0 &&
        newIndex == _currentIndex + 1 &&
        entry.id != currentId) {
      _prioritizeShuffleEntries(<MediaEntry>[entry]);
    }
    _publishQueue();
    _scheduleSave();
    _notifyIfOpen();
  }

  Future<void> undoRemove() async {
    final undo = _undo;
    if (!_acceptsCommands || undo == null || undo.entries.isEmpty) return;
    _queueStructureRevision++;
    final insertIndex = undo.index.clamp(0, _queue.length);
    _queue.insertAll(insertIndex, undo.entries);
    _rebuildQueueIndex(insertIndex);
    if (shuffle) _prepareShuffleRemaining();
    final restoredIndex = undo.previousCurrentId == null
        ? -1
        : (_queueIdToIndex[undo.previousCurrentId] ?? -1);
    _currentIndex = restoredIndex >= 0
        ? restoredIndex
        : (_currentIndex >= 0 && insertIndex <= _currentIndex
              ? _currentIndex + undo.entries.length
              : _currentIndex);
    _undo = null;

    if (!undo.displacedActiveSource) {
      _publishQueue();
      _scheduleSave();
      _notifyIfOpen();
      return;
    }

    _cancelPendingOpen(reason: 'queue restored');
    _markSourceDisplaced();
    _clearResume();
    _engineHasMedia = false;
    _engineEntryId = null;
    _mediaKind = MediaKind.unknown;
    _metadata = MediaMetadata.empty;
    if (_currentIndex >= 0) {
      final entry = _queue[_currentIndex];
      _playbackState = _playbackState.copyWith(
        isPlaying: false,
        isBuffering: false,
        position: entry.position,
        duration: entry.duration,
        clearNativeSource: true,
        sourceLoaded: false,
      );
      _publishTransport();
      if (undo.wasPlaying) {
        await playIndex(_currentIndex);
        return;
      }
      _notifyIfOpen();
      await _ignorePlaybackFailure(_playback.stop);
      if (!_acceptsCommands) return;
    } else {
      _publishTransport();
    }
    _publishQueue();
    _scheduleSave();
    _notifyIfOpen();
  }

  Future<void> clearQueue() async {
    if (!_acceptsCommands) return;
    _syncCurrentProgress();
    final clearedEntries = List<MediaEntry>.of(_queue);
    final oldCurrentId = current?.id;
    final wasActive = isPlaying || _pendingOpen != null;
    final displacedActiveSource =
        _engineHasMedia || _pendingOpen != null || _currentIndex >= 0;
    final displacedCurrent = _currentIndex >= 0;

    _operation++;
    _queueStructureRevision++;
    _importOperation++;
    _cancelPendingOpen(reason: 'queue cleared');
    _markSourceDisplaced();
    _queue.clear();
    _queueIdToIndex.clear();
    _navigationHistory.clear();
    _navigationCursor = -1;
    _pendingNavigationEntryId = null;
    _pendingNavigationCursor = null;
    _shuffleRemaining.clear();
    _shuffleVisited.clear();
    _currentIndex = -1;
    _undo = clearedEntries.isEmpty
        ? null
        : _QueueUndo(
            entries: clearedEntries,
            index: 0,
            previousCurrentId: oldCurrentId,
            wasPlaying: wasActive,
            displacedActiveSource: displacedActiveSource,
            displacedCurrent: displacedCurrent,
            isClearAll: true,
          );
    _clearResume();
    _engineHasMedia = false;
    _engineEntryId = null;
    _mediaKind = MediaKind.unknown;
    _metadata = MediaMetadata.empty;
    _publishQueue();
    _playbackState = _playbackState.copyWith(
      isPlaying: false,
      isBuffering: false,
      position: Duration.zero,
      duration: Duration.zero,
      completed: false,
      clearNativeSource: true,
      sourceLoaded: false,
    );
    _publishTransport();
    _notifyIfOpen();
    await _ignorePlaybackFailure(_playback.stop);
    if (!_acceptsCommands) return;
    _scheduleSave();
    _notifyIfOpen();
  }

  void _syncCurrentProgress() {
    final engineId = _engineEntryId;
    if (engineId == null) return;
    final progressIndex = _queueIdToIndex[engineId] ?? -1;
    if (progressIndex < 0 || progressIndex >= _queue.length) return;
    final entry = _queue[progressIndex];
    var position = _playbackState.position;
    final floor = _resumeFloor;
    if (floor != null && _resumeEntryId == entry.id && position < floor) {
      position = floor;
    }
    _updateQueueProgress(
      progressIndex,
      position: position,
      duration: _playbackState.duration > Duration.zero
          ? _playbackState.duration
          : entry.duration,
    );
  }

  void _updateQueueSnapshotProgress(int updatedIndex, MediaEntry updated) {
    final currentEntry = _currentIndex >= 0 && _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : null;
    _queueSnapshot = _queueSnapshot.withUpdatedEntry(
      updatedIndex,
      updated,
      currentIndex: _currentIndex,
      currentId: currentEntry?.id,
    );
    if (!_notifierDisposed) queueListenable.value = _queueSnapshot;
  }

  void _recordHistory(MediaEntry entry, {required DateTime playedAt}) {
    final sourceId = MediaEntry.canonicalSource(entry.path);
    final index = _recent.indexWhere(
      (item) => MediaEntry.canonicalSource(item.path) == sourceId,
    );
    final historyEntry = entry.copyWith(id: sourceId, lastPlayed: playedAt);
    if (index >= 0) _recent.removeAt(index);
    _recent.insert(0, historyEntry);
    if (_recent.length > PlayerController._maximumRecentEntries) {
      _recent.removeRange(
        PlayerController._maximumRecentEntries,
        _recent.length,
      );
    }
    _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
    _rebuildRecentEntryIndices();
  }

  /// Removes an entry from recent history by [entry].
  ///
  /// Returns the index and the removed entry if found, or null otherwise.
  (int, MediaEntry)? removeRecent(MediaEntry entry) {
    if (!_acceptsCommands) return null;
    final canonical = MediaEntry.canonicalSource(entry.path);
    final index = _recent.indexWhere(
      (item) =>
          item.id == entry.id ||
          item.path == entry.path ||
          item.id == canonical ||
          MediaEntry.canonicalSource(item.path) == canonical,
    );
    if (index < 0) return null;
    final removed = _recent.removeAt(index);
    _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
    _rebuildRecentEntryIndices();
    _scheduleSave();
    _notifyIfOpen();
    return (index, removed);
  }

  /// Removes an entry from recent history by its [id] or canonical path.
  (int, MediaEntry)? removeRecentById(String id) {
    if (!_acceptsCommands) return null;
    final canonical = MediaEntry.canonicalSource(id);
    final index = _recent.indexWhere(
      (item) =>
          item.id == id ||
          item.path == id ||
          item.id == canonical ||
          MediaEntry.canonicalSource(item.path) == canonical,
    );
    if (index < 0) return null;
    final removed = _recent.removeAt(index);
    _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
    _rebuildRecentEntryIndices();
    _scheduleSave();
    _notifyIfOpen();
    return (index, removed);
  }

  /// Restores a previously removed recent entry at [index].
  void restoreRecent(int index, MediaEntry entry) {
    if (!_acceptsCommands) return;
    final targetIndex = index.clamp(0, _recent.length);
    _recent.removeWhere(
      (item) => item.id == entry.id || item.path == entry.path,
    );
    _recent.insert(targetIndex, entry);
    if (_recent.length > PlayerController._maximumRecentEntries) {
      _recent.removeRange(
        PlayerController._maximumRecentEntries,
        _recent.length,
      );
    }
    _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
    _rebuildRecentEntryIndices();
    _scheduleSave();
    _notifyIfOpen();
  }

  /// Clears all entries from the recently played history.
  List<MediaEntry> clearRecent() {
    if (!_acceptsCommands || _recent.isEmpty) return const <MediaEntry>[];
    final cleared = List<MediaEntry>.of(_recent);
    _recent.clear();
    _recentIndexById.clear();
    _unmodifiableRecent = const <MediaEntry>[];
    _scheduleSave();
    _notifyIfOpen();
    return cleared;
  }

  /// Restores a list of previously cleared recent entries.
  void restoreRecentList(List<MediaEntry> entries) {
    if (!_acceptsCommands || entries.isEmpty) return;
    _recent
      ..clear()
      ..addAll(_canonicalizeRecent(entries));
    _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
    _rebuildRecentEntryIndices();
    _scheduleSave();
    _notifyIfOpen();
  }

  List<MediaEntry> _canonicalizeRecent(List<MediaEntry> entries) {
    final result = <MediaEntry>[];
    final seen = <String>{};
    for (final entry in entries) {
      final id = MediaEntry.canonicalSource(entry.path);
      if (seen.add(id)) result.add(entry.copyWith(id: id));
      if (result.length == PlayerController._maximumRecentEntries) break;
    }
    return result;
  }

  /// Publishes a new immutable queue snapshot when structural contents changed.
  void _publishQueue() {
    _queueRevision++;
    _updateQueueSnapshotEntries();
  }

  void _rebuildRecentEntryIndices() {
    _recentIndexById
      ..clear()
      ..addEntries(
        _recent.indexed.map((pair) => MapEntry(pair.$2.id, pair.$1)),
      );
    for (var i = 0; i < _recent.length; i++) {
      final canonical = MediaEntry.canonicalSource(_recent[i].path);
      _recentIndexById.putIfAbsent(canonical, () => i);
    }
  }

  void _updateQueueSnapshotEntries() {
    final currentEntry = _currentIndex >= 0 && _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : null;
    _queueSnapshot = QueueSnapshot.publish(
      queue: _queue,
      revision: _queueRevision,
      currentIndex: _currentIndex,
      currentId: currentEntry?.id,
    );
    if (!_notifierDisposed) queueListenable.value = _queueSnapshot;
  }
}
