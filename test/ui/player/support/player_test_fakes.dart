import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mpvson/data/repositories/session_repository.dart';
import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/snapshot_emitter.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/playback_session.dart';
import 'package:mpvson/domain/models/session_progress.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';

class BlockingSessionRepository extends SessionRepository {
  BlockingSessionRepository({
    this.blockDetailed = true,
    this.blockProgress = false,
    this.initialResult,
  });

  final bool blockDetailed;
  final bool blockProgress;
  final SessionLoadResult? initialResult;
  final Completer<SessionLoadResult> result = Completer<SessionLoadResult>();
  final Completer<void> progressLoadStarted = Completer<void>();
  final Completer<SessionProgress?> progress = Completer<SessionProgress?>();

  @override
  Future<SessionLoadResult> loadDetailed() {
    if (!blockDetailed && initialResult != null) {
      return Future<SessionLoadResult>.value(initialResult);
    }
    return result.future;
  }

  @override
  Future<SessionProgress?> loadProgress() {
    if (!progressLoadStarted.isCompleted) progressLoadStarted.complete();
    return blockProgress ? progress.future : Future<SessionProgress?>.value();
  }

  @override
  Future<void> save(PlaybackSession session) async {}

  @override
  Future<void> saveScrubbed(PlaybackSession session) async {}

  @override
  Future<void> saveProgress(SessionProgress progress) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> scrubNetworkUrls() async {}
}

class FakePlaybackService implements PlaybackService {
  FakePlaybackService({PlaybackSnapshot initial = const PlaybackSnapshot()})
    : _state = initial;

  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast(sync: true);
  late final SnapshotEmitter<PlaybackSnapshot> _emitter = SnapshotEmitter(
    _states,
  );
  PlaybackSnapshot _state;
  int _sourceStart = 0;
  Completer<void>? nextRateWrite;
  Completer<void>? nextSeekWrite;
  Completer<void>? nextShuffleWrite;
  final Completer<void> shuffleWriteStarted = Completer<void>();
  final List<double> rateWrites = <double>[];
  final List<Duration> seekWrites = <Duration>[];
  final List<double> volumeWrites = <double>[];
  final List<bool> shuffleWrites = <bool>[];
  final List<String> repeatModeWrites = <String>[];
  int playCalls = 0;
  int pauseCalls = 0;
  int subtitleTrackChanges = 0;
  bool disposed = false;

  @override
  Player get player =>
      throw UnsupportedError('The test does not use a player.');

  @override
  VideoController get videoController =>
      throw UnsupportedError('The test does not use a video controller.');

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  String get engineVersion => 'test';

  @override
  VideoOutputPolicy get videoOutputPolicy => const VideoOutputPolicy();

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {}

  @override
  Future<void> prepare() async {}

  @override
  Future<void> open(String path, {bool play = true}) async {
    _emit(
      _state.copyWith(
        isPlaying: play,
        isBuffering: false,
        completed: false,
        position: Duration.zero,
        duration: const Duration(minutes: 2),
        sourceStart: ++_sourceStart,
        nativeSource: MediaEntry.canonicalSource(path),
        sourceLoaded: true,
        clearError: true,
      ),
    );
  }

  @override
  Future<void> stop() async {
    _emit(
      _state.copyWith(
        isPlaying: false,
        isBuffering: false,
        completed: false,
        position: Duration.zero,
        duration: Duration.zero,
        clearNativeSource: true,
        sourceLoaded: false,
      ),
    );
  }

  @override
  Future<void> play() async {
    playCalls++;
    _emit(_state.copyWith(isPlaying: true));
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _emit(_state.copyWith(isPlaying: false));
  }

  @override
  Future<void> seek(Duration position) async {
    seekWrites.add(position);
    final sourceAtStart = _state;
    final blocker = nextSeekWrite;
    nextSeekWrite = null;
    if (blocker == null) {
      _emit(_state.copyWith(position: position));
      return;
    }

    await blocker.future;
    final staleSnapshot = sourceAtStart.copyWith(position: position);
    if (!_states.isClosed) _states.add(staleSnapshot);
  }

  @override
  Future<void> setVolume(double value) async {
    volumeWrites.add(value);
    _emit(_state.copyWith(volume: value));
  }

  @override
  Future<void> setRate(double value) async {
    rateWrites.add(value);
    final blocker = nextRateWrite;
    nextRateWrite = null;
    if (blocker != null) await blocker.future;
    _emit(_state.copyWith(rate: value));
  }

  @override
  Future<void> setShuffle(bool value) async {
    shuffleWrites.add(value);
    if (!shuffleWriteStarted.isCompleted) shuffleWriteStarted.complete();
    final blocker = nextShuffleWrite;
    nextShuffleWrite = null;
    if (blocker != null) await blocker.future;
    _emit(_state.copyWith(shuffle: value));
  }

  @override
  Future<void> setRepeatMode(String value) async {
    repeatModeWrites.add(value);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {}

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    subtitleTrackChanges++;
  }

  @override
  Future<void> loadSubtitle(String path) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await _states.close();
  }

  void emit(PlaybackSnapshot value) => _emit(value);

  void _emit(PlaybackSnapshot value) {
    _state = value;
    if (!_states.isClosed) _emitter.add(value);
  }
}
