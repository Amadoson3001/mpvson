import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/repositories/session_repository.dart';
import '../../data/services/diagnostic_log.dart';
import '../../data/services/playback_service.dart';
import '../../data/services/thumbnail_service.dart';
import '../../domain/models/control_density.dart';
import '../../domain/models/media_entry.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_thumbnail.dart';
import '../../domain/models/playback_session.dart';
import '../../domain/models/playback_settings.dart';
import '../../domain/models/session_progress.dart';
import '../../domain/models/video_output_policy.dart';

export '../../data/services/thumbnail_service.dart'
    show ThumbnailPriority, ThumbnailRequestHandle;

/// Shutdown phase of the controller.
///
/// Explicit phases keep a shutdown consistent: queue and transport commands are
/// rejected from [saving] onwards, a failed save parks the controller in
/// [awaitingDecision] where a single prompt decides the outcome, and only
/// [cancelClose] returns it to [running].
enum ControllerClosingState {
  running,
  saving,
  awaitingDecision,
  releasing,
  closed,
}

/// Immutable queue contents with a structural revision.
///
/// The revision only changes when the queue contents or the current entry
/// change, so views can cache filtering and projections by revision instead of
/// rebuilding them for every playback tick.
class QueueSnapshot {
  QueueSnapshot({
    List<MediaEntry> entries = const <MediaEntry>[],
    int revision = 0,
    int currentIndex = -1,
    String? currentId,
  }) : this._(
         entries: _PersistentQueueEntries.from(entries),
         revision: revision,
         currentIndex: currentIndex,
         currentId: currentId,
       );

  QueueSnapshot._({
    required this.entries,
    required this.revision,
    required this.currentIndex,
    required this.currentId,
  });

  static final QueueSnapshot empty = QueueSnapshot();
  static const int _maximumCachedQueries = 8;
  static const int _maximumRetainedMatches = 20000;

  final List<MediaEntry> entries;
  final int revision;
  final int currentIndex;
  final String? currentId;

  final LinkedHashMap<String, List<int>> _matchingIndices =
      LinkedHashMap<String, List<int>>();
  final Map<String, List<MediaEntry>> _filterViewCache =
      <String, List<MediaEntry>>{};
  final Map<String, List<(int, MediaEntry)>> _indexedViewCache =
      <String, List<(int, MediaEntry)>>{};
  List<int>? _allIndices;
  int _filterIndexedCallCount = 0;

  int get length => entries.length;
  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  @visibleForTesting
  int get cachedQueryCount => _matchingIndices.length;

  @visibleForTesting
  int get filterIndexedCallCount => _filterIndexedCallCount;

  @visibleForTesting
  int get totalRetainedMatches {
    var total = 0;
    for (final indices in _matchingIndices.values) {
      total += indices.length;
    }
    return total;
  }

  MediaEntry? get current => currentIndex >= 0 && currentIndex < entries.length
      ? entries[currentIndex]
      : null;

  /// Returns cached filtered queue entries matching [query].
  List<MediaEntry> filter(String query) {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return entries;
    final cachedView = _filterViewCache[trimmed];
    if (cachedView != null) {
      _touchQuery(trimmed);
      return cachedView;
    }
    final indices = _indicesFor(trimmed);
    final view = _LazyFilteredEntriesView(entries, indices);
    // A query with more matches than the snapshot's retention budget is useful
    // to this caller, but must not survive in the snapshot's view cache after
    // its matching-index entry has been evicted.
    if (_matchingIndices.containsKey(trimmed)) {
      _filterViewCache[trimmed] = view;
    }
    return view;
  }

  /// Returns cached indexed entries `(originalIndex, entry)` matching [query].
  List<(int, MediaEntry)> filterIndexed(String query) {
    _filterIndexedCallCount++;
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) {
      return _indexedViewCache[''] ??= _LazyFilteredIndexedView(
        entries,
        _indicesFor(null),
      );
    }
    final cachedView = _indexedViewCache[trimmed];
    if (cachedView != null) {
      _touchQuery(trimmed);
      return cachedView;
    }
    final indices = _indicesFor(trimmed);
    final view = _LazyFilteredIndexedView(entries, indices);
    if (_matchingIndices.containsKey(trimmed)) {
      _indexedViewCache[trimmed] = view;
    }
    return view;
  }

  void _touchQuery(String query) {
    final cached = _matchingIndices.remove(query);
    if (cached != null) _matchingIndices[query] = cached;
  }

  List<int> _indicesFor(String? query) {
    if (query == null) {
      return _allIndices ??= _AllIndicesView(entries.length);
    }
    final cached = _matchingIndices.remove(query);
    if (cached != null) {
      _matchingIndices[query] = cached;
      return cached;
    }
    final result = <int>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (entry.title.toLowerCase().contains(query) ||
          entry.path.toLowerCase().contains(query)) {
        result.add(index);
      }
    }
    final unmodifiableResult = List<int>.unmodifiable(result);
    _matchingIndices[query] = unmodifiableResult;
    _evictIndicesIfNeeded();
    return unmodifiableResult;
  }

  void _evictIndicesIfNeeded() {
    while (_matchingIndices.length > _maximumCachedQueries) {
      final key = _matchingIndices.keys.first;
      _matchingIndices.remove(key);
      _filterViewCache.remove(key);
      _indexedViewCache.remove(key);
    }
    while (_matchingIndices.isNotEmpty &&
        _calculateTotalMatches() > _maximumRetainedMatches) {
      final key = _matchingIndices.keys.first;
      _matchingIndices.remove(key);
      _filterViewCache.remove(key);
      _indexedViewCache.remove(key);
    }
  }

  int _calculateTotalMatches() {
    var total = 0;
    for (final indices in _matchingIndices.values) {
      total += indices.length;
    }
    return total;
  }

  /// Returns a new snapshot reflecting updated entry progress without discarding
  /// the cached query matches, since titles and paths did not change.
  QueueSnapshot withUpdatedProgress(
    List<MediaEntry> newEntries, {
    int? currentIndex,
    String? currentId,
    bool clearCurrentId = false,
  }) {
    final next = QueueSnapshot._(
      entries: _PersistentQueueEntries.from(newEntries),
      revision: revision,
      currentIndex: currentIndex ?? this.currentIndex,
      currentId: clearCurrentId ? null : currentId ?? this.currentId,
    );
    // Progress updates preserve the searchable fields. Reuse matches only when
    // the caller kept the same queue shape; materialized entries always come
    // from this snapshot.
    if (newEntries.length == entries.length) {
      next._matchingIndices.addAll(_matchingIndices);
      next._filterIndexedCallCount = _filterIndexedCallCount;
    }
    return next;
  }

  /// Returns a new immutable progress view by replacing just one queue entry.
  ///
  /// The chunked backing list copies one small entry chunk and its chunk index,
  /// rather than rebuilding the full queue on every playback tick.
  QueueSnapshot withUpdatedEntry(
    int index,
    MediaEntry entry, {
    required int currentIndex,
    required String? currentId,
  }) {
    final persistent = entries is _PersistentQueueEntries
        ? entries as _PersistentQueueEntries
        : _PersistentQueueEntries.from(entries);
    final next = QueueSnapshot._(
      entries: persistent.withUpdatedEntry(index, entry),
      revision: revision,
      currentIndex: currentIndex,
      currentId: currentId,
    );
    next._matchingIndices.addAll(_matchingIndices);
    next._filterIndexedCallCount = _filterIndexedCallCount;
    return next;
  }

  @override
  String toString() =>
      'QueueSnapshot(${entries.length} entries, revision $revision)';
}

/// An immutable chunked list that can share all but one small chunk with its
/// predecessor. Queue progress snapshots use it to preserve captured metadata
/// without copying every queue row on every tick.
class _PersistentQueueEntries
    with ListMixin<MediaEntry>
    implements List<MediaEntry> {
  _PersistentQueueEntries._(this._chunks, this.length);

  factory _PersistentQueueEntries.from(List<MediaEntry> entries) {
    final chunks = <List<MediaEntry>>[];
    for (var start = 0; start < entries.length; start += _chunkSize) {
      final end = min(start + _chunkSize, entries.length);
      chunks.add(List<MediaEntry>.unmodifiable(entries.getRange(start, end)));
    }
    return _PersistentQueueEntries._(
      List<List<MediaEntry>>.unmodifiable(chunks),
      entries.length,
    );
  }

  static const int _chunkSize = 64;

  final List<List<MediaEntry>> _chunks;

  @override
  final int length;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');

  @override
  MediaEntry operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    return _chunks[index ~/ _chunkSize][index % _chunkSize];
  }

  @override
  void operator []=(int index, MediaEntry value) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');

  _PersistentQueueEntries withUpdatedEntry(int index, MediaEntry entry) {
    RangeError.checkValidIndex(index, this, 'index', length);
    final chunkIndex = index ~/ _chunkSize;
    final updatedChunk = List<MediaEntry>.of(_chunks[chunkIndex]);
    updatedChunk[index % _chunkSize] = entry;
    final updatedChunks = List<List<MediaEntry>>.of(_chunks);
    updatedChunks[chunkIndex] = List<MediaEntry>.unmodifiable(updatedChunk);
    return _PersistentQueueEntries._(
      List<List<MediaEntry>>.unmodifiable(updatedChunks),
      length,
    );
  }
}

class _AllIndicesView with ListMixin<int> implements List<int> {
  const _AllIndicesView(this.length);

  @override
  final int length;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    return index;
  }

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');
}

class _LazyFilteredEntriesView
    with ListMixin<MediaEntry>
    implements List<MediaEntry> {
  const _LazyFilteredEntriesView(this._entries, this._indices);

  final List<MediaEntry> _entries;
  final List<int> _indices;

  @override
  int get length => _indices.length;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');

  @override
  MediaEntry operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _indices.length);
    return _entries[_indices[index]];
  }

  @override
  void operator []=(int index, MediaEntry value) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');
}

class _LazyFilteredIndexedView
    with ListMixin<(int, MediaEntry)>
    implements List<(int, MediaEntry)> {
  const _LazyFilteredIndexedView(this._entries, this._indices);

  final List<MediaEntry> _entries;
  final List<int> _indices;

  @override
  int get length => _indices.length;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');

  @override
  (int, MediaEntry) operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _indices.length);
    final originalIndex = _indices[index];
    return (originalIndex, _entries[originalIndex]);
  }

  @override
  void operator []=(int index, (int, MediaEntry) value) =>
      throw UnsupportedError('Cannot modify an unmodifiable list');
}

/// Transport state of the current source, separate from the queue.
class TransportState {
  const TransportState({
    this.isPlaying = false,
    this.isBuffering = false,
    this.isLoading = false,
    this.hasMedia = false,
    this.completed = false,
    this.error,
  });

  static const TransportState idle = TransportState();

  final bool isPlaying;
  final bool isBuffering;
  final bool isLoading;
  final bool hasMedia;
  final bool completed;
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is TransportState &&
      other.isPlaying == isPlaying &&
      other.isBuffering == isBuffering &&
      other.isLoading == isLoading &&
      other.hasMedia == hasMedia &&
      other.completed == completed &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    isPlaying,
    isBuffering,
    isLoading,
    hasMedia,
    completed,
    error,
  );
}

/// Owns the queue, history, session state and playback commands for the UI.
class PlayerController extends ChangeNotifier {
  static const int _maximumNavigationHistory = 10000;
  PlayerController({
    required PlaybackService playback,
    required SessionRepository sessions,
    ThumbnailService? thumbnails,
    DiagnosticSink? diagnostics,
  }) {
    _playback = playback;
    _sessions = sessions;
    _thumbnails = thumbnails;
    _diagnostics = diagnostics;
    final initial = _playback.state;
    _applySnapshot(initial, notify: false);
    _confirmedVolume = _normalizeVolume(initial.volume);
    if (_confirmedVolume > 0) _lastAudibleVolume = _confirmedVolume;
    _stateSubscription = _playback.states.listen(
      _handleSnapshot,
      onError: (Object error) => _setError(error.toString()),
    );
    _publishQueue();
    _publishTransport();
  }

  static const int _maximumRecentEntries = 100;
  static const Duration _saveDelay = Duration(seconds: 2);
  static const Duration _progressCheckpointInterval = Duration(seconds: 2);
  static const Duration _resumeFloorGrace = Duration(seconds: 10);

  /// How long a load attempt may stay unresolved before it reports a timeout.
  static const Duration _loadTimeout = Duration(seconds: 45);

  late final PlaybackService _playback;
  late final SessionRepository _sessions;
  late final ThumbnailService? _thumbnails;
  late final DiagnosticSink? _diagnostics;
  final Random _random = Random();
  final List<MediaEntry> _queue = <MediaEntry>[];
  final List<MediaEntry> _recent = <MediaEntry>[];
  StreamSubscription<PlaybackSnapshot>? _stateSubscription;
  Timer? _saveTimer;
  Timer? _progressTimer;
  Timer? _loadTimer;
  Timer? _resumeFloorTimer;
  PlaybackSnapshot _playbackState = const PlaybackSnapshot();
  _QueueUndo? _undo;
  _PendingOpen? _pendingOpen;
  Completer<void>? _pendingDecision;
  int _currentIndex = -1;
  int _queueIdCounter = 0;
  int _queueRevision = 0;
  int _queueStructureRevision = 0;
  int _importOperation = 0;
  int _transportCommandRevision = 0;
  int _progressRevision = 0;
  int _operation = 0;
  int _activeSourceStart = 0;

  /// Highest load attempt that provably describes a displaced source.
  ///
  /// Engine boundaries only increase, so any event at or below this value
  /// belongs to a source the view model has already moved on from and must be
  /// dropped instead of being attributed to the attempt that followed.
  int _displacedSourceStart = 0;
  Duration? _resumeFloor;
  String? _resumeEntryId;
  bool _resumeSeekStarted = false;
  int _resumeGeneration = 0;
  bool _engineHasMedia = false;
  String? _engineEntryId;
  ControllerClosingState _closingState = ControllerClosingState.running;
  Future<void>? _closeFuture;
  Future<void>? _releaseFuture;
  bool _discardOnClose = false;
  bool _initializing = false;
  bool _initialized = false;
  bool _completionHandled = false;
  bool _notifierDisposed = false;
  bool _saveInFlight = false;
  bool _saveRequested = false;
  Completer<void>? _saveDrain;
  bool _checkpointInFlight = false;
  bool _checkpointRequested = false;
  Completer<void>? _checkpointDrain;
  bool _saveNetworkUrls = false;
  String _repeatMode = 'off';
  String _confirmedRepeatMode = 'off';
  bool _shuffleEnabled = false;
  bool _confirmedShuffle = false;
  int _queuePreferenceSequence = 0;
  int _shufflePreferenceRevision = 0;
  int _appliedShufflePreferenceRevision = 0;
  int _shufflePreferenceSequence = 0;
  int _repeatPreferenceRevision = 0;
  int _appliedRepeatPreferenceRevision = 0;
  int _repeatPreferenceSequence = 0;
  Future<void>? _queuePreferenceDrain;
  ControlDensity _controlDensity = ControlDensity.compact;
  PlaybackSettings _playbackSettings = PlaybackSettings.defaults;
  String? _playbackSettingsError;
  int _playbackSettingsApplyRevision = 0;
  final List<String> _navigationHistory = <String>[];
  int _navigationCursor = -1;
  int? _pendingNavigationCursor;
  String? _pendingNavigationEntryId;
  final List<String> _shuffleRemaining = <String>[];
  final Set<String> _shuffleVisited = <String>{};
  String? _error;
  double? _desiredVolume;
  double _confirmedVolume = 100;
  double _lastAudibleVolume = 100;
  int _volumeRevision = 0;
  int _appliedVolumeRevision = 0;
  Completer<void>? _volumeDrain;
  QueueSnapshot _queueSnapshot = QueueSnapshot.empty;

  /// Position updates, delivered independently of queue and transport changes.
  final ValueNotifier<Duration> positionListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// Duration updates, delivered independently of queue changes.
  final ValueNotifier<Duration> durationListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// Buffering updates, delivered independently of queue changes.
  final ValueNotifier<bool> bufferingListenable = ValueNotifier<bool>(false);

  /// The queue contents and their structural revision.
  final ValueNotifier<QueueSnapshot> queueListenable =
      ValueNotifier<QueueSnapshot>(QueueSnapshot.empty);

  /// Transport state of the current source.
  final ValueNotifier<TransportState> transportListenable =
      ValueNotifier<TransportState>(TransportState.idle);

  Player get player => _playback.player;
  VideoController get videoController => _playback.videoController;
  VideoOutputPolicy get videoOutputPolicy => _playback.videoOutputPolicy;
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    _playback.applyVideoOutputPolicy(policy);
  }

  /// Read-only queue view, rebuilt only when its structure changes.
  List<MediaEntry> _snapshotQueue = <MediaEntry>[];
  List<MediaEntry> _unmodifiableQueue = const <MediaEntry>[];
  List<MediaEntry> get queue => _unmodifiableQueue;
  List<MediaEntry> _unmodifiableRecent = const <MediaEntry>[];
  List<MediaEntry> get recent => _unmodifiableRecent;
  QueueSnapshot get queueSnapshot => _queueSnapshot;
  int get queueRevision => _queueSnapshot.revision;
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

  /// Cached filtered queue matching [query] for the current [queueRevision].
  List<MediaEntry> filterQueue(String query) => _queueSnapshot.filter(query);
  List<MediaEntry> filteredQueue(String query) => _queueSnapshot.filter(query);

  /// Cached indexed queue entries `(originalIndex, entry)` matching [query].
  List<(int, MediaEntry)> filterQueueIndexed(String query) =>
      _queueSnapshot.filterIndexed(query);
  List<(int, MediaEntry)> filteredQueueIndexed(String query) =>
      _queueSnapshot.filterIndexed(query);

  /// Whether the native engine currently has a source loaded.
  ///
  /// A restored queue can have a [current] entry while remaining stopped, so
  /// views should use this instead of inferring media presence from the queue.
  bool get hasMedia => _engineHasMedia;

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
  double get volume => _desiredVolume ?? _playbackState.volume;
  double get rate => _playbackState.rate;
  String? get error => _error;
  bool get shuffle => _shuffleEnabled;
  String get repeatMode => _repeatMode;
  ControlDensity get controlDensity => _controlDensity;
  PlaybackSettings get playbackSettings => _playbackSettings;
  String? get playbackSettingsError => _playbackSettingsError;
  bool get canUndo => _undo != null;
  List<AudioTrack> get audioTracks => _playbackState.audioTracks;
  List<SubtitleTrack> get subtitleTracks => _playbackState.subtitleTracks;
  AudioTrack get currentAudioTrack => _playbackState.currentAudioTrack;
  SubtitleTrack get currentSubtitleTrack => _playbackState.currentSubtitleTrack;
  String get engineVersion => _playback.engineVersion;

  /// Shutdown phase, so controls can reflect a saving or blocked shutdown.
  ControllerClosingState get closingState => _closingState;
  bool get isClosing => _closingState != ControllerClosingState.running;

  /// Whether stream URLs are written to local session files. Off by default.
  bool get saveNetworkUrls => _saveNetworkUrls;

  TransportState get transport => transportListenable.value;

  /// Thumbnail extraction and caching service, if configured.
  ThumbnailService? get thumbnails => _thumbnails;

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

  /// Loads saved queue/history without opening or playing the last source.
  Future<void> initialize() async {
    if (_initialized || _initializing || !_acceptsCommands) return;
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
      if (loaded != null) {
        _queueStructureRevision++;
        final scrubbed = loaded.saveNetworkUrls
            ? loaded
            : loaded.withoutNetworkUrls();
        if (!loaded.saveNetworkUrls && loaded.hasNetworkEntries) {
          migrate = true;
        }
        if (_queue.isEmpty) {
          _queue
            ..clear()
            ..addAll(scrubbed.queue);
          _currentIndex = scrubbed.currentIndex;
        }
        _recent
          ..clear()
          ..addAll(_canonicalizeRecent(scrubbed.recent));
        _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
        if (_queue.isNotEmpty) {
          _currentIndex = scrubbed.currentIndex;
        }
        _repeatMode = scrubbed.repeatMode;
        _shuffleEnabled = scrubbed.shuffle;
        _controlDensity = scrubbed.controlDensity;
        _playbackSettings = scrubbed.playbackSettings.normalized();
        _saveNetworkUrls = scrubbed.saveNetworkUrls;
        _progressRevision = scrubbed.progressRevision;
        // The queue snapshot still describes the previous session here, so the
        // restored row must be read directly instead of through `current`.
        MediaEntry? restoredCurrent;
        if (_currentIndex >= 0 && _currentIndex < _queue.length) {
          restoredCurrent = _queue[_currentIndex];
        }
        _playbackState = _playbackState.copyWith(
          volume: scrubbed.volume,
          rate: scrubbed.rate,
          shuffle: scrubbed.shuffle,
          isPlaying: false,
          isBuffering: false,
          position: restoredCurrent?.position ?? Duration.zero,
          duration: restoredCurrent?.duration ?? Duration.zero,
          completed: false,
          clearNativeSource: true,
          sourceLoaded: false,
        );
        _lastAudibleVolume = scrubbed.volume > 0
            ? _normalizeVolume(scrubbed.volume)
            : 100;
      }

      // A checkpoint written after the last full save is newer than the session
      // and wins; an older or unusable checkpoint is ignored. Read it even when
      // recovery rejects the primary so URL-shaped ids can still be scrubbed.
      final checkpoint = await _sessions.loadProgress();
      if (loaded == null || !result.primaryRejected) {
        await _applyProgressCheckpoint(
          checkpoint,
          sessionRevision: loaded?.progressRevision ?? 0,
        );
      }
      if (result.note != null) {
        _diagnostics?.record('session.load', message: result.note);
      }

      // Publish the restored queue before applying engine settings: the volume,
      // rate and shuffle writes can emit snapshots immediately, and those
      // snapshots must see the restored row so they cannot reset its saved
      // position to zero.
      _publishQueue();
      // These values are independent of a loaded source, so applying them here
      // restores the user's settings while leaving the queue stopped.
      await Future.wait<void>([
        setVolume(volume, scheduleSave: false),
        _ignorePlaybackFailure(() => _playback.setRate(rate)),
        () async {
          try {
            await _playback.setShuffle(shuffle);
            _confirmedShuffle = shuffle;
          } on Object {
            _confirmedShuffle = _playback.state.shuffle;
          }
        }(),
        () async {
          try {
            await _playback.setRepeatMode(_repeatMode);
            _confirmedRepeatMode = _repeatMode;
          } on Object {
            // Keep the previous confirmed mode so a failed change can roll back.
          }
        }(),
      ]);
      if (loaded != null && _currentIndex >= 0) {
        _navigationHistory
          ..clear()
          ..add(_queue[_currentIndex].id);
        _navigationCursor = 0;
        if (shuffle) _resetShuffleCycle();
      }
      unawaited(_applyPlaybackSettings(_playbackSettings));
      _publishTransport();
      _notifyIfOpen();

      if (migrate) {
        // A migrated session without consent may still have a stream progress
        // checkpoint. Scrub it and the recovery copy before initialization
        // returns, then persist the normalized in-memory session.
        if (loaded?.saveNetworkUrls != true) {
          await _sessions.scrubNetworkUrls();
        }
        await _runCoalescedSave(scrubBackup: true);
      } else if (loaded?.saveNetworkUrls != true &&
          _checkpointNeedsUrlScrub(checkpoint, loaded)) {
        // A clean queue can still have an old URL-shaped checkpoint id from a
        // previous release. Remove it once without rewriting valid local
        // checkpoints on every launch.
        await _sessions.scrubNetworkUrls();
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
    final queueIndex = _queue.indexWhere((entry) => entry.id == id);
    if (queueIndex >= 0) {
      _queue[queueIndex] = _queue[queueIndex].copyWith(
        position: checkpoint.position,
        duration: checkpoint.duration > Duration.zero
            ? checkpoint.duration
            : _queue[queueIndex].duration,
      );
      applied = true;
    }
    final recentIndex = _recent.indexWhere((entry) => entry.id == id);
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
      repeatMode: _repeatMode,
      controlDensity: _controlDensity,
      playbackSettings: _playbackSettings,
      saveNetworkUrls: _saveNetworkUrls,
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
    _notifyIfOpen();
    if (!value) {
      try {
        _recent.removeWhere((entry) => MediaEntry.isNetworkUrl(entry.path));
        _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
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

  /// Closes without saving, used by the "Close without saving" prompt action.
  Future<void> discardClose() => close(discard: true, force: true);

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
      await _volumeDrain?.future;
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
      await _playback.dispose();
    } on Object {
      // Teardown should not prevent the native window from closing.
    }
    _closingState = ControllerClosingState.closed;
    _disposeNotifier();
  }

  Future<void> openPaths(List<String> paths, {bool append = false}) async {
    if (!_acceptsCommands) return;
    final importOperation = ++_importOperation;
    final playbackOperation = _operation;
    final transportRevision = _transportCommandRevision;
    final structureRevision = _queueStructureRevision;
    final sourcePaths = List<String>.of(paths);
    final stagedEntries = <MediaEntry>[];
    String? firstRejected;

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
        final recentEntry = _findRecent(source);
        final entry = MediaEntry.fromPath(source, id: _newQueueId(source));
        stagedEntries.add(
          recentEntry == null
              ? entry
              : entry.copyWith(
                  position: recentEntry.position,
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
    final firstNewIndex = append ? _queue.length : 0;
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
      _queue
        ..clear()
        ..addAll(stagedEntries);
      _queueStructureRevision++;
      _currentIndex = -1;
      _engineHasMedia = false;
      _engineEntryId = null;
      _clearResume();
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
    } else {
      _queue.addAll(stagedEntries);
      _queueStructureRevision++;
    }
    if (shuffle) _prepareShuffleRemaining();
    if (firstRejected != null) {
      _diagnostics?.record(
        'source.rejected',
        message: firstRejected,
        sourceId: sourcePaths.isEmpty ? null : sourcePaths.first,
      );
    }
    _error = null;

    if (!append || _currentIndex < 0) {
      await playIndex(firstNewIndex);
    } else {
      _publishQueue();
      _scheduleSave();
      _notifyIfOpen();
    }
  }

  Future<void> playIndex(int index) => _openIndex(index);

  Future<void> _openIndex(int index, {int? navigationCursor}) async {
    if (!_acceptsCommands || index < 0 || index >= _queue.length) return;
    _syncCurrentProgress();
    final operation = ++_operation;
    final entry = _queue[index];
    _pendingNavigationEntryId = entry.id;
    _pendingNavigationCursor = navigationCursor;
    _currentIndex = index;
    _clearResume();
    _completionHandled = false;
    _markSourceDisplaced();
    _engineHasMedia = false;
    _engineEntryId = null;
    _error = null;
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

    final pending = _PendingOpen(
      operation: operation,
      entryId: entry.id,
      source: entry.path,
    );
    _pendingOpen = pending;
    _armLoadTimeout(pending);
    _publishTransport();

    try {
      await _playback.open(entry.path, play: true);
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
    _undo = _QueueUndo(
      entry: removedEntry,
      index: index,
      previousCurrentId: oldCurrentId,
      wasPlaying: wasActive,
      displacedActiveSource: displacedActiveSource,
      displacedCurrent: removedCurrent,
    );
    _queueStructureRevision++;
    _queue.removeAt(index);
    _removeNavigationEntry(removedEntry.id);
    _publishQueue();

    if (_queue.isEmpty) {
      _cancelPendingOpen(reason: 'queue emptied');
      _markSourceDisplaced();
      _currentIndex = -1;
      _clearResume();
      _engineHasMedia = false;
      _engineEntryId = null;
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

  /// Uses Flutter's ReorderableListView destination-index semantics.
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (!_acceptsCommands ||
        oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex > _queue.length) {
      return;
    }
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;
    _undo = null;
    final currentId = current?.id;
    _queueStructureRevision++;
    final entry = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, entry);
    _currentIndex = currentId == null
        ? -1
        : _queue.indexWhere((item) => item.id == currentId);
    _publishQueue();
    _scheduleSave();
    _notifyIfOpen();
  }

  Future<void> undoRemove() async {
    final undo = _undo;
    if (!_acceptsCommands || undo == null) return;
    _queueStructureRevision++;
    final insertIndex = undo.index.clamp(0, _queue.length);
    _queue.insert(insertIndex, undo.entry);
    if (shuffle) _prepareShuffleRemaining();
    final restoredIndex = undo.previousCurrentId == null
        ? -1
        : _queue.indexWhere((entry) => entry.id == undo.previousCurrentId);
    _currentIndex = restoredIndex >= 0
        ? restoredIndex
        : (insertIndex <= _currentIndex ? _currentIndex + 1 : _currentIndex);
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
    _publishQueue();
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
    _operation++;
    _queueStructureRevision++;
    _importOperation++;
    _cancelPendingOpen(reason: 'queue cleared');
    _markSourceDisplaced();
    _queue.clear();
    _navigationHistory.clear();
    _navigationCursor = -1;
    _pendingNavigationEntryId = null;
    _pendingNavigationCursor = null;
    _shuffleRemaining.clear();
    _shuffleVisited.clear();
    _currentIndex = -1;
    _undo = null;
    _clearResume();
    _engineHasMedia = false;
    _engineEntryId = null;
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
      await playIndex(_currentIndex);
    } else {
      await _runPlaybackCommand(_playback.play);
    }
  }

  Future<void> seek(Duration position) async {
    if (!_acceptsCommands) return;
    _transportCommandRevision++;
    if (current == null) return;
    final target = _clampPosition(position, duration);
    if (!_engineHasMedia) {
      // A restored, stopped item has no engine position to change, so the saved
      // progress is updated directly and survives the next launch.
      _playbackState = _playbackState.copyWith(position: target);
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
      _playbackState = _playbackState.copyWith(position: target);
      _syncCurrentProgress();
      _notifyIfOpen();
      _scheduleSave();
    } on Object catch (exception) {
      _setError('Could not seek: $exception');
    }
  }

  Future<void> seekRelative(Duration delta) => seek(position + delta);

  Future<void> setVolume(double value, {bool scheduleSave = true}) async {
    if (!_acceptsCommands) return;
    final target = _normalizeVolume(value);
    final previous = volume;
    if (target > 0) {
      _lastAudibleVolume = target;
    } else if (previous > 0) {
      _lastAudibleVolume = previous;
    }
    _desiredVolume = target;
    _volumeRevision++;
    if (scheduleSave) _scheduleSave();
    final pendingWrite = _drainVolumeWrites();
    _notifyIfOpen();
    await pendingWrite;
  }

  /// Changes volume relative to the latest requested value, even while a
  /// native volume write is still in flight.
  Future<void> adjustVolume(double delta) => setVolume(volume + delta);

  /// Toggles mute and restores the last audible volume when unmuting.
  Future<void> toggleMute() => setVolume(volume > 0 ? 0 : _lastAudibleVolume);

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

  static double _normalizeVolume(double value) =>
      value.isNaN ? 0 : value.clamp(0.0, 100.0).toDouble();

  Future<void> setRate(double value) async {
    if (!_acceptsCommands) return;
    _transportCommandRevision++;
    final target = value.clamp(0.25, 4.0).toDouble();
    try {
      await _playback.setRate(target);
      _playbackState = _playbackState.copyWith(rate: target);
      _scheduleSave();
      _notifyIfOpen();
    } on Object catch (exception) {
      _setError('Could not set playback speed: $exception');
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
      final index = _queue.indexWhere(
        (entry) => entry.id == _navigationHistory[nextHistoryCursor],
      );
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
    if (position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final previousHistoryCursor = _findHistoryCursor(
      _navigationCursor - 1,
      step: -1,
    );
    if (previousHistoryCursor >= 0) {
      final index = _queue.indexWhere(
        (entry) => entry.id == _navigationHistory[previousHistoryCursor],
      );
      if (index >= 0) {
        await _openIndex(index, navigationCursor: previousHistoryCursor);
        return;
      }
    }
    if (_repeatMode == 'all' && !shuffle) {
      await playIndex((_currentIndex - 1 + _queue.length) % _queue.length);
      return;
    }
    await seek(Duration.zero);
  }

  Future<void> toggleShuffle() {
    if (!_acceptsCommands) return Future<void>.value();
    _transportCommandRevision++;
    final target = !shuffle;
    _setShuffleIntent(target);
    _shufflePreferenceRevision++;
    _shufflePreferenceSequence = ++_queuePreferenceSequence;
    _scheduleSave();
    _notifyIfOpen();
    return _drainQueuePreferences();
  }

  Future<void> cycleRepeat() {
    if (!_acceptsCommands) return Future<void>.value();
    _transportCommandRevision++;
    final nextMode = switch (_repeatMode) {
      'off' => 'all',
      'all' => 'one',
      _ => 'off',
    };
    _repeatMode = nextMode;
    _repeatPreferenceRevision++;
    _repeatPreferenceSequence = ++_queuePreferenceSequence;
    _scheduleSave();
    _notifyIfOpen();
    return _drainQueuePreferences();
  }

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
          _setError('Could not change shuffle: $exception');
          continue;
        }
        if (!_acceptsCommands) return;
        _confirmedShuffle = target;
        _appliedShufflePreferenceRevision = revision;
        continue;
      }

      final revision = _repeatPreferenceRevision;
      final target = _repeatMode;
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
        _setError('Could not change repeat mode: $exception');
        continue;
      }
      if (!_acceptsCommands) return;
      _confirmedRepeatMode = target;
      _appliedRepeatPreferenceRevision = revision;
    }
  }

  /// Changes the player's control density and schedules the session update.
  void setControlDensity(ControlDensity value) {
    if (!_acceptsCommands || _controlDensity == value) return;
    _controlDensity = value;
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
    try {
      await _playback.setAudioTrack(track);
      _playbackState = _playbackState.copyWith(currentAudioTrack: track);
      _notifyIfOpen();
    } on Object catch (exception) {
      _setError('Could not change audio track: $exception');
    }
  }

  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    try {
      await _playback.setSubtitleTrack(track);
      _playbackState = _playbackState.copyWith(currentSubtitleTrack: track);
      _notifyIfOpen();
    } on Object catch (exception) {
      _setError('Could not change subtitles: $exception');
    }
  }

  Future<void> loadSubtitle(String path) async {
    if (!_acceptsCommands) return;
    final localPath = _localPath(path);
    if (localPath != null && !await File(localPath).exists()) {
      _setError('Subtitle file not found: $path');
      return;
    }
    try {
      await _playback.loadSubtitle(path);
      _notifyIfOpen();
    } on Object catch (exception) {
      _setError('Could not load subtitles: $exception');
    }
  }

  @override
  void dispose() {
    // The shutdown path may already have released the notifiers; disposing a
    // second time must not double-dispose them or the change notifier.
    if (_notifierDisposed) return;
    if (!_isClosing) {
      _closingState = ControllerClosingState.closed;
      _operation++;
      _saveTimer?.cancel();
      _saveTimer = null;
      _progressTimer?.cancel();
      _progressTimer = null;
      _loadTimer?.cancel();
      _loadTimer = null;
      _resumeFloorTimer?.cancel();
      _resumeFloorTimer = null;
      _pendingOpen = null;
      unawaited(_cancelAndDisposePlayback());
    }
    _disposeNotifier();
    super.dispose();
  }

  /// Releases the internal listenables exactly once.
  ///
  /// Kept separate from [dispose] because a shutdown that reached the closed
  /// phase releases them before the widget tree is torn down.
  void _disposeNotifier() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    positionListenable.dispose();
    durationListenable.dispose();
    bufferingListenable.dispose();
    queueListenable.dispose();
    transportListenable.dispose();
  }

  Future<void> _advance({required bool fromCompletion}) async {
    if (_queue.isEmpty || _currentIndex < 0) return;
    if (fromCompletion && _repeatMode == 'one') {
      await playIndex(_currentIndex);
      return;
    }
    final historyCursor = _findHistoryCursor(_navigationCursor + 1, step: 1);
    if (historyCursor >= 0) {
      final historyIndex = _queue.indexWhere(
        (entry) => entry.id == _navigationHistory[historyCursor],
      );
      if (historyIndex >= 0) {
        await _openIndex(historyIndex, navigationCursor: historyCursor);
        return;
      }
    }

    final nextIndex = shuffle ? _takeShuffleNextIndex() : _currentIndex + 1;
    if (nextIndex == null) {
      await _stopAfterQueue();
      return;
    }
    if (nextIndex >= _queue.length) {
      if (_repeatMode == 'all') {
        await playIndex(0);
        return;
      } else {
        await _stopAfterQueue();
        return;
      }
    }
    await playIndex(nextIndex);
  }

  int? _takeShuffleNextIndex() {
    if (_queue.isEmpty) return null;
    _prepareShuffleRemaining();
    if (_shuffleRemaining.isEmpty) {
      if (_repeatMode != 'all') return null;
      _shuffleVisited.clear();
      final currentId = _currentQueueId;
      if (currentId != null) _shuffleVisited.add(currentId);
      _shuffleRemaining
        ..clear()
        ..addAll(_queue.map((entry) => entry.id).where((id) => id != currentId))
        ..shuffle(_random);
      if (_shuffleRemaining.isEmpty && currentId != null) {
        return _queue.indexWhere((entry) => entry.id == currentId);
      }
    }
    if (_shuffleRemaining.isEmpty) return null;
    final nextId = _shuffleRemaining.removeLast();
    return _queue.indexWhere((entry) => entry.id == nextId);
  }

  void _prepareShuffleRemaining() {
    final currentId = _currentQueueId;
    final queueIds = _queue.map((entry) => entry.id).toSet();
    _shuffleRemaining.removeWhere(
      (id) =>
          !queueIds.contains(id) ||
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

  void _resetShuffleCycle() {
    _shuffleVisited.clear();
    final currentId = _currentQueueId;
    if (currentId != null) _shuffleVisited.add(currentId);
    _shuffleRemaining
      ..clear()
      ..addAll(_queue.map((entry) => entry.id).where((id) => id != currentId))
      ..shuffle(_random);
  }

  Future<void> _stopAfterQueue() async {
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
      if (_queue.any((entry) => entry.id == id)) return cursor;
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
      if (_navigationHistory.length > _maximumNavigationHistory) {
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

  void _clearPendingNavigation(String entryId) {
    if (_pendingNavigationEntryId != entryId) return;
    _pendingNavigationEntryId = null;
    _pendingNavigationCursor = null;
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

    final oldPosition = _playbackState.position;
    final oldPlaying = _playbackState.isPlaying;
    final oldBuffering = _playbackState.isBuffering;
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

    snapshot = _applyResumeFloor(snapshot);
    _applySnapshot(snapshot, notify: false);
    if (oldDuration != _playbackState.duration && _engineHasMedia) {
      // Duration is queue metadata and should refresh queue rows once when the
      // engine resolves it; ordinary position ticks stay on the timeline path.
      _syncCurrentProgress();
    }
    if (_desiredVolume == null) {
      _confirmedVolume = _normalizeVolume(snapshot.volume);
      if (_confirmedVolume > 0) _lastAudibleVolume = _confirmedVolume;
    }

    if (snapshot.error != null && snapshot.error!.isNotEmpty) {
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
    if (snapshot.completed && !wasCompleted && !_completionHandled) {
      _completionHandled = true;
      unawaited(_advance(fromCompletion: true));
    }

    final changed =
        oldPlaying != isPlaying ||
        oldBuffering != isBuffering ||
        oldDuration != duration ||
        oldVolume != volume ||
        oldRate != rate ||
        oldShuffle != shuffle ||
        oldTracks != audioTracks ||
        oldSubtitles != subtitleTracks ||
        oldAudio != currentAudioTrack ||
        oldSubtitle != currentSubtitleTrack ||
        oldError != _error ||
        snapshot.completed != wasCompleted;

    if (oldPosition != position) {
      positionListenable.value = position;
    }
    if (oldDuration != duration) {
      durationListenable.value = duration;
    }
    if (oldBuffering != isBuffering) {
      bufferingListenable.value = isBuffering;
    }

    if (changed) {
      _publishTransport();
      _notifyIfOpen();
    }

    _updateProgressTimer();
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
    if (changed) _notifyIfOpen();
  }

  bool _isCurrentOpen(_PendingOpen pending) =>
      _acceptsCommands && identical(_pendingOpen, pending);

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

  /// Whether an engine source identity describes [source].
  ///
  /// A snapshot without an identity carries no contradicting evidence, so it is
  /// attributed to the requested source, which keeps platforms without native
  /// property observation behaving as before.
  bool _isSourceOf(String? nativeSource, String source) =>
      nativeSource == null ||
      nativeSource == MediaEntry.canonicalSource(source);

  /// Marks the attached source as displaced so its late events are dropped.
  void _markSourceDisplaced() {
    if (_activeSourceStart > _displacedSourceStart) {
      _displacedSourceStart = _activeSourceStart;
    }
  }

  void _armLoadTimeout(_PendingOpen pending) {
    _loadTimer?.cancel();
    _loadTimer = Timer(_loadTimeout, () {
      if (!identical(_pendingOpen, pending) || !_acceptsCommands) return;
      _failPendingOpen(
        pending,
        'Timed out waiting for ${_titleForEntry(pending.entryId)} to load',
      );
    });
  }

  void _finishPendingOpen() {
    _pendingOpen = null;
    _loadTimer?.cancel();
    _loadTimer = null;
    _publishTransport();
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
    _finishPendingOpen();
    _engineHasMedia = true;
    _engineEntryId = entryId;
    _activeSourceStart = boundary;
    _diagnostics?.record(
      'playback.attached',
      sourceId: entry.path,
      message:
          'boundary $boundary, duration ${duration.inMilliseconds} ms, '
          'resume ${entry.position.inMilliseconds} ms',
    );
    final saved = entry.position;
    _playbackState = _playbackState.copyWith(
      isPlaying: _playback.state.isPlaying,
      isBuffering: false,
      position: saved,
      duration: duration > Duration.zero ? duration : entry.duration,
      completed: false,
      clearError: true,
    );
    if (saved > Duration.zero) {
      _resumeFloor = saved;
      _resumeEntryId = entryId;
      _resumeSeekStarted = false;
      _resumeFloorTimer?.cancel();
      _resumeFloorTimer = Timer(_resumeFloorGrace, _clearResumeFloor);
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
        : _clampPosition(target, end);
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

  void _applySnapshot(PlaybackSnapshot snapshot, {bool notify = false}) {
    _playbackState = snapshot;
    if (snapshot.error != null && snapshot.error!.isNotEmpty) {
      _error = snapshot.error;
    }
    if (notify) _notifyIfOpen();
  }

  void _syncCurrentProgress() {
    if (!_engineHasMedia && _engineEntryId == null) return;
    final progressIndex = _engineEntryId == null
        ? _currentIndex
        : _queue.indexWhere((entry) => entry.id == _engineEntryId);
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
    if (index < _snapshotQueue.length) _snapshotQueue[index] = updated;
    final recentIndex = _recent.indexWhere(
      (item) =>
          MediaEntry.canonicalSource(item.path) ==
          MediaEntry.canonicalSource(updated.path),
    );
    if (recentIndex >= 0) {
      _recent[recentIndex] = _recent[recentIndex].copyWith(
        position: updated.position,
        duration: updated.duration,
      );
      _unmodifiableRecent = UnmodifiableListView<MediaEntry>(_recent);
    }
    _updateQueueSnapshotProgress(index, updated);
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
    if (_recent.length > _maximumRecentEntries) {
      _recent.removeRange(_maximumRecentEntries, _recent.length);
    }
    _unmodifiableRecent = List<MediaEntry>.unmodifiable(_recent);
  }

  List<MediaEntry> _canonicalizeRecent(List<MediaEntry> entries) {
    final result = <MediaEntry>[];
    final seen = <String>{};
    for (final entry in entries) {
      final id = MediaEntry.canonicalSource(entry.path);
      if (seen.add(id)) result.add(entry.copyWith(id: id));
      if (result.length == _maximumRecentEntries) break;
    }
    return result;
  }

  MediaEntry? _findRecent(String source) {
    final sourceId = MediaEntry.canonicalSource(source);
    for (final entry in _recent) {
      if (MediaEntry.canonicalSource(entry.path) == sourceId) return entry;
    }
    return null;
  }

  MediaEntry? _entryById(String id) {
    for (final entry in _queue) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  String _sourceForEntry(String id) => _entryById(id)?.path ?? '';

  String _titleForEntry(String id) =>
      _entryById(id)?.title ?? 'the selected source';

  String _newQueueId(String source) {
    _queueIdCounter++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return '$timestamp-$_queueIdCounter-${MediaEntry.canonicalSource(source).hashCode}';
  }

  String? _localPath(String source) {
    final trimmed = source.trim();
    if (MediaEntry.isNetworkUrl(trimmed)) {
      return null;
    }
    return MediaEntry.normalizeSourcePath(trimmed);
  }

  /// Publishes a new immutable queue snapshot when structural contents changed.
  void _publishQueue() {
    _queueRevision++;
    _updateQueueSnapshotEntries();
  }

  void _updateQueueSnapshotEntries() {
    final currentEntry = _currentIndex >= 0 && _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : null;
    _snapshotQueue = List<MediaEntry>.of(_queue);
    _unmodifiableQueue = UnmodifiableListView<MediaEntry>(_snapshotQueue);
    _queueSnapshot = QueueSnapshot._(
      entries: _PersistentQueueEntries.from(_queue),
      revision: _queueRevision,
      currentIndex: _currentIndex,
      currentId: currentEntry?.id,
    );
    if (!_notifierDisposed) queueListenable.value = _queueSnapshot;
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
    );
    _updateProgressTimer();
  }

  /// Debounces a full-session save after structural or settings changes.
  void _scheduleSave() {
    if (!_acceptsCommands || _saveTimer != null) return;
    _saveTimer = Timer(_saveDelay, () {
      _saveTimer = null;
      unawaited(_runCoalescedSave());
    });
  }

  bool _scrubBackupOnSave = false;

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

  Future<void> _drainPersistence() async {
    await _saveDrain?.future;
    await _checkpointDrain?.future;
    await _sessions.flush();
  }

  void _updateProgressTimer() {
    final shouldRun = _acceptsCommands && _engineHasMedia && isPlaying;
    if (shouldRun) {
      _progressTimer ??= Timer.periodic(
        _progressCheckpointInterval,
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
        final activeId = _engineEntryId ?? current?.id;
        if (activeId == null) continue;
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

  void _setError(String message) {
    if (!_acceptsCommands) return;
    _error = message;
    _publishTransport();
    _notifyIfOpen();
  }

  void _notifyIfOpen() {
    if (_notifierDisposed || _closingState != ControllerClosingState.running) {
      return;
    }
    notifyListeners();
  }

  bool get _acceptsCommands =>
      _closingState == ControllerClosingState.running && !_notifierDisposed;
  bool get _isClosing =>
      _closingState == ControllerClosingState.saving ||
      _closingState == ControllerClosingState.awaitingDecision ||
      _closingState == ControllerClosingState.releasing;
  bool get _isClosed => _closingState == ControllerClosingState.closed;

  Future<void> _cancelAndDisposePlayback() async {
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

  static Duration _clampPosition(Duration value, Duration duration) {
    if (value < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && value > duration) return duration;
    return value;
  }
}

class _QueueUndo {
  const _QueueUndo({
    required this.entry,
    required this.index,
    required this.previousCurrentId,
    required this.wasPlaying,
    required this.displacedActiveSource,
    required this.displacedCurrent,
  });

  final MediaEntry entry;
  final int index;
  final String? previousCurrentId;
  final bool wasPlaying;
  final bool displacedActiveSource;
  final bool displacedCurrent;
}

/// A load attempt whose source identity is tracked by the entry's stable id.
class _PendingOpen {
  _PendingOpen({
    required this.operation,
    required this.entryId,
    required this.source,
  });

  final int operation;
  final String entryId;
  final String source;

  /// Load-attempt identity reported by the playback service, assigned once the
  /// request has been sent to the engine.
  int boundary = 0;
}

/// How one engine snapshot relates to the load attempt that is still pending.
enum _PendingLoadOutcome {
  /// The requested source is open and can be adopted.
  confirmed,

  /// The engine refused the requested source.
  refused,

  /// The snapshot does not describe the requested source yet.
  stillLoading,
}
