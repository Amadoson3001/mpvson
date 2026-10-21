import 'package:meta/meta.dart';

/// Intent of an incoming media opening request.
enum OpenIntent {
  /// Resolves according to saved user preference (or prompts on first conflict).
  normal,

  /// Explicitly replaces the current queue and begins playback immediately.
  playNow,

  /// Explicitly appends to the queue without disrupting current playback.
  enqueue,
}

/// Origin of an opening request.
enum OpenOrigin {
  startupArgs,
  osActivation,
  dragAndDrop,
  filePicker,
  library,
  playlist,
  other,
}

/// A request to open one or more media sources.
@immutable
class OpenRequest {
  const OpenRequest({
    required this.id,
    required this.sources,
    this.intent = OpenIntent.normal,
    this.origin = OpenOrigin.other,
    this.timestamp,
  });

  final String id;
  final List<String> sources;
  final OpenIntent intent;
  final OpenOrigin origin;
  final DateTime? timestamp;

  OpenRequest copyWith({
    String? id,
    List<String>? sources,
    OpenIntent? intent,
    OpenOrigin? origin,
    DateTime? timestamp,
  }) {
    return OpenRequest(
      id: id ?? this.id,
      sources: sources ?? this.sources,
      intent: intent ?? this.intent,
      origin: origin ?? this.origin,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
