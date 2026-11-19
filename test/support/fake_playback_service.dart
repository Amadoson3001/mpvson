import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:mpvson/data/services/playback_service.dart';
import 'package:mpvson/data/services/streaming_coordinator.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/stream_rendition.dart';
import 'package:mpvson/domain/models/video_output_policy.dart';

/// In-memory [PlaybackService] so player UI tests can drive the controller
/// without the native engine.
///
/// `open()` reports the source as attached and playing, which is all the
/// controller needs to mark the engine as having media.
class FakePlaybackService implements PlaybackService {
  FakePlaybackService();

  PlaybackSnapshot _state = const PlaybackSnapshot();
  final StreamController<PlaybackSnapshot> _states =
      StreamController<PlaybackSnapshot>.broadcast();
  final List<String> openedPaths = <String>[];

  /// Reported for the next [open] call. Defaults to the opened path's
  /// canonical form, which is what the controller compares identity against.
  String? nativeSourceOverride;

  final StreamingCoordinator _streamingCoordinator = StreamingCoordinator();

  @override
  StreamingCoordinator get streamingCoordinator => _streamingCoordinator;

  @override
  Future<void> selectQuality(StreamRendition rendition) async {
    _streamingCoordinator.selectRendition(rendition);
    _state = _state.copyWith(streamPlaybackState: _streamingCoordinator.state);
    _states.add(_state);
  }

  @override
  Player get player => throw UnimplementedError('Native Player not used');

  @override
  VideoController get videoController =>
      throw UnimplementedError('Native VideoController not used');

  @override
  PlaybackSnapshot get state => _state;

  @override
  Stream<PlaybackSnapshot> get states => _states.stream;

  @override
  String get engineVersion => 'test-mpv';

  @override
  VideoOutputPolicy get videoOutputPolicy => const VideoOutputPolicy();

  @override
  void applyVideoOutputPolicy(VideoOutputPolicy policy) {}

  @override
  Future<void> prepare() async {}

  @override
  Future<void> open(String path, {bool play = true}) async {
    openedPaths.add(path);
    _state = _state.copyWith(
      isPlaying: play,
      isBuffering: false,
      sourceLoaded: true,
      // The controller compares engine identity against the canonical source,
      // so a raw path would never match on Windows (case-normalized).
      nativeSource: nativeSourceOverride ?? MediaEntry.canonicalSource(path),
      sourceStart: _state.sourceStart + 1,
      duration: const Duration(minutes: 2),
    );
    _states.add(_state);
  }

  @override
  Future<void> stop() async {
    _state = _state.copyWith(
      isPlaying: false,
      isBuffering: false,
      sourceLoaded: false,
      clearNativeSource: true,
    );
    _states.add(_state);
  }

  @override
  Future<void> play() async {
    _state = _state.copyWith(isPlaying: true);
    _states.add(_state);
  }

  @override
  Future<void> pause() async {
    _state = _state.copyWith(isPlaying: false);
    _states.add(_state);
  }

  @override
  Future<void> seek(Duration position) async {
    _state = _state.copyWith(position: position);
    _states.add(_state);
  }

  @override
  Future<void> setVolume(double value) async {
    _state = _state.copyWith(volume: value);
    _states.add(_state);
  }

  @override
  Future<void> setRate(double value) async {
    _state = _state.copyWith(rate: value);
    _states.add(_state);
  }

  @override
  Future<void> setShuffle(bool value) async {
    _state = _state.copyWith(shuffle: value);
    _states.add(_state);
  }

  @override
  Future<void> setRepeatMode(String value) async {}

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    _state = _state.copyWith(currentAudioTrack: track);
    _states.add(_state);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    _state = _state.copyWith(currentSubtitleTrack: track);
    _states.add(_state);
  }

  @override
  Future<void> loadSubtitle(String path) async {}

  @override
  Future<void> dispose() async {
    await _states.close();
  }
}
