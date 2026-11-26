import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/models/media_source.dart';
import '../../utils/lru_byte_cache.dart';
import 'diagnostic_log.dart';
import 'hls_preview_source_resolver.dart';
import 'native_player_properties.dart';

/// Quality of an extracted seek preview frame.
enum SeekPreviewQuality {
  /// Fast keyframe seek (mpv absolute+keyframes).
  keyframe,

  /// Exact decoded seek (mpv exact).
  exact,
}

/// A captured video frame with timestamp and quality metadata.
class SeekPreviewFrame {
  const SeekPreviewFrame({
    required this.bytes,
    required this.requestedTime,
    required this.capturedTime,
    required this.quality,
  });

  /// JPEG bytes of the captured video frame.
  final Uint8List bytes;

  /// Target playback position requested by the user.
  final Duration requestedTime;

  /// Actual position reported by the engine for the decoded frame.
  final Duration capturedTime;

  /// Resolution quality (keyframe vs exact).
  final SeekPreviewQuality quality;

  /// Total bytes of the JPEG image.
  int get byteLength => bytes.lengthInBytes;
}

/// Loading and ready status of seek preview imagery.
enum SeekPreviewStatus { idle, loading, ready, failed }

/// State emitted by [SeekPreviewService] to drive the UI hover bubble.
class SeekPreviewState {
  const SeekPreviewState({
    this.status = SeekPreviewStatus.idle,
    this.currentFrame,
    this.liveTextureId,
    this.targetTime = Duration.zero,
    this.isUpdating = false,
    this.isRemote = false,
    this.errorMessage,
  });

  final SeekPreviewStatus status;
  final SeekPreviewFrame? currentFrame;
  final int? liveTextureId;
  final Duration targetTime;
  final bool isUpdating;
  final bool isRemote;
  final String? errorMessage;

  bool get hasVisual =>
      liveTextureId != null ||
      (currentFrame != null && currentFrame!.bytes.isNotEmpty);

  SeekPreviewState copyWith({
    SeekPreviewStatus? status,
    SeekPreviewFrame? currentFrame,
    int? liveTextureId,
    Duration? targetTime,
    bool? isUpdating,
    bool? isRemote,
    String? errorMessage,
    bool clearError = false,
    bool clearFrame = false,
    bool clearLiveTexture = false,
  }) {
    return SeekPreviewState(
      status: status ?? this.status,
      currentFrame: clearFrame ? null : (currentFrame ?? this.currentFrame),
      liveTextureId: clearLiveTexture
          ? null
          : (liveTextureId ?? this.liveTextureId),
      targetTime: targetTime ?? this.targetTime,
      isUpdating: isUpdating ?? this.isUpdating,
      isRemote: isRemote ?? this.isRemote,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// In-memory LRU cache capped at 128 frames or 6 MiB with pre-emptive eviction
/// when memory pressure thresholds are met.
///
/// Tracks requested time, captured time, and approximate/exact quality.
/// Results are never persisted to disk.
class SeekPreviewLRUCache {
  SeekPreviewLRUCache({
    this.maxEntries = 128,
    this.maxBytes = 6 * 1024 * 1024, // 6 MiB tuned bound
    this.pressureThreshold = 0.8,
  }) : _cache = LruByteCache<int, SeekPreviewFrame>(
         maxEntries: maxEntries,
         maxBytes: maxBytes,
         sizeOf: (frame) => frame.byteLength,
         pressureThreshold: pressureThreshold,
       );

  final int maxEntries;
  final int maxBytes;
  final double pressureThreshold;
  final LruByteCache<int, SeekPreviewFrame> _cache;

  int get length => _cache.length;
  int get currentBytes => _cache.currentBytes;

  static int _exactKey(Duration time) => (time.inMilliseconds * 2) + 1;
  static int _bucketKey(Duration time) => (time.inSeconds * 2);

  /// Looks up a cached frame for [target].
  ///
  /// If [exactOnly] is true, returns only an exact timestamp match.
  /// Otherwise, prefers an exact timestamp match, an exact capture within 250ms
  /// (returned as approximate), then an approximate frame from the same bucket.
  SeekPreviewFrame? get(Duration target, {bool exactOnly = false}) {
    final exactKey = _exactKey(target);
    final exact = _cache.get(exactKey);
    if (exact != null && exact.requestedTime == target) {
      return exact;
    }
    if (exactOnly) return null;

    // An exact capture from a nearby timestamp is a better moving preview than
    // a keyframe from elsewhere in the same second. Return it as approximate
    // so the service still schedules an exact refinement for [target].
    final nearbyExact = _nearestExactEntry(target);
    if (nearbyExact != null &&
        nearbyExact.distance <= const Duration(milliseconds: 250)) {
      final frame = _cache.get(nearbyExact.key)!;
      return SeekPreviewFrame(
        bytes: frame.bytes,
        requestedTime: frame.requestedTime,
        capturedTime: frame.capturedTime,
        quality: SeekPreviewQuality.keyframe,
      );
    }

    return _cache.get(_bucketKey(target));
  }

  ({int key, Duration distance})? _nearestExactEntry(Duration target) {
    ({int key, Duration distance})? nearest;
    for (final entry in _cache.entries) {
      if (entry.value.quality != SeekPreviewQuality.exact) continue;
      final distance = (entry.value.capturedTime - target).abs();
      if (nearest == null || distance < nearest.distance) {
        nearest = (key: entry.key, distance: distance);
      }
    }
    return nearest;
  }

  /// Inserts a newly completed frame into the LRU cache, pre-emptively evicting
  /// lower-priority keyframe entries when nearing memory pressure thresholds,
  /// and strictly evicting oldest entries when exceeding [maxEntries] or [maxBytes].
  void put(SeekPreviewFrame frame) {
    final key = frame.quality == SeekPreviewQuality.exact
        ? _exactKey(frame.requestedTime)
        : _bucketKey(frame.requestedTime);
    _cache.put(key, frame);
    if (_cache.isUnderPressure) {
      _evictPreemptively();
    }
    _cache.evictToBounds();
  }

  /// Pre-emptively evicts lower-value keyframe (approximate) entries first,
  /// reducing cache usage down towards 75% capacity to prevent eviction churn.
  void _evictPreemptively() {
    _cache.evictUnderPressure(
      prefer: (key, frame) => frame.quality == SeekPreviewQuality.keyframe,
    );
  }

  /// Trims cached frames under external memory pressure.
  void trimMemory() {
    _evictPreemptively();
  }

  /// Clears all cached frames immediately.
  void clear() {
    _cache.clear();
  }
}

/// Abstract backend for extracting preview video frames.
///
/// Injected for testing to verify scheduler and lifecycle behavior without
/// requiring a native engine texture or external network source.
abstract interface class SeekPreviewBackend {
  /// Optional live Flutter texture ID rendered directly by the preview worker.
  int? get liveTextureId;

  /// Whether this backend can update preview frames directly via [seekLive]
  /// without taking screenshots or encoding JPEG frames.
  bool get supportsLiveTexture;

  /// Opens [source] starting at [start] position with a bounded [timeout].
  Future<void> open(
    String source, {
    Map<String, String>? httpHeaders,
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  });

  /// Seeks the live preview texture directly to [target] without capturing a
  /// screenshot.
  Future<void> seekLive(Duration target, {required bool exact});

  /// Seeks to [target] and captures the resulting decoded video frame.
  ///
  /// If [exact] is false, uses `absolute+keyframes` for maximum speed.
  /// If true, uses exact seek refinement.
  Future<SeekPreviewFrame?> extractFrame(
    Duration target, {
    required bool exact,
    Duration timeout = const Duration(seconds: 3),
  });

  /// Cancels in-flight frame extraction, if supported.
  void cancelExtraction();

  /// Pauses the preview worker decoder.
  Future<void> pause();

  /// Stops playback on the preview worker.
  Future<void> stop();

  /// Disposes native player and video controller resources.
  Future<void> dispose();
}

typedef SeekPreviewBackendFactory = SeekPreviewBackend Function();

/// Production backend using media_kit and bundled libmpv.
class MediaKitSeekPreviewBackend implements SeekPreviewBackend {
  MediaKitSeekPreviewBackend({
    this.playerFactory,
    this.videoControllerFactory,
    this.diagnostics,
    this.hlsSourceResolver,
    this.platformInitTimeout = defaultPlatformInitTimeout,
  });

  /// How long the preview worker waits for the video output's platform
  /// initialization before giving up. Without this bound a stalled platform
  /// channel leaves the backend queue wedged forever, which in turn hangs
  /// [dispose] behind the stuck open.
  static const Duration defaultPlatformInitTimeout = Duration(seconds: 10);
  final Duration platformInitTimeout;

  final Player Function()? playerFactory;
  final VideoController Function(Player player)? videoControllerFactory;
  final DiagnosticSink? diagnostics;
  final HlsPreviewSourceResolver? hlsSourceResolver;
  Player? _player;
  VideoController? _videoController;
  StreamSubscription<String>? _playerErrorSubscription;
  String? _lastPlayerError;
  bool _disposed = false;
  SeekPreviewFrame? _lastCapturedFrame;
  String? _resolvedSourceInput;
  String? _resolvedPlayerSource;
  String? _verifiedOutputForSource;
  bool _seekObserversReady = false;
  String? _sourceId;

  @override
  int? get liveTextureId => _disposed ? null : _videoController?.id.value;

  @override
  bool get supportsLiveTexture =>
      !_disposed &&
      _videoController != null &&
      _videoController!.id.value != null;
  int _mediaPathEvent = 0;
  int _trackListEvent = 0;
  int _durationEvent = 0;
  int _seekableEvent = 0;
  String? _observedPath;
  String? _observedTrackList;
  String? _observedDuration;
  String? _observedSeekable;
  int _seekingEvent = 0;
  int _timePositionEvent = 0;
  int _activeSeekingEventStart = 0;
  bool _seekObservationActive = false;
  bool _sawSeekingTrue = false;
  bool _sawSeekingComplete = false;
  int _extractGeneration = 0;
  Completer<void>? _observerPulse;

  int get _observerEpoch =>
      _mediaPathEvent +
      _trackListEvent +
      _durationEvent +
      _seekableEvent +
      _seekingEvent +
      _timePositionEvent;

  void _notifyObserverPulse() {
    final completer = _observerPulse;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _observerPulse = null;
  }

  Future<void> _waitForObserverOrTimeout(
    int epochBeforeRead,
    Duration fallbackDelay,
  ) async {
    if (_disposed || _observerEpoch != epochBeforeRead) {
      return;
    }
    final completer = (_observerPulse != null && !_observerPulse!.isCompleted)
        ? _observerPulse!
        : (_observerPulse = Completer<void>());
    Timer? timer;
    timer = Timer(fallbackDelay, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_observerPulse, completer)) {
        _observerPulse = null;
      }
    });
    try {
      await completer.future;
    } finally {
      timer.cancel();
    }
  }

  @override
  void cancelExtraction() {
    _extractGeneration++;
    _notifyObserverPulse();
  }

  Future<Player> _ensurePlayer() async {
    if (_player != null) return _player!;
    final factory = playerFactory;
    final player = factory != null
        ? factory()
        : Player(
            configuration: const PlayerConfiguration(
              title: 'Mpvson seek preview',
              muted: true,
              osc: false,
              libass: false,
              bufferSize: 2 * 1024 * 1024,
            ),
          );
    _player = player;
    _playerErrorSubscription = player.stream.error.listen((error) {
      _lastPlayerError = error;
    });

    final native = player.platform;
    if (native is NativePlayer) {
      const properties = <String, String>{
        'ao': 'null',
        'audio': 'no',
        'aid': 'no',
        'sub': 'no',
        'sid': 'no',
        'sub-auto': 'no',
        'audio-file-auto': 'no',
        'cache': 'no',
        'cache-on-disk': 'no',
        'cache-secs': '0',
        'demuxer-readahead-secs': '0',
        'demuxer-max-bytes': '2097152',
        'demuxer-max-back-bytes': '1048576',
        'hls-bitrate': 'min',
        // Software decode with fast/skiploopfilter avoids GPU decoder
        // contention and large VRAM pools on low-end hardware while keeping
        // single-keyframe preview decode ~5-15ms.
        'hwdec': 'no',
        'vd-lavc-fast': 'yes',
        'vd-lavc-skiploopfilter': 'all',
        'vd-lavc-threads': '2',
        'sws-scaler': 'fast-bilinear',
        'scale': 'bilinear',
        'cscale': 'bilinear',
        'dscale': 'bilinear',
        'tscale': 'linear',
        'correct-downscaling': 'no',
        'dither': 'no',
        'hr-seek': 'no',
        'video-sync': 'desync',
      };
      await applyNativePlayerProperties(
        native,
        properties,
        onError: (key, error) {
          _record(
            'preview.configure',
            message: 'Could not set $key',
            error: error,
          );
        },
      );
    }

    final vcFactory = videoControllerFactory;
    _videoController = vcFactory != null
        ? vcFactory(player)
        : VideoController(
            player,
            configuration: const VideoControllerConfiguration(
              width: 320,
              height: 180,
              enableHardwareAcceleration: true,
              hwdec: 'no',
            ),
          );

    // VideoController schedules native setup from a post-frame callback. A
    // paused main player may have no later frame to trigger that callback.
    WidgetsBinding.instance.ensureVisualUpdate();
    try {
      await _videoController!.platform.future.timeout(platformInitTimeout);
    } on TimeoutException catch (error) {
      _record(
        'preview.video_output',
        message: 'Preview video output did not initialize in time',
        error: error,
      );
      // The player's engine gate waits for this same initialization; release
      // it so later engine commands (and player disposal) cannot hang on a
      // video output that will never arrive.
      final platform = player.platform;
      if (platform != null && !platform.videoControllerCompleter.isCompleted) {
        platform.videoControllerCompleter.complete();
      }
      rethrow;
    }

    return player;
  }

  bool _isRemoteSource(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  @override
  Future<void> open(
    String source, {
    Map<String, String>? httpHeaders,
    Duration start = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_disposed) return;
    _lastCapturedFrame = null;
    _verifiedOutputForSource = null;
    _sourceId = source;
    final stopwatch = Stopwatch()..start();
    final isRemote = _isRemoteSource(source);
    var playbackSource = source;
    if (!isRemote) {
      _resolvedSourceInput = source;
      _resolvedPlayerSource = source;
    } else if (_resolvedSourceInput == source) {
      playbackSource = _resolvedPlayerSource ?? source;
    } else {
      _resolvedSourceInput = source;
      try {
        final remaining = timeout - stopwatch.elapsed;
        final selected = await (hlsSourceResolver ?? HlsPreviewSourceResolver())
            .resolve(
              source,
              timeout: remaining.isNegative ? Duration.zero : remaining,
              httpHeaders: httpHeaders,
            );
        if (selected != null) {
          playbackSource = selected.toString();
          _record(
            'preview.hls_variant',
            message: 'Selected the lowest-bandwidth video rendition',
          );
        }
      } on TimeoutException {
        _resolvedSourceInput = null;
        rethrow;
      } on Object catch (error) {
        _record(
          'preview.hls_resolve_fallback',
          message: 'Could not resolve HLS master; using supplied source',
          error: error,
        );
      }
      _resolvedPlayerSource = playbackSource;
    }
    final player = await _ensurePlayer();
    final native = player.platform;
    if (native is NativePlayer) {
      await _ensureSeekObservers(native);
      await applyNativePlayerProperties(
        native,
        <String, String>{
          'demuxer-lavf-o': isRemote && _isHlsPlaylistSource(playbackSource)
              ? 'http_multiple=0'
              : '',
          // Local files render directly into the 320x180 GPU texture without
          // software scaling; remote streams keep vf scaling for bounded
          // screenshot capture into the LRU cache.
          'vf': isRemote
              ? 'scale=w=320:h=320:force_original_aspect_ratio=decrease'
              : '',
        },
        onError: (key, error) {
          _record(
            'preview.configure',
            message: 'Could not configure $key for preview source',
            error: error,
          );
        },
      );
    }
    final pathEvent = _mediaPathEvent;
    final trackListEvent = _trackListEvent;
    final durationEvent = _durationEvent;
    await player.open(
      Media(
        playbackSource,
        httpHeaders: httpHeaders,
        start: start > Duration.zero ? start : null,
      ),
      play: false,
    );
    if (native is NativePlayer) {
      final remaining = timeout - stopwatch.elapsed;
      await _waitForMediaLoaded(
        native,
        source: playbackSource,
        pathEvent: pathEvent,
        trackListEvent: trackListEvent,
        durationEvent: durationEvent,
        timeout: remaining.isNegative ? Duration.zero : remaining,
      );
    }
    _record(
      'preview.open',
      message: 'Preview media loaded in ${stopwatch.elapsedMilliseconds} ms',
    );
  }

  Future<void> _waitForMediaLoaded(
    NativePlayer native, {
    required String source,
    required int pathEvent,
    required int trackListEvent,
    required int durationEvent,
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      if (_disposed) throw StateError('Preview backend disposed while opening');
      final epoch = _observerEpoch;

      var currentPath = _observedPath;
      var currentTrackList = _observedTrackList;
      var currentDuration = _observedDuration;
      var currentSeekable = _observedSeekable;

      bool isReady() {
        final pathMatches = _pathMatchesSource(currentPath, source);
        final pathChanged = _mediaPathEvent > pathEvent;
        final pathReady =
            pathMatches || (pathChanged && _isNonEmpty(currentPath));
        final tracksReady =
            _hasMediaTracks(currentTrackList) &&
            (_trackListEvent > trackListEvent || pathMatches);
        final durationReady =
            _hasPositiveDuration(currentDuration) &&
            (_durationEvent > durationEvent || pathMatches);
        return pathReady &&
            (tracksReady || durationReady) &&
            _isYes(currentSeekable ?? '');
      }

      if (!isReady()) {
        final values = await Future.wait<String?>([
          _readProperty(native, 'path'),
          _readProperty(native, 'track-list'),
          _readProperty(native, 'duration'),
          _readProperty(native, 'seekable'),
        ]);
        currentPath = values[0] ?? currentPath;
        currentTrackList = values[1] ?? currentTrackList;
        currentDuration = values[2] ?? currentDuration;
        currentSeekable = values[3] ?? currentSeekable;
      }

      if (isReady()) {
        _record(
          'preview.media_loaded',
          message:
              'Native media readiness confirmed in '
              '${stopwatch.elapsedMilliseconds} ms; '
              'tracks=${_summarizeTrackList(currentTrackList)}, '
              'duration=${_durationSummary(currentDuration)}',
        );
        return;
      }
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      final delay = remaining < const Duration(milliseconds: 10)
          ? remaining
          : const Duration(milliseconds: 10);
      await _waitForObserverOrTimeout(epoch, delay);
    }
    final snapshot = await _readReadinessSnapshot(native);
    _record(
      'preview.media_load_timeout',
      message:
          'Native media did not become ready in '
          '${timeout.inMilliseconds} ms; $snapshot',
      error: _lastPlayerError,
    );
    throw TimeoutException('Timed out waiting for preview media to load');
  }

  Future<String> _readReadinessSnapshot(NativePlayer native) async {
    final path = await _readProperty(native, 'path');
    final tracks = await _readProperty(native, 'track-list');
    final duration = await _readProperty(native, 'duration');
    final seekable = await _readProperty(native, 'seekable');
    final seeking = await _readProperty(native, 'seeking');
    final position = await _readProperty(native, 'time-pos');
    final hasPath = _isNonEmpty(path ?? _observedPath);
    return 'path=${hasPath ? 'set' : 'empty'}, '
        'tracks=${_summarizeTrackList(tracks ?? _observedTrackList)}, '
        'duration=${_durationSummary(duration ?? _observedDuration)}, '
        'seekable=${seekable ?? 'unavailable'}, '
        'seeking=${seeking ?? 'unavailable'}, '
        'time-pos=${position ?? 'unavailable'}, '
        'error=${_lastPlayerError ?? 'none'}';
  }

  bool _isNonEmpty(String? value) => value != null && value.trim().isNotEmpty;

  bool _pathMatchesSource(String? path, String source) {
    if (!_isNonEmpty(path)) return false;
    try {
      return Media.normalizeURI(path!.trim()) == Media.normalizeURI(source);
    } on Object {
      return path!.trim() == source.trim();
    }
  }

  bool _isHlsPlaylistSource(String source) {
    final uri = Uri.tryParse(source);
    final path = uri?.path ?? source.split('?').first.split('#').first;
    final normalizedPath = path.toLowerCase();
    return normalizedPath.endsWith('.m3u8') || normalizedPath.endsWith('.m3u');
  }

  bool _hasPositiveDuration(String? value) {
    final seconds = value == null ? null : double.tryParse(value.trim());
    return seconds != null && seconds.isFinite && seconds > 0;
  }

  String _durationSummary(String? value) => _hasPositiveDuration(value)
      ? '${(double.parse(value!) * 1000).round()}ms'
      : 'unknown';

  bool _hasMediaTracks(String? value) {
    if (value == null) return false;
    try {
      final decoded = jsonDecode(value);
      return decoded is List && decoded.any((track) => track is Map);
    } on FormatException {
      return false;
    }
  }

  String _summarizeTrackList(String? value) {
    if (value == null) return 'unavailable';
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return 'invalid';
      var video = 0;
      var audio = 0;
      var subtitle = 0;
      var other = 0;
      for (final item in decoded) {
        if (item is! Map) continue;
        switch (item['type']) {
          case 'video':
            video++;
            break;
          case 'audio':
            audio++;
            break;
          case 'sub':
            subtitle++;
            break;
          default:
            other++;
            break;
        }
      }
      if (video + audio + subtitle + other == 0) return 'empty';
      return 'video=$video,audio=$audio,subtitle=$subtitle,other=$other';
    } on FormatException {
      return 'invalid';
    }
  }

  @override
  Future<void> seekLive(Duration target, {required bool exact}) async {
    if (_disposed || _player == null) return;
    final player = _player!;
    final native = player.platform;
    if (native is NativePlayer) {
      final targetSeconds = (target.inMilliseconds / 1000.0).toString();
      final seekFlag = exact ? 'absolute+exact' : 'absolute+keyframes';
      await native.command(['seek', targetSeconds, seekFlag]);
    } else {
      await player.seek(target);
    }
  }

  @override
  Future<SeekPreviewFrame?> extractFrame(
    Duration target, {
    required bool exact,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_disposed || _player == null) return null;
    final currentGen = ++_extractGeneration;
    final player = _player!;
    final completedFrame = _matchingCompletedFrame(target, exact: exact);
    if (completedFrame != null) {
      _record(
        'preview.completed_frame_reuse',
        message:
            'Reused decoded frame captured at '
            '${completedFrame.capturedTime.inMilliseconds} ms',
      );
      return completedFrame;
    }
    final native = player.platform;
    final seekStopwatch = Stopwatch()..start();
    Duration capturedPosition;
    if (native is NativePlayer) {
      await _ensureSeekObservers(native);
      final before = await _readTimePosition(native);
      _sawSeekingTrue = false;
      _sawSeekingComplete = false;
      final startSeekingEvent = _seekingEvent;
      final startPositionEvent = _timePositionEvent;
      final targetSeconds = (target.inMilliseconds / 1000.0).toString();
      final seekFlag = exact ? 'absolute+exact' : 'absolute+keyframes';
      _activeSeekingEventStart = startSeekingEvent;
      _seekObservationActive = true;
      try {
        await native.command(['seek', targetSeconds, seekFlag]);
        final readinessBudget = timeout - seekStopwatch.elapsed;
        capturedPosition = await _waitForSeekReady(
          native,
          target: target,
          exact: exact,
          before: before,
          startSeekingEvent: startSeekingEvent,
          startPositionEvent: startPositionEvent,
          extractGen: currentGen,
          timeout: readinessBudget.isNegative ? Duration.zero : readinessBudget,
        );
      } finally {
        _seekObservationActive = false;
      }
      final outputBudget = timeout - seekStopwatch.elapsed;
      await _verifyBoundedVideoOutput(
        native,
        outputBudget.isNegative ? Duration.zero : outputBudget,
      );
    } else {
      await player.seek(target);
      capturedPosition = player.state.position;
    }

    if (_disposed || _extractGeneration != currentGen) return null;
    final bytes = await player.screenshot(format: 'image/jpeg');
    if (_disposed ||
        _extractGeneration != currentGen ||
        bytes == null ||
        bytes.isEmpty) {
      return null;
    }

    final frame = SeekPreviewFrame(
      bytes: bytes,
      requestedTime: target,
      capturedTime: capturedPosition,
      quality: exact ? SeekPreviewQuality.exact : SeekPreviewQuality.keyframe,
    );
    _lastCapturedFrame = frame;
    _record(
      exact ? 'preview.exact_capture' : 'preview.keyframe_capture',
      message:
          'Captured at ${capturedPosition.inMilliseconds} ms in '
          '${seekStopwatch.elapsedMilliseconds} ms',
    );
    return frame;
  }

  SeekPreviewFrame? _matchingCompletedFrame(
    Duration target, {
    required bool exact,
  }) {
    final frame = _lastCapturedFrame;
    if (frame == null) return null;
    final exactTimestampMatch = frame.capturedTime == target;
    if (exact) {
      final accurateExactFrame =
          frame.quality == SeekPreviewQuality.exact &&
          _withinFrame(frame.capturedTime, target);
      if (!exactTimestampMatch && !accurateExactFrame) {
        return null;
      }
    } else if (!_withinFrame(frame.capturedTime, target)) {
      return null;
    }
    return SeekPreviewFrame(
      bytes: frame.bytes,
      requestedTime: target,
      capturedTime: frame.capturedTime,
      quality: exact ? SeekPreviewQuality.exact : SeekPreviewQuality.keyframe,
    );
  }

  Future<void> _ensureSeekObservers(NativePlayer native) async {
    if (_seekObserversReady) return;
    await Future.wait([
      _observeProperty(native, 'path', (value) {
        _mediaPathEvent++;
        _observedPath = value;
        _notifyObserverPulse();
      }),
      _observeProperty(native, 'track-list', (value) {
        _trackListEvent++;
        _observedTrackList = value;
        _notifyObserverPulse();
      }),
      _observeProperty(native, 'duration', (value) {
        _durationEvent++;
        _observedDuration = value;
        _notifyObserverPulse();
      }),
      _observeProperty(native, 'seekable', (value) {
        _seekableEvent++;
        _observedSeekable = value;
        _notifyObserverPulse();
      }),
      _observeProperty(native, 'seeking', (value) {
        _seekingEvent++;
        if (_seekObservationActive &&
            _seekingEvent > _activeSeekingEventStart) {
          if (_isYes(value)) {
            _sawSeekingTrue = true;
          } else if (_sawSeekingTrue) {
            _sawSeekingComplete = true;
          }
        }
        _notifyObserverPulse();
      }),
      _observeProperty(native, 'time-pos', (value) {
        _timePositionEvent++;
        _notifyObserverPulse();
      }),
    ]);
    _seekObserversReady = true;
  }

  Future<void> _observeProperty(
    NativePlayer native,
    String property,
    void Function(String value) onValue,
  ) async {
    try {
      await native.observeProperty(property, (value) async => onValue(value));
    } on Object catch (error) {
      // Read polling remains available if this property cannot be observed.
      _record(
        'preview.observe_property',
        message: 'Could not observe native $property',
        error: error,
      );
    }
  }

  Future<Duration> _waitForSeekReady(
    NativePlayer native, {
    required Duration target,
    required bool exact,
    required Duration? before,
    required int startSeekingEvent,
    required int startPositionEvent,
    required int extractGen,
    required Duration timeout,
  }) async {
    final limit = timeout;
    final stopwatch = Stopwatch()..start();
    var stableSamples = 0;
    Duration? previousPosition;
    while (stopwatch.elapsed < limit) {
      if (_disposed || _extractGeneration != extractGen) {
        throw StateError('Preview seek cancelled');
      }
      final epoch = _observerEpoch;
      final seeking = await _readProperty(native, 'seeking');
      final position = await _readTimePosition(native);
      if (seeking != null) {
        if (_isYes(seeking)) {
          _sawSeekingTrue = true;
        } else if (_sawSeekingTrue && _seekingEvent > startSeekingEvent) {
          _sawSeekingComplete = true;
        }
      }

      final seekingEnded =
          _sawSeekingComplete ||
          (_sawSeekingTrue && seeking != null && !_isYes(seeking));
      final positionChanged =
          position != null &&
          ((before == null && _timePositionEvent > startPositionEvent) ||
              (before != null && position != before));
      final withinTarget =
          position != null && (position - target).abs() <= _frameTolerance();
      if (position != null && position == previousPosition) {
        stableSamples++;
      } else {
        stableSamples = 0;
      }
      previousPosition = position;

      if (seekingEnded && position != null) {
        if (exact && !withinTarget) {
          throw StateError(
            'Exact seek ended at ${position.inMilliseconds} ms for '
            '${target.inMilliseconds} ms target',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 8));
        if (_disposed || _extractGeneration != extractGen) {
          throw StateError('Preview seek cancelled');
        }
        final settledSeeking = await _readProperty(native, 'seeking');
        if (settledSeeking == null || _isYes(settledSeeking)) {
          await _waitForObserverOrTimeout(
            epoch,
            const Duration(milliseconds: 12),
          );
          continue;
        }
        final settled = await _readTimePosition(native);
        if (settled != null) {
          if (exact && !_withinFrame(settled, target)) {
            throw StateError(
              'Exact seek settled at ${settled.inMilliseconds} ms for '
              '${target.inMilliseconds} ms target',
            );
          }
          return settled;
        }
      }

      // Some builds coalesce the short seeking=true/false pair.
      final fallbackReady =
          (stableSamples >= 1 || positionChanged) &&
          seeking != null &&
          !_isYes(seeking) &&
          (positionChanged || withinTarget) &&
          (!exact || withinTarget);
      if (fallbackReady) {
        await Future<void>.delayed(const Duration(milliseconds: 8));
        if (_disposed || _extractGeneration != extractGen) {
          throw StateError('Preview seek cancelled');
        }
        final settledSeeking = await _readProperty(native, 'seeking');
        final settled = await _readTimePosition(native);
        if (settledSeeking != null &&
            !_isYes(settledSeeking) &&
            settled != null &&
            (!exact || _withinFrame(settled, target))) {
          _record(
            'preview.seek_readiness_fallback',
            message: 'Native seek transition coalesced; position settled',
          );
          return settled;
        }
      }
      final remaining = limit - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      final delay = remaining < const Duration(milliseconds: 12)
          ? remaining
          : const Duration(milliseconds: 12);
      await _waitForObserverOrTimeout(epoch, delay);
    }
    final snapshot = await _readReadinessSnapshot(native);
    _record(
      'preview.seek_readiness_timeout',
      message:
          'Timed out waiting for native seek readiness; '
          'target=${target.inMilliseconds}ms, exact=$exact; $snapshot',
      error: _lastPlayerError,
    );
    throw TimeoutException('Timed out waiting for preview frame readiness');
  }

  Future<void> _verifyBoundedVideoOutput(
    NativePlayer native,
    Duration timeout,
  ) async {
    if (_sourceId != null && _verifiedOutputForSource == _sourceId) {
      return;
    }
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      final raw = await _readProperty(native, 'video-out-params');
      if (raw != null) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final width = decoded['w'];
            final height = decoded['h'];
            if (width is num && height is num && width > 0 && height > 0) {
              if (width > 320 || height > 320) {
                _record(
                  'preview.output_dimensions',
                  message: 'Filtered output exceeds 320x320',
                );
                throw StateError('Preview output exceeds the 320px bound');
              }
              _verifiedOutputForSource = _sourceId;
              return;
            }
          }
        } on FormatException {
          // The native property can be temporarily incomplete while a seek
          // is settling. Continue polling within the request deadline.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    _record(
      'preview.output_dimensions_timeout',
      message: 'Native output dimensions were unavailable before capture',
    );
    throw TimeoutException('Timed out verifying bounded preview dimensions');
  }

  Duration _frameTolerance() {
    final fps = _player?.state.track.video.fps;
    if (fps != null && fps.isFinite && fps > 0) {
      return Duration(microseconds: (1000000 / fps).ceil());
    }
    return const Duration(milliseconds: 100);
  }

  bool _withinFrame(Duration a, Duration b) =>
      (a - b).abs() <= _frameTolerance();

  Future<String?> _readProperty(NativePlayer native, String property) async {
    try {
      return await native.getProperty(property);
    } on Object catch (error) {
      _record(
        'preview.seek_observation',
        message: 'Could not read native $property',
        error: error,
      );
      return null;
    }
  }

  Future<Duration?> _readTimePosition(NativePlayer native) async {
    final value = await _readProperty(native, 'time-pos');
    final position = value == null ? null : _durationFromSeconds(value);
    return position;
  }

  Duration? _durationFromSeconds(String value) {
    final seconds = double.tryParse(value.trim());
    if (seconds == null || !seconds.isFinite || seconds < 0) return null;
    return Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    );
  }

  bool _isYes(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'yes' || normalized == 'true' || normalized == '1';
  }

  void _record(String stage, {String? message, Object? error}) {
    diagnostics?.record(
      stage,
      sourceId: _sourceId == null ? null : MediaSource.redact(_sourceId!),
      message: message == null ? null : MediaSource.redactText(message),
      error: error == null ? null : MediaSource.redactText('$error'),
    );
  }

  @override
  Future<void> pause() async {
    if (_disposed || _player == null) return;
    try {
      await _player?.pause();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _lastCapturedFrame = null;
    _verifiedOutputForSource = null;
    if (_disposed || _player == null) return;
    try {
      await _player?.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _extractGeneration++;
    _notifyObserverPulse();
    _lastCapturedFrame = null;
    _verifiedOutputForSource = null;
    _resolvedSourceInput = null;
    _resolvedPlayerSource = null;
    final player = _player;
    final errorSubscription = _playerErrorSubscription;
    _player = null;
    _playerErrorSubscription = null;
    _videoController = null;

    try {
      await errorSubscription?.cancel();
    } on Object {
      // Continue releasing the native player if stream teardown fails.
    }
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }
}

/// Service that coordinates on-demand seek preview frame extraction, bounded
/// scheduling, and in-memory frame caching.
class SeekPreviewService {
  SeekPreviewService({
    SeekPreviewBackendFactory? backendFactory,
    this.onExtractionStateChange,
    SeekPreviewLRUCache? cache,
    this.diagnostics,
    Duration? idleWorkerTimeout,
    Duration? localIdleWorkerTimeout,
    Duration? localPrewarmDelay,
  }) : _backendFactory =
           backendFactory ??
           (() => MediaKitSeekPreviewBackend(diagnostics: diagnostics)),
       _cache = cache ?? SeekPreviewLRUCache(),
       _idleWorkerTimeout = idleWorkerTimeout ?? defaultIdleWorkerTimeout,
       _localIdleWorkerTimeout =
           localIdleWorkerTimeout ?? defaultLocalIdleWorkerTimeout,
       _localPrewarmDelay = localPrewarmDelay ?? defaultLocalPrewarmDelay {
    _clock.start();
  }

  static const Duration defaultIdleWorkerTimeout = Duration(seconds: 6);
  static const Duration defaultLocalIdleWorkerTimeout = Duration(seconds: 45);
  static const Duration defaultLocalPrewarmDelay = Duration(milliseconds: 350);
  static const Duration _liveSeekThrottle = Duration(milliseconds: 33);
  static const Duration _remoteSeekThrottle = Duration(milliseconds: 100);
  static const Duration _liveSeekDedupTolerance = Duration(milliseconds: 100);

  final Duration _idleWorkerTimeout;
  final Duration _localIdleWorkerTimeout;
  final Duration _localPrewarmDelay;

  final SeekPreviewBackendFactory _backendFactory;
  final void Function(bool extracting)? onExtractionStateChange;
  final SeekPreviewLRUCache _cache;
  final DiagnosticSink? diagnostics;
  final Stopwatch _clock = Stopwatch();

  final ValueNotifier<SeekPreviewState> _stateNotifier =
      ValueNotifier<SeekPreviewState>(const SeekPreviewState());

  ValueListenable<SeekPreviewState> get stateListenable => _stateNotifier;
  SeekPreviewState get state => _stateNotifier.value;
  SeekPreviewLRUCache get cache => _cache;

  int _sourceGeneration = 0;
  int _interactionGeneration = 0;

  String? _currentSource;
  Map<String, String>? _currentHttpHeaders;
  bool _isAudio = false;
  bool _isSeekable = true;
  bool _isSuspended = false;
  bool _isPlaybackBuffering = false;
  bool _interactionActive = false;

  /// Identifies the seek-bar surface that owns the current interaction.
  ///
  /// A player can expose more than one seek bar for the same controller (for
  /// example the shell strip and the player controls). Teardown of one surface
  /// must not tear down an interaction that another surface still owns.
  Object? _interactionOwner;

  bool _hasFailed = false;
  bool _isExtracting = false;
  bool _activeRequestCancelled = false;

  Duration? _activeExtractionTarget;
  int? _activeSourceGeneration;
  int? _activeInteractionGeneration;
  int? _activeIntentRevision;
  bool _activeExtractionExact = false;
  Duration? _latestTarget;
  Duration? _pendingTarget;
  bool _pendingExact = false;
  Duration? _lastExtractionStartTime;
  Duration? _lastLiveSeekTarget;
  bool _lastLiveSeekExact = false;
  int _intentRevision = 0;
  int _requestCounter = 0;
  int? _activeRequestId;

  Timer? _idleWorkerReleaseTimer;
  Timer? _pointerExitGraceTimer;
  Timer? _prewarmTimer;
  Timer? _refineTimer;
  Timer? _playbackHealthTimer;
  Timer? _throttleTimer;

  SeekPreviewBackend? _backend;
  String? _backendSource;
  Map<String, String>? _backendHttpHeaders;
  Future<void>? _backendQueue;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  Duration _now() => _clock.elapsed;

  bool _isStale(int interactionGen, int sourceGen) =>
      _disposed ||
      _interactionGeneration != interactionGen ||
      _sourceGeneration != sourceGen;

  bool _isRequestRelevant({
    required int interactionGen,
    required int sourceGen,
    required int intentRevision,
    required Duration target,
    required bool exact,
  }) {
    if (_isStale(interactionGen, sourceGen)) return false;
    if (intentRevision == _intentRevision) return true;
    return !exact &&
        _latestTarget != null &&
        _latestTarget!.inSeconds == target.inSeconds;
  }

  bool _canRunExtraction({
    required int interactionGen,
    required int sourceGen,
    required int intentRevision,
    required Duration target,
    required bool exact,
  }) {
    final source = _currentSource;
    return !_disposed &&
        _sourceGeneration == sourceGen &&
        _interactionGeneration == interactionGen &&
        _interactionActive &&
        !_isSuspended &&
        !(_isPlaybackBuffering && _isCurrentSourceRemote) &&
        !_isAudio &&
        _isSeekable &&
        source != null &&
        source.isNotEmpty &&
        !_hasFailed &&
        _isRequestRelevant(
          interactionGen: interactionGen,
          sourceGen: sourceGen,
          intentRevision: intentRevision,
          target: target,
          exact: exact,
        );
  }

  bool get _isCurrentSourceRemote {
    final src = _currentSource;
    if (src == null) return false;
    final uri = Uri.tryParse(src);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  Future<T> _enqueueBackendOperation<T>(Future<T> Function() action) {
    final previous = _backendQueue;
    final result = previous == null
        ? Future<T>.sync(action)
        : previous.then<T>((_) => action());
    // Keep the queue usable after a failed operation while preserving [result]
    // for the caller that needs to report that failure. Clearing a settled tail
    // also keeps later teardown work in the caller's current async zone.
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _backendQueue = tail;
    unawaited(
      tail.then((_) {
        if (identical(_backendQueue, tail)) _backendQueue = null;
      }),
    );
    return result;
  }

  Future<T> _withDeadline<T>(Future<T> operation, Duration timeout) {
    final completer = Completer<T>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('Preview deadline expired'));
      }
    });
    operation.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    return completer.future.whenComplete(timer.cancel);
  }

  Duration _remaining(Duration started, Duration budget) {
    final remaining = budget - (_now() - started);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _record(String stage, {String? message, Object? error}) {
    diagnostics?.record(
      stage,
      sourceId: _currentSource == null
          ? null
          : MediaSource.redact(_currentSource!),
      message: message == null ? null : MediaSource.redactText(message),
      error: error == null ? null : MediaSource.redactText('$error'),
    );
  }

  void _cancelActiveRequest() {
    if (_isExtracting) {
      _activeRequestCancelled = true;
      _backend?.cancelExtraction();
    }
  }

  /// Trims cached frames to relieve memory pressure.
  void trimMemory() => _cache.trimMemory();

  bool get _hasReadyLocalLiveTexture =>
      !_isCurrentSourceRemote &&
      _backend != null &&
      _backendSource == _currentSource &&
      _backend!.supportsLiveTexture &&
      _backend!.liveTextureId != null;

  /// Updates the current active media source.
  ///
  /// Increments source generation, cancels in-flight work, invalidates cached
  /// frames immediately, and clears previous results. Local video files are
  /// gently pre-warmed so the first hover renders immediately without loading.
  Future<void> setSource(
    String? source, {
    Map<String, String>? httpHeaders,
    bool isAudio = false,
    bool isSeekable = true,
  }) async {
    if (_disposed) return;
    _sourceGeneration++;
    final sourceGen = _sourceGeneration;
    _currentSource = source;
    _currentHttpHeaders = httpHeaders == null || httpHeaders.isEmpty
        ? null
        : Map<String, String>.unmodifiable(httpHeaders);
    _isAudio = isAudio;
    _isSeekable = isSeekable;
    _cancelActiveRequest();
    _hasFailed = false;
    _interactionActive = false;
    _interactionOwner = null;
    _latestTarget = null;
    _lastLiveSeekTarget = null;
    _lastLiveSeekExact = false;
    _intentRevision++;
    _pendingTarget = null;
    _pendingExact = false;
    _prewarmTimer?.cancel();
    _prewarmTimer = null;
    _refineTimer?.cancel();
    _throttleTimer?.cancel();
    _pointerExitGraceTimer?.cancel();
    _idleWorkerReleaseTimer?.cancel();

    final isRemote = _isCurrentSourceRemote;
    _cache.clear();
    _stateNotifier.value = SeekPreviewState(isRemote: isRemote);

    final shouldKeepWorker =
        source != null && source.isNotEmpty && !isAudio && isSeekable;

    if (!shouldKeepWorker) {
      // Queue teardown behind any in-flight open/seek/capture. Returning before
      // it drains lets the UI adopt the new source immediately.
      unawaited(
        _enqueueBackendOperation(() async {
          final old = _backend;
          _backend = null;
          _backendSource = null;
          _backendHttpHeaders = null;
          if (old != null) {
            try {
              await old.dispose();
            } on Object catch (error) {
              _record(
                'preview.dispose',
                message: 'Old preview player disposal failed',
                error: error,
              );
            }
          }
        }),
      );
      return;
    }

    // Reuse the existing worker across video switches (stopping the old media
    // first so OS file handles are released immediately) to avoid paying
    // libmpv + GPU surface teardown/creation on every playlist item.
    if (_backend != null) {
      unawaited(
        _enqueueBackendOperation(() async {
          if (_sourceGeneration != sourceGen) return;
          final existing = _backend;
          if (existing == null) return;
          _backendSource = null;
          _backendHttpHeaders = null;
          try {
            await existing.stop();
          } on Object catch (error) {
            _record(
              'preview.stop',
              message: 'Could not stop previous preview source',
              error: error,
            );
          }
        }),
      );
    }

    if (!isRemote && !_isSuspended) {
      _scheduleLocalPrewarm(source, sourceGen);
    }
  }

  void _scheduleLocalPrewarm(String source, int sourceGen) {
    _prewarmTimer?.cancel();
    _prewarmTimer = Timer(_localPrewarmDelay, () {
      _prewarmTimer = null;
      unawaited(_runLocalPrewarm(source, sourceGen));
    });
  }

  Future<void> _runLocalPrewarm(String source, int sourceGen) async {
    if (_disposed ||
        _sourceGeneration != sourceGen ||
        _isSuspended ||
        _isAudio ||
        !_isSeekable ||
        _currentSource != source ||
        _isCurrentSourceRemote) {
      return;
    }
    await _enqueueBackendOperation(() async {
      if (_disposed ||
          _sourceGeneration != sourceGen ||
          _isSuspended ||
          _isAudio ||
          !_isSeekable ||
          _currentSource != source ||
          _isCurrentSourceRemote) {
        return;
      }
      if (_backend != null && _backendSource == source) {
        return;
      }
      var backend = _backend;
      if (backend == null) {
        backend = _backendFactory();
        _backend = backend;
      }
      try {
        await backend.open(
          source,
          start: Duration.zero,
          timeout: const Duration(seconds: 5),
        );
        if (!_disposed &&
            _sourceGeneration == sourceGen &&
            _currentSource == source &&
            identical(_backend, backend)) {
          _backendSource = source;
          _scheduleIdleWorkerRelease();
          if (_interactionActive) {
            _restoreLatestIntent();
          }
        }
      } on Object catch (error) {
        _record(
          'preview.prewarm',
          message: 'Local preview pre-warm skipped',
          error: error,
        );
      }
    });
  }

  /// Sets audio state for the current media.
  void setAudio(bool isAudio) {
    if (_isAudio == isAudio) return;
    _isAudio = isAudio;
    if (isAudio) {
      _cancelActiveRequest();
      _prewarmTimer?.cancel();
      _prewarmTimer = null;
      _pointerExitGraceTimer?.cancel();
      _intentRevision++;
      _pendingTarget = null;
      _refineTimer?.cancel();
      _throttleTimer?.cancel();
      _pauseOrStopWorker(stopRemote: _isCurrentSourceRemote);
    }
  }

  /// Sets seekability for the current media.
  void setSeekable(bool isSeekable) {
    if (_isSeekable == isSeekable) return;
    _isSeekable = isSeekable;
    if (!isSeekable) {
      _cancelActiveRequest();
      _prewarmTimer?.cancel();
      _prewarmTimer = null;
      _pointerExitGraceTimer?.cancel();
      _intentRevision++;
      _pendingTarget = null;
      _refineTimer?.cancel();
      _throttleTimer?.cancel();
      _pauseOrStopWorker(stopRemote: _isCurrentSourceRemote);
    }
  }

  /// Called when the pointer moves or scrubs along the seek bar.
  ///
  /// For local files, seeks the live GPU preview texture directly at up to
  /// ~30 fps without loading spinners or JPEG capture overhead. For remote
  /// streams, throttles extraction to <= 1 per 100 ms with LRU caching.
  void onPointerMove(Duration target, {Object? owner}) {
    if (_disposed) return;
    if (owner != null && !identical(owner, _interactionOwner)) {
      // A different seek-bar surface took over the timeline. Invalidate work
      // issued for the outgoing surface before adopting the new owner.
      if (_interactionOwner != null) _interactionGeneration++;
      _interactionOwner = owner;
    }
    _prewarmTimer?.cancel();
    _prewarmTimer = null;
    _idleWorkerReleaseTimer?.cancel();
    _pointerExitGraceTimer?.cancel();

    if (!_interactionActive) {
      _interactionActive = true;
      _interactionGeneration++;
      _hasFailed = false; // Retry only on a new interaction
    }
    _latestTarget = target;
    final revision = ++_intentRevision;
    _scheduleIdleWorkerRelease();

    if (_isAudio ||
        !_isSeekable ||
        _currentSource == null ||
        _currentSource!.isEmpty) {
      _stateNotifier.value = _stateNotifier.value.copyWith(targetTime: target);
      _pendingTarget = null;
      _pendingExact = false;
      return;
    }

    if (_hasFailed) {
      _stateNotifier.value = _stateNotifier.value.copyWith(targetTime: target);
      return;
    }

    // Fast path for local files: direct live texture seeking with zero loading
    // spinner and fine-grained 30 fps scrubbing.
    if (!_isCurrentSourceRemote) {
      if (_hasReadyLocalLiveTexture) {
        final textureId = _backend!.liveTextureId!;
        final currentState = _stateNotifier.value;
        if (currentState.liveTextureId != textureId ||
            currentState.status != SeekPreviewStatus.ready ||
            currentState.isUpdating ||
            currentState.isRemote) {
          _stateNotifier.value = currentState.copyWith(
            status: SeekPreviewStatus.ready,
            liveTextureId: textureId,
            targetTime: target,
            isUpdating: false,
            isRemote: false,
            clearError: true,
          );
        }

        if (_lastLiveSeekTarget != null &&
            (_lastLiveSeekTarget! - target).abs() < _liveSeekDedupTolerance &&
            !_pendingExact) {
          _scheduleIdleRefinement(target);
          return;
        }

        _pendingTarget = target;
        _pendingExact = false;
        _scheduleIdleRefinement(target);
        _pumpScheduler();
        return;
      }

      // Check LRU cache (used if a backend does not expose a live texture).
      if (_showCachedFrame(target, revision)) return;

      // Local files never enter a visual loading/spinner state.
      _pendingTarget = target;
      _pendingExact = false;
      final currentState = _stateNotifier.value;
      if (currentState.isUpdating ||
          currentState.status == SeekPreviewStatus.loading ||
          currentState.isRemote) {
        _stateNotifier.value = currentState.copyWith(
          targetTime: target,
          isUpdating: false,
          isRemote: false,
          status: currentState.hasVisual
              ? SeekPreviewStatus.ready
              : SeekPreviewStatus.idle,
        );
      }
      _scheduleIdleRefinement(target);
      _pumpScheduler();
      return;
    }

    // Remote stream path: check LRU cache first.
    if (_showCachedFrame(target, revision)) return;

    // Deduplicate requests into 1-second buckets while moving
    final currentBucket = target.inSeconds;
    if (_isExtracting &&
        !_activeRequestCancelled &&
        _activeExtractionTarget?.inSeconds == currentBucket &&
        _activeSourceGeneration == _sourceGeneration &&
        _activeInteractionGeneration == _interactionGeneration &&
        !_activeExtractionExact &&
        _activeRequestId != null) {
      _pendingTarget = null;
      _pendingExact = false;
      _stateNotifier.value = _stateNotifier.value.copyWith(
        targetTime: target,
        isUpdating: true,
        isRemote: true,
      );
      _scheduleIdleRefinement(target);
      return;
    }

    if (_pendingTarget?.inSeconds == currentBucket && !_pendingExact) {
      _pendingTarget = target;
      _stateNotifier.value = _stateNotifier.value.copyWith(
        targetTime: target,
        isUpdating: true,
        isRemote: true,
      );
      _scheduleIdleRefinement(target);
      return;
    }

    // Cancel in-flight extraction if user scrubbed to a different time bucket
    if (_isExtracting &&
        (_activeExtractionTarget == null ||
            _activeExtractionTarget!.inSeconds != currentBucket)) {
      _cancelActiveRequest();
    }

    // Replace pending target with newest pointer position
    _pendingTarget = target;
    _pendingExact = false;
    _stateNotifier.value = _stateNotifier.value.copyWith(
      targetTime: target,
      isUpdating: true,
      isRemote: true,
      status: _stateNotifier.value.currentFrame != null
          ? SeekPreviewStatus.ready
          : SeekPreviewStatus.loading,
    );

    _scheduleIdleRefinement(target);
    _pumpScheduler();
  }

  bool _showCachedFrame(Duration target, int revision) {
    final cached = _cache.get(target, exactOnly: false);
    if (cached == null) return false;
    final capturedAtTarget = cached.capturedTime == target;
    final alreadyExact =
        (cached.quality == SeekPreviewQuality.exact &&
            cached.requestedTime == target) ||
        capturedAtTarget;
    late final SeekPreviewFrame frame;
    if (alreadyExact) {
      frame = cached.quality == SeekPreviewQuality.exact
          ? cached
          : SeekPreviewFrame(
              bytes: cached.bytes,
              requestedTime: target,
              capturedTime: cached.capturedTime,
              quality: SeekPreviewQuality.exact,
            );
    } else if (cached.quality == SeekPreviewQuality.exact) {
      frame = SeekPreviewFrame(
        bytes: cached.bytes,
        requestedTime: cached.requestedTime,
        capturedTime: cached.capturedTime,
        quality: SeekPreviewQuality.keyframe,
      );
    } else {
      frame = cached;
    }
    if (frame.quality == SeekPreviewQuality.exact) _cache.put(frame);

    _pendingTarget = null;
    _pendingExact = false;
    _throttleTimer?.cancel();
    _refineTimer?.cancel();
    _stateNotifier.value = _stateNotifier.value.copyWith(
      status: SeekPreviewStatus.ready,
      currentFrame: frame,
      targetTime: target,
      isUpdating: false,
      clearError: true,
    );

    if (!alreadyExact) {
      final interactionGen = _interactionGeneration;
      final sourceGen = _sourceGeneration;
      _refineTimer = Timer(const Duration(milliseconds: 250), () {
        _scheduleExactRefinement(target, interactionGen, sourceGen, revision);
      });
    }
    return true;
  }

  void _scheduleIdleRefinement(Duration target) {
    _refineTimer?.cancel();
    final interactionGen = _interactionGeneration;
    final sourceGen = _sourceGeneration;
    final revision = _intentRevision;
    _refineTimer = Timer(const Duration(milliseconds: 250), () {
      _scheduleExactRefinement(target, interactionGen, sourceGen, revision);
    });
  }

  void _scheduleExactRefinement(
    Duration target,
    int interactionGen,
    int sourceGen,
    int intentRevision,
  ) {
    if (_isStale(interactionGen, sourceGen) ||
        _intentRevision != intentRevision ||
        _hasFailed ||
        _isSuspended ||
        (_isPlaybackBuffering && _isCurrentSourceRemote)) {
      return;
    }
    final cachedExact = _cache.get(target, exactOnly: true);
    if (cachedExact != null) {
      _stateNotifier.value = _stateNotifier.value.copyWith(
        status: SeekPreviewStatus.ready,
        currentFrame: cachedExact,
        targetTime: target,
        isUpdating: false,
      );
      return;
    }

    _pendingTarget = target;
    _pendingExact = true;
    _pumpScheduler();
  }

  void _pumpScheduler() {
    if (_disposed ||
        !_interactionActive ||
        _isAudio ||
        !_isSeekable ||
        _isExtracting ||
        _isSuspended ||
        (_isPlaybackBuffering && _isCurrentSourceRemote) ||
        _currentSource == null ||
        _latestTarget == null ||
        _hasFailed) {
      return;
    }

    if (_pendingTarget == null) return;

    final now = _now();
    final lastStart = _lastExtractionStartTime;
    final elapsed = lastStart == null ? null : now - lastStart;
    final throttle = !_isCurrentSourceRemote
        ? _liveSeekThrottle
        : _remoteSeekThrottle;
    if (elapsed != null && elapsed < throttle) {
      _throttleTimer?.cancel();
      _throttleTimer = Timer(throttle - elapsed, _pumpScheduler);
      return;
    }

    final target = _pendingTarget!;
    final exact = _pendingExact;
    _pendingTarget = null;
    _pendingExact = false;
    _activeExtractionTarget = target;
    _activeSourceGeneration = _sourceGeneration;
    _activeInteractionGeneration = _interactionGeneration;
    _activeIntentRevision = _intentRevision;
    _activeExtractionExact = exact;
    _activeRequestCancelled = false;
    _isExtracting = true;
    _lastExtractionStartTime = now;
    final requestId = ++_requestCounter;
    _activeRequestId = requestId;
    onExtractionStateChange?.call(true);

    unawaited(
      _runExtraction(
        target,
        exact,
        _interactionGeneration,
        _sourceGeneration,
        _intentRevision,
        requestId,
      ),
    );
  }

  Future<void> _runExtraction(
    Duration target,
    bool exact,
    int interactionGen,
    int sourceGen,
    int intentRevision,
    int requestId,
  ) async {
    final started = _now();
    final warm = _backend != null && _backendSource == _currentSource;
    final deadline = warm
        ? const Duration(seconds: 3)
        : _isCurrentSourceRemote
        // A cold remote request includes manifest resolution and initial
        // media readiness before its bounded seek/capture stage.
        ? const Duration(seconds: 8)
        : const Duration(seconds: 5);
    var stage = 'open';
    var requestCancelled = false;
    bool canRun() =>
        !requestCancelled &&
        !(_activeRequestId == requestId && _activeRequestCancelled) &&
        _canRunExtraction(
          interactionGen: interactionGen,
          sourceGen: sourceGen,
          intentRevision: intentRevision,
          target: target,
          exact: exact,
        );
    void cancelRequest() {
      requestCancelled = true;
      if (_activeRequestId == requestId) _activeRequestCancelled = true;
    }

    var liveSeekHandled = false;
    final operation = _enqueueBackendOperation<SeekPreviewFrame?>(() async {
      if (!canRun()) {
        cancelRequest();
        return null;
      }
      var backend = _backend;
      final sourceMatchesBackend =
          _backendSource == _currentSource &&
          mapEquals(_backendHttpHeaders, _currentHttpHeaders);
      if (backend != null && _backendSource != null && !sourceMatchesBackend) {
        _backendSource = null;
        _backendHttpHeaders = null;
        try {
          await backend.stop();
        } on Object catch (error) {
          _record(
            'preview.stop',
            message: 'Previous source stop failed',
            error: error,
          );
        }
        if (!canRun()) {
          cancelRequest();
          return null;
        }
      }

      if (backend == null) {
        backend = _backendFactory();
        _backend = backend;
      }
      var openedAtTarget = false;
      if (_backendSource != _currentSource ||
          !mapEquals(_backendHttpHeaders, _currentHttpHeaders)) {
        stage = 'open';
        final openingSource = _currentSource!;
        final openingHeaders = _currentHttpHeaders;
        final openStart = _latestTarget ?? target;
        await backend.open(
          openingSource,
          httpHeaders: openingHeaders,
          start: openStart,
          timeout: _remaining(started, deadline),
        );
        if (!_disposed &&
            _sourceGeneration == sourceGen &&
            _currentSource == openingSource &&
            mapEquals(_currentHttpHeaders, openingHeaders)) {
          _backendSource = openingSource;
          _backendHttpHeaders = openingHeaders;
          openedAtTarget = true;
        }
        if (!canRun()) {
          cancelRequest();
          return null;
        }
      }
      if (!canRun()) {
        cancelRequest();
        return null;
      }

      // Local live-texture path: seek the GPU texture directly with zero
      // screenshot/JPEG/isolate overhead.
      if (!_isCurrentSourceRemote &&
          backend.supportsLiveTexture &&
          backend.liveTextureId != null) {
        final effectiveTarget = exact ? target : (_latestTarget ?? target);
        final alreadyAtTarget =
            openedAtTarget &&
            !exact &&
            (effectiveTarget - target).abs() < _liveSeekDedupTolerance;
        final alreadyExactAtTarget =
            exact &&
            _lastLiveSeekExact &&
            _lastLiveSeekTarget == effectiveTarget;
        if (!alreadyAtTarget && !alreadyExactAtTarget) {
          stage = exact ? 'exact live seek' : 'keyframe live seek';
          await backend.seekLive(effectiveTarget, exact: exact);
        }
        _lastLiveSeekTarget = effectiveTarget;
        _lastLiveSeekExact = exact;
        liveSeekHandled = true;
        if (!_disposed &&
            _sourceGeneration == sourceGen &&
            _interactionGeneration == interactionGen &&
            !_hasFailed) {
          final textureId = backend.liveTextureId;
          if (textureId != null) {
            _stateNotifier.value = _stateNotifier.value.copyWith(
              status: SeekPreviewStatus.ready,
              liveTextureId: textureId,
              targetTime: effectiveTarget,
              isUpdating: false,
              isRemote: false,
              clearError: true,
            );
          }
        }
        return null;
      }

      stage = exact
          ? 'exact seek/readiness/capture'
          : 'keyframe seek/readiness/capture';
      return backend.extractFrame(
        target,
        exact: exact,
        timeout: _remaining(started, deadline),
      );
    });

    try {
      final frame = await _withDeadline(operation, deadline);
      if (liveSeekHandled ||
          requestCancelled ||
          (_activeRequestId == requestId && _activeRequestCancelled)) {
        return;
      }

      if (frame != null && frame.bytes.isNotEmpty) {
        if (!_isStale(interactionGen, sourceGen)) _cache.put(frame);
        if (_isRequestRelevant(
              interactionGen: interactionGen,
              sourceGen: sourceGen,
              intentRevision: intentRevision,
              target: target,
              exact: exact,
            ) &&
            !_hasFailed) {
          final currentTarget = _latestTarget ?? target;
          final exactCache = frame.quality == SeekPreviewQuality.keyframe
              ? _cache.get(currentTarget, exactOnly: true)
              : null;
          if (exactCache != null) return;
          _stateNotifier.value = _stateNotifier.value.copyWith(
            status: SeekPreviewStatus.ready,
            currentFrame: frame,
            targetTime: currentTarget,
            isUpdating: _isCurrentSourceRemote && _pendingTarget != null,
            isRemote: _isCurrentSourceRemote,
            clearError: true,
          );
        }
      } else {
        _markFailure(
          'Preview unavailable',
          interactionGen,
          sourceGen,
          intentRevision,
          target,
          exact,
        );
      }
    } on TimeoutException catch (error) {
      if (requestCancelled ||
          (_activeRequestId == requestId && _activeRequestCancelled)) {
        cancelRequest();
        return;
      }
      cancelRequest();
      _record(
        'preview.timeout',
        message:
            'Preview request timed out during $stage after '
            '${(_now() - started).inMilliseconds} ms',
        error: error,
      );
      _markFailure(
        'Preview unavailable',
        interactionGen,
        sourceGen,
        intentRevision,
        target,
        exact,
      );
      _finishLogicalRequest(requestId);
      // Future.timeout does not cancel native work. Keep the backend queue
      // occupied until that work drains; stop/dispose are queued behind it.
      try {
        await operation;
      } on Object {
        // The request already reported its bounded failure to the UI.
      }
    } on Object catch (error) {
      if (requestCancelled ||
          (_activeRequestId == requestId && _activeRequestCancelled)) {
        cancelRequest();
        return;
      }
      _record(
        'preview.failure',
        message: 'Preview request failed during $stage',
        error: error,
      );
      _markFailure(
        'Preview unavailable',
        interactionGen,
        sourceGen,
        intentRevision,
        target,
        exact,
      );
    } finally {
      _finishLogicalRequest(requestId);
      if (!_disposed) _pumpScheduler();
    }
  }

  void _finishLogicalRequest(int requestId) {
    if (_activeRequestId != requestId) return;
    _isExtracting = false;
    _activeExtractionTarget = null;
    _activeSourceGeneration = null;
    _activeInteractionGeneration = null;
    _activeIntentRevision = null;
    _activeExtractionExact = false;
    _activeRequestCancelled = false;
    _activeRequestId = null;
    onExtractionStateChange?.call(false);
  }

  void _markFailure(
    String message,
    int interactionGen,
    int sourceGen,
    int intentRevision,
    Duration target,
    bool exact,
  ) {
    if (!_isRequestRelevant(
          interactionGen: interactionGen,
          sourceGen: sourceGen,
          intentRevision: intentRevision,
          target: target,
          exact: exact,
        ) ||
        !_interactionActive ||
        _isSuspended ||
        (_isPlaybackBuffering && _isCurrentSourceRemote) ||
        _isAudio ||
        !_isSeekable) {
      return;
    }
    _hasFailed = true;
    _pendingTarget = null;
    _pendingExact = false;
    _refineTimer?.cancel();
    _record('preview.failure', message: message);
    _stateNotifier.value = _stateNotifier.value.copyWith(
      status: SeekPreviewStatus.failed,
      errorMessage: message,
      isUpdating: false,
    );
  }

  /// Pauses on pointer exit, retains remote media for a short reentry grace,
  /// then releases the paused worker after the idle timeout.
  ///
  /// Passing [owner] from a seek-bar surface prevents a stale surface from
  /// ending an interaction that another surface now owns.
  void onPointerExit({Object? owner}) {
    if (_disposed) return;
    if (owner != null &&
        _interactionOwner != null &&
        !identical(owner, _interactionOwner)) {
      return;
    }
    _interactionOwner = null;
    _interactionActive = false;
    _interactionGeneration++;
    _cancelActiveRequest();
    final exitInteractionGeneration = _interactionGeneration;
    final exitSourceGeneration = _sourceGeneration;
    _intentRevision++;
    _latestTarget = null;
    _pendingTarget = null;
    _pendingExact = false;
    _refineTimer?.cancel();
    _throttleTimer?.cancel();

    _pauseOrStopWorker(
      stopRemote: false,
      expectedInteractionGeneration: exitInteractionGeneration,
      expectedSourceGeneration: exitSourceGeneration,
    );

    _pointerExitGraceTimer?.cancel();
    if (_isCurrentSourceRemote) {
      _pointerExitGraceTimer = Timer(const Duration(milliseconds: 400), () {
        _pointerExitGraceTimer = null;
        _pauseOrStopWorker(
          stopRemote: true,
          expectedInteractionGeneration: exitInteractionGeneration,
          expectedSourceGeneration: exitSourceGeneration,
        );
      });
    }

    _scheduleIdleWorkerRelease();
  }

  /// Detaches a seek-bar surface during widget teardown.
  ///
  /// Unlike [onPointerExit], teardown does not open a re-entry grace window and
  /// does not arm an idle-release timer. The interaction's timers are cancelled
  /// and any worker that exists or is being created is released promptly.
  /// Passing [owner] keeps an outgoing widget from cancelling an interaction
  /// that a different seek-bar surface now owns.
  void detachInteraction([Object? owner]) {
    if (_disposed) return;
    if (owner != null &&
        _interactionOwner != null &&
        !identical(owner, _interactionOwner)) {
      return;
    }
    _interactionOwner = null;
    _interactionActive = false;
    _interactionGeneration++;
    _cancelActiveRequest();
    _intentRevision++;
    _latestTarget = null;
    _pendingTarget = null;
    _pendingExact = false;
    _refineTimer?.cancel();
    _refineTimer = null;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _pointerExitGraceTimer?.cancel();
    _pointerExitGraceTimer = null;
    _prewarmTimer?.cancel();
    _prewarmTimer = null;
    _idleWorkerReleaseTimer?.cancel();
    _idleWorkerReleaseTimer = null;
    // Capture the generation established by this detach. If another seek bar
    // takes over before the queued release runs, that release must not dispose
    // the worker the incoming surface is now using.
    final detachInteractionGeneration = _interactionGeneration;
    final detachSourceGeneration = _sourceGeneration;
    // Teardown has no re-entry grace period: release the worker now instead of
    // leaving a long-lived idle timer behind for a widget that no longer exists.
    unawaited(
      _releaseWorker(
        force: true,
        expectedInteractionGeneration: detachInteractionGeneration,
        expectedSourceGeneration: detachSourceGeneration,
      ),
    );
  }

  void _scheduleIdleWorkerRelease() {
    _idleWorkerReleaseTimer?.cancel();
    // Hovering without a worker (for example before pre-warm creates one) must
    // not leave a timer pending. Pre-warm arms its own release once it adopts
    // a worker, so there is always cleanup for a worker that exists.
    if (_disposed || _backend == null) return;
    final timeout = _isCurrentSourceRemote
        ? _idleWorkerTimeout
        : _localIdleWorkerTimeout;
    final releaseInteractionGeneration = _interactionGeneration;
    final releaseSourceGeneration = _sourceGeneration;
    final releaseIntentRevision = _intentRevision;
    _idleWorkerReleaseTimer = Timer(timeout, () {
      _idleWorkerReleaseTimer = null;
      unawaited(
        _releaseWorker(
          force: true,
          expectedInteractionGeneration: releaseInteractionGeneration,
          expectedSourceGeneration: releaseSourceGeneration,
          expectedIntentRevision: releaseIntentRevision,
        ),
      );
    });
  }

  void _pauseOrStopWorker({
    required bool stopRemote,
    int? expectedInteractionGeneration,
    int? expectedSourceGeneration,
  }) {
    final backend = _backend;
    if (backend == null) return;
    unawaited(
      _enqueueBackendOperation(() async {
        if (!identical(_backend, backend)) return;
        if (expectedInteractionGeneration != null &&
            (_interactionActive ||
                _interactionGeneration != expectedInteractionGeneration ||
                _sourceGeneration != expectedSourceGeneration)) {
          return;
        }
        try {
          if (stopRemote) {
            await backend.stop();
            _backendSource = null;
            _backendHttpHeaders = null;
          } else {
            await backend.pause();
          }
        } on Object catch (error) {
          _record(
            stopRemote ? 'preview.stop' : 'preview.pause',
            message: 'Could not quiet preview worker',
            error: error,
          );
        }
      }),
    );
  }

  Future<void> _releaseWorker({
    bool force = false,
    int? expectedInteractionGeneration,
    int? expectedSourceGeneration,
    int? expectedIntentRevision,
  }) async {
    if (_disposed) return;
    // Check inside the queue: a pre-warm operation that has not created its
    // backend yet may still be ahead of us, and a detach must also release a
    // worker that is created after the detach request was issued. The optional
    // generation guards retire only the worker belonging to the interaction
    // that requested this release; a later seek bar that took over keeps its
    // worker. Explicit suspend/dispose callers omit the guards.
    await _enqueueBackendOperation(() async {
      if (_disposed) return;
      if (expectedInteractionGeneration != null &&
          expectedInteractionGeneration != _interactionGeneration) {
        return;
      }
      if (expectedSourceGeneration != null &&
          expectedSourceGeneration != _sourceGeneration) {
        return;
      }
      if (expectedIntentRevision != null &&
          expectedIntentRevision != _intentRevision) {
        return;
      }
      final backend = _backend;
      if (backend == null) return;
      if (_interactionActive && !force) return;
      if (force) _interactionActive = false;
      _backend = null;
      _backendSource = null;
      _backendHttpHeaders = null;
      _lastLiveSeekTarget = null;
      _lastLiveSeekExact = false;
      if (!_disposed && _stateNotifier.value.liveTextureId != null) {
        _stateNotifier.value = _stateNotifier.value.copyWith(
          clearLiveTexture: true,
        );
      }
      try {
        await backend.dispose();
      } on Object catch (error) {
        _record(
          'preview.dispose',
          message: 'Idle worker disposal failed',
          error: error,
        );
      }
    });
  }

  /// Suspends preview work (e.g. during minimize).
  void suspend() {
    if (_disposed) return;
    _cancelActiveRequest();
    _prewarmTimer?.cancel();
    _prewarmTimer = null;
    _pointerExitGraceTimer?.cancel();
    _idleWorkerReleaseTimer?.cancel();
    _isSuspended = true;
    if (_latestTarget != null) {
      _pendingTarget = _latestTarget;
    }
    _refineTimer?.cancel();
    _throttleTimer?.cancel();
    if (_stateNotifier.value.liveTextureId != null) {
      _stateNotifier.value = _stateNotifier.value.copyWith(
        clearLiveTexture: true,
      );
    }
    _pauseOrStopWorker(stopRemote: _isCurrentSourceRemote);
    unawaited(_releaseWorker(force: true));
  }

  /// Resumes preview work after minimize/unpause.
  void resume() {
    if (_disposed) return;
    _isSuspended = false;
    if (_interactionActive) {
      _restoreLatestIntent();
    } else if (!_isCurrentSourceRemote &&
        !_isAudio &&
        _isSeekable &&
        _currentSource != null &&
        _currentSource!.isNotEmpty &&
        _backendSource != _currentSource) {
      _scheduleLocalPrewarm(_currentSource!, _sourceGeneration);
    }
  }

  /// Coordinates with main playback buffering.
  ///
  /// Suspends remote preview work whenever main playback buffers; resumes only
  /// after playback has remained healthy for one second and preview interaction
  /// is still active.
  void onPlaybackBuffering(bool buffering) {
    if (_disposed) return;
    if (buffering) {
      _pointerExitGraceTimer?.cancel();
      _isPlaybackBuffering = true;
      _playbackHealthTimer?.cancel();
      _playbackHealthTimer = null;
      if (_isCurrentSourceRemote) {
        _cancelActiveRequest();
        if (_latestTarget != null) _pendingTarget = _latestTarget;
        _refineTimer?.cancel();
        _throttleTimer?.cancel();
        _pauseOrStopWorker(stopRemote: true);
      }
    } else {
      _playbackHealthTimer?.cancel();
      _playbackHealthTimer = Timer(const Duration(seconds: 1), () {
        _isPlaybackBuffering = false;
        if (!_isSuspended) _restoreLatestIntent();
      });
    }
  }

  void _restoreLatestIntent() {
    final target = _latestTarget;
    if (!_interactionActive ||
        target == null ||
        _disposed ||
        _isSuspended ||
        _isAudio ||
        !_isSeekable ||
        _currentSource == null ||
        _currentSource!.isEmpty ||
        _hasFailed) {
      return;
    }

    if (_showCachedFrame(target, _intentRevision)) return;

    final activeTarget = _activeExtractionTarget;
    final activeRequestMatches =
        _isExtracting &&
        !_activeRequestCancelled &&
        _activeSourceGeneration == _sourceGeneration &&
        _activeInteractionGeneration == _interactionGeneration &&
        activeTarget != null &&
        activeTarget.inSeconds == target.inSeconds &&
        (!_activeExtractionExact ||
            (activeTarget == target &&
                _activeIntentRevision == _intentRevision));
    if (activeRequestMatches) {
      _pendingTarget = null;
      _pendingExact = false;
      _stateNotifier.value = _stateNotifier.value.copyWith(
        targetTime: target,
        isUpdating: _isCurrentSourceRemote,
      );
      if (!_activeExtractionExact) _scheduleIdleRefinement(target);
      return;
    }

    final activeExactForSameBucket =
        _isExtracting &&
        _activeExtractionExact &&
        _activeExtractionTarget?.inSeconds == target.inSeconds;
    _pendingTarget = target;
    _pendingExact = activeExactForSameBucket;
    if (!activeExactForSameBucket) _scheduleIdleRefinement(target);
    _pumpScheduler();
  }

  /// Disposes the service, all active timers, caches, and backend players.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    _cancelActiveRequest();
    _interactionGeneration++;
    _sourceGeneration++;
    _intentRevision++;
    _interactionActive = false;
    _interactionOwner = null;
    _latestTarget = null;
    _pendingTarget = null;
    _pendingExact = false;
    _idleWorkerReleaseTimer?.cancel();
    _pointerExitGraceTimer?.cancel();
    _prewarmTimer?.cancel();
    _refineTimer?.cancel();
    _throttleTimer?.cancel();
    _playbackHealthTimer?.cancel();
    _cache.clear();
    _stateNotifier.dispose();
    final future = _enqueueBackendOperation(() async {
      final old = _backend;
      _backend = null;
      _backendSource = null;
      if (old == null) return;
      try {
        await old.dispose();
      } on Object catch (error) {
        _record(
          'preview.dispose',
          message: 'Preview worker disposal failed',
          error: error,
        );
      }
    });
    _disposeFuture = future;
    return future;
  }
}
