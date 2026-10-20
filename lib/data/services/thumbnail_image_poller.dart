import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

typedef ThumbnailImageHeaderCheck = bool Function(Uint8List bytes);
typedef ThumbnailImageDecoder = Future<bool> Function(Uint8List bytes);

enum ThumbnailImagePollFailure {
  none,
  cancelled,
  deadline,
  oversized,
  filesystem,
}

class ThumbnailImagePollResult {
  const ThumbnailImagePollResult({
    required this.failure,
    this.bytes,
    this.lastSeenSize = 0,
  });

  final ThumbnailImagePollFailure failure;
  final Uint8List? bytes;
  final int lastSeenSize;
}

/// Waits for a native thumbnail output file to finish writing and decode.
/// Reads stay bounded even if the file grows between the size check and read.
/// Transient filesystem errors are retried until the deadline; a missing output
/// directory fails immediately.
class ThumbnailImagePoller {
  const ThumbnailImagePoller({
    required this.maximumBytes,
    this.pollInterval = const Duration(milliseconds: 35),
  });

  static const Set<String> supportedExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
  };

  final int maximumBytes;
  final Duration pollInterval;

  Future<ThumbnailImagePollResult> waitForImage({
    required Directory directory,
    required DateTime deadline,
    required Duration timeout,
    required ThumbnailImageHeaderCheck hasImageHeader,
    required ThumbnailImageDecoder decodes,
    bool Function()? isCancelled,
  }) async {
    final watch = Stopwatch()..start();
    final lastSizes = <String, int>{};
    final lastFailedSizes = <String, int>{};
    final lastFailedMtimes = <String, DateTime>{};
    var lastSeenSize = 0;

    while (watch.elapsed < timeout && DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() ?? false) {
        return ThumbnailImagePollResult(
          failure: ThumbnailImagePollFailure.cancelled,
          lastSeenSize: lastSeenSize,
        );
      }

      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (isCancelled?.call() ?? false) {
            return ThumbnailImagePollResult(
              failure: ThumbnailImagePollFailure.cancelled,
              lastSeenSize: lastSeenSize,
            );
          }
          if (entity is! File ||
              !supportedExtensions.contains(_extension(entity.path))) {
            continue;
          }

          final FileStat before;
          try {
            before = await entity.stat();
          } on FileSystemException {
            // Windows may briefly deny stat while the writer still holds the
            // file; retry on a later poll instead of failing the whole capture.
            continue;
          }
          if (before.type != FileSystemEntityType.file || before.size <= 0) {
            continue;
          }
          lastSeenSize = before.size > lastSeenSize
              ? before.size
              : lastSeenSize;
          if (before.size > maximumBytes) {
            return ThumbnailImagePollResult(
              failure: ThumbnailImagePollFailure.oversized,
              lastSeenSize: before.size,
            );
          }

          final previousFailedSize = lastFailedSizes[entity.path];
          final previousFailedMtime = lastFailedMtimes[entity.path];
          if (previousFailedSize == before.size &&
              previousFailedMtime == before.modified) {
            // Contents/size have not changed since last decode failure; do not retry yet.
            continue;
          }

          final previousSize = lastSizes[entity.path];
          lastSizes[entity.path] = before.size;
          if (previousSize != before.size) continue;

          RandomAccessFile? handle;
          try {
            handle = await entity.open(mode: FileMode.read);
            final readSize = await handle.length();
            if (readSize > maximumBytes) {
              return ThumbnailImagePollResult(
                failure: ThumbnailImagePollFailure.oversized,
                lastSeenSize: readSize,
              );
            }
            final bytes = await handle.read(readSize);
            final after = await entity.stat();
            if (bytes.length != readSize ||
                after.type != FileSystemEntityType.file ||
                after.size != before.size) {
              lastSizes.remove(entity.path);
              continue;
            }
            if (bytes.isEmpty || !hasImageHeader(bytes)) continue;

            final decodeResult = Completer<bool>();
            try {
              unawaited(
                decodes(bytes).then(
                  (value) {
                    if (!decodeResult.isCompleted) {
                      decodeResult.complete(value);
                    }
                  },
                  onError: (Object _, StackTrace _) {
                    if (!decodeResult.isCompleted) {
                      decodeResult.complete(false);
                    }
                  },
                ),
              );
            } on Object {
              decodeResult.complete(false);
            }
            while (!decodeResult.isCompleted) {
              if (isCancelled?.call() ?? false) {
                return ThumbnailImagePollResult(
                  failure: ThumbnailImagePollFailure.cancelled,
                  lastSeenSize: lastSeenSize,
                );
              }
              final timeoutRemaining = timeout - watch.elapsed;
              final deadlineRemaining = deadline.difference(DateTime.now());
              if (timeoutRemaining <= Duration.zero ||
                  deadlineRemaining <= Duration.zero) {
                return ThumbnailImagePollResult(
                  failure: ThumbnailImagePollFailure.deadline,
                  lastSeenSize: lastSeenSize,
                );
              }
              final remaining = timeoutRemaining < deadlineRemaining
                  ? timeoutRemaining
                  : deadlineRemaining;
              final pause = remaining < pollInterval ? remaining : pollInterval;
              await Future<void>.delayed(pause);
            }
            final isDecodable = await decodeResult.future;
            if (isCancelled?.call() ?? false) {
              return ThumbnailImagePollResult(
                failure: ThumbnailImagePollFailure.cancelled,
                lastSeenSize: lastSeenSize,
              );
            }
            if (watch.elapsed >= timeout ||
                !DateTime.now().isBefore(deadline)) {
              return ThumbnailImagePollResult(
                failure: ThumbnailImagePollFailure.deadline,
                lastSeenSize: lastSeenSize,
              );
            }
            if (isDecodable) {
              lastFailedSizes.remove(entity.path);
              lastFailedMtimes.remove(entity.path);
              return ThumbnailImagePollResult(
                failure: ThumbnailImagePollFailure.none,
                bytes: bytes,
                lastSeenSize: bytes.length,
              );
            } else {
              lastFailedSizes[entity.path] = before.size;
              lastFailedMtimes[entity.path] = before.modified;
            }
          } on FileSystemException {
            // Windows may briefly deny reads while libmpv closes the file.
          } finally {
            try {
              await handle?.close();
            } on Object {
              // A failed close does not make the image usable.
            }
          }
        }
      } on FileSystemException {
        if (isCancelled?.call() ?? false) {
          return ThumbnailImagePollResult(
            failure: ThumbnailImagePollFailure.cancelled,
            lastSeenSize: lastSeenSize,
          );
        }
        if (!await _directoryExists(directory)) {
          return ThumbnailImagePollResult(
            failure: ThumbnailImagePollFailure.filesystem,
            lastSeenSize: lastSeenSize,
          );
        }
        // The directory is still present, so the failure is transient. Keep
        // polling until the normal deadline instead of failing the capture.
      }

      if (isCancelled?.call() ?? false) {
        return ThumbnailImagePollResult(
          failure: ThumbnailImagePollFailure.cancelled,
          lastSeenSize: lastSeenSize,
        );
      }
      await Future<void>.delayed(pollInterval);
    }

    return ThumbnailImagePollResult(
      failure: ThumbnailImagePollFailure.deadline,
      lastSeenSize: lastSeenSize,
    );
  }

  static Future<bool> _directoryExists(Directory directory) async {
    try {
      return await directory.exists();
    } on FileSystemException {
      return false;
    }
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot).toLowerCase();
  }
}
