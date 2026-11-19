import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../domain/models/media_entry.dart';
import '../../domain/models/stream_playback_state.dart';
import '../../domain/models/stream_rendition.dart';

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

/// Strongly typed repeat modes supported by the player.
enum PlayerRepeatMode {
  off('off'),
  all('all'),
  one('one');

  const PlayerRepeatMode(this.value);

  /// String wire / session representation of the repeat mode.
  final String value;

  /// Parses a repeat mode from its string representation.
  static PlayerRepeatMode fromString(String? value) => switch (value) {
    'all' => PlayerRepeatMode.all,
    'one' => PlayerRepeatMode.one,
    _ => PlayerRepeatMode.off,
  };
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
  final Map<String, List<(int, MediaEntry)>> _indexedViewCache =
      <String, List<(int, MediaEntry)>>{};
  List<int>? _allIndices;

  int get length => entries.length;
  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  MediaEntry? get current => currentIndex >= 0 && currentIndex < entries.length
      ? entries[currentIndex]
      : null;

  /// Returns cached indexed entries `(originalIndex, entry)` matching [query].
  List<(int, MediaEntry)> filterIndexed(String query) {
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
      _indexedViewCache.remove(key);
    }
    while (_matchingIndices.isNotEmpty &&
        _calculateTotalMatches() > _maximumRetainedMatches) {
      final key = _matchingIndices.keys.first;
      _matchingIndices.remove(key);
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
    return next;
  }

  /// Structural snapshot sharing its chunked entry storage with [queue].
  static QueueSnapshot publish({
    required List<MediaEntry> queue,
    required int revision,
    required int currentIndex,
    required String? currentId,
  }) {
    return QueueSnapshot._(
      entries: _PersistentQueueEntries.from(queue),
      revision: revision,
      currentIndex: currentIndex,
      currentId: currentId,
    );
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

/// Shuffle and repeat, independent of transport and position ticks.
@immutable
class PlaybackMode {
  const PlaybackMode({
    this.shuffle = false,
    this.repeat = PlayerRepeatMode.off,
  });

  static const PlaybackMode initial = PlaybackMode();

  final bool shuffle;
  final PlayerRepeatMode repeat;

  @override
  bool operator ==(Object other) =>
      other is PlaybackMode &&
      other.shuffle == shuffle &&
      other.repeat == repeat;

  @override
  int get hashCode => Object.hash(shuffle, repeat);
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
    this.streamPlaybackState = const StreamPlaybackState(),
  });

  static const TransportState idle = TransportState();

  final bool isPlaying;
  final bool isBuffering;
  final bool isLoading;
  final bool hasMedia;
  final bool completed;
  final String? error;
  final StreamPlaybackState streamPlaybackState;

  bool get isStreaming => streamPlaybackState.isStreaming;
  String? get streamStageMessage => streamPlaybackState.stageMessage;
  StreamStage get streamStage => streamPlaybackState.stage;
  List<StreamRendition> get availableRenditions =>
      streamPlaybackState.availableRenditions;
  StreamRendition? get selectedRendition =>
      streamPlaybackState.selectedRendition;
  StreamRendition? get activeRendition => streamPlaybackState.activeRendition;
  int? get inputBitrate => streamPlaybackState.inputBitrate;

  @override
  bool operator ==(Object other) =>
      other is TransportState &&
      other.isPlaying == isPlaying &&
      other.isBuffering == isBuffering &&
      other.isLoading == isLoading &&
      other.hasMedia == hasMedia &&
      other.completed == completed &&
      other.error == error &&
      other.streamPlaybackState == streamPlaybackState;

  @override
  int get hashCode => Object.hash(
    isPlaying,
    isBuffering,
    isLoading,
    hasMedia,
    completed,
    error,
    streamPlaybackState,
  );
}

/// Reasons why background thumbnail extraction is suspended.
enum ThumbnailSuspensionReason {
  windowMinimized,
  playbackBuffering,
  previewExtraction,
}
