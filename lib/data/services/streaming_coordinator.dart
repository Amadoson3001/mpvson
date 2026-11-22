import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../../domain/models/media_source.dart';
import '../../domain/models/resolved_stream.dart';
import '../../domain/models/stream_playback_state.dart';
import '../repositories/app_preferences_repository.dart'
    show PreferredStreamQuality;
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
    this.isAutoQuality = true,
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
  final bool isAutoQuality;
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
  }) : _ytDlpResolver = ytDlpResolver ?? YtDlpResolver(),
       manifestService = manifestService ?? StreamManifestService();

  YtDlpResolver _ytDlpResolver;
  YtDlpResolver get ytDlpResolver => _ytDlpResolver;
  final StreamManifestService manifestService;
  final DiagnosticSink? diagnostics;

  String? _configuredYtDlpPath;
  PreferredStreamQuality _preferredQuality = PreferredStreamQuality.auto;

  PreferredStreamQuality get preferredQuality => _preferredQuality;

  /// Updates the configured yt-dlp executable path and preferred stream quality
  /// at runtime without disrupting active playback.
  void configureStreamingPreferences({
    String? ytDlpPath,
    PreferredStreamQuality? preferredQuality,
  }) {
    final normalizedPath = ytDlpPath?.trim();
    final effectivePath = normalizedPath != null && normalizedPath.isNotEmpty
        ? normalizedPath
        : null;
    if (effectivePath != _configuredYtDlpPath) {
      _configuredYtDlpPath = effectivePath;
      _ytDlpResolver = YtDlpResolver(
        runner: _ytDlpResolver.runner,
        executablePath: YtDlpResolver.resolveDefaultExecutablePath(
          customPath: effectivePath,
        ),
      );
    }
    if (preferredQuality != null) {
      _preferredQuality = preferredQuality;
    }
  }

  final StreamController<StreamPlaybackState> _stateController =
      StreamController<StreamPlaybackState>.broadcast(sync: true);
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

  /// Returns the current stream format (HLS, DASH, direct, or progressive).
  StreamFormat get activeFormat {
    if (_activeManifest != null) {
      return _activeManifest!.format;
    }
    if (_activeResolvedPage != null) {
      return StreamFormat.direct;
    }
    final lower = _currentState.streamUrl.toLowerCase();
    if (lower.contains('.m3u8')) return StreamFormat.hls;
    if (lower.contains('.mpd')) return StreamFormat.dash;
    return StreamFormat.progressive;
  }

  // Auto-quality tracking
  DateTime? _lastQualitySwitchTime;
  Timer? _qualitySwitchTimer;
  StreamRendition? _pendingRendition;
  StreamRendition? _previousSelection;
  bool _previousAutoQuality = true;
  int _consecutiveUnderruns = 0;
  DateTime? _firstUnderrunWindowStart;
  DateTime? _healthyBufferStart;

  /// Callback invoked when a transient stream drop needs to be reopened.
  Future<void> Function(int attemptId, Duration resumePosition)?
  onReconnectRequired;

  /// Callback invoked when Auto Quality decides to adapt to a new rendition.
  Future<void> Function(StreamRendition target)? onAutoQualitySwitch;

  /// Last known playback position reported by demuxer / transport.
  Duration _lastKnownPosition = Duration.zero;
  bool _accessRefreshAttempted = false;

  bool ownsAttempt(int attemptId) =>
      attemptId == _currentState.attemptId &&
      _currentCancelToken != null &&
      !_currentCancelToken!.isCancelled;

  void updatePosition(Duration position) {
    if (position >= Duration.zero) _lastKnownPosition = position;
  }

  /// Refreshes signed stream tokens via yt-dlp if active page has expiring tokens.
  Future<ResolvedStream?> refreshExpiringStream() async {
    final page = _activeResolvedPage;
    final attemptId = currentAttemptId;
    if (page == null || !ownsAttempt(attemptId)) return null;
    try {
      final refreshed = await ytDlpResolver.refresh(
        page,
        cancelToken: _currentCancelToken,
      );
      if (!ownsAttempt(attemptId)) return null;
      _activeResolvedPage = refreshed;
      _emit(_currentState.copyWith(streamUrl: refreshed.streamUrl));
      diagnostics?.record(
        'stream.refresh.success',
        sourceId: MediaSource.redact(_currentState.originalUrl),
      );
      return refreshed;
    } on Object catch (e) {
      diagnostics?.record(
        'stream.refresh.failed',
        sourceId: MediaSource.redact(_currentState.originalUrl),
        error: e.toString(),
      );
      return null;
    }
  }

  void failAccessRefresh(int attemptId) {
    if (!ownsAttempt(attemptId)) return;
    _emit(
      _currentState.copyWith(
        stage: StreamStage.failed,
        clearStageMessage: true,
        error:
            'Access denied. The link may require authentication or have expired.',
      ),
    );
  }

  /// Completely stops streaming, cancels attempts, and clears state.
  void stop() {
    cancelActiveAttempt(reason: 'playback stopped');
    _activeResolvedPage = null;
    _activeManifest = null;
    _emit(const StreamPlaybackState());
  }

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
    _qualitySwitchTimer?.cancel();
    _pendingRendition = null;
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

    _activeManifest = null;
    _activeResolvedPage = null;
    _lastKnownPosition = Duration.zero;
    _accessRefreshAttempted = false;
    final attemptId = ++_attemptCounter;
    final cancelToken = CancellationToken();
    _currentCancelToken = cancelToken;
    _attemptStartTime = DateTime.now();
    _lastQualitySwitchTime = null;
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
        _emit(
          _currentState.copyWith(
            stage: StreamStage.resolving,
            stageMessage: 'Resolving link',
          ),
        );
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
        } on YtDlpCancelledException {
          return null;
        } on YtDlpNotFoundException catch (e) {
          if (cancelToken.isCancelled || attemptId != _attemptCounter) {
            return null;
          }
          diagnostics?.record(
            'stream.ytdlp.missing',
            sourceId: MediaSource.redact(url),
            error: MediaSource.redactText(e.toString()),
          );
          if (ytDlpResolver.isKnownVideoHost(url)) {
            _emit(
              _currentState.copyWith(
                stage: StreamStage.failed,
                clearStageMessage: true,
                error: Platform.isWindows
                    ? 'yt-dlp is required to play links from this site. Place yt-dlp.exe next to mpvson.exe or install yt-dlp on PATH.'
                    : 'yt-dlp is required to play links from this site. Install yt-dlp on PATH.',
              ),
            );
            return null;
          }
          // Non-known hosts may be extensionless direct media; fall back.
        } on YtDlpResolutionException catch (e) {
          if (cancelToken.isCancelled || attemptId != _attemptCounter) {
            return null;
          }
          diagnostics?.record(
            'stream.ytdlp.error',
            sourceId: MediaSource.redact(url),
            error: MediaSource.redactText(e.message),
          );
          if (ytDlpResolver.isKnownVideoHost(url) &&
              e.errorType != YtDlpErrorType.unsupportedUrl) {
            _emit(
              _currentState.copyWith(
                stage: StreamStage.failed,
                clearStageMessage: true,
                error: _ytDlpUserErrorMessage(e.errorType),
              ),
            );
            return null;
          }
        } on Object catch (e) {
          if (cancelToken.isCancelled || attemptId != _attemptCounter) {
            return null;
          }
          diagnostics?.record(
            'stream.ytdlp.error',
            sourceId: MediaSource.redact(url),
            error: MediaSource.redactText(e.toString()),
          );
          // If yt-dlp fails or is missing on non-known hosts, fall back to direct opening attempt.
        }
      }

      // 2. If playableUrl looks like an adaptive manifest (HLS or DASH)
      final lowerPlayable = playableUrl.toLowerCase();
      final isHlsOrDash =
          lowerPlayable.contains('.m3u8') ||
          lowerPlayable.contains('.mpd') ||
          lowerPlayable.contains('manifest');

      if (candidateRenditions.isEmpty &&
          (isHlsOrDash ||
              !RegExp(
                r'\.(mp4|mkv|webm|mp3|m4a|aac|flac|wav|ogg)(?:[?#]|$)',
              ).hasMatch(lowerPlayable))) {
        if (cancelToken.isCancelled || attemptId != _attemptCounter) {
          return null;
        }
        _emit(
          _currentState.copyWith(
            stage: StreamStage.resolving,
            stageMessage: 'Loading stream info',
          ),
        );
        try {
          final manifest = await manifestService.discover(
            playableUrl,
            timeout: const Duration(seconds: 3),
          );
          if (cancelToken.isCancelled || attemptId != _attemptCounter) {
            return null;
          }

          if (manifest.format != StreamFormat.direct) {
            _activeManifest = manifest;
          }
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
      final isAutoSelected =
          _preferredQuality == PreferredStreamQuality.auto ||
          initialRendition == null ||
          initialRendition.isAuto;
      final effectiveSelectedRendition = isAutoSelected
          ? StreamRendition.auto
          : initialRendition;

      if (!isAutoSelected &&
          _activeManifest == null &&
          initialRendition.url != null &&
          initialRendition.url!.isNotEmpty) {
        playableUrl = initialRendition.url!;
        audioUrl = initialRendition.audioUrl ?? audioUrl;
        httpHeaders = initialRendition.httpHeaders ?? httpHeaders;
      }

      final normalizedTitle = title?.trim();
      _emit(
        _currentState.copyWith(
          streamUrl: playableUrl,
          audioUrl: audioUrl,
          resolvedTitle: normalizedTitle != null && normalizedTitle.isNotEmpty
              ? normalizedTitle
              : null,
          stage: StreamStage.connecting,
          stageMessage: 'Connecting',
          availableRenditions: renditionsWithAuto,
          selectedRendition: effectiveSelectedRendition,
          activeRendition: isAutoSelected || _activeManifest != null
              ? null
              : initialRendition,
          isAutoQuality: isAutoSelected,
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
        isAutoQuality: isAutoSelected,
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

  /// Picks an initial rendition based on [preferredQuality].
  ///
  /// For [PreferredStreamQuality.auto], selects a conservative rendition near
  /// 720p within the 2 Mbps budget. For explicit presets (`best`, `p1080`, `p720`,
  /// `p480`), picks the highest quality matching the constraint (falling back to
  /// the lowest available video rendition when all exceed a capped preset).
  StreamRendition? _pickInitialRendition(List<StreamRendition> renditions) {
    if (renditions.isEmpty) return null;

    // Filter compatible video renditions
    final videoRenditions = renditions.where((r) => r.hasVideo).toList();
    if (videoRenditions.isEmpty) return renditions.first;

    // Sort by height ascending, then bitrate ascending
    videoRenditions.sort((a, b) {
      final heightCmp = (a.height ?? 0).compareTo(b.height ?? 0);
      if (heightCmp != 0) return heightCmp;
      return (a.bitrate ?? 0).compareTo(b.bitrate ?? 0);
    });

    switch (_preferredQuality) {
      case PreferredStreamQuality.auto:
        StreamRendition? bestFit;
        for (final r in videoRenditions) {
          final h = r.height ?? 0;
          final br = r.bitrate ?? 0;
          if (h <= 720 && (br == 0 || br <= _initialBitrateBudget)) {
            bestFit = r;
          }
        }
        return bestFit ?? videoRenditions.first;
      case PreferredStreamQuality.best:
        return videoRenditions.last;
      case PreferredStreamQuality.p1080:
      case PreferredStreamQuality.p720:
      case PreferredStreamQuality.p480:
        final cap = _preferredQuality.maxHeight!;
        StreamRendition? bestCapped;
        for (final r in videoRenditions) {
          final h = r.height ?? 0;
          if (h <= cap) {
            bestCapped = r;
          }
        }
        return bestCapped ?? videoRenditions.first;
    }
  }

  /// Applies streaming options to [NativePlayer] per Phase 2 requirements.
  Future<void> applyStreamingSettings(
    NativePlayer nativePlayer, {
    required bool isNetwork,
    bool isLive = false,
    bool isLowSpec = false,
    bool limitDemuxerCache = false,
    bool Function()? shouldContinue,
  }) async {
    try {
      if (!isNetwork) {
        // Local playback: cache disabled, modest readahead
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty('cache', 'no', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty('cache-on-disk', 'no', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty(
              'demuxer-readahead-secs',
              isLowSpec ? '2' : '8',
              waitForInitialization: false,
            )
            .timeout(const Duration(seconds: 1));
      } else {
        // Cloud streaming: memory-backed caching, bounded readahead
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty('cache', 'yes', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty('cache-on-disk', 'no', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));

        // Readahead: ~12s progressive/VOD, ~6s live HLS (Phase 2 spec)
        final readaheadSecs = isLive ? '6' : '12';
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty(
              'demuxer-readahead-secs',
              readaheadSecs,
              waitForInitialization: false,
            )
            .timeout(const Duration(seconds: 1));
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty(
              'demuxer-max-bytes',
              isLowSpec ? '33554432' : '67108864', // 32MB / 64MB memory limit
              waitForInitialization: false,
            )
            .timeout(const Duration(seconds: 1));
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty('network-timeout', '15', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
        if (shouldContinue?.call() == false) return;
        await nativePlayer
            .setProperty('tls-verify', 'yes', waitForInitialization: false)
            .timeout(const Duration(seconds: 1));
      }
    } catch (_) {
      // Ignore unsupported properties on older engine versions
    }
  }

  /// Records the actual engine inputs after a direct rendition is opened.
  void recordStreamInput(String url, String? audioUrl) {
    if (!ownsAttempt(currentAttemptId)) return;
    _emit(
      _currentState.copyWith(
        streamUrl: url,
        audioUrl: audioUrl,
        clearAudioUrl: audioUrl == null,
      ),
    );
  }

  /// Observes engine lifecycle events for the active attempt.
  void handleNativeLifecycleEvent(
    NativeMediaEvent event, {
    required int attemptId,
    int? httpStatusCode,
  }) {
    if (!ownsAttempt(attemptId)) return;

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
          _handlePlaybackError(event.errorCode, httpStatusCode: httpStatusCode);
        }
        break;

      case NativeMediaEventKind.seekableChanged:
        _emit(_currentState.copyWith(seekable: event.seekable));
        break;

      case NativeMediaEventKind.chaptersChanged:
        break;
      case NativeMediaEventKind.demuxerStatsChanged:
        break;
    }
  }

  /// Updates live demuxer cache and throughput statistics.
  void updateDemuxerStats({
    Duration? bufferedDuration,
    int? rawInputRate, // bytes per second
    int? width,
    int? height,
    bool? pausedForCache,
  }) {
    if (_currentState.stage == StreamStage.idle ||
        _currentState.stage == StreamStage.failed) {
      return;
    }

    final effectiveBuffered =
        bufferedDuration ?? _currentState.bufferedDuration;
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
    } else if (bufferedDuration != null) {
      if (bufferedDuration > const Duration(seconds: 8)) {
        _healthyBufferStart ??= now;
      } else {
        _healthyBufferStart = null;
      }
    }

    final nextWidth = width ?? _currentState.decodedWidth;
    final nextHeight = height ?? _currentState.decodedHeight;
    StreamRendition? observedRendition;
    if (nextHeight != null && (width != null || height != null)) {
      final matches = _currentState.availableRenditions.where(
        (r) =>
            !r.isAuto &&
            r.height == nextHeight &&
            (r.width == null || nextWidth == null || r.width == nextWidth),
      );
      if (matches.length == 1) observedRendition = matches.single;
      // A caller can request a rendition not present in the discovery list.
      if (matches.isEmpty &&
          _pendingRendition?.height == nextHeight &&
          (_pendingRendition?.width == null ||
              _pendingRendition?.width == nextWidth)) {
        observedRendition = _pendingRendition;
      }
    }
    final confirmed =
        _pendingRendition != null &&
        observedRendition?.id == _pendingRendition!.id;
    if (confirmed) {
      _qualitySwitchTimer?.cancel();
      _pendingRendition = null;
    }
    var nextStage = confirmed ? StreamStage.ready : _currentState.stage;
    var nextMessage = _currentState.stageMessage;
    var clearMessage = confirmed;

    if (pausedForCache == true && nextStage == StreamStage.ready) {
      nextStage = StreamStage.buffering;
      nextMessage = 'Buffering';
      clearMessage = false;
    } else if (pausedForCache == false && nextStage == StreamStage.buffering) {
      nextStage = StreamStage.ready;
      clearMessage = true;
    }

    final nextState = _currentState.copyWith(
      activeRendition: _pendingRendition == null ? observedRendition : null,
      stage: nextStage,
      stageMessage: clearMessage ? null : nextMessage,
      clearStageMessage: clearMessage,
      bufferedDuration: effectiveBuffered,
      inputBitrate: bitrateBps ?? _currentState.inputBitrate,
      decodedWidth: nextWidth,
      decodedHeight: nextHeight,
    );
    if (nextState != _currentState) {
      _emit(nextState);
    }

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
    _previousSelection = _currentState.selectedRendition;
    _previousAutoQuality = _currentState.isAutoQuality;
    _lastQualitySwitchTime = now;
    _consecutiveUnderruns = 0;
    _healthyBufferStart = null;
    _emit(
      _currentState.copyWith(
        stage: StreamStage.switchingQuality,
        stageMessage: 'Switching to ${target.label}',
      ),
    );
    _beginQualityConfirmation(target);
    if (onAutoQualitySwitch != null) {
      unawaited(
        onAutoQualitySwitch!(target).catchError((Object _) {
          failQualitySwitch(target);
        }),
      );
    }
  }

  /// Manually selects a rendition. Locks the selection for the current entry.
  void selectRendition(StreamRendition rendition) {
    if (rendition.isAuto) {
      _qualitySwitchTimer?.cancel();
      _pendingRendition = null;
      _emit(
        _currentState.copyWith(
          isAutoQuality: true,
          selectedRendition: StreamRendition.auto,
          stage: _currentState.stage == StreamStage.switchingQuality
              ? StreamStage.ready
              : _currentState.stage,
          clearStageMessage:
              _currentState.stage == StreamStage.switchingQuality,
        ),
      );
      return;
    }

    if (_pendingRendition == null) {
      _previousSelection = _currentState.selectedRendition;
      _previousAutoQuality = _currentState.isAutoQuality;
    }
    _lastQualitySwitchTime = DateTime.now();
    _consecutiveUnderruns = 0;
    _healthyBufferStart = null;

    _emit(
      _currentState.copyWith(
        isAutoQuality: false,
        selectedRendition: rendition,
        stage: StreamStage.switchingQuality,
        stageMessage: 'Switching to ${rendition.label}',
      ),
    );
    _beginQualityConfirmation(rendition);
  }

  void _beginQualityConfirmation(StreamRendition target) {
    _qualitySwitchTimer?.cancel();
    _pendingRendition = target;
    final attempt = currentAttemptId;
    _qualitySwitchTimer = Timer(const Duration(seconds: 8), () {
      if (!ownsAttempt(attempt)) return;
      failQualitySwitch(target);
    });
  }

  /// Confirms a switch after the engine reports the requested track or edition.
  void confirmQualitySwitch(StreamRendition target) {
    if (_pendingRendition != target) return;
    _qualitySwitchTimer?.cancel();
    _pendingRendition = null;
    _emit(
      _currentState.copyWith(
        activeRendition: target,
        stage: StreamStage.ready,
        clearStageMessage: true,
      ),
    );
  }

  void failQualitySwitch(StreamRendition target) {
    if (_pendingRendition != target) return;
    _qualitySwitchTimer?.cancel();
    _pendingRendition = null;
    _emit(
      _currentState.copyWith(
        stage: StreamStage.ready,
        clearStageMessage: true,
        selectedRendition: _previousSelection,
        isAutoQuality: _previousAutoQuality,
      ),
    );
  }

  /// Handles playback error with bounded transient retries.
  void _handlePlaybackError(int errorCode, {int? httpStatusCode}) {
    final isHttpNotFound = httpStatusCode == 404 || httpStatusCode == 410;
    final isHttpForbidden = httpStatusCode == 401 || httpStatusCode == 403;

    if (isHttpForbidden &&
        _activeResolvedPage?.isExpiring == true &&
        !_accessRefreshAttempted &&
        onReconnectRequired != null) {
      _accessRefreshAttempted = true;
      final attempt = currentAttemptId;
      _emit(
        _currentState.copyWith(
          stage: StreamStage.reconnecting,
          stageMessage: 'Refreshing link...',
        ),
      );
      unawaited(
        onReconnectRequired!(
          attempt,
          _currentState.isLive ? Duration.zero : _lastKnownPosition,
        ),
      );
      return;
    }

    // 1. Check for terminal error codes or terminal HTTP statuses
    final isTerminal =
        isHttpNotFound ||
        isHttpForbidden ||
        errorCode == -4 || // Legacy sentinel / MPV_ERROR_INVALID_PARAMETER
        errorCode == -16 || // MPV_ERROR_NOTHING_TO_PLAY
        errorCode == -17 || // MPV_ERROR_UNKNOWN_FORMAT
        errorCode == -18 || // MPV_ERROR_UNSUPPORTED
        errorCode == -19 || // MPV_ERROR_NOT_IMPLEMENTED
        errorCode == -3 || // MPV_ERROR_UNINITIALIZED
        errorCode == -2; // MPV_ERROR_NOMEM

    if (isTerminal) {
      final errorMessage = (isHttpNotFound || errorCode == -4)
          ? 'Stream not found (404). Check the URL.'
          : isHttpForbidden
          ? 'Access denied (HTTP $httpStatusCode). The link may require authentication or have expired.'
          : 'Stream failed to load (error $errorCode).';
      diagnostics?.record(
        'stream.error.terminal',
        sourceId: MediaSource.redact(_currentState.originalUrl),
        error:
            'Terminal playback error: $errorCode'
            '${httpStatusCode != null ? ' (HTTP $httpStatusCode)' : ''}',
      );
      _emit(
        _currentState.copyWith(
          stage: StreamStage.failed,
          clearStageMessage: true,
          error: errorMessage,
        ),
      );
      return;
    }

    // 2. Transient error: attempt real reconnection up to 2 times
    if (_currentState.reconnectAttempts < 2) {
      final nextAttempts = _currentState.reconnectAttempts + 1;
      diagnostics?.record(
        'stream.reconnect.attempt',
        sourceId: MediaSource.redact(_currentState.originalUrl),
        message: 'Reconnecting ($nextAttempts/2) after error $errorCode',
      );
      _emit(
        _currentState.copyWith(
          stage: StreamStage.reconnecting,
          stageMessage: 'Reconnecting (attempt $nextAttempts/2)...',
          reconnectAttempts: nextAttempts,
        ),
      );

      final currentAttempt = _currentState.attemptId;
      final currentPos = _currentState.isLive
          ? Duration.zero
          : _lastKnownPosition;
      if (onReconnectRequired != null) {
        Future<void>.delayed(Duration(milliseconds: 300 * nextAttempts), () {
          if (currentAttempt == _currentState.attemptId &&
              _currentState.stage == StreamStage.reconnecting) {
            onReconnectRequired!(currentAttempt, currentPos);
          }
        });
      }
    } else {
      diagnostics?.record(
        'stream.reconnect.exhausted',
        sourceId: MediaSource.redact(_currentState.originalUrl),
        message:
            'Max reconnect attempts (2) reached for attempt ${_currentState.attemptId}',
      );
      _emit(
        _currentState.copyWith(
          stage: StreamStage.failed,
          clearStageMessage: true,
          error: 'Streaming connection lost. Tap Retry to reconnect.',
        ),
      );
    }
  }

  static String _ytDlpUserErrorMessage(YtDlpErrorType errorType) {
    return switch (errorType) {
      YtDlpErrorType.loginRequired =>
        'This video requires sign-in or age confirmation.',
      YtDlpErrorType.videoUnavailable =>
        'This video is unavailable or has been removed.',
      YtDlpErrorType.geoRestricted =>
        'This video is not available in your region.',
      YtDlpErrorType.drmProtected => 'DRM-protected streams are not supported.',
      YtDlpErrorType.rateLimited =>
        'The video host rate-limited requests. Try again shortly.',
      YtDlpErrorType.networkError =>
        'Could not reach the video host. Check your connection.',
      YtDlpErrorType.unsupportedUrl || YtDlpErrorType.unknown =>
        'Could not resolve video stream from this page.',
    };
  }

  void dispose() {
    cancelActiveAttempt(reason: 'coordinator disposed');
    _stateController.close();
  }
}
