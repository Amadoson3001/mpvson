import 'dart:io';
import 'dart:typed_data';

import '../../domain/models/media_entry.dart';
import '../../domain/models/media_thumbnail.dart';

/// A thumbnail image and the duration discovered while opening its source.
class ThumbnailExtraction {
  ThumbnailExtraction({required Uint8List bytes, this.duration = Duration.zero})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final Uint8List bytes;
  final Duration duration;
}

/// Cancellation token passed to extraction operations to support early termination
/// and decoder interruption.
class ThumbnailCancellation {
  bool _cancelled = false;
  bool _interrupted = false;
  int _interruptionGeneration = 0;
  bool _waitingInQueue = false;
  void Function(bool waiting)? _onQueueStateChange;
  void Function()? onInterrupt;

  bool get isCancelled => _cancelled;
  bool get isInterrupted => _interrupted;
  int get interruptionGeneration => _interruptionGeneration;
  bool get isWaitingInQueue => _waitingInQueue;

  void interrupt() {
    _interrupted = true;
    _interruptionGeneration++;
    try {
      onInterrupt?.call();
    } on Object {
      // Interruption is best effort.
    }
  }

  void resetInterrupted() {
    _interrupted = false;
  }

  void setWaitingInQueue(bool waiting) {
    if (_waitingInQueue == waiting) return;
    _waitingInQueue = waiting;
    _onQueueStateChange?.call(waiting);
  }

  /// Observes queue waits so a request can pause its timeout while queued.
  void bindQueueWait(void Function(bool waiting)? listener) {
    _onQueueStateChange = listener;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    interrupt();
  }
}

/// A reference-counted handle for an active or queued thumbnail request.
///
/// Consumers retain this handle while the thumbnail is needed (e.g. while a
/// queue row is mounted or visible) and call [release] or [cancel] when no
/// longer needed. When all handles for a request are released, the request is
/// cancelled, removed from queues, and any active decoder is interrupted.
abstract interface class ThumbnailRequestHandle {
  /// The entry whose thumbnail was requested.
  MediaEntry get entry;

  /// The resulting thumbnail image bytes, or `null` if the request failed or was cancelled.
  Future<Uint8List?> get result;

  /// The resulting [MediaThumbnail], or `null` if the request failed or was cancelled.
  Future<MediaThumbnail?> get thumbnail;

  /// Releases this consumer's interest in the thumbnail.
  ///
  /// When no active consumers remain for a request, it is removed from queues
  /// and active decoders are interrupted where possible.
  void release();

  /// Releases this consumer's interest in the thumbnail. Alias for [release].
  void cancel();
}

/// Local diagnostic record tracking thumbnail extraction stages and failures.
class ThumbnailDiagnosticRecord {
  const ThumbnailDiagnosticRecord({
    required this.stage,
    required this.sourceId,
    required this.timestamp,
    this.message,
    this.error,
  });

  /// The processing stage during which the event or failure occurred.
  final String stage;

  /// Redacted identifier of the media source.
  final String sourceId;

  /// When this diagnostic was recorded.
  final DateTime timestamp;

  /// Optional stage diagnostic details.
  final String? message;

  /// Optional underlying error or exception.
  final Object? error;

  @override
  String toString() =>
      '[$stage] source=$sourceId${message != null ? ': $message' : ''}${error != null ? ' ($error)' : ''}';
}

/// Extraction boundary for deterministic tests and alternate native engines.
///
/// Implementations must write any temporary output only into
/// [outputDirectory], must not modify [source], and should return `null` when
/// the source has no usable video frame.
abstract interface class ThumbnailExtractor {
  Future<ThumbnailExtraction?> extract(
    String source, {
    required Directory outputDirectory,
    ThumbnailCancellation? cancellation,
  });

  /// Reads duration metadata without asking the video output to render a frame.
  Future<Duration> probeDuration(
    String source, {
    ThumbnailCancellation? cancellation,
  });

  void requestIdleCleanup() {}

  Future<void> dispose();
}

enum ThumbnailPriority { normal, high }

abstract interface class ThumbnailService {
  Future<MediaThumbnail?> load(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  });

  /// Requests a thumbnail with a reference-counted handle that can be cancelled.
  ThumbnailRequestHandle request(
    MediaEntry entry, {
    ThumbnailPriority priority = ThumbnailPriority.normal,
  });

  /// Returns a memory-cached thumbnail for immediate display, if present.
  MediaThumbnail? peek(MediaEntry entry);

  void suspend() {}

  void resume() {}

  void trimMemory() {}

  Future<void> dispose();
}

typedef ThumbnailImageValidator = Future<bool> Function(Uint8List bytes);
