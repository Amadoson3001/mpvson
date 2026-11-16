// Public constructor names intentionally differ from private backing fields.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/updates/app_version.dart';
import '../../domain/updates/github_app_release.dart';
import '../../domain/updates/release_info.dart';
import '../../domain/updates/semantic_version.dart';
import '../../domain/updates/update_manifest.dart';
import '../../domain/updates/update_record.dart';
import '../../domain/updates/update_url.dart';
import '../../utils/file_utils.dart';
import 'download_manager.dart';
import 'http_response_length.dart';
import 'process_runner.dart';
import 'redirecting_get.dart';

/// Checks for complete desktop application bundles and verifies them before
/// exposing the downloaded archive to the user.
class UpdateService extends ChangeNotifier {
  UpdateService({
    Uri? manifestUri,
    http.Client? client,
    Future<Directory> Function()? supportDirectoryProvider,
    UpdatePlatform Function()? platformProvider,
    bool useGitHubReleases = true,
    bool? preferInstaller,
    bool Function()? isWindowsProvider,
    Future<void> Function(String installerPath)? installerLauncher,
    this.currentVersion = AppVersion.current,
  }) : _manifestUri = manifestUri ?? _manifestUriFromEnvironment(),
       _usesOfficialGitHubSource =
           (manifestUri ?? _manifestUriFromEnvironment()) == null &&
           useGitHubReleases,
       _configured =
           ((manifestUri ?? _manifestUriFromEnvironment()) != null &&
               (manifestUri ?? _manifestUriFromEnvironment())
                   .toString()
                   .trim()
                   .isNotEmpty) ||
           useGitHubReleases,
       _preferInstaller = preferInstaller,
       _isWindowsProvider = isWindowsProvider ?? (() => Platform.isWindows),
       _installerLauncher = installerLauncher,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _platformProvider = platformProvider ?? (() => UpdatePlatform.current),
       _downloadManager = DownloadManager(
         idleTimeout: _requestTimeout,
         maxDuration: _maxDownloadDuration,
       ) {
    _status = configured ? 'idle' : 'unconfigured';
  }

  static const String _configuredManifest = String.fromEnvironment(
    'MPVSON_UPDATE_MANIFEST',
  );
  static const int _maxRedirects = 4;
  static const Duration _requestTimeout = Duration(seconds: 20);
  static const Duration _maxDownloadDuration = Duration(minutes: 30);
  static const int _maxManifestBytes = 256 * 1024;
  static const int _maxDownloadBytes = 2 * 1024 * 1024 * 1024;

  final Uri? _manifestUri;
  final bool _usesOfficialGitHubSource;
  final bool _configured;
  final bool? _preferInstaller;
  final bool Function() _isWindowsProvider;
  final Future<void> Function(String installerPath)? _installerLauncher;
  final http.Client _client;
  final bool _ownsClient;
  final Future<Directory> Function() _supportDirectoryProvider;
  final UpdatePlatform Function() _platformProvider;
  final String currentVersion;
  final DownloadManager _downloadManager;
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
  String? _failureKind;
  String _failurePhase = 'check';

  bool get configured => _configured;
  bool get busy => _busy;
  bool get usesOfficialGitHubSource => _usesOfficialGitHubSource;
  String get sourceLabel => _usesOfficialGitHubSource
      ? GitHubAppRelease.sourceLabel
      : 'Custom update feed';

  bool get canLaunchInstaller =>
      _isWindowsProvider() &&
      _status == 'ready' &&
      _downloadPath != null &&
      _downloadPath!.toLowerCase().endsWith('.exe');

  String get status => _status;
  double get progress => _progress;
  String? get error => _error;
  ReleaseInfo? get release => _release;
  String? get downloadPath => _downloadPath;

  /// What the app was doing when the current 'error' state was recorded:
  /// 'check', 'download', or 'apply' (opening the verified archive).
  String? get failureKind => _failureKind;

  /// True when the current 'error' state came from a failed download rather
  /// than a failed update check or a failed apply step.
  bool get failedDuringDownload => _failureKind == 'download';

  static Uri? _manifestUriFromEnvironment() {
    final value = _configuredManifest.trim();
    return value.isEmpty ? null : Uri.tryParse(value);
  }

  /// Fetches the configured manifest or official GitHub release and exposes a
  /// release only when it is newer than the running application.
  ///
  /// When [silent] is true (e.g. a startup background check), transient offline
  /// or HTTP failures keep the service in `'idle'` instead of surfacing an error.
  Future<void> check({bool silent = false}) async {
    if (_disposed || _busy) return;
    if (!configured) {
      _setState(status: 'unconfigured', progress: 0, error: null);
      return;
    }

    _busy = true;
    _downloadable = false;
    _failurePhase = 'check';
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
      final platform = _platformProvider();
      final ReleaseInfo release;
      if (_usesOfficialGitHubSource) {
        release = await _fetchGitHubRelease(platform, abortCompleter);
      } else {
        final manifestUri = _manifestUri;
        if (manifestUri == null) {
          throw const _UpdateException(
            'Configured update manifest URL is invalid.',
          );
        }
        release = await _fetchManifest(manifestUri, platform, abortCompleter);
      }
      if (_disposed) return;

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
        if (silent) {
          _failureKind = null;
          _setState(status: 'idle', progress: 0, error: null);
        } else {
          _fail(error);
        }
      }
    } finally {
      _activeAbortCompleters.remove(abortCompleter);
      if (!abortCompleter.isCompleted) {
        abortCompleter.complete();
      }
      _finishOperation();
    }
  }

  Future<ReleaseInfo> _fetchManifest(
    Uri manifestUri,
    UpdatePlatform platform,
    Completer<void> abortCompleter,
  ) async {
    _requireHttps(manifestUri, 'Manifest URL');
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
    return UpdateManifest.parse(body, platform: platform).release;
  }

  Future<ReleaseInfo> _fetchGitHubRelease(
    UpdatePlatform platform,
    Completer<void> abortCompleter,
  ) async {
    final response = await _sendGet(
      GitHubAppRelease.latestApiUri,
      abortCompleter,
      headers: <String, String>{
        'Accept': 'application/vnd.github+json',
        'User-Agent':
            'Mpvson/${currentVersion.replaceAll(RegExp(r'[\r\n]'), '')}',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    );
    if (response.statusCode == HttpStatus.notFound) {
      await _cancelBody(response);
      throw const _UpdateException('No published release was found yet.');
    }
    if (response.statusCode != HttpStatus.ok) {
      await _cancelBody(response);
      throw _UpdateException(
        'GitHub release check failed (HTTP ${response.statusCode}).',
      );
    }

    final body = await _readTextBody(
      response,
      _maxManifestBytes,
      abortCompleter,
    );
    final outcome = GitHubAppRelease.parseLatest(
      body,
      platform: platform,
      preferInstaller: _preferInstaller ?? _detectInstalledWindows(),
    );

    if (outcome.manifestUri != null) {
      return _fetchManifest(outcome.manifestUri!, platform, abortCompleter);
    }

    final release = outcome.release!;
    final checksumsUri = outcome.checksumsUri;
    if (checksumsUri == null) return release;

    final sumsResponse = await _sendGet(checksumsUri, abortCompleter);
    if (sumsResponse.statusCode != HttpStatus.ok) {
      await _cancelBody(sumsResponse);
      throw _UpdateException(
        'Could not fetch SHA256SUMS (HTTP ${sumsResponse.statusCode}).',
      );
    }
    final sumsText = await _readTextBody(
      sumsResponse,
      _maxManifestBytes,
      abortCompleter,
    );
    final resolvedHash = GitHubAppRelease.parseSha256Sums(
      sumsText,
      assetName: outcome.selectedAssetName!,
    );
    return ReleaseInfo(
      version: release.version,
      notes: release.notes,
      engineVersion: release.engineVersion,
      downloadUri: release.downloadUri,
      sha256: resolvedHash,
      releaseUri: release.releaseUri,
    );
  }

  static bool _detectInstalledWindows() {
    if (!Platform.isWindows) return false;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      return File(p.join(exeDir.path, 'unins000.exe')).existsSync();
    } on Object {
      return false;
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
    _failurePhase = 'download';
    _setState(status: 'downloading', progress: 0, error: null);
    File? temporaryFile;
    File? verifiedArchive;
    var temporaryFileCreated = false;

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
      final contentLength = responseBodyLength(response);
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

      try {
        await _downloadManager.streamToFile(
          response.stream,
          partialFile,
          abort: abortCompleter,
          maxBytes: _maxDownloadBytes,
          expectedBytes: contentLength,
          expectedSha256: release.sha256,
          onProgress: (frac, received, total) {
            if (contentLength != null && contentLength > 0) {
              _setProgress(frac);
            }
          },
          isDisposed: () => _disposed,
        );
      } on DownloadCancelledException {
        if (_disposed) return;
        throw const _DisposedException();
      } on DownloadIdleTimeoutException {
        throw TimeoutException(
          'Update download stream timed out.',
          const Duration(seconds: 20),
        );
      } on DownloadDurationExceededException {
        throw const _UpdateException(
          'Update download exceeded the time limit.',
        );
      } on DownloadSizeLimitException {
        throw const _UpdateException('Update bundle exceeds the size limit.');
      } on DownloadSizeMismatchException {
        throw const _UpdateException('Update download ended unexpectedly.');
      } on DownloadHashMismatchException {
        throw const _UpdateException(
          'Update bundle failed its SHA-256 integrity check.',
        );
      } on DownloadException catch (e) {
        throw _UpdateException(e.message);
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
      verifiedArchive = finalFile;

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
      verifiedArchive = null;

      // A committed archive belongs to the cache even if disposal raced the
      // record write. _setState ignores updates after disposal.
      _setState(
        status: 'ready',
        progress: 1,
        error: null,
        downloadPath: finalFile.path,
      );
    } on Object catch (error) {
      if (temporaryFile != null && temporaryFileCreated) {
        try {
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } catch (_) {}
      }
      final orphan = verifiedArchive;
      if (orphan != null) {
        try {
          if (await orphan.exists()) await orphan.delete();
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
      _finishOperation();
    }
  }

  /// Opens the verified archive in its containing location for manual install.
  /// The service deliberately does not install or replace a running bundle.
  Future<void> openDownload() async {
    if (_disposed || _busy) return;
    _failurePhase = 'apply';
    final path = _downloadPath;
    if (path == null || _release == null) {
      _fail(const _UpdateException('There is no verified update to open.'));
      return;
    }

    _busy = true;
    notifyListeners();
    try {
      if (!await File(path).exists()) {
        throw const _UpdateException(
          'The verified update file is no longer available.',
        );
      }
      if (_disposed) return;
      await showInFolder(path);
      _setState(status: 'ready', error: null);
    } on Object catch (error) {
      _fail(error);
    } finally {
      _finishOperation();
    }
  }

  /// Re-verifies the downloaded Windows installer's SHA-256 digest and launches
  /// it detached so the user can close Mpvson and complete the upgrade.
  Future<bool> launchInstaller() async {
    if (_disposed || _busy) return false;
    _failurePhase = 'apply';
    final path = _downloadPath;
    final release = _release;
    if (!canLaunchInstaller || path == null || release == null) {
      _fail(
        const _UpdateException('There is no verified installer to launch.'),
      );
      return false;
    }

    _busy = true;
    notifyListeners();
    try {
      final file = File(path);
      if (!await file.exists()) {
        throw const _UpdateException(
          'The verified installer file is no longer available.',
        );
      }
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (digest != release.sha256.toLowerCase()) {
        throw const _UpdateException(
          'The installer failed its SHA-256 verification before launch.',
        );
      }
      if (_disposed) return false;
      final launcher = _installerLauncher;
      if (launcher != null) {
        await launcher(path);
      } else {
        await ProcessRunner.standard.start(
          path,
          const <String>['/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'],
          workingDirectory: file.parent.path,
          mode: ProcessStartMode.detached,
        );
      }
      _setState(status: 'ready', error: null);
      return true;
    } on Object catch (error) {
      _fail(error);
      return false;
    } finally {
      _finishOperation();
    }
  }

  void _finishOperation() {
    _busy = false;
    if (!_disposed) notifyListeners();
  }

  Future<http.StreamedResponse> _sendGet(
    Uri uri,
    Completer<void> abortCompleter, {
    Map<String, String>? headers,
  }) async {
    return sendGetFollowingRedirects(
      uri: uri,
      maxRedirects: _maxRedirects,
      refuse: (refusal) => switch (refusal) {
        RedirectRefusal.missingLocation => const _UpdateException(
          'Update server returned an invalid redirect.',
        ),
        RedirectRefusal.tooManyRedirects => const _UpdateException(
          'Update request exceeded the redirect limit.',
        ),
        RedirectRefusal.insecureTarget => const _UpdateException(
          'Redirect URL must use HTTPS and contain no credentials.',
        ),
      },
      send: (destination) async {
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
              ..headers.addAll(<String, String>{
                'Accept': 'application/json, application/octet-stream',
                ...?headers,
              });
        final pendingResponse = _client.send(request).then((response) {
          if (_disposed || abortCompleter.isCompleted) {
            unawaited(_cancelBody(response));
            throw const _DisposedException();
          }
          return response;
        });
        http.StreamedResponse response;
        try {
          response = await Future.any<http.StreamedResponse>([
            pendingResponse,
            abortCompleter.future.then<http.StreamedResponse>(
              (_) => throw const _DisposedException(),
            ),
          ]).timeout(_requestTimeout);
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
        return response;
      },
      cancelBody: _cancelBody,
    );
  }

  Future<String> _readTextBody(
    http.StreamedResponse response,
    int maximumBytes,
    Completer<void> abortCompleter,
  ) async {
    final contentLength = responseBodyLength(response);
    if (contentLength != null && contentLength > maximumBytes) {
      await _cancelBody(response);
      throw const _UpdateException('Update manifest exceeds the size limit.');
    }

    try {
      final result = await _downloadManager.streamToBytes(
        response.stream,
        abort: abortCompleter,
        maxBytes: maximumBytes,
        expectedBytes: contentLength,
        isDisposed: () => _disposed,
      );
      final bytes = result.bytes ?? Uint8List(0);
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        throw const _UpdateException('Update manifest is not valid UTF-8.');
      }
    } on DownloadCancelledException {
      throw const _DisposedException();
    } on DownloadIdleTimeoutException {
      throw TimeoutException(
        'Update manifest request timed out.',
        const Duration(seconds: 20),
      );
    } on DownloadDurationExceededException {
      throw const _UpdateException('Update manifest request timed out.');
    } on DownloadSizeLimitException {
      throw const _UpdateException('Update manifest exceeds the size limit.');
    } on DownloadSizeMismatchException {
      throw const _UpdateException('Update manifest ended unexpectedly.');
    } on DownloadException catch (e) {
      throw _UpdateException(e.message);
    }
  }

  Future<void> _cancelBody(http.StreamedResponse response) async {
    await response.stream.listen(null).cancel();
  }

  static void _requireHttps(Uri uri, String label) {
    if (!isSafeHttpsUri(uri)) {
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
    _failureKind = _failurePhase;
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
