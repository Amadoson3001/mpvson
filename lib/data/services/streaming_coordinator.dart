import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../../domain/models/media_source.dart';
import '../../domain/models/resolved_stream.dart';
import '../../domain/models/stream_playback_state.dart';
import 'diagnostic_log.dart';
import 'native_media_events.dart';
import 'stream_manifest_service.dart';
import 'yt_dlp_resolver.dart';

/// Information produced when preparing a network stream for libmpv.
@immutable
class ResolvedStreamInfo {
  const ResolvedStreamInfo({
    required this.attemptId,
    required this.originalUrl,
    required this.playableUrl,
    this.audioUrl,
    this.title,
    this.renditions = const [],
    this.selectedRendition,
    this.isLive = false,
    this.isExpiring = false,
    this.expiresAt,
    this.httpHeaders,
  });

  final int attemptId;
  final String originalUrl;
  final String playableUrl;
  final String? audioUrl;
  final String? title;
  final List<StreamRendition> renditions;
  final StreamRendition? selectedRendition;
  final bool isLive;
  final bool isExpiring;
  final DateTime? expiresAt;
  final Map<String, String>? httpHeaders;
}

/// Coordinates cloud media streaming, attempt lifecycles, buffering policies,
/// transient retries, rendition switching, and auto-quality adaptation.
class StreamingCoordinator {
  StreamingCoordinator({
    YtDlpResolver? ytDlpResolver,
    StreamManifestService? manifestService,
    this.diagnostics,
  }) : ytDlpResolver = ytDlpResolver ?? YtDlpResolver(),
       manifestService = manifestService ?? StreamManifestService();

  final YtDlpResolver ytDlpResolver;
  final StreamManifestService manifestService;
  final DiagnosticSink? diagnostics;

  final StreamController<StreamPlaybackState> _stateController =
      StreamController<StreamPlaybackState>.broadcast();
  Stream<StreamPlaybackState> get streamState => _stateController.stream;

  StreamPlaybackState _currentState = const StreamPlaybackState();
  StreamPlaybackState get state => _currentState;

  int _attemptCounter = 0;
  int get currentAttemptId => _currentState.attemptId;

  CancellationToken? _currentCancelToken;
  DateTime? _attemptStartTime;

  // Resolved source memory
  ResolvedStream? _activeResolvedPage;
  StreamManifestInfo? _activeManifest;

  ResolvedStream? get activeResolvedPage => _activeResolvedPage;
  StreamManifestInfo? get activeManifest => _activeManifest;

  // Auto-quality tracking
  DateTime? _lastQualitySwitchTime;
  int _consecutiveUnderruns = 0;
  DateTime? _firstUnderrunWindowStart;
  DateTime? _healthyBufferStart;

  static const Duration _switchCooldown = Duration(seconds: 15);
  static const int _initialBitrateBudget =
      2000000; // 2 Mbps ceiling for initial Auto

  void _emit(StreamPlaybackState newState) {
    _currentState = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Cancels any outstanding attempt and resets to idle.
  void cancelActiveAttempt({String? reason}) {
    if (_currentCancelToken != null && !_currentCancelToken!.isCancelled) {
      _currentCancelToken!.cancel();
      _currentCancelToken = null;
    }
    if (_currentState.stage != StreamStage.idle) {
      diagnostics?.record(
        'stream.coordinator.cancel',
        sourceId: MediaSource.redact(_currentState.originalUrl),
        message:
            'Attempt ${_currentState.attemptId} cancelled: ${reason ?? "superseded"}',
      );
      _emit(
        _currentState.copyWith(
          stage: StreamStage.idle,
          clearStageMessage: true,
        ),
      );
    }
  }

  /// Synchronously allocates an attempt ID and begins preparation of [url].
  Future<ResolvedStreamInfo?> prepareStream(
    String url, {
    bool play = true,
  }) async {
    cancelActiveAttempt(reason: 'new stream requested');

    final attemptId = ++_attemptCounter;
    final cancelToken = CancellationToken();
    _currentCancelToken = cancelToken;
    _attemptStartTime = DateTime.now();
    _lastQualitySwitchTime = DateTime.now();
    _consecutiveUnderruns = 0;
    _firstUnderrunWindowStart = null;
    _healthyBufferStart = null;

    _emit(
      StreamPlaybackState(
        attemptId: attemptId,
        originalUrl: url,
        streamUrl: url,
        stage: StreamStage.resolving,
        stageMessage: 'Opening stream',
        isAutoQuality: true,
      ),
    );

    diagnostics?.record(
      'stream.prepare.start',
      sourceId: MediaSource.redact(url),
      message: 'Attempt $attemptId issued',
    );

    try {
      String playableUrl = url;
      String? audioUrl;
      String? title;
      List<StreamRendition> candidateRenditions = [];
      bool isLive = false;
      bool isExpiring = false;
      DateTime? expiresAt;
      Map<String, String>? httpHeaders;

      // 1. Check if supported public page URL for yt-dlp resolution
      if (ytDlpResolver.canResolve(url)) {
        if (cancelToken.isCancelled || attemptId != _attemptCounter) {
          return null;
        }
        try {
          final resolved = await ytDlpResolver.resolve(
            url,
            cancelToken: cancelToken,
            timeout: const Duration(seconds: 35),
          );
          if (cancelToken.isCancelled || attemptId != _attemptCounter) {
            return null;
          }

          _activeResolvedPage = resolved;
          playableUrl = resolved.streamUrl;
          audioUrl = resolved.audioUrl;
          title = resolved.title;
          candidateRenditions = resolved.renditions;
          isExpiring = resolved.isExpiring;
          expiresAt = resolved.expiresAt;
          httpHeaders = resolved.httpHeaders;
        } on Object catch (e) {
          if (cancelToken.isCancelled || attemptId != _attemptCounter) {
            return null;
          }
          diagnostics?.record(
            'stream.ytdlp.error',
            sourceId: MediaSource.redact(url),
            error: e.toString(),
          );
          // If yt-dlp fails or is missing, fall back to direct opening attempt
        }
      }

      // 2. If playableUrl looks like an adaptive manifest (HLS or DASH)
      final lowerPlayable = playableUrl.toLowerCase();
      final isHlsOrDash =
          lowerPlayable.contains('.m3u8') ||
          lowerPlayable.contains('.mpd') ||
          lowerPlayable.contains('manifest');

      if (isHlsOrDash && candidateRenditions.isEmpty) {
        if (cancelToken.isCancelled || attemptId != _attemptCounter) {
          return null;
        }
        try {
          final manifest = await manifestService.discover(
            playableUrl,
            timeout: const Duration(seconds: 3),
          );
          if (cancelToken.isCancelled || attemptId != _attemptCounter) {
            return null;
          }

          _activeManifest = manifest;
          isLive = manifest.isLive;
          if (manifest.variants.isNotEmpty) {
            candidateRenditions = manifest.variants;
          }
        } on Object catch (e) {
          if (cancelToken.isCancelled || attemptId != _attemptCounter) {
            return null;
          }
          diagnostics?.record(
            'stream.manifest.error',
            sourceId: MediaSource.redact(playableUrl),
            error: e.toString(),
          );
        }
      }

      if (cancelToken.isCancelled || attemptId != _attemptCounter) return null;

      // Build selectable rendition list with Auto option
      final renditionsWithAuto = <StreamRendition>[];
      if (candidateRenditions.isNotEmpty) {
        renditionsWithAuto.add(StreamRendition.auto);
        renditionsWithAuto.addAll(candidateRenditions);
      }

      // Initial quality selection
      final initialRendition = _pickInitialRendition(candidateRenditions);

      _emit(
        _currentState.copyWith(
          streamUrl: playableUrl,
          audioUrl: audioUrl,
          stage: StreamStage.connecting,
          stageMessage: 'Connecting',
          availableRenditions: renditionsWithAuto,
          selectedRendition: StreamRendition.auto,
          activeRendition: initialRendition,
          isLive: isLive,
        ),
      );

      return ResolvedStreamInfo(
        attemptId: attemptId,
        originalUrl: url,
        playableUrl: playableUrl,
        audioUrl: audioUrl,
        title: title,
        renditions: renditionsWithAuto,
        selectedRendition: initialRendition,
        isLive: isLive,
        isExpiring: isExpiring,
        expiresAt: expiresAt,
        httpHeaders: httpHeaders,
      );
    } catch (e) {
      if (cancelToken.isCancelled || attemptId != _attemptCounter) return null;
      _emit(
        _currentState.copyWith(
          stage: StreamStage.failed,
          error:
              'Could not connect to media stream: ${MediaSource.redact(e.toString())}',
        ),
      );
      return null;
    }
  }

  /// Picks a conservative initial rendition near 720p within 2 Mbps total bitrate budget.
  StreamRendition? _pickInitialRendition(List<StreamRendition> renditions) {
    if (renditions.isEmpty) return null;

    // Filter compatible video renditions
    final videoRenditions = renditions.where((r) => r.hasVideo).toList();
    if (videoRenditions.isEmpty) return renditions.first;

    // Sort by height ascending
    videoRenditions.sort((a, b) => (a.height ?? 0).compareTo(b.height ?? 0));

    // Find best match <= 720p with bitrate <= 2 Mbps
    StreamRendition? bestFit;
    for (final r in videoRenditions) {
      final h = r.height ?? 0;
      final br = r.bitrate ?? 0;
      if (h <= 720 && (br == 0 || br <= _initialBitrateBudget)) {
        bestFit = r;
      }
    }

    return bestFit ?? videoRenditions.first;
  }

  /// Applies streaming options to [NativePlayer] per Phase 2 requirements.
  Future<void> applyStreamingSettings(
    NativePlayer nativePlayer, {
    required bool isNetwork,
    bool isLive = false,
    bool isLowSpec = false,
    bool limitDemuxerCache = false,
  }) async {
    try {
      if (!isNetwork) {
        // Local playback: cache disabled, modest readahead
        await nativePlayer
            .setProperty('cache', 'no', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty('cache-on-disk', 'no', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty(
              'demuxer-readahead-secs',
              isLowSpec ? '2' : '8',
              waitForInitialization: false,
            )
            .timeout(const Duration(seconds: 1));
      } else {
        // Cloud streaming: memory-backed caching, bounded readahead
        await nativePlayer
            .setProperty('cache', 'yes', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty('cache-on-disk', 'no', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));

        // Readahead: ~12s progressive/VOD, ~6s live HLS (Phase 2 spec)
        final readaheadSecs = isLive ? '6' : '12';
        await nativePlayer
            .setProperty(
              'demuxer-readahead-secs',
              readaheadSecs,
              waitForInitialization: false,
            )
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty(
              'demuxer-max-bytes',
              isLowSpec ? '33554432' : '67108864', // 32MB / 64MB memory limit
              waitForInitialization: false,
            )
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty('network-timeout', '15', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        await nativePlayer
            .setProperty('tls-verify', 'yes', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
      }
    } catch (_) {
      // Ignore unsupported properties on older engine versions
    }
  }

  /// Observes engine lifecycle events for the active attempt.
  void handleNativeLifecycleEvent(
    NativeMediaEvent event, {
    required int attemptId,
  }) {
    if (attemptId != _currentState.attemptId) return;

    switch (event.kind) {
      case NativeMediaEventKind.started:
        if (_currentState.stage == StreamStage.connecting ||
            _currentState.stage == StreamStage.resolving) {
          _emit(
            _currentState.copyWith(
              stage: StreamStage.buffering,
              stageMessage: 'Buffering',
            ),
          );
        }
        break;

      case NativeMediaEventKind.loaded:
        final now = DateTime.now();
        final durationToFirst = _attemptStartTime != null
            ? now.difference(_attemptStartTime!)
            : null;

        _emit(
          _currentState.copyWith(
            stage: StreamStage.ready,
            clearStageMessage: true,
            firstOutputTime: now,
            timeToFirstOutput: durationToFirst,
          ),
        );
        diagnostics?.record(
          'stream.ready',
          sourceId: MediaSource.redact(_currentState.originalUrl),
          message:
              'First output reached in ${durationToFirst?.inMilliseconds ?? 0} ms',
        );
        break;

      case NativeMediaEventKind.ended:
        if (event.endReason == NativeEndReason.error && event.errorCode != 0) {
          _handlePlaybackError(event.errorCode);
        }
        break;

      case NativeMediaEventKind.seekableChanged:
        _emit(_currentState.copyWith(seekable: event.seekable));
        break;

      case NativeMediaEventKind.chaptersChanged:
        break;
    }
  }

  /// Updates live demuxer cache and throughput statistics.
  void updateDemuxerStats({
    required Duration bufferedDuration,
    int? rawInputRate, // bytes per second
    int? width,
    int? height,
    bool? pausedForCache,
  }) {
    if (_currentState.stage == StreamStage.idle ||
        _currentState.stage == StreamStage.failed) {
      return;
    }

    final bitrateBps = rawInputRate != null && rawInputRate > 0
        ? rawInputRate * 8
        : null;

    final now = DateTime.now();

    // Check for underruns
    if (pausedForCache == true) {
      _firstUnderrunWindowStart ??= now;
      if (now.difference(_firstUnderrunWindowStart!) <=
          const Duration(seconds: 30)) {
        _consecutiveUnderruns++;
      } else {
        _firstUnderrunWindowStart = now;
        _consecutiveUnderruns = 1;
      }
      _healthyBufferStart = null;
    } else if (bufferedDuration > const Duration(seconds: 8)) {
      _healthyBufferStart ??= now;
    } else {
      _healthyBufferStart = null;
    }

    _emit(
      _currentState.copyWith(
        bufferedDuration: bufferedDuration,
        inputBitrate: bitrateBps ?? _currentState.inputBitrate,
        decodedWidth: width ?? _currentState.decodedWidth,
        decodedHeight: height ?? _currentState.decodedHeight,
      ),
    );

    // Auto-quality adaptation checks
    if (_currentState.isAutoQuality) {
      _evaluateAutoQuality(now);
    }
  }

  /// Evaluates whether an automatic quality switch should occur.
  void _evaluateAutoQuality(DateTime now) {
    if (_lastQualitySwitchTime != null &&
        now.difference(_lastQualitySwitchTime!) < _switchCooldown) {
      return;
    }

    final renditions = _currentState.availableRenditions
        .where((r) => !r.isAuto && r.hasVideo)
        .toList();
    if (renditions.length < 2) return;

    renditions.sort((a, b) => (a.height ?? 0).compareTo(b.height ?? 0));
    final currentIndex = renditions.indexWhere(
      (r) => r.id == _currentState.activeRendition?.id,
    );
    if (currentIndex < 0) return;

    // 1. Downshift check: persistent buffer depletion (< 1s) or >= 2 underruns in 30s
    final needsDownshift =
        _consecutiveUnderruns >= 2 ||
        (_currentState.bufferedDuration < const Duration(seconds: 1) &&
            _currentState.bufferedDuration > Duration.zero);

    if (needsDownshift && currentIndex > 0) {
      final target = renditions[currentIndex - 1];
      diagnostics?.record(
        'stream.auto_quality.downshift',
        message:
            'Downshifting from ${renditions[currentIndex].label} to ${target.label}',
      );
      _performAutoSwitch(target, now);
      return;
    }

    // 2. Upshift check: >= 30s healthy buffer (> 8s) and sustained throughput >= 1.5x next rung
    if (_healthyBufferStart != null &&
        now.difference(_healthyBufferStart!) >= const Duration(seconds: 30) &&
        currentIndex < renditions.length - 1) {
      final nextRendition = renditions[currentIndex + 1];
      final currentBitrate = _currentState.inputBitrate ?? 0;
      final requiredBitrate = (nextRendition.bitrate ?? 0) * 1.5;

      if (requiredBitrate > 0 && currentBitrate >= requiredBitrate) {
        diagnostics?.record(
          'stream.auto_quality.upshift',
          message:
              'Upshifting from ${renditions[currentIndex].label} to ${nextRendition.label}',
        );
        _performAutoSwitch(nextRendition, now);
      }
    }
  }

  void _performAutoSwitch(StreamRendition target, DateTime now) {
    _lastQualitySwitchTime = now;
    _consecutiveUnderruns = 0;
    _healthyBufferStart = null;
    _emit(
      _currentState.copyWith(
        activeRendition: target,
        stage: StreamStage.switchingQuality,
        stageMessage: 'Switching to ${target.label}',
      ),
    );
  }

  /// Manually selects a rendition. Locks the selection for the current entry.
  void selectRendition(StreamRendition rendition) {
    if (rendition.isAuto) {
      _emit(
        _currentState.copyWith(
          isAutoQuality: true,
          selectedRendition: StreamRendition.auto,
        ),
      );
      return;
    }

    _lastQualitySwitchTime = DateTime.now();
    _consecutiveUnderruns = 0;
    _healthyBufferStart = null;

    _emit(
      _currentState.copyWith(
        isAutoQuality: false,
        selectedRendition: rendition,
        activeRendition: rendition,
        stage: StreamStage.switchingQuality,
        stageMessage: 'Switching to ${rendition.label}',
      ),
    );
  }

  /// Handles playback error with bounded transient retries.
  void _handlePlaybackError(int errorCode) {
    // If we have not exceeded the cap of 2 reconnects
    if (_currentState.reconnectAttempts < 2) {
      final nextAttempts = _currentState.reconnectAttempts + 1;
      _emit(
        _currentState.copyWith(
          stage: StreamStage.reconnecting,
          stageMessage: 'Reconnecting (attempt $nextAttempts/2)...',
          reconnectAttempts: nextAttempts,
        ),
      );
    } else {
      _emit(
        _currentState.copyWith(
          stage: StreamStage.failed,
          error: 'Streaming connection lost. Tap Retry to reconnect.',
        ),
      );
    }
  }

  void dispose() {
    cancelActiveAttempt(reason: 'coordinator disposed');
    _stateController.close();
  }
}
