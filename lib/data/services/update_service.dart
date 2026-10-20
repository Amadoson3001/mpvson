import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/updates/release_info.dart';
import '../../domain/updates/semantic_version.dart';
import '../../domain/updates/update_manifest.dart';
import '../../domain/updates/update_record.dart';

/// Checks for complete desktop application bundles and verifies them before
/// exposing the downloaded archive to the user.
class UpdateService extends ChangeNotifier {
  UpdateService({
    Uri? manifestUri,
    http.Client? client,
    Future<Directory> Function()? supportDirectoryProvider,
    UpdatePlatform Function()? platformProvider,
    this.currentVersion = '0.1.0',
    Future<void> Function(String path)? openDownloadLocationForTesting,
    Duration requestTimeoutForTesting = const Duration(seconds: 20),
    Duration maxDownloadDurationForTesting = const Duration(minutes: 30),
    int maxManifestBytesForTesting = 256 * 1024,
    int maxDownloadBytesForTesting = 2 * 1024 * 1024 * 1024,
  }) : _manifestUri = manifestUri ?? _manifestUriFromEnvironment(),
       _configured = manifestUri == null
           ? _configuredManifest.trim().isNotEmpty
           : manifestUri.toString().trim().isNotEmpty,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _platformProvider = platformProvider ?? (() => UpdatePlatform.current),
       _openDownloadedArtifact = openDownloadLocationForTesting,
       _requestTimeout = requestTimeoutForTesting,
       _maxDownloadDuration = maxDownloadDurationForTesting,
       _maxManifestBytes = maxManifestBytesForTesting,
       _maxDownloadBytes = maxDownloadBytesForTesting {
    _status = configured ? 'idle' : 'unconfigured';
  }

  static const String _configuredManifest = String.fromEnvironment(
    'MPVSON_UPDATE_MANIFEST',
  );
  static const int _maxRedirects = 4;

  final Uri? _manifestUri;
  final bool _configured;
  final http.Client _client;
  final bool _ownsClient;
  final Future<Directory> Function() _supportDirectoryProvider;
  final UpdatePlatform Function() _platformProvider;
  final String currentVersion;
  final Future<void> Function(String path)? _openDownloadedArtifact;
  final Duration _requestTimeout;
  final Duration _maxDownloadDuration;
  final int _maxManifestBytes;
  final int _maxDownloadBytes;
  final Random _random = Random.secure();

  final Set<Completer<void>> _activeAbortCompleters = {};
  final Set<StreamSubscription<dynamic>> _activeSubscriptions = {};
  final Set<Completer<void>> _activeStreamCompleters = {};

  String _status = 'idle';
  double _progress = 0;
  String? _error;
  ReleaseInfo? _release;
  String? _downloadPath;
  bool _busy = false;
  bool _disposed = false;
  bool _downloadable = false;

  bool get configured => _configured;

  String get status => _status;
  double get progress => _progress;
  String? get error => _error;
  ReleaseInfo? get release => _release;
  String? get downloadPath => _downloadPath;

  static Uri? _manifestUriFromEnvironment() {
    final value = _configuredManifest.trim();
    return value.isEmpty ? null : Uri.tryParse(value);
  }

  /// Fetches the configured manifest and exposes a release only when it is
  /// newer than the running application.
  Future<void> check() async {
    if (_disposed || _busy) return;
    if (!configured) {
      _setState(status: 'unconfigured', progress: 0, error: null);
      return;
    }

    _busy = true;
    _downloadable = false;
    _setState(
      status: 'checking',
      progress: 0,
      error: null,
      clearRelease: true,
      clearDownloadPath: true,
    );

    final abortCompleter = Completer<void>();
    _activeAbortCompleters.add(abortCompleter);

    try {
      SemanticVersion.parse(currentVersion);
      final manifestUri = _manifestUri;
      if (manifestUri == null) {
        throw const _UpdateException(
          'Configured update manifest URL is invalid.',
        );
      }
      _requireHttps(manifestUri, 'Manifest URL');
      final platform = _platformProvider();
      final response = await _sendGet(manifestUri, abortCompleter);
      if (response.statusCode != HttpStatus.ok) {
        await _cancelBody(response);
        throw _UpdateException(
          'Update manifest request failed (HTTP ${response.statusCode}).',
        );
      }

      final body = await _readTextBody(
        response,
        _maxManifestBytes,
        abortCompleter,
      );
      if (_disposed) return;
      final release = UpdateManifest.parse(body, platform: platform).release;
      final current = SemanticVersion.parse(currentVersion);
      final latest = SemanticVersion.parse(release.version);
      if (latest.compareTo(current) > 0) {
        _downloadable = true;
        _setState(status: 'available', release: release, progress: 0);
      } else {
        _setState(status: 'upToDate', release: release, progress: 0);
      }
    } on Object catch (error) {
      if (!_disposed) {
        _fail(error);
      }
    } finally {
      _activeAbortCompleters.remove(abortCompleter);
      if (!abortCompleter.isCompleted) {
        abortCompleter.complete();
      }
      _busy = false;
    }
  }

  /// Downloads the selected bundle to app support storage and checks its
  /// SHA-256 digest before marking it ready.
  Future<void> download() async {
    if (_disposed || _busy) return;
    final release = _release;
    if (release == null || !_downloadable) {
      _setState(error: 'There is no newer release available to download.');
      return;
    }
    if (_status != 'available' && _status != 'error') {
      return;
    }

    _busy = true;
    _setState(status: 'downloading', progress: 0, error: null);
    File? temporaryFile;
    var temporaryFileCreated = false;
    IOSink? output;

    final abortCompleter = Completer<void>();
    _activeAbortCompleters.add(abortCompleter);

    try {
      final platform = _platformProvider();
      final directory = Directory(
        p.join((await _supportDirectoryProvider()).path, 'updates'),
      );
      await directory.create(recursive: true);
      final store = UpdateOwnershipStore(directory);

      // Reuse matching cached bundle if verified and recorded.
      final cachedFile = await store.findMatchingVerifiedBundle(
        version: release.version,
        sha256: release.sha256,
      );
      if (cachedFile != null) {
        if (_disposed) return;
        _setState(
          status: 'ready',
          progress: 1,
          error: null,
          downloadPath: cachedFile.path,
        );
        return;
      }

      final response = await _sendGet(release.downloadUri, abortCompleter);
      if (response.statusCode != HttpStatus.ok) {
        await _cancelBody(response);
        throw _UpdateException(
          'Update download failed (HTTP ${response.statusCode}).',
        );
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > _maxDownloadBytes) {
        await _cancelBody(response);
        throw const _UpdateException('Update bundle exceeds the size limit.');
      }

      final targetName = _artifactName(release, platform);
      final randomSuffix = _random.nextInt(1 << 32).toRadixString(16);
      final destination = File(
        p.join(directory.path, '$randomSuffix-$targetName'),
      );
      final partialFile = File(
        p.join(
          directory.path,
          '.mpvson-update-$pid-${DateTime.now().microsecondsSinceEpoch}-$randomSuffix.part',
        ),
      );
      temporaryFile = partialFile;
      await partialFile.create(exclusive: true);
      temporaryFileCreated = true;
      output = partialFile.openWrite();

      final hashSink = _DigestSink();
      final hashInput = sha256.startChunkedConversion(hashSink);
      var receivedBytes = 0;
      final stopwatch = Stopwatch()..start();

      final streamCompleter = Completer<void>();
      StreamSubscription<List<int>>? subscription;
      Timer? idleTimer;

      void resetIdleTimer() {
        idleTimer?.cancel();
        idleTimer = Timer(_requestTimeout, () {
          if (!abortCompleter.isCompleted) {
            abortCompleter.complete();
          }
          subscription?.cancel();
          if (!streamCompleter.isCompleted) {
            streamCompleter.completeError(
              TimeoutException(
                'Update download stream timed out.',
                const Duration(seconds: 20),
              ),
            );
          }
        });
      }

      resetIdleTimer();

      subscription = response.stream.listen(
        (chunk) {
          if (_disposed) {
            idleTimer?.cancel();
            subscription?.cancel();
            if (!streamCompleter.isCompleted) {
              streamCompleter.completeError(const _DisposedException());
            }
            return;
          }
          resetIdleTimer();
          if (stopwatch.elapsed > _maxDownloadDuration) {
            idleTimer?.cancel();
            subscription?.cancel();
            if (!streamCompleter.isCompleted) {
              streamCompleter.completeError(
                const _UpdateException(
                  'Update download exceeded the time limit.',
                ),
              );
            }
            return;
          }
          receivedBytes += chunk.length;
          if (receivedBytes > _maxDownloadBytes) {
            idleTimer?.cancel();
            subscription?.cancel();
            if (!streamCompleter.isCompleted) {
              streamCompleter.completeError(
                const _UpdateException('Update bundle exceeds the size limit.'),
              );
            }
            return;
          }
          output?.add(chunk);
          hashInput.add(chunk);
          if (contentLength != null && contentLength > 0) {
            _setProgress(receivedBytes / contentLength);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          idleTimer?.cancel();
          if (!streamCompleter.isCompleted) {
            streamCompleter.completeError(error, stackTrace);
          }
        },
        onDone: () {
          idleTimer?.cancel();
          if (!streamCompleter.isCompleted) {
            streamCompleter.complete();
          }
        },
        cancelOnError: true,
      );

      _activeSubscriptions.add(subscription);
      _activeStreamCompleters.add(streamCompleter);

      try {
        await streamCompleter.future;
      } finally {
        idleTimer?.cancel();
        _activeSubscriptions.remove(subscription);
        _activeStreamCompleters.remove(streamCompleter);
        await subscription.cancel();
      }

      hashInput.close();
      await output.flush();
      await output.close();
      output = null;

      if (_disposed) {
        if (temporaryFileCreated) {
          try {
            if (await temporaryFile.exists()) await temporaryFile.delete();
          } catch (_) {}
        }
        return;
      }

      if (stopwatch.elapsed > _maxDownloadDuration) {
        throw const _UpdateException(
          'Update download exceeded the time limit.',
        );
      }
      if (contentLength != null && receivedBytes != contentLength) {
        throw const _UpdateException('Update download ended unexpectedly.');
      }
      final actualHash = hashSink.value?.toString().toLowerCase();
      if (actualHash == null || actualHash != release.sha256.toLowerCase()) {
        throw const _UpdateException(
          'Update bundle failed its SHA-256 integrity check.',
        );
      }

      if (_disposed) {
        if (temporaryFileCreated) {
          try {
            if (await temporaryFile.exists()) await temporaryFile.delete();
          } catch (_) {}
        }
        return;
      }

      final finalFile = await partialFile.rename(destination.path);
      temporaryFile = null;
      temporaryFileCreated = false;

      if (_disposed) {
        try {
          if (await finalFile.exists()) await finalFile.delete();
        } catch (_) {}
        return;
      }

      await store.recordVerifiedDownload(
        version: release.version,
        sha256: release.sha256,
        bundleFile: finalFile,
      );

      if (_disposed) {
        try {
          if (await finalFile.exists()) await finalFile.delete();
        } catch (_) {}
        return;
      }

      _setState(
        status: 'ready',
        progress: 1,
        error: null,
        downloadPath: finalFile.path,
      );
    } on Object catch (error) {
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (temporaryFile != null && temporaryFileCreated) {
        try {
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } catch (_) {}
      }
      if (!_disposed) {
        _fail(error);
      }
    } finally {
      _activeAbortCompleters.remove(abortCompleter);
      if (!abortCompleter.isCompleted) {
        abortCompleter.complete();
      }
      _busy = false;
    }
  }

  /// Opens the verified archive in its containing location for manual install.
  /// The service deliberately does not install or replace a running bundle.
  Future<void> openDownload() async {
    if (_disposed) return;
    final path = _downloadPath;
    if (path == null || _release == null) {
      _fail(const _UpdateException('There is no verified update to open.'));
      return;
    }

    try {
      if (!await File(path).exists()) {
        throw const _UpdateException(
          'The verified update file is no longer available.',
        );
      }
      final opener = _openDownloadedArtifact;
      if (opener != null) {
        await opener(path);
      } else {
        final platform = _platformProvider();
        if (platform == UpdatePlatform.windows) {
          await Process.start('explorer.exe', [
            '/select,$path',
          ], mode: ProcessStartMode.detached);
        } else {
          await Process.start('xdg-open', [
            p.dirname(path),
          ], mode: ProcessStartMode.detached);
        }
      }
      _setState(status: 'ready', error: null);
    } on Object catch (error) {
      _fail(error);
    }
  }

  Future<http.StreamedResponse> _sendGet(
    Uri uri,
    Completer<void> abortCompleter,
  ) async {
    var destination = uri;
    for (
      var redirectCount = 0;
      redirectCount <= _maxRedirects;
      redirectCount++
    ) {
      if (_disposed) throw const _DisposedException();
      _requireHttps(destination, 'Request URL');
      final request =
          http.AbortableRequest(
              'GET',
              destination,
              abortTrigger: abortCompleter.future,
            )
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers['Accept'] = 'application/json, application/octet-stream';
      http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(_requestTimeout);
      } on TimeoutException {
        if (!abortCompleter.isCompleted) {
          abortCompleter.complete();
        }
        throw const _UpdateException('Update request timed out.');
      } catch (error) {
        if (!abortCompleter.isCompleted) {
          abortCompleter.complete();
        }
        rethrow;
      }

      if (response.statusCode < 300 || response.statusCode >= 400) {
        return response;
      }

      await _cancelBody(response);
      if (redirectCount == _maxRedirects) {
        throw const _UpdateException(
          'Update request exceeded the redirect limit.',
        );
      }
      final location = response.headers['location'];
      if (location == null || location.trim().isEmpty) {
        throw const _UpdateException(
          'Update server returned an invalid redirect.',
        );
      }
      final redirected = destination.resolve(location);
      _requireHttps(redirected, 'Redirect URL');
      destination = redirected;
    }
    throw const _UpdateException('Update request exceeded the redirect limit.');
  }

  Future<String> _readTextBody(
    http.StreamedResponse response,
    int maximumBytes,
    Completer<void> abortCompleter,
  ) async {
    final contentLength = response.contentLength;
    if (contentLength != null && contentLength > maximumBytes) {
      await _cancelBody(response);
      throw const _UpdateException('Update manifest exceeds the size limit.');
    }

    final bytes = BytesBuilder(copy: false);
    var count = 0;
    final stopwatch = Stopwatch()..start();

    final streamCompleter = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(_requestTimeout, () {
        if (!abortCompleter.isCompleted) {
          abortCompleter.complete();
        }
        subscription?.cancel();
        if (!streamCompleter.isCompleted) {
          streamCompleter.completeError(
            TimeoutException(
              'Update manifest request timed out.',
              const Duration(seconds: 20),
            ),
          );
        }
      });
    }

    resetIdleTimer();

    subscription = response.stream.listen(
      (chunk) {
        if (_disposed) {
          idleTimer?.cancel();
          subscription?.cancel();
          if (!streamCompleter.isCompleted) {
            streamCompleter.completeError(const _DisposedException());
          }
          return;
        }
        resetIdleTimer();
        if (stopwatch.elapsed > _requestTimeout) {
          idleTimer?.cancel();
          subscription?.cancel();
          if (!streamCompleter.isCompleted) {
            streamCompleter.completeError(
              const _UpdateException('Update manifest request timed out.'),
            );
          }
          return;
        }
        count += chunk.length;
        if (count > maximumBytes) {
          idleTimer?.cancel();
          subscription?.cancel();
          if (!streamCompleter.isCompleted) {
            streamCompleter.completeError(
              const _UpdateException('Update manifest exceeds the size limit.'),
            );
          }
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        idleTimer?.cancel();
        if (!streamCompleter.isCompleted) {
          streamCompleter.completeError(error, stackTrace);
        }
      },
      onDone: () {
        idleTimer?.cancel();
        if (!streamCompleter.isCompleted) {
          streamCompleter.complete();
        }
      },
      cancelOnError: true,
    );

    _activeSubscriptions.add(subscription);
    _activeStreamCompleters.add(streamCompleter);

    try {
      await streamCompleter.future;
    } finally {
      idleTimer?.cancel();
      _activeSubscriptions.remove(subscription);
      _activeStreamCompleters.remove(streamCompleter);
      await subscription.cancel();
    }

    if (contentLength != null && count != contentLength) {
      throw const _UpdateException('Update manifest ended unexpectedly.');
    }
    try {
      return utf8.decode(bytes.takeBytes(), allowMalformed: false);
    } on FormatException {
      throw const _UpdateException('Update manifest is not valid UTF-8.');
    }
  }

  Future<void> _cancelBody(http.StreamedResponse response) async {
    await response.stream.listen(null).cancel();
  }

  static void _requireHttps(Uri uri, String label) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw _UpdateException(
        '$label must use HTTPS and contain no credentials.',
      );
    }
  }

  static String _artifactName(ReleaseInfo release, UpdatePlatform platform) {
    final lastSegment = release.downloadUri.pathSegments.isEmpty
        ? 'update-bundle'
        : release.downloadUri.pathSegments.last;
    final safeFileName = lastSegment
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'^\.+'), '');
    final version = release.version.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final fileName = safeFileName.isEmpty ? 'update-bundle' : safeFileName;
    final truncatedVersion = version.length > 60
        ? version.substring(0, 60)
        : version;
    final truncatedName = fileName.length > 80
        ? fileName.substring(fileName.length - 80)
        : fileName;
    return 'mpvson-${platform.manifestKey}-$truncatedVersion-${release.sha256.substring(0, 12)}-$truncatedName';
  }

  void _setProgress(double value) {
    if (_disposed) return;
    _progress = value.clamp(0, 1).toDouble();
    notifyListeners();
  }

  void _setState({
    String? status,
    double? progress,
    String? error,
    ReleaseInfo? release,
    String? downloadPath,
    bool clearRelease = false,
    bool clearDownloadPath = false,
  }) {
    if (_disposed) return;
    if (status != null) _status = status;
    if (progress != null) _progress = progress.clamp(0, 1).toDouble();
    _error = error;
    if (clearRelease) {
      _release = null;
    } else if (release != null) {
      _release = release;
    }
    if (clearDownloadPath) {
      _downloadPath = null;
    } else if (downloadPath != null) {
      _downloadPath = downloadPath;
    }
    notifyListeners();
  }

  void _fail(Object error) {
    if (_disposed) return;
    _setState(status: 'error', error: _messageFor(error));
  }

  static String _messageFor(Object error) {
    if (error is _UpdateException) return error.message;
    if (error is _DisposedException) return error.message;
    if (error is FormatException) return error.message;
    if (error is TimeoutException) {
      return 'Update request timed out. Check your connection and try again.';
    }
    if (error is SocketException) {
      return 'Could not reach the update server. Check your connection and try again.';
    }
    if (error is http.RequestAbortedException) {
      return 'Update request was aborted.';
    }
    if (error is http.ClientException) return error.message;
    if (error is HttpException) return error.message;
    return 'Update failed: $error';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final completer in _activeAbortCompleters.toList()) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _activeAbortCompleters.clear();

    for (final sub in _activeSubscriptions.toList()) {
      sub.cancel();
    }
    _activeSubscriptions.clear();

    for (final completer in _activeStreamCompleters.toList()) {
      if (!completer.isCompleted) {
        completer.completeError(const _DisposedException());
      }
    }
    _activeStreamCompleters.clear();

    if (_ownsClient) _client.close();
    super.dispose();
  }
}

final class _UpdateException implements Exception {
  const _UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class _DisposedException implements Exception {
  const _DisposedException();

  final String message = 'Service was disposed.';

  @override
  String toString() => message;
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
