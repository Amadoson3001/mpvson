import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:mpvson/data/services/process_runner.dart';
import 'package:mpvson/domain/models/resolved_stream.dart';
import 'package:path/path.dart' as p;

/// Availability status of the yt-dlp executable.
enum YtDlpAvailability { available, missing, outdated, failed }

/// Status and version diagnostic information for the yt-dlp executable.
@immutable
class YtDlpStatus {
  final YtDlpAvailability availability;
  final String? version;
  final String? executablePath;
  final String? message;

  const YtDlpStatus({
    required this.availability,
    this.version,
    this.executablePath,
    this.message,
  });

  bool get isAvailable => availability == YtDlpAvailability.available;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is YtDlpStatus &&
        other.availability == availability &&
        other.version == version &&
        other.executablePath == executablePath &&
        other.message == message;
  }

  @override
  int get hashCode =>
      Object.hash(availability, version, executablePath, message);

  @override
  String toString() =>
      'YtDlpStatus(availability: $availability, version: $version, path: $executablePath)';
}

/// Error category for classified yt-dlp resolution failures.
enum YtDlpErrorType {
  unsupportedUrl,
  videoUnavailable,
  loginRequired,
  geoRestricted,
  drmProtected,
  rateLimited,
  networkError,
  unknown,
}

/// Base exception for yt-dlp resolver operations.
abstract class YtDlpException implements Exception {
  final String message;
  const YtDlpException(this.message);

  @override
  String toString() => message;
}

/// Thrown when the yt-dlp executable cannot be found or started.
class YtDlpNotFoundException extends YtDlpException {
  final String? executable;
  final Object? innerException;

  const YtDlpNotFoundException(
    super.message, {
    this.executable,
    this.innerException,
  });

  @override
  String toString() => 'YtDlpNotFoundException: $message';
}

/// Thrown when resolution is cancelled via a [CancellationToken].
class YtDlpCancelledException extends YtDlpException {
  const YtDlpCancelledException([super.message = 'Resolution was cancelled']);

  @override
  String toString() => 'YtDlpCancelledException: $message';
}

/// Thrown when yt-dlp fails to resolve a stream or exits with an error.
class YtDlpResolutionException extends YtDlpException {
  final int? exitCode;
  final String? stderr;
  final YtDlpErrorType errorType;
  final String? url;

  const YtDlpResolutionException(
    super.message, {
    this.exitCode,
    this.stderr,
    this.errorType = YtDlpErrorType.unknown,
    this.url,
  });

  @override
  String toString() =>
      'YtDlpResolutionException($errorType, exitCode: $exitCode): $message';
}

/// Token used to request cooperative cancellation of async resolver operations.
class CancellationToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
    _listeners.clear();
  }

  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

/// Service that delegates public page URL resolution to a managed `yt-dlp` executable.
class YtDlpResolver {
  final ProcessRunner runner;
  final String executablePath;

  YtDlpResolver({ProcessRunner? runner, String? executablePath})
    : runner = runner ?? ProcessRunner.standard,
      executablePath = executablePath ?? resolveDefaultExecutablePath();

  /// Default executable name for the current platform.
  static String get defaultExecutablePath =>
      Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';

  /// Resolves the `yt-dlp` executable path from [customPath], `MPVSON_YTDLP_PATH`,
  /// beside the running binary (or its `bin/` directory), or by falling back to PATH.
  static String resolveDefaultExecutablePath({String? customPath}) {
    final trimmedCustom = customPath?.trim();
    if (trimmedCustom != null &&
        trimmedCustom.isNotEmpty &&
        File(trimmedCustom).existsSync()) {
      return trimmedCustom;
    }
    final envPath = Platform.environment['MPVSON_YTDLP_PATH']?.trim();
    if (envPath != null && envPath.isNotEmpty && File(envPath).existsSync()) {
      return envPath;
    }
    final exeName = defaultExecutablePath;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      for (final candidate in <String>[
        p.join(exeDir, exeName),
        p.join(exeDir, 'bin', exeName),
      ]) {
        if (File(candidate).existsSync()) {
          return candidate;
        }
      }
    } on Object {
      // Fall back to PATH lookup if resolvedExecutable cannot be inspected.
    }
    return trimmedCustom != null && trimmedCustom.isNotEmpty
        ? trimmedCustom
        : exeName;
  }

  static final RegExp _knownVideoHosts = RegExp(
    r'(^|\.)('
    r'youtube\.com|youtu\.be|'
    r'vimeo\.com|'
    r'dailymotion\.com|'
    r'twitch\.tv|'
    r'bilibili\.com|'
    r'soundcloud\.com|'
    r'tiktok\.com|'
    r'twitter\.com|x\.com|'
    r'facebook\.com|fb\.watch|'
    r'instagram\.com|'
    r'reddit\.com|'
    r'streamable\.com|'
    r'loom\.com|'
    r'bandcamp\.com|'
    r'rumble\.com|'
    r'odysee\.com'
    r')$',
    caseSensitive: false,
  );

  static final RegExp _directMediaExtensions = RegExp(
    r'\.(mp4|m4v|mkv|webm|avi|mov|wmv|flv|ts|m2ts|m3u8|mpd|mp3|m4a|aac|flac|wav|ogg|oga|opus)$',
    caseSensitive: false,
  );

  static final RegExp _headerNamePattern = RegExp(r'^[a-zA-Z0-9_\-]+$');

  /// Denylisted header names (hop-by-hop, security-sensitive, or credentials).
  static final Set<String> _disallowedHeaders = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'authorization',
    'cookie',
    'set-cookie',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'proxy-connection',
    'host',
  };

  /// Whether [url] points to a known public video page host that requires
  /// extractor resolution rather than direct engine playback.
  bool isKnownVideoHost(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    return _knownVideoHosts.hasMatch(host);
  }

  /// Determines whether [url] is a candidate for resolution via yt-dlp.
  bool canResolve(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;

    if (_knownVideoHosts.hasMatch(host)) {
      return true;
    }

    final path = uri.path.toLowerCase();
    if (_directMediaExtensions.hasMatch(path)) {
      return false;
    }

    return true;
  }

  /// Checks whether yt-dlp is installed and reports its version and status.
  Future<YtDlpStatus> checkAvailability({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final result = await runner.run(
        executablePath,
        const ['--version'],
        timeout: timeout,
        runInShell: false,
      );
      if (result.exitCode == 0) {
        final version = result.stdout.trim();
        final isOutdated = _isVersionOutdated(version);
        return YtDlpStatus(
          availability: isOutdated
              ? YtDlpAvailability.outdated
              : YtDlpAvailability.available,
          version: version,
          executablePath: executablePath,
          message: isOutdated
              ? 'yt-dlp is outdated ($version)'
              : 'yt-dlp is available ($version)',
        );
      } else {
        return YtDlpStatus(
          availability: YtDlpAvailability.failed,
          executablePath: executablePath,
          message:
              'yt-dlp check exited with code ${result.exitCode}: ${result.stderr.trim()}',
        );
      }
    } on TimeoutException {
      return YtDlpStatus(
        availability: YtDlpAvailability.failed,
        executablePath: executablePath,
        message: 'yt-dlp --version timed out',
      );
    } catch (e) {
      return YtDlpStatus(
        availability: YtDlpAvailability.missing,
        executablePath: executablePath,
        message: 'yt-dlp executable not found: $e',
      );
    }
  }

  /// Resolves the given public page [url] into a playable [ResolvedStream].
  Future<ResolvedStream> resolve(
    String url, {
    Duration timeout = const Duration(seconds: 35),
    CancellationToken? cancelToken,
  }) async {
    final trimmedUrl = url.trim();
    if (!canResolve(trimmedUrl)) {
      throw YtDlpResolutionException(
        'URL is not supported for page resolution: $url',
        errorType: YtDlpErrorType.unsupportedUrl,
        url: url,
      );
    }

    final arguments = [
      '--ignore-config',
      '--no-playlist',
      '--no-download',
      '--dump-single-json',
      '--',
      trimmedUrl,
    ];

    final result = await _runProcessWithCancellationAndTimeout(
      executable: executablePath,
      arguments: arguments,
      timeout: timeout,
      cancelToken: cancelToken,
    );

    if (result.exitCode != 0) {
      final stderr = result.stderr.trim();
      final errorType = _classifyError(stderr);
      throw YtDlpResolutionException(
        stderr.isNotEmpty
            ? stderr
            : 'yt-dlp exited with non-zero exit code ${result.exitCode}',
        exitCode: result.exitCode,
        stderr: stderr,
        errorType: errorType,
        url: trimmedUrl,
      );
    }

    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(result.stdout);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected JSON map root object');
      }
      json = decoded;
    } catch (e) {
      throw YtDlpResolutionException(
        'Failed to parse yt-dlp JSON output: $e',
        exitCode: result.exitCode,
        stderr: result.stderr,
        url: trimmedUrl,
      );
    }

    return _parseStreamJson(trimmedUrl, json);
  }

  /// Re-resolves an expiring or expired stream, preserving the active rendition format if possible.
  Future<ResolvedStream> refresh(
    ResolvedStream stream, {
    Duration timeout = const Duration(seconds: 35),
    CancellationToken? cancelToken,
  }) async {
    final fresh = await resolve(
      stream.originalUrl,
      timeout: timeout,
      cancelToken: cancelToken,
    );

    if (stream.formatId != null) {
      final matchingRendition = fresh.renditions
          .where((r) => r.formatId == stream.formatId)
          .firstOrNull;
      if (matchingRendition != null) {
        return fresh.copyWith(
          streamUrl: matchingRendition.url,
          audioUrl: matchingRendition.audioUrl,
          formatId: matchingRendition.formatId,
        );
      }
    }

    return fresh;
  }

  /// Extracts the expiration token from URL query parameters (e.g. `expire=...`).
  DateTime? extractExpiration(String? url) {
    if (url == null || url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      for (final entry in uri.queryParameters.entries) {
        final key = entry.key.toLowerCase();
        if (key == 'expire' ||
            key == 'expires' ||
            key == 'exp' ||
            key == 'validto' ||
            key == 'expiry' ||
            key == 'token_expire') {
          final val = int.tryParse(entry.value);
          if (val != null) {
            if (val > 1000000000000) {
              return DateTime.fromMillisecondsSinceEpoch(val, isUtc: true);
            } else if (val > 100000000) {
              return DateTime.fromMillisecondsSinceEpoch(
                val * 1000,
                isUtc: true,
              );
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Strips unsafe headers, hop-by-hop headers, and header keys/values with CRLF characters.
  Map<String, String>? sanitizeHttpHeaders(
    Map<String, dynamic>? rawHeaders, {
    Uri? originUri,
  }) {
    if (rawHeaders == null || rawHeaders.isEmpty) return null;
    final sanitized = <String, String>{};

    for (final entry in rawHeaders.entries) {
      final key = entry.key.trim();
      final value = entry.value?.toString().trim();
      if (key.isEmpty || value == null || value.isEmpty) continue;

      // Reject headers containing newlines (CRLF injection)
      if (key.contains('\r') ||
          key.contains('\n') ||
          value.contains('\r') ||
          value.contains('\n')) {
        continue;
      }

      // Check key format
      if (!_headerNamePattern.hasMatch(key)) continue;

      // Strip hop-by-hop and credential headers
      if (_disallowedHeaders.contains(key.toLowerCase())) continue;

      sanitized[key] = value;
    }

    return sanitized.isEmpty ? null : Map.unmodifiable(sanitized);
  }

  ResolvedStream _parseStreamJson(
    String originalUrl,
    Map<String, dynamic> json,
  ) {
    final type = json['_type'] as String?;
    if (type == 'playlist' ||
        (json['entries'] is List && (json['entries'] as List).isNotEmpty)) {
      throw YtDlpResolutionException(
        'Playlists and collection results are not supported: $originalUrl',
        errorType: YtDlpErrorType.unsupportedUrl,
        url: originalUrl,
      );
    }

    final title = json['title'] as String?;
    final rawDuration = json['duration'] as num?;
    final duration = rawDuration != null
        ? Duration(seconds: rawDuration.round())
        : null;
    final extractor = (json['extractor'] ?? json['extractor_key']) as String?;
    final httpHeaders = sanitizeHttpHeaders(
      json['http_headers'] as Map<String, dynamic>?,
      originUri: Uri.tryParse(originalUrl),
    );

    final rawFormats = json['formats'] as List<dynamic>?;
    final parsedFormats = <_InternalFormat>[];

    if (rawFormats != null) {
      for (final item in rawFormats) {
        if (item is! Map<String, dynamic>) continue;
        final formatUrl = item['url'] as String?;
        if (formatUrl == null || formatUrl.isEmpty) continue;
        if (!formatUrl.startsWith('http://') &&
            !formatUrl.startsWith('https://')) {
          continue;
        }

        final formatNote = (item['format_note'] ?? item['format'])?.toString();
        if (item['has_drm'] == true ||
            (formatNote != null && formatNote.toLowerCase().contains('drm'))) {
          continue;
        }

        parsedFormats.add(_parseFormatItem(item));
      }
    }

    String selectedStreamUrl;
    String? selectedAudioUrl;
    String? selectedFormatId;
    List<StreamRendition> renditions = [];

    if (parsedFormats.isNotEmpty) {
      final audioFormats =
          parsedFormats.where((f) => f.hasAudio && !f.hasVideo).toList()
            ..sort((a, b) => b.audioBitrate.compareTo(a.audioBitrate));
      final bestAudio = audioFormats.firstOrNull;

      final muxedFormats = parsedFormats.where((f) => f.isMuxed).toList()
        ..sort((a, b) {
          final hCmp = b.height.compareTo(a.height);
          if (hCmp != 0) return hCmp;
          return b.bitrate.compareTo(a.bitrate);
        });

      final videoOnlyFormats =
          parsedFormats.where((f) => f.hasVideo && !f.hasAudio).toList()
            ..sort((a, b) {
              final hCmp = b.height.compareTo(a.height);
              if (hCmp != 0) return hCmp;
              return b.bitrate.compareTo(a.bitrate);
            });

      final videoFormats = parsedFormats.where((f) => f.hasVideo).toList();

      for (final vf in videoFormats) {
        if (vf.isMuxed) {
          renditions.add(
            StreamRendition(
              id: vf.formatId,
              url: vf.url,
              width: vf.width > 0 ? vf.width : null,
              height: vf.height > 0 ? vf.height : null,
              bitrate: vf.bitrate > 0 ? vf.bitrate : null,
              frameRate: vf.fps > 0 ? vf.fps : null,
              videoCodec: vf.videoCodec,
              audioCodec: vf.audioCodec,
              formatNote: vf.formatNote,
              container: vf.container,
              httpHeaders: vf.httpHeaders,
              isMuxed: true,
              fileSize: vf.fileSize,
              audioUrl: null,
            ),
          );
        } else {
          renditions.add(
            StreamRendition(
              id: vf.formatId,
              url: vf.url,
              width: vf.width > 0 ? vf.width : null,
              height: vf.height > 0 ? vf.height : null,
              bitrate: vf.bitrate > 0 ? vf.bitrate : null,
              frameRate: vf.fps > 0 ? vf.fps : null,
              videoCodec: vf.videoCodec,
              audioCodec: bestAudio?.audioCodec,
              formatNote: vf.formatNote,
              container: vf.container,
              httpHeaders: vf.httpHeaders,
              isMuxed: false,
              fileSize: vf.fileSize,
              audioUrl: bestAudio?.url,
            ),
          );
        }
      }

      renditions.sort((a, b) {
        final ah = a.height ?? 0;
        final bh = b.height ?? 0;
        if (bh != ah) return bh.compareTo(ah);
        final af = a.fps ?? 0;
        final bf = b.fps ?? 0;
        if (bf != af) return bf.compareTo(af);
        final ab = a.bitrate ?? 0;
        final bb = b.bitrate ?? 0;
        return bb.compareTo(ab);
      });

      if (muxedFormats.isNotEmpty) {
        final bestMuxed = muxedFormats.first;
        selectedStreamUrl = bestMuxed.url;
        selectedAudioUrl = null;
        selectedFormatId = bestMuxed.formatId;
      } else if (videoOnlyFormats.isNotEmpty) {
        final bestVideo = videoOnlyFormats.first;
        selectedStreamUrl = bestVideo.url;
        selectedAudioUrl = bestAudio?.url;
        selectedFormatId = bestVideo.formatId;
      } else if (audioFormats.isNotEmpty) {
        final topAudio = audioFormats.first;
        selectedStreamUrl = topAudio.url;
        selectedAudioUrl = null;
        selectedFormatId = topAudio.formatId;
        renditions = audioFormats
            .map(
              (a) => StreamRendition(
                id: a.formatId,
                url: a.url,
                audioCodec: a.audioCodec,
                bitrate: a.bitrate > 0 ? a.bitrate : null,
                formatNote: a.formatNote,
                container: a.container,
                httpHeaders: a.httpHeaders,
                isMuxed: false,
                fileSize: a.fileSize,
              ),
            )
            .toList();
      } else {
        final topUrl = json['url'] as String?;
        if (topUrl != null &&
            (topUrl.startsWith('http://') || topUrl.startsWith('https://'))) {
          selectedStreamUrl = topUrl;
          selectedAudioUrl = null;
          selectedFormatId = json['format_id']?.toString() ?? 'direct';
          renditions = [
            StreamRendition(
              id: selectedFormatId,
              url: selectedStreamUrl,
              isMuxed: true,
            ),
          ];
        } else {
          throw YtDlpResolutionException(
            'No playable formats found for URL: $originalUrl',
            errorType: YtDlpErrorType.unsupportedUrl,
            url: originalUrl,
          );
        }
      }
    } else {
      final topUrl = json['url'] as String?;
      if (topUrl != null &&
          (topUrl.startsWith('http://') || topUrl.startsWith('https://'))) {
        selectedStreamUrl = topUrl;
        selectedAudioUrl = null;
        selectedFormatId = json['format_id']?.toString() ?? 'direct';
        renditions = [
          StreamRendition(
            id: selectedFormatId,
            url: selectedStreamUrl,
            isMuxed: true,
          ),
        ];
      } else {
        throw YtDlpResolutionException(
          'No playable stream found for URL: $originalUrl',
          errorType: YtDlpErrorType.unsupportedUrl,
          url: originalUrl,
        );
      }
    }

    final streamExp = extractExpiration(selectedStreamUrl);
    final audioExp = selectedAudioUrl != null
        ? extractExpiration(selectedAudioUrl)
        : null;
    DateTime? expiresAt;
    if (streamExp != null && audioExp != null) {
      expiresAt = streamExp.isBefore(audioExp) ? streamExp : audioExp;
    } else {
      expiresAt = streamExp ?? audioExp;
    }
    final isExpiring = expiresAt != null;

    return ResolvedStream(
      originalUrl: originalUrl,
      streamUrl: selectedStreamUrl,
      audioUrl: selectedAudioUrl,
      title: title,
      httpHeaders: httpHeaders,
      renditions: List.unmodifiable(renditions),
      isExpiring: isExpiring,
      expiresAt: expiresAt,
      formatId: selectedFormatId,
      extractor: extractor,
      duration: duration,
    );
  }

  _InternalFormat _parseFormatItem(Map<String, dynamic> item) {
    final formatId = item['format_id']?.toString() ?? 'unknown';
    final url = item['url'] as String;
    final width = (item['width'] as num?)?.toInt() ?? 0;
    final height = (item['height'] as num?)?.toInt() ?? 0;
    final fps = (item['fps'] as num?)?.toDouble() ?? 0.0;
    final rawBitrateKbps = (item['tbr'] ?? item['vbr']) as num?;
    final bitrate = rawBitrateKbps != null && rawBitrateKbps > 0
        ? (rawBitrateKbps * 1000).round()
        : 0;
    final rawAudioBitrateKbps = (item['abr'] ?? item['tbr']) as num?;
    final audioBitrate = rawAudioBitrateKbps != null && rawAudioBitrateKbps > 0
        ? (rawAudioBitrateKbps * 1000).round()
        : 0;
    final vcodec = item['vcodec'] as String?;
    final acodec = item['acodec'] as String?;
    final formatNote = (item['format_note'] ?? item['format'])?.toString();
    final container = (item['ext'] ?? item['container'])?.toString();
    final fileSize = ((item['filesize'] ?? item['filesize_approx']) as num?)
        ?.toInt();
    final httpHeaders = sanitizeHttpHeaders(
      item['http_headers'] as Map<String, dynamic>?,
      originUri: Uri.tryParse(url),
    );

    final hasVideo =
        (vcodec != null && vcodec != 'none') || height > 0 || width > 0;
    final hasAudio = acodec != null && acodec != 'none';

    return _InternalFormat(
      formatId: formatId,
      url: url,
      width: width,
      height: height,
      fps: fps,
      bitrate: bitrate,
      audioBitrate: audioBitrate,
      videoCodec: vcodec,
      audioCodec: acodec,
      formatNote: formatNote,
      container: container,
      fileSize: fileSize,
      httpHeaders: httpHeaders,
      hasVideo: hasVideo,
      hasAudio: hasAudio,
    );
  }

  Future<ProcessExecutionResult> _runProcessWithCancellationAndTimeout({
    required String executable,
    required List<String> arguments,
    required Duration timeout,
    CancellationToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const YtDlpCancelledException('Resolution cancelled before start');
    }

    final Process process;
    try {
      process = await runner.start(executable, arguments, runInShell: false);
    } on ProcessException catch (e) {
      throw YtDlpNotFoundException(
        'Failed to execute yt-dlp ($executable): ${e.message}',
        executable: executable,
        innerException: e,
      );
    } catch (e) {
      if (e is YtDlpException) rethrow;
      throw YtDlpNotFoundException(
        'Failed to execute yt-dlp ($executable): $e',
        executable: executable,
        innerException: e,
      );
    }

    final stdoutBytes = BytesBuilder(copy: false);
    final stderrBytes = BytesBuilder(copy: false);
    final stdoutCompleter = Completer<void>();
    final stderrCompleter = Completer<void>();

    const maxStdoutBytes = 15 * 1024 * 1024;
    const maxStderrBytes = 1024 * 1024;

    final stdoutSub = process.stdout.listen(
      (chunk) {
        if (stdoutBytes.length < maxStdoutBytes) {
          stdoutBytes.add(chunk);
        }
      },
      onDone: () {
        if (!stdoutCompleter.isCompleted) stdoutCompleter.complete();
      },
      onError: (Object e) {
        if (!stdoutCompleter.isCompleted) stdoutCompleter.completeError(e);
      },
      cancelOnError: false,
    );

    final stderrSub = process.stderr.listen(
      (chunk) {
        if (stderrBytes.length < maxStderrBytes) {
          stderrBytes.add(chunk);
        }
      },
      onDone: () {
        if (!stderrCompleter.isCompleted) stderrCompleter.complete();
      },
      onError: (Object e) {
        if (!stderrCompleter.isCompleted) stderrCompleter.completeError(e);
      },
      cancelOnError: false,
    );

    final stopwatch = Stopwatch()..start();
    Timer? timeoutTimer;
    void Function()? cancelListener;
    bool isTimeout = false;
    bool isCancelled = false;

    void killProcess() {
      try {
        process.kill();
      } catch (_) {}
    }

    if (cancelToken != null) {
      cancelListener = () {
        isCancelled = true;
        killProcess();
      };
      cancelToken.addListener(cancelListener);
    }

    timeoutTimer = Timer(timeout, () {
      isTimeout = true;
      killProcess();
    });

    try {
      final exitCode = await process.exitCode;
      await Future.wait([
        stdoutCompleter.future,
        stderrCompleter.future,
      ]).catchError((_) => <void>[]);

      if (isCancelled || (cancelToken?.isCancelled ?? false)) {
        throw const YtDlpCancelledException('Resolution cancelled by caller');
      }

      if (isTimeout) {
        throw TimeoutException(
          'yt-dlp resolution timed out after ${timeout.inSeconds}s',
          timeout,
        );
      }

      final stdoutString = utf8.decode(
        stdoutBytes.takeBytes(),
        allowMalformed: true,
      );
      final stderrString = utf8.decode(
        stderrBytes.takeBytes(),
        allowMalformed: true,
      );

      return ProcessExecutionResult(
        exitCode: exitCode,
        stdout: stdoutString,
        stderr: stderrString,
        elapsed: stopwatch.elapsed,
      );
    } finally {
      timeoutTimer.cancel();
      if (cancelListener != null && cancelToken != null) {
        cancelToken.removeListener(cancelListener);
      }
      await stdoutSub.cancel().catchError((_) {});
      await stderrSub.cancel().catchError((_) {});
    }
  }

  static bool _isVersionOutdated(String version) {
    final match = RegExp(r'^(\d{4})\.(\d{2})\.(\d{2})').firstMatch(version);
    if (match != null) {
      final year = int.tryParse(match.group(1) ?? '');
      if (year != null && year < 2023) {
        return true;
      }
    }
    return false;
  }

  static YtDlpErrorType _classifyError(String stderr) {
    final lower = stderr.toLowerCase();
    if (lower.contains('unsupported url') ||
        lower.contains('is not a valid url')) {
      return YtDlpErrorType.unsupportedUrl;
    }
    if (lower.contains('sign in') ||
        lower.contains('confirm you') ||
        lower.contains('confirm your age') ||
        lower.contains('login') ||
        lower.contains('private video')) {
      return YtDlpErrorType.loginRequired;
    }
    if (lower.contains('video unavailable') ||
        lower.contains('has been removed') ||
        lower.contains('not found') ||
        lower.contains('does not exist')) {
      return YtDlpErrorType.videoUnavailable;
    }
    if (lower.contains('not available in your country') ||
        lower.contains('geo-restricted') ||
        lower.contains('georestricted') ||
        lower.contains('blocked in your country')) {
      return YtDlpErrorType.geoRestricted;
    }
    if (lower.contains('drm') || lower.contains('protected')) {
      return YtDlpErrorType.drmProtected;
    }
    if (lower.contains('too many requests') ||
        lower.contains('429') ||
        lower.contains('rate limit')) {
      return YtDlpErrorType.rateLimited;
    }
    if (lower.contains('unable to download webpage') ||
        lower.contains('connection refused') ||
        lower.contains('timed out') ||
        lower.contains('name or service not known')) {
      return YtDlpErrorType.networkError;
    }
    return YtDlpErrorType.unknown;
  }
}

class _InternalFormat {
  final String formatId;
  final String url;
  final int width;
  final int height;
  final double fps;
  final int bitrate;
  final int audioBitrate;
  final String? videoCodec;
  final String? audioCodec;
  final String? formatNote;
  final String? container;
  final int? fileSize;
  final Map<String, String>? httpHeaders;
  final bool hasVideo;
  final bool hasAudio;

  const _InternalFormat({
    required this.formatId,
    required this.url,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrate,
    required this.audioBitrate,
    required this.videoCodec,
    required this.audioCodec,
    required this.formatNote,
    required this.container,
    required this.fileSize,
    required this.httpHeaders,
    required this.hasVideo,
    required this.hasAudio,
  });

  bool get isMuxed => hasVideo && hasAudio;
}
