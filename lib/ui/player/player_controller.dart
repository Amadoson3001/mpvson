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
import '../../data/services/seek_preview_service.dart';
import '../../data/services/thumbnail_service.dart';
import '../../domain/models/control_density.dart';
import '../../domain/models/graphics_settings.dart';
import '../../domain/models/media_catalog.dart';
import '../../domain/models/media_entry.dart';
import '../../domain/models/media_kind.dart';
import '../../domain/models/media_metadata.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_thumbnail.dart';
import '../../domain/models/playback_chapter.dart';
import '../../domain/models/playback_session.dart';
import '../../domain/models/playback_settings.dart';
import '../../domain/models/session_progress.dart';
import '../../domain/models/video_output_policy.dart';
import '../../utils/memory_trimmer.dart';

import 'playback_position_smoother.dart';
import 'player_state.dart';

export '../../data/services/seek_preview_service.dart'
    show
        MediaKitSeekPreviewBackend,
        SeekPreviewBackend,
        SeekPreviewBackendFactory,
        SeekPreviewFrame,
        SeekPreviewLRUCache,
        SeekPreviewQuality,
        SeekPreviewService,
        SeekPreviewState,
        SeekPreviewStatus;
export '../../data/services/thumbnail_service.dart'
    show ThumbnailPriority, ThumbnailRequestHandle;
export '../../domain/models/media_kind.dart' show MediaKind;
export '../../domain/models/media_metadata.dart'
    show AudioTechnicalInfo, MediaMetadata;
export 'player_state.dart';

part 'player_controller_session.dart';
part 'player_controller_queue.dart';
part 'player_controller_transport.dart';
part 'player_controller_playback.dart';
part 'player_controller_engine.dart';

/// Owns the queue, history, session state and playback commands for the UI.
class PlayerController extends ChangeNotifier {
  static const int _maximumNavigationHistory = 10000;

  PlayerController({
    required PlaybackService playback,
    required SessionRepository sessions,
    ThumbnailService? thumbnails,
    SeekPreviewService? seekPreview,
    SeekPreviewBackendFactory? previewBackendFactory,
    DiagnosticSink? diagnostics,
  }) {
    _playback = playback;
    _sessions = sessions;
    _thumbnails = thumbnails;
    _diagnostics = diagnostics;
    _seekPreview =
        seekPreview ??
        SeekPreviewService(
          backendFactory: previewBackendFactory,
          onExtractionStateChange: _handlePreviewExtractionStateChange,
          diagnostics: diagnostics,
        );
    final initial = _playback.state;
    _applySnapshot(initial, notify: false);
    _confirmedVolume = _normalizeVolume(initial.volume);
    if (_confirmedVolume > 0) _lastAudibleVolume = _confirmedVolume;
    _confirmedRate = _normalizeRate(initial.rate);
    _confirmedShuffle = initial.shuffle;
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

  bool _trimOnMinimize = GraphicsSettings.defaults.trimOnMinimize;

  late final SessionRepository _sessions;

  late final ThumbnailService? _thumbnails;

  late final SeekPreviewService _seekPreview;

  late final DiagnosticSink? _diagnostics;

  final Set<ThumbnailSuspensionReason> _thumbnailSuspensionReasons =
      <ThumbnailSuspensionReason>{};

  final Random _random = Random();

  final List<MediaEntry> _queue = <MediaEntry>[];

  final Map<String, int> _queueIdToIndex = <String, int>{};

  final Map<String, int> _recentIndexById = <String, int>{};

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

  bool _isStopped = false;

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

  bool _scrubBackupOnSave = false;

  Completer<void>? _saveDrain;

  bool _checkpointInFlight = false;

  bool _checkpointRequested = false;

  Completer<void>? _checkpointDrain;

  bool _saveNetworkUrls = false;

  PlayerRepeatMode _repeatMode = PlayerRepeatMode.off;

  PlayerRepeatMode _confirmedRepeatMode = PlayerRepeatMode.off;

  bool _shuffleEnabled = false;

  bool _confirmedShuffle = false;

  int _queuePreferenceSequence = 0;

  int _shufflePreferenceRevision = 0;

  int _appliedShufflePreferenceRevision = 0;

  int _shufflePreferenceSequence = 0;

  int _repeatPreferenceRevision = 0;

  int _appliedRepeatPreferenceRevision = 0;

  int _repeatPreferenceSequence = 0;

  int _saveNetworkUrlsRevision = 0;

  bool _autoPlayNextVideo = true;

  int _autoPlayNextVideoRevision = 0;

  bool _autoPlayNextAudio = true;

  int _autoPlayNextAudioRevision = 0;

  Future<void>? _queuePreferenceDrain;

  Future<void>? _startupPreferenceDrain;

  ControlDensity _controlDensity = ControlDensity.compact;

  int _controlDensityRevision = 0;

  PlaybackSettings _playbackSettings = PlaybackSettings.defaults;

  String? _playbackSettingsError;

  int _playbackSettingsApplyRevision = 0;

  int _playbackSettingsRevision = 0;

  bool _hasRestoredPlaybackSettings = false;

  PlaybackQualityPreset? _recommendedQualityPreset;

  final List<String> _navigationHistory = <String>[];

  int _navigationCursor = -1;

  int? _pendingNavigationCursor;

  String? _pendingNavigationEntryId;

  final List<String> _shuffleRemaining = <String>[];

  final Set<String> _shuffleVisited = <String>{};

  String? _error;

  MediaKind _mediaKind = MediaKind.unknown;

  MediaMetadata _metadata = MediaMetadata.empty;

  double? _desiredVolume;

  double _confirmedVolume = 100;

  double _lastAudibleVolume = 100;

  int _volumeRevision = 0;

  int _appliedVolumeRevision = 0;

  Completer<void>? _volumeDrain;

  double? _desiredRate;

  double _confirmedRate = 1;

  int _rateRevision = 0;

  int _appliedRateRevision = 0;

  bool _rateWriteShouldSave = true;

  Completer<void>? _rateDrain;

  int _seekRevision = 0;

  QueueSnapshot _queueSnapshot = QueueSnapshot.empty;

  /// Duration updates, delivered independently of queue changes.
  final ValueNotifier<Duration> durationListenable = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// Buffering updates, delivered independently of queue changes.
  final ValueNotifier<bool> bufferingListenable = ValueNotifier<bool>(false);

  /// Chapter markers of the attached source; changes only when the list does.
  final ValueNotifier<List<PlaybackChapter>> chaptersListenable =
      ValueNotifier<List<PlaybackChapter>>(const <PlaybackChapter>[]);

  /// The queue contents and their structural revision.
  final ValueNotifier<QueueSnapshot> queueListenable =
      ValueNotifier<QueueSnapshot>(QueueSnapshot.empty);

  /// Transport state of the current source.
  final ValueNotifier<TransportState> transportListenable =
      ValueNotifier<TransportState>(TransportState.idle);

  /// Volume of the current source, independent of transport ticks.
  final ValueNotifier<double> volumeListenable = ValueNotifier<double>(100);

  /// Shuffle and repeat, independent of transport ticks.
  final ValueNotifier<PlaybackMode> playbackModeListenable =
      ValueNotifier<PlaybackMode>(PlaybackMode.initial);

  /// Fires only when the player's structural presentation changes (current
  /// entry, media kind, error, density, recent list). Volume/rate/transport
  /// ticks stay on their dedicated listenables.
  final _StructureNotifier _structureNotifier = _StructureNotifier();

  String? _structureKey;

  final PlaybackPositionSmoother _positionSmoother = PlaybackPositionSmoother();

  List<MediaEntry> _unmodifiableRecent = const <MediaEntry>[];

  static double _normalizeVolume(double value) =>
      value.isNaN ? 0 : value.clamp(0.0, 100.0).toDouble();

  static double _normalizeRate(double value) =>
      value.isNaN ? 1 : value.clamp(0.25, 4.0).toDouble();

  void _notifyListeners() => notifyListeners();

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

  static MediaKind _classifyMediaKind({
    required MediaEntry? entry,
    required PlaybackSnapshot snapshot,
  }) {
    if (entry == null && snapshot.nativeSource == null) {
      return MediaKind.unknown;
    }

    final videoTracks = snapshot.videoTracks;
    final hasOrdinaryVideo = videoTracks.any(
      (track) =>
          track.id != 'auto' &&
          track.id != 'no' &&
          track.albumart != true &&
          track.image != true,
    );

    if (hasOrdinaryVideo) {
      return MediaKind.video;
    }

    final hasCoverArt = videoTracks.any(
      (track) =>
          track.id != 'auto' &&
          track.id != 'no' &&
          (track.albumart == true || track.image == true),
    );

    if (hasCoverArt) {
      return MediaKind.audio;
    }

    if (snapshot.audioTracks.isNotEmpty) {
      return MediaKind.audio;
    }

    if (entry != null) {
      return MediaCatalog.kindFromExtension(entry.path);
    }

    return MediaKind.unknown;
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

class _StructureNotifier extends ChangeNotifier {
  void markChanged() => notifyListeners();
}
