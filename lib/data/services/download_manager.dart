import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Progress callback reporting current fractional progress (0.0 to 1.0),
/// received byte count, and expected total byte count if known.
typedef DownloadProgressCallback =
    void Function(double progress, int receivedBytes, int? totalBytes);

/// Flusher callback used to handle backpressure on the sink (injectable for testing).
typedef DownloadSinkFlusher = Future<void> Function(IOSink sink);

/// Result of a completed streaming download.
class DownloadResult {
  final int totalBytes;
  final String sha256;
  final Uint8List? bytes;

  const DownloadResult({
    required this.totalBytes,
    required this.sha256,
    this.bytes,
  });
}

/// Thrown when a download is aborted or cancelled.
class DownloadCancelledException implements Exception {
  final String message;
  const DownloadCancelledException([this.message = 'Download was cancelled.']);

  @override
  String toString() => message;
}

/// Thrown when download constraints (size, duration, timeout, hash) are violated.
class DownloadException implements Exception {
  final String message;
  const DownloadException(this.message);

  @override
  String toString() => message;
}

class DownloadIdleTimeoutException extends DownloadException {
  const DownloadIdleTimeoutException([
    super.message = 'Download stream timed out.',
  ]);
}

class DownloadDurationExceededException extends DownloadException {
  const DownloadDurationExceededException([
    super.message = 'Download exceeded the time limit.',
  ]);
}

class DownloadSizeLimitException extends DownloadException {
  const DownloadSizeLimitException([
    super.message = 'Download exceeds the configured size limit.',
  ]);
}

class DownloadSizeMismatchException extends DownloadException {
  const DownloadSizeMismatchException([
    super.message = 'Download size does not match expected size.',
  ]);
}

class DownloadHashMismatchException extends DownloadException {
  const DownloadHashMismatchException([
    super.message = 'Downloaded file SHA-256 mismatch.',
  ]);
}

class _Sha256Sink implements Sink<crypto.Digest> {
  crypto.Digest? digest;

  @override
  void add(crypto.Digest data) => digest = data;

  @override
  void close() {}
}

/// Utility for streaming data to a file or memory with progress reporting,
/// idle timeouts, size enforcement, backpressure handling, and SHA-256 verification.
class DownloadManager {
  const DownloadManager({
    this.idleTimeout = const Duration(seconds: 20),
    this.maxDuration = const Duration(minutes: 30),
  });

  final Duration idleTimeout;
  final Duration maxDuration;

  /// Streams [stream] into [destinationFile], computing its SHA-256 and enforcing limits.
  Future<DownloadResult> streamToFile(
    Stream<List<int>> stream,
    File destinationFile, {
    Completer<void>? abort,
    int? maxBytes,
    int? expectedBytes,
    String? expectedSha256,
    DownloadProgressCallback? onProgress,
    DownloadSinkFlusher? flushSink,
    bool Function()? isDisposed,
    void Function(void Function() abortCallback)? registerAbortCallback,
  }) {
    return _consume(
      stream,
      abort: abort,
      maxBytes: maxBytes,
      expectedBytes: expectedBytes,
      expectedSha256: expectedSha256,
      onProgress: onProgress,
      isDisposed: isDisposed,
      registerAbortCallback: registerAbortCallback,
      destinationFile: destinationFile,
      flushSink: flushSink,
      collectBytes: false,
    );
  }

  /// Streams [stream] into memory, computing its SHA-256 and enforcing limits.
  Future<DownloadResult> streamToBytes(
    Stream<List<int>> stream, {
    Completer<void>? abort,
    int? maxBytes,
    int? expectedBytes,
    String? expectedSha256,
    DownloadProgressCallback? onProgress,
    bool Function()? isDisposed,
    void Function(void Function() abortCallback)? registerAbortCallback,
  }) {
    return _consume(
      stream,
      abort: abort,
      maxBytes: maxBytes,
      expectedBytes: expectedBytes,
      expectedSha256: expectedSha256,
      onProgress: onProgress,
      isDisposed: isDisposed,
      registerAbortCallback: registerAbortCallback,
      collectBytes: true,
    );
  }

  Future<DownloadResult> _consume(
    Stream<List<int>> stream, {
    Completer<void>? abort,
    int? maxBytes,
    int? expectedBytes,
    String? expectedSha256,
    DownloadProgressCallback? onProgress,
    DownloadSinkFlusher? flushSink,
    bool Function()? isDisposed,
    void Function(void Function() abortCallback)? registerAbortCallback,
    File? destinationFile,
    required bool collectBytes,
  }) async {
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    var received = 0;
    var finished = false;
    Timer? idleTimer;
    StreamSubscription<List<int>>? subscription;
    IOSink? sink;
    final memory = collectBytes ? BytesBuilder(copy: false) : null;
    final digestSink = _Sha256Sink();
    final hashInput = crypto.sha256.startChunkedConversion(digestSink);

    void fail(Object error) {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      subscription?.cancel();
      if (!completer.isCompleted) completer.completeError(error);
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(idleTimeout, () {
        if (abort != null && !abort.isCompleted) {
          abort.complete();
        }
        fail(const DownloadIdleTimeoutException());
      });
    }

    void abortCallback() {
      fail(const DownloadCancelledException());
    }

    registerAbortCallback?.call(abortCallback);

    if (abort != null) {
      if (abort.isCompleted) {
        fail(const DownloadCancelledException());
      } else {
        abort.future.then((_) {
          fail(const DownloadCancelledException());
        });
      }
    }

    var sinkBackpressure = false;
    void resumeAfterSink() {
      sinkBackpressure = false;
      if (finished ||
          completer.isCompleted ||
          (abort != null && abort.isCompleted) ||
          (isDisposed?.call() == true)) {
        return;
      }
      resetIdleTimer();
      subscription?.resume();
    }

    try {
      if (destinationFile != null) {
        sink = destinationFile.openWrite();
      }
      resetIdleTimer();

      subscription = stream.listen(
        (chunk) {
          if (isDisposed?.call() == true ||
              (abort != null && abort.isCompleted)) {
            fail(const DownloadCancelledException());
            return;
          }
          resetIdleTimer();
          if (stopwatch.elapsed > maxDuration) {
            fail(const DownloadDurationExceededException());
            return;
          }
          received += chunk.length;
          if (maxBytes != null && received > maxBytes) {
            fail(const DownloadSizeLimitException());
            return;
          }
          if (expectedBytes != null &&
              expectedBytes > 0 &&
              received > expectedBytes) {
            fail(const DownloadSizeLimitException());
            return;
          }
          hashInput.add(chunk);
          sink?.add(chunk);
          memory?.add(chunk);

          if (onProgress != null) {
            final total = expectedBytes ?? maxBytes;
            final frac = (total != null && total > 0)
                ? (received / total).clamp(0.0, 1.0)
                : 0.0;
            onProgress(frac, received, expectedBytes);
          }

          final currentSink = sink;
          if (flushSink != null && !sinkBackpressure && currentSink != null) {
            sinkBackpressure = true;
            idleTimer?.cancel();
            idleTimer = null;
            subscription?.pause();
            final flushFuture = flushSink(currentSink);
            flushFuture.catchError((_) {}).whenComplete(resumeAfterSink);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          fail(error);
        },
        onDone: () async {
          if (finished) return;
          finished = true;
          idleTimer?.cancel();
          if (stopwatch.elapsed > maxDuration) {
            completer.completeError(const DownloadDurationExceededException());
            return;
          }
          try {
            hashInput.close();
            final activeSink = sink;
            sink = null;
            if (activeSink != null) {
              await activeSink.flush();
              await activeSink.close();
            }

            if (expectedBytes != null &&
                expectedBytes > 0 &&
                received != expectedBytes) {
              completer.completeError(const DownloadSizeMismatchException());
              return;
            }

            final sha = digestSink.digest?.toString() ?? '';
            if (expectedSha256 != null &&
                expectedSha256.isNotEmpty &&
                sha.toLowerCase() != expectedSha256.toLowerCase()) {
              completer.completeError(const DownloadHashMismatchException());
              return;
            }

            completer.complete();
          } catch (e, st) {
            completer.completeError(e, st);
          }
        },
        cancelOnError: true,
      );

      await completer.future;
      return DownloadResult(
        totalBytes: received,
        sha256: digestSink.digest?.toString() ?? '',
        bytes: memory?.takeBytes(),
      );
    } finally {
      idleTimer?.cancel();
      await subscription?.cancel();
      try {
        await sink?.close();
      } catch (_) {}
    }
  }
}
