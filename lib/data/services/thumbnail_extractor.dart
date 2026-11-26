import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/media_catalog.dart';
import '../../domain/models/media_kind.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_thumbnail.dart';
import 'diagnostic_log.dart';
import 'pure_dart_media_parser.dart';
import 'thumbnail_contract.dart';
import 'thumbnail_image.dart';
import 'thumbnail_image_poller.dart';

class MediaKitThumbnailExtractor implements ThumbnailExtractor {
  MediaKitThumbnailExtractor({
    ThumbnailImageValidator? imageValidator,
    this._diagnostics,
    Player Function()? playerFactory,
    PureDartMediaParser? pureDartParser,
  }) : _imageValidator = imageValidator ?? thumbnailImageIsDecodable,
       _playerFactory = playerFactory ?? _defaultPlayerFactory,
       _pureDartParser = pureDartParser ?? const PureDartMediaParser();

  static const Duration _nativeTimeout = Duration(seconds: 12);
  static const Duration _metadataWait = Duration(seconds: 4);
  static const Duration _frameWait = Duration(seconds: 6);

  final ThumbnailImageValidator _imageValidator;
  final DiagnosticSink? _diagnostics;
  final Player Function() _playerFactory;
  final PureDartMediaParser _pureDartParser;

  Player? _decoder;
  Future<void> _lock = Future<void>.value();
  Timer? _idleTimer;
  int _activeOperations = 0;
  bool _disposed = false;

  static Player _defaultPlayerFactory() => Player(
    configuration: const PlayerConfiguration(
      title: 'Mpvson thumbnail decoder',
      vo: 'null',
      muted: true,
      osc: false,
      libass: false,
      bufferSize: 0,
    ),
  );

  Player _getOrCreateDecoder() {
    if (_decoder != null) return _decoder!;
    return _decoder = _playerFactory();
  }

  void _recordDiagnostic(
    String stage, {
    String? source,
    String? message,
    Object? error,
  }) {
    final redacted = source == null ? 'unknown' : MediaSource.redact(source);
    _diagnostics?.record(
      stage,
      sourceId: redacted,
      message: message,
      error: error,
    );
  }

  Future<T> _runSerialized<T>({
    required ThumbnailCancellation? cancellation,
    required T defaultValue,
    required Future<T> Function(Player decoder) action,
  }) async {
    if (_disposed ||
        (cancellation?.isCancelled ?? false) ||
        (cancellation?.isInterrupted ?? false)) {
      return defaultValue;
    }

    _idleTimer?.cancel();
    _idleTimer = null;
    _activeOperations++;

    final previousLock = _lock;
    final completer = Completer<void>();
    _lock = completer.future;

    Player? decoder;
    try {
      await previousLock;
      if (_disposed ||
          (cancellation?.isCancelled ?? false) ||
          (cancellation?.isInterrupted ?? false)) {
        return defaultValue;
      }

      // Decoder creation can fail when native media initialization is
      // unavailable. Keep it inside the serialized cleanup so a failed factory
      // cannot leave every later operation waiting on this lock forever.
      final createdDecoder = _getOrCreateDecoder();
      decoder = createdDecoder;
      cancellation?.onInterrupt = () {
        try {
          unawaited(createdDecoder.stop());
        } catch (_) {}
      };
      if ((cancellation?.isCancelled ?? false) ||
          (cancellation?.isInterrupted ?? false)) {
        return defaultValue;
      }
      return await action(createdDecoder);
    } finally {
      if (decoder != null) {
        try {
          cancellation?.onInterrupt = null;
          await decoder.stop();
        } catch (_) {
          // Reset source-specific state between jobs.
        }
      }
      _finishOperation();
      completer.complete();
    }
  }

  void _finishOperation() {
    _activeOperations--;
    if (_activeOperations <= 0 && !_disposed) {
      _activeOperations = 0;
      _scheduleIdleCleanup();
    }
  }

  void _scheduleIdleCleanup() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_disposeIdleDecoder());
    });
  }

  @override
  void requestIdleCleanup() {
    if (_disposed) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_activeOperations <= 0) {
      unawaited(_disposeIdleDecoder());
    }
  }

  Future<void> _disposeIdleDecoder() async {
    if (_disposed || _activeOperations > 0 || _decoder == null) return;
    final previousLock = _lock;
    final completer = Completer<void>();
    _lock = completer.future;

    try {
      await previousLock;
    } catch (_) {}

    try {
      if (_disposed || _activeOperations > 0 || _decoder == null) return;
      final decoder = _decoder;
      _decoder = null;
      if (decoder != null) {
        try {
          await decoder.stop();
        } catch (_) {}
        try {
          await decoder.dispose();
        } catch (_) {}
      }
    } finally {
      completer.complete();
    }
  }

  @override
  Future<MediaThumbnail?> extract(
    String source, {
    required Directory outputDirectory,
    ThumbnailCancellation? cancellation,
  }) async {
    final audioArtwork = await _extractAudioArtwork(source, cancellation);
    if (audioArtwork.handled) return audioArtwork.extraction;
    return _runSerialized<MediaThumbnail?>(
      cancellation: cancellation,
      defaultValue: null,
      action: (player) async {
        final deadline = DateTime.now().add(_nativeTimeout);
        final native = player.platform;
        if (native is! NativePlayer) {
          _recordDiagnostic(
            'configure',
            source: source,
            message: 'Player platform is not NativePlayer',
          );
          return null;
        }
        try {
          await _configure(
            native,
            outputDirectory,
            deadline,
            imageOutput: false,
            // A video-only file is unloaded if both video and audio are
            // disabled. The null output keeps this metadata pass headless.
            videoTrack: 'auto',
          );
        } catch (error) {
          _recordDiagnostic(
            'configure',
            source: source,
            message: 'Failed configuring native VO properties',
            error: error,
          );
          return null;
        }

        if (_disposed ||
            (cancellation?.isCancelled ?? false) ||
            (cancellation?.isInterrupted ?? false)) {
          return null;
        }

        try {
          await player
              .open(Media(source), play: false)
              .timeout(_remaining(deadline));
        } catch (error) {
          _recordDiagnostic(
            'open',
            source: source,
            message: 'Failed opening source in native player',
            error: error,
          );
          return null;
        }

        if (_disposed ||
            (cancellation?.isCancelled ?? false) ||
            (cancellation?.isInterrupted ?? false)) {
          return null;
        }

        final tracks = await _waitForVideoTracks(
          player,
          native,
          deadline,
          cancellation: cancellation,
        );
        if (tracks == null || tracks.isEmpty) {
          _recordDiagnostic(
            'tracks',
            source: source,
            message: 'No video tracks discovered within metadata wait period',
          );
          return null;
        }

        final cover = _firstWhereOrNull(
          tracks,
          (track) => track.albumart == true || track.image == true,
        );
        final video =
            cover ??
            _firstWhereOrNull(
              tracks,
              (track) => track.albumart != true && track.image != true,
            );
        final selected = video;
        if (selected == null) {
          _recordDiagnostic(
            'track_selection',
            source: source,
            message: 'No suitable video or cover track found in track list',
          );
          return null;
        }

        final duration = await _readDuration(player, native, deadline);
        final start = cover == null
            ? _representativePosition(duration)
            : Duration.zero;

        if (_disposed ||
            (cancellation?.isCancelled ?? false) ||
            (cancellation?.isInterrupted ?? false)) {
          return null;
        }

        try {
          // Reopen with the chosen track and output driver set beforehand.
          // The metadata pass uses vo=null so automatic video selection cannot
          // leave an ordinary frame ahead of embedded cover art in the output.
          await player.stop().timeout(_remaining(deadline));
          await _configure(
            native,
            outputDirectory,
            deadline,
            imageOutput: true,
            videoTrack: selected.id,
          );
          await player
              .open(Media(source, start: start), play: false)
              .timeout(_remaining(deadline));
          await player.seek(start).timeout(_remaining(deadline));
          await native.setProperty('frames', '1').timeout(_remaining(deadline));
          await player.play().timeout(_remaining(deadline));
        } catch (error) {
          _recordDiagnostic(
            'play',
            source: source,
            message: 'Failed activating frame extraction under vo=image',
            error: error,
          );
          return null;
        }

        final bytes = await _waitForCompleteImage(
          outputDirectory,
          deadline,
          cancellation: cancellation,
          source: source,
        );
        if (bytes == null || bytes.isEmpty) return null;
        if (_disposed ||
            (cancellation?.isCancelled ?? false) ||
            (cancellation?.isInterrupted ?? false)) {
          return null;
        }

        return MediaThumbnail(bytes: bytes, duration: duration);
      },
    );
  }

  /// Reads embedded audio artwork without starting a native decoder.
  ///
  /// Capturing a frame from an audio-only container cannot produce a usable
  /// thumbnail, and creating a decoder for every song delayed music artwork
  /// substantially. Containers understood by the pure parser are resolved
  /// here; anything else still falls back to the native path.
  Future<({bool handled, MediaThumbnail? extraction})> _extractAudioArtwork(
    String source,
    ThumbnailCancellation? cancellation,
  ) async {
    if (MediaCatalog.kindFromExtension(source) != MediaKind.audio) {
      return (handled: false, extraction: null);
    }
    if (_disposed || (cancellation?.isCancelled ?? false)) {
      return (handled: true, extraction: null);
    }
    final info = await _pureDartParser.parse(source);
    if (_disposed || (cancellation?.isCancelled ?? false)) {
      return (handled: true, extraction: null);
    }
    if (info == null) return (handled: false, extraction: null);
    final artwork = info.embeddedArtworkBytes;
    if (artwork == null || artwork.isEmpty) {
      return (handled: true, extraction: null);
    }
    return (
      handled: true,
      extraction: MediaThumbnail(bytes: artwork, duration: info.duration),
    );
  }

  Future<void> _configure(
    NativePlayer player,
    Directory output,
    DateTime deadline, {
    required bool imageOutput,
    required String videoTrack,
  }) async {
    await player
        .setProperty('vo-image-outdir', p.normalize(output.path))
        .timeout(_remaining(deadline));
    await player
        .setProperty('vo-image-format', 'jpg')
        .timeout(_remaining(deadline));
    await player
        .setProperty('vo-image-jpeg-quality', '84')
        .timeout(_remaining(deadline));
    await player.setProperty('sid', 'no').timeout(_remaining(deadline));
    await player.setProperty('vid', videoTrack).timeout(_remaining(deadline));
    // Keep audio selected so mpv exposes attached cover-art tracks, but send it
    // to a null output instead of opening the user's audio device.
    await player.setProperty('ao', 'null').timeout(_remaining(deadline));
    await player.setProperty('aid', 'auto').timeout(_remaining(deadline));
    // Clear the previous capture's one-frame limit before opening either pass.
    await player.setProperty('frames', 'all').timeout(_remaining(deadline));
    await player
        .setProperty('cache-on-disk', 'no')
        .timeout(_remaining(deadline));
    await player.setProperty('cache', 'no').timeout(_remaining(deadline));
    await player
        .setProperty('demuxer-readahead-secs', '0')
        .timeout(_remaining(deadline));
    await player
        .setProperty('demuxer-max-bytes', '2097152')
        .timeout(_remaining(deadline));
    await player
        .setProperty('demuxer-max-back-bytes', '0')
        .timeout(_remaining(deadline));
    await player
        .setProperty('vd-lavc-threads', '1')
        .timeout(_remaining(deadline));

    // Scale native output before writing where supported.
    try {
      await player
          .setProperty(
            'vf',
            'scale=w=320:h=320:force_original_aspect_ratio=decrease',
          )
          .timeout(_remaining(deadline));
    } on Object {
      // Native scaling is best-effort optimization; Dart normalizer guarantees bounds.
    }

    // Select output before opening. Duration probes leave the shared decoder at
    // vo=null; switching back only after open can leave the next capture silent.
    await player
        .setProperty('vo', imageOutput ? 'image' : 'null')
        .timeout(_remaining(deadline));
  }

  Future<List<VideoTrack>?> _waitForVideoTracks(
    Player player,
    NativePlayer native,
    DateTime deadline, {
    ThumbnailCancellation? cancellation,
  }) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < _metadataWait && DateTime.now().isBefore(deadline)) {
      if (_disposed ||
          (cancellation?.isCancelled ?? false) ||
          (cancellation?.isInterrupted ?? false)) {
        return null;
      }
      final video = _realVideoTracks(player);
      if (video.isNotEmpty) return video;
      final nativeTracks = await _readNativeVideoTracks(native, deadline);
      if (nativeTracks.isNotEmpty) return nativeTracks;
      await _readDuration(player, native, deadline);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return _realVideoTracks(player);
  }

  Future<List<VideoTrack>> _readNativeVideoTracks(
    NativePlayer native,
    DateTime deadline,
  ) async {
    Future<String?> read(String property) async {
      if (!DateTime.now().isBefore(deadline)) return null;
      try {
        final remaining = _remaining(deadline);
        final timeout = remaining < const Duration(milliseconds: 700)
            ? remaining
            : const Duration(milliseconds: 700);
        final value = (await native.getProperty(property).timeout(timeout))
            .trim();
        return value.isEmpty || value == 'unavailable' ? null : value;
      } catch (_) {
        return null;
      }
    }

    final count = int.tryParse(await read('track-list/count') ?? '') ?? 0;
    final tracks = <VideoTrack>[];
    for (var index = 0; index < count && index < 32; index++) {
      if (await read('track-list/$index/type') != 'video') continue;
      final id = await read('track-list/$index/id');
      if (id == null || id.isEmpty) continue;
      final isArtwork = await read('track-list/$index/albumart') == 'yes';
      final isImage = await read('track-list/$index/image') == 'yes';
      tracks.add(
        VideoTrack(id, null, null, albumart: isArtwork, image: isImage),
      );
    }
    return tracks;
  }

  Future<Duration> _readDuration(
    Player player,
    NativePlayer native,
    DateTime deadline,
  ) async {
    final duration = player.state.duration;
    if (duration > Duration.zero) return duration;
    if (!DateTime.now().isBefore(deadline)) return Duration.zero;
    try {
      final remaining = _remaining(deadline);
      final timeout = remaining > const Duration(milliseconds: 700)
          ? const Duration(milliseconds: 700)
          : remaining;
      final text = await native.getProperty('duration').timeout(timeout);
      final seconds = double.tryParse(text.trim());
      if (seconds != null && seconds.isFinite && seconds > 0) {
        return Duration(
          microseconds: (seconds * Duration.microsecondsPerSecond).round(),
        );
      }
    } on Object {
      // Duration metadata is optional; thumbnails remain useful without it.
    }
    return Duration.zero;
  }

  static Duration _representativePosition(Duration duration) {
    if (duration <= const Duration(milliseconds: 500)) return Duration.zero;
    final target = duration.inMilliseconds ~/ 10;
    final milliseconds = target.clamp(300, 5000).toInt();
    return Duration(
      milliseconds: milliseconds
          .clamp(0, duration.inMilliseconds - 150)
          .toInt(),
    );
  }

  Future<Uint8List?> _waitForCompleteImage(
    Directory directory,
    DateTime deadline, {
    ThumbnailCancellation? cancellation,
    String? source,
  }) async {
    const poller = ThumbnailImagePoller(
      maximumBytes: thumbnailMaximumExtractedBytes,
    );
    final result = await poller.waitForImage(
      directory: directory,
      deadline: deadline,
      timeout: _frameWait,
      hasImageHeader: thumbnailBytesLookLikeImage,
      decodes: _isValidImage,
      isCancelled: () =>
          _disposed ||
          (cancellation?.isCancelled ?? false) ||
          (cancellation?.isInterrupted ?? false),
    );
    switch (result.failure) {
      case ThumbnailImagePollFailure.none:
        return result.bytes;
      case ThumbnailImagePollFailure.cancelled:
        return null;
      case ThumbnailImagePollFailure.oversized:
        _recordDiagnostic(
          'file_size_limit',
          source: source,
          message:
              'Extracted image exceeds 12 MiB limit (${result.lastSeenSize} bytes)',
        );
        return null;
      case ThumbnailImagePollFailure.deadline:
        _recordDiagnostic(
          'capture',
          source: source,
          message: result.lastSeenSize > 0
              ? 'Partial image (${result.lastSeenSize} bytes) did not complete before deadline'
              : 'No output image file detected before deadline',
        );
        return null;
      case ThumbnailImagePollFailure.filesystem:
        _recordDiagnostic(
          'capture',
          source: source,
          message: 'Could not inspect native thumbnail output',
        );
        return null;
    }
  }

  Future<bool> _isValidImage(Uint8List bytes) async {
    try {
      return await _imageValidator(bytes);
    } on Object {
      return false;
    }
  }

  static List<VideoTrack> _realVideoTracks(Player player) => player
      .state
      .tracks
      .video
      .where((track) => track.id != 'auto' && track.id != 'no')
      .toList(growable: false);

  static Duration _remaining(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Thumbnail decoder operation timed out.');
    }
    return remaining;
  }

  static T? _firstWhereOrNull<T>(
    Iterable<T> values,
    bool Function(T value) predicate,
  ) {
    for (final value in values) {
      if (predicate(value)) return value;
    }
    return null;
  }

  @override
  Future<Duration> probeDuration(
    String source, {
    ThumbnailCancellation? cancellation,
  }) async {
    if (MediaCatalog.kindFromExtension(source) == MediaKind.audio) {
      final info = await _pureDartParser.parse(source);
      if (_disposed || (cancellation?.isCancelled ?? false)) {
        return Duration.zero;
      }
      if (info != null) return info.duration;
    }
    return _runSerialized<Duration>(
      cancellation: cancellation,
      defaultValue: Duration.zero,
      action: (player) async {
        final deadline = DateTime.now().add(_nativeTimeout);
        try {
          final native = player.platform;
          if (native is! NativePlayer) return Duration.zero;
          await native.setProperty('vo', 'null').timeout(_remaining(deadline));
          await native.setProperty('sid', 'no').timeout(_remaining(deadline));
          await native.setProperty('vid', 'auto').timeout(_remaining(deadline));
          await native.setProperty('ao', 'null').timeout(_remaining(deadline));
          await native.setProperty('aid', 'auto').timeout(_remaining(deadline));
          await native
              .setProperty('cache-on-disk', 'no')
              .timeout(_remaining(deadline));
          await native.setProperty('cache', 'no').timeout(_remaining(deadline));
          await native
              .setProperty('demuxer-readahead-secs', '0')
              .timeout(_remaining(deadline));
          await native
              .setProperty('demuxer-max-bytes', '2097152')
              .timeout(_remaining(deadline));
          await native
              .setProperty('demuxer-max-back-bytes', '0')
              .timeout(_remaining(deadline));
          await native
              .setProperty('vd-lavc-threads', '1')
              .timeout(_remaining(deadline));
          await native
              .setProperty('frames', 'all')
              .timeout(_remaining(deadline));
          await player
              .open(Media(source), play: false)
              .timeout(_remaining(deadline));

          final watch = Stopwatch()..start();
          while (watch.elapsed < _metadataWait &&
              DateTime.now().isBefore(deadline)) {
            if (_disposed || (cancellation?.isCancelled ?? false)) {
              return Duration.zero;
            }
            final duration = await _readDuration(player, native, deadline);
            if (duration > Duration.zero) return duration;
            await Future<void>.delayed(const Duration(milliseconds: 80));
          }
          return Duration.zero;
        } on Object {
          return Duration.zero;
        }
      },
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _idleTimer?.cancel();
    _idleTimer = null;

    final previousLock = _lock;
    final completer = Completer<void>();
    _lock = completer.future;

    try {
      await previousLock;
    } catch (_) {}

    final decoder = _decoder;
    _decoder = null;
    if (decoder != null) {
      try {
        await decoder.stop();
      } catch (_) {}
      try {
        await decoder.dispose();
      } catch (_) {}
    }
    completer.complete();
  }
}
