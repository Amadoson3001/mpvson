import 'package:flutter/foundation.dart';

import 'stream_rendition.dart';

/// The active lifecycle stage of a cloud stream.
enum StreamStage {
  idle,
  resolving,
  connecting,
  buffering,
  ready,
  reconnecting,
  switchingQuality,
  failed,
}

/// The state of cloud media streaming for the current attempt.
@immutable
class StreamPlaybackState {
  const StreamPlaybackState({
    this.attemptId = 0,
    this.originalUrl = '',
    this.streamUrl = '',
    this.audioUrl,
    this.resolvedTitle,
    this.stage = StreamStage.idle,
    this.stageMessage,
    this.selectedRendition,
    this.activeRendition,
    this.decodedWidth,
    this.decodedHeight,
    this.availableRenditions = const [],
    this.isAutoQuality = true,
    this.bufferedDuration = Duration.zero,
    this.inputBitrate,
    this.reconnectAttempts = 0,
    this.isLive = false,
    this.seekable = true,
    this.firstOutputTime,
    this.timeToFirstOutput,
    this.error,
  });

  /// The unique monotonically increasing ID of the current native engine open attempt.
  final int attemptId;

  /// The original URL pasted or opened by the user.
  final String originalUrl;

  /// The direct stream or child playlist URL currently fed to libmpv.
  final String streamUrl;

  /// Optional external audio URL loaded concurrently.
  final String? audioUrl;

  /// Human-readable title resolved from the stream source (for example by yt-dlp).
  final String? resolvedTitle;

  /// The active lifecycle stage.
  final StreamStage stage;

  /// User-facing short status message (e.g. "Opening stream", "Buffering", "Reconnecting", "Switching to 720p").
  final String? stageMessage;

  /// User's requested rendition (or Auto).
  final StreamRendition? selectedRendition;

  /// The confirmed active rendition playing in the native engine.
  final StreamRendition? activeRendition;

  /// Decoded video frame width.
  final int? decodedWidth;

  /// Decoded video frame height.
  final int? decodedHeight;

  /// List of selectable renditions for the current source.
  final List<StreamRendition> availableRenditions;

  /// Whether Auto quality policy is currently active.
  final bool isAutoQuality;

  /// Current demuxer buffer ahead of playback position.
  final Duration bufferedDuration;

  /// Estimated network input bitrate in bits per second.
  final int? inputBitrate;

  /// Number of reconnect attempts performed for this stream episode.
  final int reconnectAttempts;

  /// Whether the current stream is a live broadcast.
  final bool isLive;

  /// Whether the current stream supports seeking.
  final bool seekable;

  /// Timestamp when the first video frame or audio packet was rendered.
  final DateTime? firstOutputTime;

  /// Duration from request issue to first rendered output.
  final Duration? timeToFirstOutput;

  /// Safe, redacted error message if streaming failed.
  final String? error;

  bool get isStreaming => originalUrl.isNotEmpty;

  bool get isLoading =>
      stage == StreamStage.resolving ||
      stage == StreamStage.connecting ||
      stage == StreamStage.buffering ||
      stage == StreamStage.reconnecting ||
      stage == StreamStage.switchingQuality;

  StreamPlaybackState copyWith({
    int? attemptId,
    String? originalUrl,
    String? streamUrl,
    String? audioUrl,
    bool clearAudioUrl = false,
    String? resolvedTitle,
    bool clearResolvedTitle = false,
    StreamStage? stage,
    String? stageMessage,
    bool clearStageMessage = false,
    StreamRendition? selectedRendition,
    bool clearSelectedRendition = false,
    StreamRendition? activeRendition,
    bool clearActiveRendition = false,
    int? decodedWidth,
    int? decodedHeight,
    List<StreamRendition>? availableRenditions,
    bool? isAutoQuality,
    Duration? bufferedDuration,
    int? inputBitrate,
    bool clearInputBitrate = false,
    int? reconnectAttempts,
    bool? isLive,
    bool? seekable,
    DateTime? firstOutputTime,
    Duration? timeToFirstOutput,
    String? error,
    bool clearError = false,
  }) {
    return StreamPlaybackState(
      attemptId: attemptId ?? this.attemptId,
      originalUrl: originalUrl ?? this.originalUrl,
      streamUrl: streamUrl ?? this.streamUrl,
      audioUrl: clearAudioUrl ? null : (audioUrl ?? this.audioUrl),
      resolvedTitle: clearResolvedTitle
          ? null
          : (resolvedTitle ?? this.resolvedTitle),
      stage: stage ?? this.stage,
      stageMessage: clearStageMessage
          ? null
          : (stageMessage ?? this.stageMessage),
      selectedRendition: clearSelectedRendition
          ? null
          : (selectedRendition ?? this.selectedRendition),
      activeRendition: clearActiveRendition
          ? null
          : (activeRendition ?? this.activeRendition),
      decodedWidth: decodedWidth ?? this.decodedWidth,
      decodedHeight: decodedHeight ?? this.decodedHeight,
      availableRenditions: availableRenditions ?? this.availableRenditions,
      isAutoQuality: isAutoQuality ?? this.isAutoQuality,
      bufferedDuration: bufferedDuration ?? this.bufferedDuration,
      inputBitrate: clearInputBitrate
          ? null
          : (inputBitrate ?? this.inputBitrate),
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      isLive: isLive ?? this.isLive,
      seekable: seekable ?? this.seekable,
      firstOutputTime: firstOutputTime ?? this.firstOutputTime,
      timeToFirstOutput: timeToFirstOutput ?? this.timeToFirstOutput,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StreamPlaybackState &&
        other.attemptId == attemptId &&
        other.originalUrl == originalUrl &&
        other.streamUrl == streamUrl &&
        other.audioUrl == audioUrl &&
        other.resolvedTitle == resolvedTitle &&
        other.stage == stage &&
        other.stageMessage == stageMessage &&
        other.selectedRendition == selectedRendition &&
        other.activeRendition == activeRendition &&
        other.decodedWidth == decodedWidth &&
        other.decodedHeight == decodedHeight &&
        listEquals(other.availableRenditions, availableRenditions) &&
        other.isAutoQuality == isAutoQuality &&
        other.bufferedDuration == bufferedDuration &&
        other.inputBitrate == inputBitrate &&
        other.reconnectAttempts == reconnectAttempts &&
        other.isLive == isLive &&
        other.seekable == seekable &&
        other.firstOutputTime == firstOutputTime &&
        other.timeToFirstOutput == timeToFirstOutput &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(
    attemptId,
    originalUrl,
    streamUrl,
    audioUrl,
    stage,
    stageMessage,
    selectedRendition,
    activeRendition,
    decodedWidth,
    decodedHeight,
    Object.hashAll(availableRenditions),
    isAutoQuality,
    bufferedDuration,
    inputBitrate,
    reconnectAttempts,
    isLive,
    seekable,
    firstOutputTime,
    timeToFirstOutput,
    Object.hash(resolvedTitle, error),
  );

  @override
  String toString() =>
      'StreamPlaybackState(attempt: $attemptId, stage: ${stage.name}, '
      'rendition: ${activeRendition?.label ?? "none"}, buffer: ${bufferedDuration.inSeconds}s, '
      'bitrate: ${inputBitrate != null ? "${inputBitrate! ~/ 1000} kbps" : "unknown"})';
}
