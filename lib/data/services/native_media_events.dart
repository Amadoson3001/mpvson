import 'dart:async';
import 'dart:convert';

import 'package:media_kit/media_kit.dart';

import '../../domain/models/playback_chapter.dart';

/// What the native playback engine reports for a source.
enum NativeMediaEventKind {
  /// libmpv started loading a source. The event carries the source it started.
  started,

  /// libmpv confirmed the started source is open (its content is readable).
  loaded,

  /// libmpv reached the end of the attached source.
  ended,

  /// libmpv reported a change in seekability of the attached source.
  seekableChanged,

  /// libmpv reported the chapter list of the attached source.
  chaptersChanged,

  /// libmpv reported updated demuxer cache, bitrate, resolution or position.
  demuxerStatsChanged,
}

/// A native engine notification about the source it has attached.
class NativeMediaEvent {
  const NativeMediaEvent.started(this.source, {this.playlistEntryId})
    : kind = NativeMediaEventKind.started,
      seekable = true,
      chapters = const <PlaybackChapter>[],
      endReason = null,
      errorCode = 0,
      demuxerCacheDuration = null,
      rawInputRate = null,
      pausedForCache = null,
      dwidth = null,
      dheight = null,
      timePos = null;
  const NativeMediaEvent.loaded()
    : kind = NativeMediaEventKind.loaded,
      source = '',
      playlistEntryId = null,
      seekable = true,
      chapters = const <PlaybackChapter>[],
      endReason = null,
      errorCode = 0,
      demuxerCacheDuration = null,
      rawInputRate = null,
      pausedForCache = null,
      dwidth = null,
      dheight = null,
      timePos = null;
  const NativeMediaEvent.ended({
    this.endReason,
    this.errorCode = 0,
    this.playlistEntryId,
  }) : kind = NativeMediaEventKind.ended,
       source = '',
       seekable = true,
       chapters = const <PlaybackChapter>[],
       demuxerCacheDuration = null,
       rawInputRate = null,
       pausedForCache = null,
       dwidth = null,
       dheight = null,
       timePos = null;
  const NativeMediaEvent.seekable(this.seekable)
    : kind = NativeMediaEventKind.seekableChanged,
      source = '',
      playlistEntryId = null,
      chapters = const <PlaybackChapter>[],
      endReason = null,
      errorCode = 0,
      demuxerCacheDuration = null,
      rawInputRate = null,
      pausedForCache = null,
      dwidth = null,
      dheight = null,
      timePos = null;
  const NativeMediaEvent.chapters(this.chapters)
    : kind = NativeMediaEventKind.chaptersChanged,
      source = '',
      playlistEntryId = null,
      seekable = true,
      endReason = null,
      errorCode = 0,
      demuxerCacheDuration = null,
      rawInputRate = null,
      pausedForCache = null,
      dwidth = null,
      dheight = null,
      timePos = null;
  const NativeMediaEvent.demuxerStats({
    this.demuxerCacheDuration,
    this.rawInputRate,
    this.pausedForCache,
    this.dwidth,
    this.dheight,
    this.timePos,
  }) : kind = NativeMediaEventKind.demuxerStatsChanged,
       source = '',
       playlistEntryId = null,
       seekable = true,
       chapters = const <PlaybackChapter>[],
       endReason = null,
       errorCode = 0;

  final NativeMediaEventKind kind;

  /// Raw source string reported by the engine for [NativeMediaEventKind.started]
  /// (may include a Windows long-path prefix or a URL), empty otherwise.
  final String source;

  /// Optional playlist entry ID reported by mpv for START_FILE or END_FILE.
  final int? playlistEntryId;

  /// End reason (EOF, stop, error, redirect) for [NativeMediaEventKind.ended].
  final NativeEndReason? endReason;

  /// Engine error code (0 for success).
  final int errorCode;

  /// Whether the attached source supports arbitrary seeking.
  final bool seekable;

  /// Chapter markers reported for [NativeMediaEventKind.chaptersChanged].
  final List<PlaybackChapter> chapters;

  /// Demuxer cache duration in seconds.
  final Duration? demuxerCacheDuration;

  /// Raw input rate in bytes per second.
  final int? rawInputRate;

  /// Whether demuxer is paused waiting for cache.
  final bool? pausedForCache;

  /// Display width in pixels.
  final int? dwidth;

  /// Display height in pixels.
  final int? dheight;

  /// Current playback position.
  final Duration? timePos;

  @override
  String toString() =>
      'NativeMediaEvent(${kind.name}, $source, seekable: $seekable, '
      'chapters: ${chapters.length})';
}

/// Property names observed on the native player.
///
/// `path` is notified by libmpv for every load, including reopening the same
/// source. `file-format` never notified in the probe, so the loaded
/// confirmation uses the demuxer's track list and duration instead.
abstract final class NativePropertyNames {
  static const String path = 'path';
  static const String trackList = 'track-list';
  static const String duration = 'duration';
  static const String eofReached = 'eof-reached';
  static const String idleActive = 'idle-active';
  static const String seekable = 'seekable';
  static const String chapterList = 'chapter-list';
  static const String demuxerCacheDuration = 'demuxer-cache-duration';
  static const String rawInputRate = 'raw-input-rate';
  static const String pausedForCache = 'paused-for-cache';
  static const String dwidth = 'dwidth';
  static const String dheight = 'dheight';
  static const String timePos = 'time-pos';

  /// Every property the adapter observes, in registration order.
  static const List<String> all = <String>[
    path,
    trackList,
    duration,
    eofReached,
    idleActive,
    seekable,
    chapterList,
    demuxerCacheDuration,
    rawInputRate,
    pausedForCache,
    dwidth,
    dheight,
    timePos,
  ];
}

/// Interprets one observed libmpv property change.
///
/// Returns null when the change carries no source lifecycle information.
NativeMediaEvent? interpretNativeProperty(String property, String value) {
  switch (property) {
    case NativePropertyNames.path:
      final source = value.trim();
      return source.isEmpty ? null : NativeMediaEvent.started(source);
    case NativePropertyNames.trackList:
      try {
        final tracks = jsonDecode(value);
        return tracks is List &&
                tracks.any((track) => track is Map && track.isNotEmpty)
            ? const NativeMediaEvent.loaded()
            : null;
      } on FormatException {
        return null;
      }
    case NativePropertyNames.duration:
      final seconds = double.tryParse(value.trim());
      return seconds == null || !seconds.isFinite || seconds <= 0
          ? null
          : const NativeMediaEvent.loaded();
    case NativePropertyNames.eofReached:
      return _isYes(value)
          ? const NativeMediaEvent.ended(endReason: NativeEndReason.eof)
          : null;
    case NativePropertyNames.idleActive:
      return _isYes(value)
          ? const NativeMediaEvent.ended(endReason: NativeEndReason.stop)
          : null;
    case NativePropertyNames.seekable:
      return NativeMediaEvent.seekable(_isYes(value));
    case NativePropertyNames.chapterList:
      return NativeMediaEvent.chapters(parseChapterList(value));
    case NativePropertyNames.demuxerCacheDuration:
      final seconds = double.tryParse(value.trim());
      if (seconds != null && seconds >= 0) {
        return NativeMediaEvent.demuxerStats(
          demuxerCacheDuration: Duration(
            milliseconds: (seconds * 1000).round(),
          ),
        );
      }
      return null;
    case NativePropertyNames.rawInputRate:
      final bytesPerSec = int.tryParse(value.trim());
      if (bytesPerSec != null && bytesPerSec >= 0) {
        return NativeMediaEvent.demuxerStats(rawInputRate: bytesPerSec);
      }
      return null;
    case NativePropertyNames.pausedForCache:
      return NativeMediaEvent.demuxerStats(pausedForCache: _isYes(value));
    case NativePropertyNames.dwidth:
      final width = int.tryParse(value.trim());
      if (width != null && width > 0) {
        return NativeMediaEvent.demuxerStats(dwidth: width);
      }
      return null;
    case NativePropertyNames.dheight:
      final height = int.tryParse(value.trim());
      if (height != null && height > 0) {
        return NativeMediaEvent.demuxerStats(dheight: height);
      }
      return null;
    case NativePropertyNames.timePos:
      final seconds = double.tryParse(value.trim());
      if (seconds != null && seconds >= 0) {
        return NativeMediaEvent.demuxerStats(
          timePos: Duration(milliseconds: (seconds * 1000).round()),
        );
      }
      return null;
    default:
      return null;
  }
}

/// Parses libmpv's `chapter-list` JSON into chapter markers ordered by time.
List<PlaybackChapter> parseChapterList(String value) {
  final Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    return const <PlaybackChapter>[];
  }
  if (decoded is! List) return const <PlaybackChapter>[];
  final chapters = <PlaybackChapter>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final seconds = item['time'];
    if (seconds is! num || !seconds.isFinite || seconds < 0) continue;
    final title = item['title']?.toString().trim() ?? '';
    chapters.add(
      PlaybackChapter(
        title: title,
        start: Duration(milliseconds: (seconds * 1000).round()),
      ),
    );
  }
  if (chapters.isEmpty) return const <PlaybackChapter>[];
  chapters.sort((a, b) => a.start.compareTo(b.start));
  return List<PlaybackChapter>.unmodifiable(chapters);
}

bool _isYes(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized == 'yes' || normalized == 'true' || normalized == '1';
}

/// Narrow, repository-owned view of the native engine's source lifecycle.
///
/// media_kit exposes property observation on its native player but no
/// source-identity events. Mpvson owns this small adapter so playback state can
/// be attributed to the source the engine actually has attached instead of the
/// source the player last requested.
abstract interface class NativeMediaEvents {
  /// Started, loaded and ended notifications in engine order.
  Stream<NativeMediaEvent> get events;

  /// Registers the native observers.
  ///
  /// Returns false when the current player implementation cannot report native
  /// events, in which case playback falls back to request-based attribution.
  Future<bool> start();

  Future<void> dispose();
}

/// Used when a player implementation has no native event channel.
class DisabledNativeMediaEvents implements NativeMediaEvents {
  const DisabledNativeMediaEvents();

  @override
  Stream<NativeMediaEvent> get events => const Stream<NativeMediaEvent>.empty();

  @override
  Future<bool> start() async => false;

  @override
  Future<void> dispose() async {}
}

/// Reads the observed libmpv properties of a media_kit native player.
class MediaKitNativeMediaEvents implements NativeMediaEvents {
  MediaKitNativeMediaEvents(this._player);

  final Player _player;
  final StreamController<NativeMediaEvent> _events =
      StreamController<NativeMediaEvent>.broadcast(sync: true);
  final List<String> _observedProperties = [];
  StreamSubscription<NativeLifecycleEvent>? _lifecycleSubscription;
  String? _lastObservedSource;
  bool _started = false;
  bool _disposed = false;

  @override
  Stream<NativeMediaEvent> get events => _events.stream;

  @override
  Future<bool> start() async {
    if (_disposed) return false;
    if (_started) return true;
    final platform = _player.platform;
    if (platform is! NativePlayer) return false;
    try {
      _lifecycleSubscription = platform.nativeLifecycle.listen((event) {
        if (_disposed) return;
        switch (event.kind) {
          case NativeLifecycleKind.startFile:
            _events.add(
              NativeMediaEvent.started(
                _lastObservedSource ?? '',
                playlistEntryId: event.playlistEntryId,
              ),
            );
            break;
          case NativeLifecycleKind.fileLoaded:
            _events.add(const NativeMediaEvent.loaded());
            break;
          case NativeLifecycleKind.endFile:
            _events.add(
              NativeMediaEvent.ended(
                endReason: event.reason,
                errorCode: event.error,
                playlistEntryId: event.playlistEntryId,
              ),
            );
            break;
        }
      });

      for (final property in NativePropertyNames.all) {
        if (_disposed) {
          await _unobserveAll(platform);
          return false;
        }
        await platform.observeProperty(property, (value) async {
          if (property == NativePropertyNames.path) {
            _lastObservedSource = value.trim();
          }
          _handle(property, value);
        });
        _observedProperties.add(property);
      }
    } on Object {
      // An engine build that refuses one of the properties keeps playback
      // working through request-based attribution.
      await _unobserveAll(platform);
      return false;
    }
    _started = true;
    return true;
  }

  Future<void> _unobserveAll(NativePlayer platform) async {
    await _lifecycleSubscription?.cancel();
    _lifecycleSubscription = null;
    final toRemove = List<String>.of(_observedProperties);
    _observedProperties.clear();
    for (final prop in toRemove) {
      try {
        await platform.unobserveProperty(prop);
      } catch (_) {}
    }
  }

  void _handle(String property, String value) {
    if (_disposed) return;
    final event = interpretNativeProperty(property, value);
    if (event == null) return;
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _lifecycleSubscription?.cancel();
    _lifecycleSubscription = null;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await _unobserveAll(platform);
    }
    try {
      await _events.close();
    } on Object {
      // Teardown must not throw when the native player is already gone.
    }
  }
}
