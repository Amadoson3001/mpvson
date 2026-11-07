import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/models/graphics_settings.dart';
import '../../domain/models/media_catalog.dart';
import '../../domain/models/media_entry.dart';
import '../../domain/models/media_kind.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/playback_chapter.dart';
import '../../domain/models/playback_settings.dart';
import '../../domain/models/video_output_policy.dart';
import 'diagnostic_log.dart';
import 'native_media_events.dart';
import 'playback_source_identity.dart';
import 'snapshot_emitter.dart';

/// The playback state a native engine event describes, before identity stamping.
///
/// Kept pure so the transition rules are verified without a native engine. The
/// duration belongs to the engine's own property rather than to one load: it
/// survives a `started` event because media_kit reports a changed duration on
/// its stream, while clearing it here stranded a source at zero when the engine
/// re-reported the same path without a new duration notification.
PlaybackSnapshot applyNativeEvent(
  PlaybackSnapshot state,
  NativeMediaEvent event,
) {
  switch (event.kind) {
    case NativeMediaEventKind.started:
      return state.copyWith(
        isBuffering: true,
        completed: false,
        position: Duration.zero,
        chapters: const <PlaybackChapter>[],
      );
    case NativeMediaEventKind.loaded:
      return state.copyWith(isBuffering: false);
    case NativeMediaEventKind.ended:
      return state.copyWith(
        completed: true,
        isPlaying: false,
        isBuffering: false,
      );
    case NativeMediaEventKind.seekableChanged:
      return state.copyWith(seekable: event.seekable);
    case NativeMediaEventKind.chaptersChanged:
      return state.copyWith(chapters: event.chapters);
  }
}

/// Immutable snapshot emitted whenever libmpv reports new playback state.
class PlaybackSnapshot {
  const PlaybackSnapshot({
    this.isPlaying = false,
    this.isBuffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.seekable = true,
    this.volume = 100,
    this.rate = 1,
    this.shuffle = false,
    this.videoTracks = const <VideoTrack>[],
    this.audioTracks = const <AudioTrack>[],
    this.subtitleTracks = const <SubtitleTrack>[],
    this.currentAudioTrack = const AudioTrack('auto', null, null),
    this.currentSubtitleTrack = const SubtitleTrack('auto', null, null),
    this.chapters = const <PlaybackChapter>[],
    this.error,
    this.sourceStart = 0,
    this.nativeSource,
    this.sourceLoaded = false,
  });

  final bool isPlaying;
  final bool isBuffering;
  final bool completed;
  final Duration position;
  final Duration duration;
  final bool seekable;
  bool get isSeekable => seekable && duration > Duration.zero;
  final double volume;
  final double rate;
  final bool shuffle;
  final List<VideoTrack> videoTracks;
  final List<AudioTrack> audioTracks;
  final List<SubtitleTrack> subtitleTracks;
  final AudioTrack currentAudioTrack;
  final SubtitleTrack currentSubtitleTrack;

  /// Chapter markers reported for the attached source, ordered by start time.
  final List<PlaybackChapter> chapters;
  final String? error;

  /// Load attempt this snapshot belongs to.
  ///
  /// Snapshots stamped with a boundary below the attempt the view model is
  /// waiting for describe an earlier source and must be ignored.
  final int sourceStart;

  /// Canonical identity of the source the native engine has attached, when the
  /// platform reports it.
  final String? nativeSource;

  /// Whether the native engine confirmed the attached source is open.
  ///
  /// Position and duration are only meaningful while this is true; they may
  /// still describe the previous source during a load.
  final bool sourceLoaded;

  PlaybackSnapshot copyWith({
    bool? isPlaying,
    bool? isBuffering,
    bool? completed,
    Duration? position,
    Duration? duration,
    bool? seekable,
    double? volume,
    double? rate,
    bool? shuffle,
    List<VideoTrack>? videoTracks,
    List<AudioTrack>? audioTracks,
    List<SubtitleTrack>? subtitleTracks,
    AudioTrack? currentAudioTrack,
    SubtitleTrack? currentSubtitleTrack,
    List<PlaybackChapter>? chapters,
    String? error,
    bool clearError = false,
    int? sourceStart,
    String? nativeSource,
    bool clearNativeSource = false,
    bool? sourceLoaded,
  }) {
    return PlaybackSnapshot(
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      completed: completed ?? this.completed,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      seekable: seekable ?? this.seekable,
      volume: volume ?? this.volume,
      rate: rate ?? this.rate,
      shuffle: shuffle ?? this.shuffle,
      videoTracks: videoTracks ?? this.videoTracks,
      audioTracks: audioTracks ?? this.audioTracks,
      subtitleTracks: subtitleTracks ?? this.subtitleTracks,
      currentAudioTrack: currentAudioTrack ?? this.currentAudioTrack,
      currentSubtitleTrack: currentSubtitleTrack ?? this.currentSubtitleTrack,
      chapters: chapters ?? this.chapters,
      error: clearError ? null : error ?? this.error,
      sourceStart: sourceStart ?? this.sourceStart,
      nativeSource: clearNativeSource
          ? null
          : nativeSource ?? this.nativeSource,
      sourceLoaded: sourceLoaded ?? this.sourceLoaded,
    );
  }
}

/// Media playback boundary used by the view model.
///
/// The default factory creates a media_kit/libmpv-backed implementation. Tests
/// can implement this interface to drive the controller without loading the
/// native engine.
abstract interface class PlaybackService {
  factory PlaybackService({
    Player? player,
    VideoController? videoController,
    NativeMediaEvents? nativeEvents,
    DiagnosticSink? diagnostics,
  }) = MediaKitPlaybackService;

  Player get player;
  VideoController get videoController;
  PlaybackSnapshot get state;
  Stream<PlaybackSnapshot> get states;
  String get engineVersion;
  VideoOutputPolicy get videoOutputPolicy;

  /// Applies video output sizing and visibility policy.
  void applyVideoOutputPolicy(VideoOutputPolicy policy);

  /// One-time bootstrap work: caches engine metadata and starts native event
  /// observation. Playback readiness must not depend on this completing.
  Future<void> prepare();

  Future<void> open(String path, {bool play = true});
  Future<void> stop();
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double value);
  Future<void> setRate(double value);
  Future<void> setShuffle(bool value);
  Future<void> setRepeatMode(String value);
  Future<void> setAudioTrack(AudioTrack track);
  Future<void> setSubtitleTrack(SubtitleTrack track);
  Future<void> loadSubtitle(String path);
  Future<void> dispose();
}

/// Optional runtime tuning supported by native mpv playback.
///
/// Kept separate from [PlaybackService] so test and alternate playback
/// implementations do not have to expose engine-specific controls.
abstract interface class PlaybackSettingsCapability {
  Future<PlaybackSettingsApplyResult> applyPlaybackSettings(
    PlaybackSettings settings,
  );
}

/// Runtime graphics controls that require native playback support.
abstract interface class GraphicsSettingsCapability {
  void applyGraphicsSettings(GraphicsSettings settings);
}

/// Best-effort release of video-output device memory.
abstract interface class VideoMemoryCapability {
  Future<void> trimVideoMemory();
}

/// Reports which requested mpv properties matched after the write completed.
class PlaybackSettingsApplyResult {
  const PlaybackSettingsApplyResult({
    this.supported = true,
    this.appliedProperties = const <String>[],
    this.failedProperties = const <String>[],
    this.superseded = false,
    this.reason,
  });

  final bool supported;
  final List<String> appliedProperties;
  final List<String> failedProperties;
  final bool superseded;
  final String? reason;

  bool get succeeded => !superseded && supported && failedProperties.isEmpty;
}

/// Production implementation backed by media_kit and its bundled libmpv.
class MediaKitPlaybackService
    implements
        PlaybackService,
        PlaybackSettingsCapability,
        GraphicsSettingsCapability,
        VideoMemoryCapability {
  MediaKitPlaybackService({
    Player? player,
    VideoController? videoController,
    NativeMediaEvents? nativeEvents,
    DiagnosticSink? diagnostics,
    @visibleForTesting
    Future<void> Function(String property, String value)?
    propertyWriterForTesting,
  }) : _player =
           player ??
           Player(
             configuration: const PlayerConfiguration(
               title: 'Mpvson',
               libass: true,
               bufferSize: 16 * 1024 * 1024,
             ),
           ),
       _nativeEvents = nativeEvents,
       _ownsNativeEvents = nativeEvents == null {
    // Assigned here rather than in the initializer list so the public parameter
    // name stays `diagnostics`; named parameters cannot be private.
    _diagnostics = diagnostics;
    _videoController = videoController;
    _propertyWriter = propertyWriterForTesting ?? _writeNativeProperty;
    _state = _snapshotFrom(
      _player.state,
    ).copyWith(sourceStart: 0, clearNativeSource: true);
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      _listen<bool>(
        _player.stream.playing,
        (state, value) => state.copyWith(
          isPlaying: value,
          isBuffering: value && !_player.state.buffering
              ? false
              : state.isBuffering,
        ),
      ),
      _listen<bool>(
        _player.stream.buffering,
        (state, value) => state.copyWith(isBuffering: value),
      ),
      _listen<bool>(
        _player.stream.completed,
        (state, value) => state.copyWith(completed: value),
      ),
      _listen<Duration>(
        _player.stream.position,
        (state, value) => state.copyWith(position: value),
      ),
      _listen<Duration>(
        _player.stream.duration,
        (state, value) => state.copyWith(duration: value),
      ),
      _listen<double>(
        _player.stream.volume,
        (state, value) => state.copyWith(volume: value),
      ),
      _listen<double>(
        _player.stream.rate,
        (state, value) => state.copyWith(rate: value),
      ),
      _listen<bool>(
        _player.stream.shuffle,
        (state, value) => state.copyWith(shuffle: value),
      ),
      _listen<Tracks>(
        _player.stream.tracks,
        (state, value) => state.copyWith(
          videoTracks: List<VideoTrack>.unmodifiable(value.video),
          audioTracks: List<AudioTrack>.unmodifiable(value.audio),
          subtitleTracks: List<SubtitleTrack>.unmodifiable(value.subtitle),
        ),
      ),
      _listen<Track>(
        _player.stream.track,
        (state, value) => state.copyWith(
          currentAudioTrack: value.audio,
          currentSubtitleTrack: value.subtitle,
        ),
      ),
      _player.stream.videoParams.listen((_) {
        // Color, gamma and decoder metadata also change videoParams. Keep the
        // texture when its dimensions are unchanged, including when adjusting
        // picture controls during playback.
        _scheduleResize();
      }),
      _player.stream.width.listen((_) {
        _scheduleResize();
      }),
      _player.stream.height.listen((_) {
        _scheduleResize();
      }),
      _player.stream.error.listen(
        (message) => _emit(_stampedFailure(message)),
        onError: (Object error) => _emit(_stampedFailure(error.toString())),
      ),
    ]);
  }

  final Player _player;
  final NativeMediaEvents? _nativeEvents;
  NativeMediaEvents? _observedNativeEvents;
  final bool _ownsNativeEvents;
  DiagnosticSink? _diagnostics;
  VideoController? _videoController;

  /// Runtime mpv property bridge.
  ///
  /// Production resolves writes and reads against the native engine handle;
  /// engines without mpv properties (and tests without libmpv) route through
  /// the same seam so the video-track suspension logic behaves identically
  /// everywhere.
  late final Future<void> Function(String property, String value)
  _propertyWriter;

  bool _preferHardwareDecoding = true;
  VideoMemoryMode _videoMemoryMode = VideoMemoryMode.zeroCopy;
  bool _limitDemuxerCache = GraphicsSettings.defaults.limitDemuxerCache;
  final StreamController<PlaybackSnapshot> _stateController =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);
  late final SnapshotEmitter<PlaybackSnapshot> _emitter =
      SnapshotEmitter<PlaybackSnapshot>(_stateController);
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  _PendingPlaybackSettings? _pendingPlaybackSettings;
  _PendingPlaybackSettings? _activePlaybackSettings;
  Future<void>? _playbackSettingsDrain;
  final Map<String, String> _confirmedPlaybackProperties = <String, String>{};
  PlaybackSettings _appliedPlaybackSettings = PlaybackSettings.defaults;
  bool? _appliedBufferingPolicyNetwork;
  bool? _appliedBufferingPolicyLowSpec;
  bool? _appliedBufferingPolicyLimitCache;
  final PlaybackSourceIdentity _identity = PlaybackSourceIdentity();
  StreamSubscription<NativeMediaEvent>? _nativeSubscription;
  Future<void>? _prepareFuture;
  late PlaybackSnapshot _state;
  bool _disposed = false;
  bool _observationStarted = false;
  String _engineVersion = 'libmpv (version unavailable through media_kit)';
  bool _engineVersionLoaded = false;
  VideoOutputPolicy _videoOutputPolicy = const VideoOutputPolicy();
  Timer? _resizeDebounceTimer;
  Timer? _hiddenVideoSuspendTimer;
  bool _videoTrackSuspended = false;
  int? _lastAppliedWidth;
  int? _lastAppliedHeight;
  bool? _lastAppliedVisibility;
  bool _pendingForceResize = false;

  static const Duration _hiddenVideoSuspendDelay = Duration(seconds: 4);
  static const MethodChannel _videoChannel = MethodChannel(
    'com.alexmercerind/media_kit_video',
  );

  String _resolveHwdec(bool preferHardwareDecoding) => resolveHwdec(
    preferHardwareDecoding: preferHardwareDecoding,
    mode: _videoMemoryMode,
    isWindows: Platform.isWindows,
  );

  @override
  void applyGraphicsSettings(GraphicsSettings settings) {
    final normalized = settings.normalized();
    final modeChanged = _videoMemoryMode != normalized.videoMemoryMode;
    final limitChanged = _limitDemuxerCache != normalized.limitDemuxerCache;
    _videoMemoryMode = normalized.videoMemoryMode;
    _limitDemuxerCache = normalized.limitDemuxerCache;

    if (modeChanged) {
      _confirmedPlaybackProperties.remove('hwdec');
      if (_videoController != null) unawaited(_pushRuntimeHwdec());
    }
    final isNetwork = _appliedBufferingPolicyNetwork;
    if (limitChanged && isNetwork != null) {
      unawaited(_applyBufferingPolicy(isNetwork: isNetwork, force: true));
    }
  }

  Future<void> _writeNativeProperty(String property, String value) async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    await native.setProperty(property, value, waitForInitialization: false);
  }

  Future<void> _pushRuntimeHwdec() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    final value = _resolveHwdec(_preferHardwareDecoding);
    try {
      await native
          .setProperty('hwdec', value, waitForInitialization: false)
          .timeout(const Duration(seconds: 2));
      final actual = await native
          .getProperty('hwdec', waitForInitialization: false)
          .timeout(const Duration(seconds: 2));
      if (_propertyMatches(actual, value)) {
        _confirmedPlaybackProperties['hwdec'] = value;
      } else {
        _confirmedPlaybackProperties.remove('hwdec');
      }
    } on Object {
      _confirmedPlaybackProperties.remove('hwdec');
    }
  }

  @override
  Player get player => _player;

  @override
  VideoController get videoController {
    final existing = _videoController;
    if (existing != null) return existing;
    // Audio-only sessions never allocate a video output. The controller is
    // created when a video is opened or a Video widget first renders.
    final controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        hwdec: _resolveHwdec(_preferHardwareDecoding),
      ),
    );
    _videoController = controller;
    _applyStoredVideoPolicy(controller);
    // A failed native attachment (platform channel error, missing decoder,
    // disposed engine) must not be cached: drop the broken controller so the
    // next video open or rendered frame recreates it.
    unawaited(
      controller.platform.future.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_videoController, controller)) {
            _videoController = null;
            _lastAppliedWidth = null;
            _lastAppliedHeight = null;
          }
        },
      ),
    );
    return controller;
  }

  void _applyStoredVideoPolicy(VideoController controller) {
    final visible = _videoOutputPolicy.visible;
    _lastAppliedVisibility = visible;
    unawaited(
      controller.setRenderVisibility(visible).catchError((Object _) {}),
    );
    _syncVideoDecoding(visible);
    _lastAppliedWidth = null;
    _lastAppliedHeight = null;
    _scheduleResize(force: true);
  }

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _stateController.stream;

  @override
  String get engineVersion => _engineVersion;

  @override
  VideoOutputPolicy get videoOutputPolicy => _videoOutputPolicy;

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {
    if (_disposed) return;
    final visibilityChanged = _lastAppliedVisibility != policy.visible;
    _videoOutputPolicy = policy;
    final controller = _videoController;
    if (visibilityChanged && controller != null) {
      _lastAppliedVisibility = policy.visible;
      // Best-effort: a platform channel failure must not become an unhandled
      // async error; the next policy application retries the visibility.
      unawaited(
        controller
            .setRenderVisibility(policy.visible)
            .catchError((Object _) {}),
      );
    }
    _syncVideoDecoding(policy.visible);
    _scheduleResize();
  }

  @override
  Future<void> trimVideoMemory() async {
    try {
      await _videoChannel.invokeMethod<void>('VideoOutputManager.TrimMemory');
    } on MissingPluginException {
      // The channel is Windows-only; the working-set trim still applies.
    } on PlatformException {
      // Best-effort: never block minimize or restore.
    }
  }

  /// Stops decoding the video track while its output is hidden.
  ///
  /// The texture keeps its last frame and the track list is unchanged, so
  /// restoring the track only resumes rendering; no layout or texture swap
  /// happens. A grace period avoids churn during quick library/minimize hops.
  void _syncVideoDecoding(bool visible) {
    if (_disposed) return;
    if (visible) {
      _hiddenVideoSuspendTimer?.cancel();
      _hiddenVideoSuspendTimer = null;
      if (_videoTrackSuspended) {
        _videoTrackSuspended = false;
        unawaited(_setVideoTrackEnabled(true));
      }
      return;
    }
    if (_videoTrackSuspended || _hiddenVideoSuspendTimer != null) return;
    _hiddenVideoSuspendTimer = Timer(_hiddenVideoSuspendDelay, () {
      _hiddenVideoSuspendTimer = null;
      if (_disposed || _videoOutputPolicy.visible) return;
      _videoTrackSuspended = true;
      unawaited(_setVideoTrackEnabled(false));
    });
  }

  /// Reconciles the hidden-video suspension with a freshly loaded source.
  ///
  /// A file load resets mpv's file-local `vid` selection, so a suspension that
  /// described the previous source no longer holds and the next track would
  /// keep decoding behind a hidden output. The suspension is re-applied
  /// immediately for the new source; the visibility grace period only exists
  /// to keep quick hide/show hops from churning the track selection.
  void _reconcileVideoSuspensionAfterLoad() {
    if (_disposed || _videoOutputPolicy.visible) return;
    if (!_videoTrackSuspended) return;
    _hiddenVideoSuspendTimer?.cancel();
    _hiddenVideoSuspendTimer = null;
    // The new file reset the engine's track selection, so the suspension
    // applies to it again from this point on.
    _videoTrackSuspended = true;
    unawaited(_setVideoTrackEnabled(false, note: 're-applied for new source'));
  }

  Future<void> _setVideoTrackEnabled(bool enabled, {String? note}) async {
    // The suspension decision is recorded at the point it is made; engines
    // without mpv properties report the intent without a native write.
    _diagnostics?.record(
      'playback.video_track',
      message: note == null
          ? (enabled ? 'resumed' : 'suspended')
          : '${enabled ? 'resumed' : 'suspended'} ($note)',
    );
    try {
      await _propertyWriter('vid', enabled ? 'auto' : 'no');
    } on Object catch (error) {
      _diagnostics?.record('playback.video_track', error: error);
    }
  }

  void _scheduleResize({bool force = false}) {
    if (force) {
      _pendingForceResize = true;
    }
    _resizeDebounceTimer?.cancel();
    _resizeDebounceTimer = Timer(const Duration(milliseconds: 60), () {
      if (_disposed) return;
      final forceNow = _pendingForceResize;
      _pendingForceResize = false;
      _applyViewportSize(force: forceNow);
    });
  }

  void _applyViewportSize({bool force = false}) {
    final pw = _videoOutputPolicy.physicalWidth;
    final ph = _videoOutputPolicy.physicalHeight;
    if (pw == null || ph == null || pw <= 0 || ph <= 0) {
      if (_lastAppliedWidth != null || _lastAppliedHeight != null || force) {
        _lastAppliedWidth = null;
        _lastAppliedHeight = null;
        _forceControllerSize(width: null, height: null);
      }
      return;
    }
    // media_kit's width/height already include pixel aspect and rotation.
    final size = _videoOutputPolicy.fitVideo(
      width: _player.state.width,
      height: _player.state.height,
    );
    if (size == null) return;
    final targetWidth = size.width;
    final targetHeight = size.height;
    if (!force &&
        targetWidth == _lastAppliedWidth &&
        targetHeight == _lastAppliedHeight) {
      return;
    }
    _lastAppliedWidth = targetWidth;
    _lastAppliedHeight = targetHeight;
    _forceControllerSize(width: targetWidth, height: targetHeight);
  }

  void _forceControllerSize({required int? width, required int? height}) {
    final controller = _videoController;
    if (controller == null) return;
    unawaited(() async {
      try {
        await controller.setSize(width: width, height: height);
      } catch (_) {
        // A source close can race the debounced resize. The next source or
        // viewport event reapplies its current policy.
      }
    }());
  }

  /// The load attempt of the most recent [open] or [stop] request.
  int get requestedBoundary => _identity.boundaryCounter;

  /// Serializes engine opens so a rapid next/previous can never attach a stale
  /// source. Each queued open re-checks that it is still the newest request
  /// immediately before the engine is told to load anything; a superseded open
  /// completes without touching the engine.
  Future<void>? _openTail;

  @override
  Future<void> open(String path, {bool play = true}) async {
    // Registering the request with the identity tracker must stay synchronous:
    // it assigns the boundary later opens use to detect they were superseded.
    final boundary = _identity.beginOpen(path);
    _diagnostics?.record(
      'playback.open',
      sourceId: MediaSource.redact(path),
      message: 'boundary $boundary, play $play',
    );
    unawaited(_startNativeObservation());
    _emit(
      _state.copyWith(
        sourceStart: boundary,
        isPlaying: play,
        isBuffering: true,
        completed: false,
        position: Duration.zero,
        duration: Duration.zero,
        chapters: const <PlaybackChapter>[],
        clearError: true,
        clearNativeSource: true,
        sourceLoaded: false,
      ),
    );
    _lastAppliedWidth = null;
    _lastAppliedHeight = null;
    final previous = _openTail;
    final done = Completer<void>();
    _openTail = done.future;
    unawaited(_runQueuedOpen(path, play, boundary, previous, done));
    return done.future;
  }

  Future<void> _runQueuedOpen(
    String path,
    bool play,
    int boundary,
    Future<void>? previous,
    Completer<void> done,
  ) async {
    try {
      // One open reaches the engine at a time; the newest request always wins.
      try {
        await previous;
      } on Object {
        // A failed earlier open must not stop the newest request.
      }
      if (done.isCompleted || _disposed) return;
      if (_identity.boundaryCounter != boundary) {
        _diagnostics?.record(
          'playback.open',
          sourceId: MediaSource.redact(path),
          message: 'boundary $boundary superseded before the engine open',
        );
        return;
      }
      if (MediaCatalog.kindFromExtension(path) != MediaKind.audio) {
        // Attach the video output before opening so video sources keep their
        // first-frame path. Known audio sources never allocate it.
        videoController;
      }
      _scheduleResize(force: true);
      await _applyBufferingPolicy(isNetwork: MediaEntry.isNetworkUrl(path));
      if (done.isCompleted || _disposed) return;
      // The policy writes above can be slow; re-check staleness immediately
      // before the engine open so a rapid next/previous never races this load.
      if (_identity.boundaryCounter != boundary) {
        _diagnostics?.record(
          'playback.open',
          sourceId: MediaSource.redact(path),
          message: 'boundary $boundary superseded before the engine open',
        );
        return;
      }
      _syncVideoDecoding(_videoOutputPolicy.visible);
      await _player.open(Media(path), play: play);
      _reconcileVideoSuspensionAfterLoad();
      if (!_identity.observationActive && !_disposed) {
        _emit(_stamped(_state.copyWith(isBuffering: _player.state.buffering)));
      }
    } on Object catch (error, stackTrace) {
      if (!done.isCompleted) {
        done.completeError(error, stackTrace);
      }
      return;
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }

  @override
  Future<void> prepare() {
    final existing = _prepareFuture;
    if (existing != null) return existing;
    final future = _prepare();
    _prepareFuture = future;
    return future;
  }

  Future<void> _prepare() async {
    await _startNativeObservation();
    await loadEngineVersion();
  }

  /// Watches the native engine's own source lifecycle.
  ///
  /// Registration also delivers libmpv's current value for each property, so a
  /// source that is already attached is reported as soon as observation starts.
  /// The event subscription exists before registration begins, so those first
  /// reports are attributed instead of being dropped.
  Future<void> _startNativeObservation() async {
    if (_observationStarted || _disposed) return;
    _observationStarted = true;
    final events =
        _nativeEvents ??
        (_player.platform is NativePlayer
            ? MediaKitNativeMediaEvents(_player)
            : const DisabledNativeMediaEvents());
    _observedNativeEvents = events;
    _nativeSubscription = events.events.listen(_handleNativeEvent);
    final watch = Stopwatch()..start();
    final bool supported;
    try {
      supported = await events.start();
    } on Object catch (error) {
      _identity.activateObservation(supported: false);
      _diagnostics?.record(
        'native.observe',
        message: 'unsupported',
        error: error,
      );
      return;
    }
    if (_disposed) return;
    _identity.activateObservation(supported: supported);
    _diagnostics?.record(
      'native.observe',
      message: supported ? 'supported' : 'unsupported',
      error: 'after ${watch.elapsedMilliseconds} ms',
    );
    // Activation can resolve the source that was requested while the observers
    // were still being registered; publish it so no load stays unconfirmed.
    _emit(_stamped(_state));
  }

  /// Reads the loaded engine version once, during bootstrap.
  Future<void> loadEngineVersion() async {
    if (_engineVersionLoaded || _disposed) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    _engineVersionLoaded = true;
    try {
      final version =
          (await platform
                  .getProperty('mpv-version')
                  .timeout(const Duration(seconds: 3)))
              .trim();
      if (version.isNotEmpty && !_disposed) {
        final cleanVersion = version
            .replaceAll(RegExp(r'-dev[-+.0-9a-zA-Z]*'), '')
            .trim();
        _engineVersion = 'libmpv $cleanVersion';
        _diagnostics?.record('engine.version', message: _engineVersion);
      }
    } on Object {
      // Some libmpv builds omit this property; keep the explicit fallback.
      _engineVersionLoaded = false;
    }
  }

  Future<void> _applyBufferingPolicy({
    required bool isNetwork,
    bool force = false,
  }) async {
    // The engine keeps these options across sources, so repeating the same
    // native writes before every local-file open only delays playback.
    final lowSpec = _appliedPlaybackSettings.isLowSpecOrRamPreserved;
    if (!force &&
        _appliedBufferingPolicyNetwork == isNetwork &&
        _appliedBufferingPolicyLowSpec == lowSpec &&
        _appliedBufferingPolicyLimitCache == _limitDemuxerCache) {
      return;
    }
    final nativePlayer = _player.platform;
    if (nativePlayer is! NativePlayer) return;
    try {
      if (!isNetwork) {
        // Ordinary local files: disable network-style caching and use 1s
        // read-ahead. Byte caps come from the graphics settings.
        await nativePlayer
            .setProperty('cache', 'no', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty('cache-on-disk', 'no', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty(
              'demuxer-readahead-secs',
              '1',
              waitForInitialization: false,
            )
            .timeout(const Duration(seconds: 1));
      } else {
        // HTTP(S) and network paths: retain disk-backed caching.
        await nativePlayer
            .setProperty('cache', 'yes', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty('cache-on-disk', 'yes', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty('cache-secs', '20', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty(
              'demuxer-readahead-secs',
              '20',
              waitForInitialization: false,
            )
            .timeout(const Duration(seconds: 1));
      }

      final limits = demuxerCacheLimits(
        limit: _limitDemuxerCache,
        lowSpec: lowSpec,
      );
      await nativePlayer
          .setProperty(
            'demuxer-max-bytes',
            limits.forwardBytes.toString(),
            waitForInitialization: false,
          )
          .timeout(const Duration(seconds: 1));
      await nativePlayer
          .setProperty(
            'demuxer-max-back-bytes',
            limits.backBytes.toString(),
            waitForInitialization: false,
          )
          .timeout(const Duration(seconds: 1));

      _appliedBufferingPolicyNetwork = isNetwork;
      _appliedBufferingPolicyLowSpec = lowSpec;
      _appliedBufferingPolicyLimitCache = _limitDemuxerCache;
    } on Object catch (error) {
      _diagnostics?.record('playback.buffering_policy', error: error);
    }
  }

  @override
  Future<void> stop() async {
    _hiddenVideoSuspendTimer?.cancel();
    _hiddenVideoSuspendTimer = null;
    final boundary = _identity.beginStop();
    _diagnostics?.record('playback.stop', message: 'boundary $boundary');
    _emit(
      _state.copyWith(
        sourceStart: boundary,
        isPlaying: false,
        isBuffering: false,
        completed: false,
        position: Duration.zero,
        duration: Duration.zero,
        chapters: const <PlaybackChapter>[],
        clearNativeSource: true,
        sourceLoaded: false,
      ),
    );
    await _player.stop();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double value) => _player.setVolume(value);

  @override
  Future<void> setRate(double value) => _player.setRate(value);

  @override
  Future<void> setShuffle(bool value) => _player.setShuffle(value);

  @override
  // Queue repeat is implemented by PlayerController. The media_kit player
  // contains only one source at a time, so native playlist repeat would loop
  // before the controller can advance its own queue.
  Future<void> setRepeatMode(String value) =>
      _player.setPlaylistMode(PlaylistMode.none);

  @override
  Future<void> setAudioTrack(AudioTrack track) => _player.setAudioTrack(track);

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _player.setSubtitleTrack(track);

  @override
  Future<void> loadSubtitle(String path) async {
    final uri = Uri.tryParse(path);
    final scheme = uri?.scheme.toLowerCase();
    final subtitlePath =
        scheme == 'http' || scheme == 'https' || scheme == 'file'
        ? path
        : Uri.file(path, windows: Platform.isWindows).toString();
    await _player.setSubtitleTrack(SubtitleTrack.uri(subtitlePath));
  }

  @override
  Future<PlaybackSettingsApplyResult> applyPlaybackSettings(
    PlaybackSettings settings,
  ) {
    if (_disposed) {
      return Future<PlaybackSettingsApplyResult>.value(
        const PlaybackSettingsApplyResult(
          supported: false,
          reason: 'The playback engine is closing.',
        ),
      );
    }
    final normalized = settings.normalized();
    final existing = _pendingPlaybackSettings;
    if (existing != null && existing.settings == normalized) {
      return existing.completer.future;
    }
    if (existing != null) {
      _completeSettingsRequest(
        existing,
        const PlaybackSettingsApplyResult(supported: true, superseded: true),
      );
    }
    final pending = _PendingPlaybackSettings(normalized);
    _pendingPlaybackSettings = pending;
    _startPlaybackSettingsDrain();
    return pending.completer.future;
  }

  void _startPlaybackSettingsDrain() {
    if (_playbackSettingsDrain != null) return;
    late final Future<void> drain;
    drain = _drainPlaybackSettings().whenComplete(() {
      if (identical(_playbackSettingsDrain, drain)) {
        _playbackSettingsDrain = null;
        if (_pendingPlaybackSettings != null) _startPlaybackSettingsDrain();
      }
    });
    _playbackSettingsDrain = drain;
  }

  Future<void> _drainPlaybackSettings() async {
    while (!_disposed) {
      final request = _pendingPlaybackSettings;
      if (request == null) return;
      _pendingPlaybackSettings = null;
      _activePlaybackSettings = request;
      PlaybackSettingsApplyResult result;
      try {
        result = await _applyPlaybackSettings(request.settings);
      } on Object catch (error) {
        result = PlaybackSettingsApplyResult(
          supported: false,
          reason: 'Could not apply mpv settings: $error',
        );
      }
      _completeSettingsRequest(request, result);
      if (identical(_activePlaybackSettings, request)) {
        _activePlaybackSettings = null;
      }
    }

    final pending = _pendingPlaybackSettings;
    _pendingPlaybackSettings = null;
    if (pending != null) {
      const result = PlaybackSettingsApplyResult(
        supported: false,
        reason: 'The playback engine is closing.',
      );
      _completeSettingsRequest(pending, result);
    }
  }

  void _completeSettingsRequest(
    _PendingPlaybackSettings request,
    PlaybackSettingsApplyResult result,
  ) {
    if (!request.completer.isCompleted) request.completer.complete(result);
  }

  Future<PlaybackSettingsApplyResult> _applyPlaybackSettings(
    PlaybackSettings settings,
  ) async {
    final previousLowSpec = _appliedPlaybackSettings.isLowSpecOrRamPreserved;
    _appliedPlaybackSettings = settings;
    _preferHardwareDecoding = settings.preferHardwareDecoding;
    final appliedNetwork = _appliedBufferingPolicyNetwork;
    if (appliedNetwork != null &&
        previousLowSpec != settings.isLowSpecOrRamPreserved) {
      unawaited(_applyBufferingPolicy(isNetwork: appliedNetwork, force: true));
    }
    final controller = _videoController;
    if (controller != null) {
      try {
        // A runtime property write is deferred until VideoController has
        // completed its native initialization, even while no source is open.
        await controller.platform.future.timeout(const Duration(seconds: 4));
      } on Object catch (error) {
        return PlaybackSettingsApplyResult(
          supported: false,
          reason: 'The native video output is not ready: $error',
        );
      }
    }
    if (_disposed) {
      return const PlaybackSettingsApplyResult(
        supported: false,
        reason: 'The playback engine is closing.',
      );
    }
    final nativePlayer = _player.platform;
    if (nativePlayer is! NativePlayer) {
      return const PlaybackSettingsApplyResult(
        supported: false,
        reason: 'The active playback engine does not expose mpv settings.',
      );
    }

    final preset = switch (settings.qualityPreset) {
      PlaybackQualityPreset.performance => const <String, String>{
        'scale': 'bilinear',
        'cscale': 'bilinear',
        'dscale': 'bilinear',
        'deband': 'no',
      },
      PlaybackQualityPreset.balanced => const <String, String>{
        'scale': 'lanczos',
        'cscale': 'bilinear',
        'dscale': 'hermite',
        'deband': 'no',
      },
      PlaybackQualityPreset.quality => const <String, String>{
        'scale': 'ewa_lanczossharp',
        'cscale': 'bilinear',
        'dscale': 'mitchell',
        'deband': 'yes',
      },
    };
    final properties = <String, String>{
      'hwdec': _resolveHwdec(settings.preferHardwareDecoding),
      ...preset,
      'brightness': settings.brightness.toString(),
      'contrast': settings.contrast.toString(),
      'saturation': settings.saturation.toString(),
      'gamma': settings.gamma.toString(),
      'audio-delay': settings.audioDelaySeconds.toString(),
      'sub-delay': settings.subtitleDelaySeconds.toString(),
    };
    final applied = <String>[];
    final failed = <String>[];
    for (final entry in properties.entries) {
      if (_disposed) {
        return PlaybackSettingsApplyResult(
          supported: false,
          appliedProperties: List<String>.unmodifiable(applied),
          failedProperties: List<String>.unmodifiable(failed),
          reason: 'The playback engine is closing.',
        );
      }
      if (_confirmedPlaybackProperties[entry.key] == entry.value) {
        applied.add(entry.key);
        continue;
      }
      try {
        // Wait for VideoController initialization before sending runtime mpv
        // writes. media_kit returns void from setProperty, so read the value
        // back and only report properties that match the requested value.
        await nativePlayer
            .setProperty(entry.key, entry.value, waitForInitialization: false)
            .timeout(const Duration(seconds: 2));
        final actual = await nativePlayer
            .getProperty(entry.key, waitForInitialization: false)
            .timeout(const Duration(seconds: 2));
        if (_propertyMatches(actual, entry.value)) {
          applied.add(entry.key);
          _confirmedPlaybackProperties[entry.key] = entry.value;
        } else {
          failed.add(entry.key);
          _confirmedPlaybackProperties.remove(entry.key);
        }
      } on Object {
        failed.add(entry.key);
        _confirmedPlaybackProperties.remove(entry.key);
      }
    }
    return PlaybackSettingsApplyResult(
      appliedProperties: List<String>.unmodifiable(applied),
      failedProperties: List<String>.unmodifiable(failed),
      reason: failed.isEmpty
          ? null
          : 'mpv did not confirm: ${failed.join(', ')}',
    );
  }

  static bool _propertyMatches(String actual, String requested) {
    final expectedNumber = double.tryParse(requested);
    if (expectedNumber != null) {
      final actualNumber = double.tryParse(actual.trim());
      return actualNumber != null &&
          actualNumber.isFinite &&
          (actualNumber - expectedNumber).abs() < 0.0001;
    }
    return actual.trim().toLowerCase() == requested.toLowerCase();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    const closingResult = PlaybackSettingsApplyResult(
      supported: false,
      reason: 'The playback engine is closing.',
    );
    final activeSettings = _activePlaybackSettings;
    if (activeSettings != null) {
      _completeSettingsRequest(activeSettings, closingResult);
    }
    final pendingSettings = _pendingPlaybackSettings;
    _pendingPlaybackSettings = null;
    if (pendingSettings != null) {
      _completeSettingsRequest(pendingSettings, closingResult);
    }
    _resizeDebounceTimer?.cancel();
    _resizeDebounceTimer = null;
    _hiddenVideoSuspendTimer?.cancel();
    _hiddenVideoSuspendTimer = null;
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } on Object {
        // Keep tearing down the remaining subscriptions and the native player.
      }
    }
    _subscriptions.clear();
    try {
      await _nativeSubscription?.cancel();
    } on Object {
      // Native observation teardown must not block player disposal.
    }
    _nativeSubscription = null;
    if (_ownsNativeEvents) {
      try {
        await _observedNativeEvents?.dispose();
      } on Object {
        // Native event teardown is best effort.
      }
    }
    try {
      await _stateController.close();
    } on Object {
      // Native player disposal must still run if the Dart stream has an issue.
    }
    await _player.dispose();
  }

  /// Attributes one engine event to the source the engine reported.
  void _handleNativeEvent(NativeMediaEvent event) {
    if (_disposed) return;
    _diagnostics?.record(
      'native.event',
      sourceId: event.source.isEmpty ? null : MediaSource.redact(event.source),
      message: event.kind.name,
    );
    switch (event.kind) {
      case NativeMediaEventKind.started:
        final attachment = _identity.attachStarted(event.source);
        if (!attachment.hasSource) return;
        _lastAppliedWidth = null;
        _lastAppliedHeight = null;
        _scheduleResize(force: true);
        // The started event is the point where the new file's own `vid`
        // selection is definitely in effect; make sure a hidden output is not
        // decoding it.
        _reconcileVideoSuspensionAfterLoad();
        _emit(_stamped(applyNativeEvent(_state, event)));
      case NativeMediaEventKind.loaded:
        final attachment = _identity.attachLoaded();
        if (!attachment.hasSource) return;
        _scheduleResize(force: true);
        _emit(_stamped(applyNativeEvent(_state, event)));
      case NativeMediaEventKind.ended:
        final attachment = _identity.attachEnded();
        if (!attachment.hasSource) return;
        _emit(_stamped(applyNativeEvent(_state, event)));
      case NativeMediaEventKind.seekableChanged:
        _emit(_stamped(applyNativeEvent(_state, event)));
      case NativeMediaEventKind.chaptersChanged:
        _emit(_stamped(applyNativeEvent(_state, event)));
    }
  }

  StreamSubscription<Object?> _listen<T>(
    Stream<T> stream,
    PlaybackSnapshot Function(PlaybackSnapshot state, T value) update,
  ) {
    return stream.listen(
      (value) => _emit(_stamped(update(_state, value))),
      onError: (Object error) =>
          _emit(_stamped(_state.copyWith(error: error.toString()))),
    );
  }

  PlaybackSnapshot _stamped(PlaybackSnapshot state) {
    final attachment = _identity.attached;
    return state.copyWith(
      sourceStart: attachment.boundary,
      nativeSource: attachment.source,
      clearNativeSource: !attachment.hasSource,
      sourceLoaded: attachment.loaded,
    );
  }

  /// Attributes an engine failure to the load attempt it belongs to.
  ///
  /// libmpv reports a load it refused without ever notifying `path`, so the
  /// outstanding request is the only identity that can describe the failure.
  PlaybackSnapshot _stampedFailure(String message) {
    final attachment = _identity.unresolvedRequest ?? _identity.attached;
    return _state.copyWith(
      error: message,
      sourceStart: attachment.boundary,
      nativeSource: attachment.source,
      clearNativeSource: !attachment.hasSource,
      sourceLoaded: attachment.loaded,
    );
  }

  void _emit(PlaybackSnapshot state) {
    if (_disposed) return;
    _state = state;
    // Listeners may issue a playback command that publishes again; the emitter
    // keeps that nested publish from reaching the stream re-entrantly.
    _emitter.add(state);
  }

  static PlaybackSnapshot _snapshotFrom(PlayerState state) => PlaybackSnapshot(
    isPlaying: state.playing,
    isBuffering: state.buffering,
    completed: state.completed,
    position: state.position,
    duration: state.duration,
    volume: state.volume,
    rate: state.rate,
    shuffle: state.shuffle,
    videoTracks: List<VideoTrack>.unmodifiable(state.tracks.video),
    audioTracks: List<AudioTrack>.unmodifiable(state.tracks.audio),
    subtitleTracks: List<SubtitleTrack>.unmodifiable(state.tracks.subtitle),
    currentAudioTrack: state.track.audio,
    currentSubtitleTrack: state.track.subtitle,
  );
}

class _PendingPlaybackSettings {
  _PendingPlaybackSettings(this.settings);

  PlaybackSettings settings;
  final Completer<PlaybackSettingsApplyResult> completer =
      Completer<PlaybackSettingsApplyResult>();
}
