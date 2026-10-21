import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Public constructor names intentionally differ from private backing fields.
// ignore_for_file: prefer_initializing_formals

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../data/repositories/engine_installation_repository.dart';
import '../../data/repositories/engine_update_preferences_repository.dart';
import '../../domain/updates/engine_release.dart';
import '../../domain/updates/engine_update_channel.dart';
import '../../domain/updates/engine_selection.dart';
import '../../domain/updates/mpv_github_release.dart';
import '../../domain/updates/semantic_version.dart' as app_version;
import 'http_response_length.dart';

enum EngineUpdatePlatform {
  windows,
  linux,
  unsupported;

  static EngineUpdatePlatform get current {
    if (Platform.isWindows) return EngineUpdatePlatform.windows;
    if (Platform.isLinux) return EngineUpdatePlatform.linux;
    return EngineUpdatePlatform.unsupported;
  }
}

typedef EngineSignatureVerifier =
    Future<bool> Function({
      required List<int> message,
      required List<int> signature,
      required List<int> publicKey,
    });

/// Checks Windows libmpv builds and stages them for the next launch.
/// Linux deliberately delegates engine updates to the distribution.
class EngineUpdateService extends ChangeNotifier {
  EngineUpdateService({
    http.Client? client,
    EngineInstallationRepository? repository,
    Uri? manifestUri,
    String? publicKeyBase64,
    EngineSignatureVerifier? signatureVerifier,
    bool? useOfficialMpvSource,
    EngineUpdatePlatform Function()? platformProvider,
    EngineUpdatePreferencesRepository? preferencesRepository,
    this.appVersion = '0.1.0',
    this.supportedMediaKitVersion = '1.2.6',
    String currentVersion = '0.0.0',
    Duration requestTimeout = const Duration(seconds: 20),
    Duration maxDownloadDuration = const Duration(minutes: 30),
    int maxManifestBytes = 256 * 1024,
    int maxDownloadBytes = 512 * 1024 * 1024,
  }) : _manifestUri = manifestUri ?? _manifestUriFromEnvironment(),
       _publicKeyBase64 = (publicKeyBase64 ?? _configuredPublicKey).trim(),
       _signatureVerifier = signatureVerifier,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _repository = repository ?? EngineInstallationRepository(),
       _platformProvider =
           platformProvider ?? (() => EngineUpdatePlatform.current),
       _bundledVersion = currentVersion,
       _currentVersion = currentVersion,
       _requestTimeout = requestTimeout,
       _maxDownloadDuration = maxDownloadDuration,
       _maxManifestBytes = maxManifestBytes,
       _maxDownloadBytes = maxDownloadBytes {
    _preferencesRepository =
        preferencesRepository ??
        EngineUpdatePreferencesRepository(
          storageDirectoryProvider: () async {
            final enginesDirectory = await _repository.enginesDirectory;
            return Directory(p.join(enginesDirectory.parent.path, 'updates'));
          },
        );
    // A custom feed needs both halves: the manifest URL and the public key that
    // verifies it. A one-sided configuration keeps the official source and is
    // reported as a warning instead of silently disabling engine updates.
    final hasManifest =
        _manifestUri != null && _manifestUri.toString().trim().isNotEmpty;
    final hasKey = _signatureVerifier != null || _publicKeyBase64.isNotEmpty;
    final customRequested =
        useOfficialMpvSource == false ||
        manifestUri != null ||
        publicKeyBase64 != null ||
        signatureVerifier != null ||
        _configuredManifest.trim().isNotEmpty ||
        _configuredPublicKey.trim().isNotEmpty;
    if (useOfficialMpvSource == true) {
      _usesOfficialMpvSource = true;
      _configured = _isSelfManagedPlatform;
    } else if (hasManifest && hasKey) {
      _usesOfficialMpvSource = false;
      final problem = _validateCustomSource();
      if (problem == null) {
        _configured = true;
      } else {
        _configured = false;
        _configurationError = problem;
      }
    } else {
      _usesOfficialMpvSource = _isSelfManagedPlatform;
      _configured = _isSelfManagedPlatform;
      if (customRequested) {
        _configurationWarning = hasManifest
            ? 'Engine updates use the official mpv builds because the custom '
                  'feed is incomplete: its public key is missing.'
            : 'Engine updates use the official mpv builds because the custom '
                  'feed is incomplete: its manifest URL is missing.';
      }
    }
    _status = _isSelfManagedPlatform
        ? (_configured ? 'idle' : 'unconfigured')
        : 'systemManaged';
  }

  /// Validates a complete custom feed and returns a user-readable problem.
  ///
  /// Returns null when the manifest URL and key can be used.
  String? _validateCustomSource() {
    final manifest = _manifestUri;
    if (manifest == null || !manifest.isAbsolute || manifest.host.isEmpty) {
      return 'The engine manifest URL must be an absolute HTTPS URL.';
    }
    if (manifest.scheme != 'https') {
      return 'The engine manifest URL must use HTTPS.';
    }
    if (_signatureVerifier != null) return null;
    try {
      final bytes = base64Decode(_publicKeyBase64);
      if (bytes.length != 32) {
        return 'The engine public key must be a base64 encoded 32 byte '
            'Ed25519 key.';
      }
    } on FormatException {
      return 'The engine public key must be base64.';
    }
    return null;
  }

  static const String _configuredManifest = String.fromEnvironment(
    'MPVSON_ENGINE_UPDATE_MANIFEST',
  );
  static const String _configuredPublicKey = String.fromEnvironment(
    'MPVSON_ENGINE_PUBLIC_KEY',
  );
  static const int _maxRedirects = 4;

  final Uri? _manifestUri;
  final String _publicKeyBase64;
  final EngineSignatureVerifier? _signatureVerifier;
  final http.Client _client;
  final bool _ownsClient;
  final EngineInstallationRepository _repository;
  late final EngineUpdatePreferencesRepository _preferencesRepository;
  final EngineUpdatePlatform Function() _platformProvider;
  final Duration _requestTimeout;
  final Duration _maxDownloadDuration;
  final int _maxManifestBytes;
  final int _maxDownloadBytes;
  final String _bundledVersion;

  late final bool _usesOfficialMpvSource;

  final Set<Completer<void>> _activeRequests = <Completer<void>>{};
  final Set<void Function()> _abortBodyReads = <void Function()>{};
  final Set<StreamSubscription<List<int>>> _activeSubscriptions =
      <StreamSubscription<List<int>>>{};

  final String appVersion;
  final String supportedMediaKitVersion;

  late final bool _configured;
  String _currentVersion;
  String? _pendingVersion;
  String _status = 'idle';
  double _progress = 0;
  String? _error;
  String? _configurationWarning;
  String? _configurationError;
  EngineRelease? _release;
  EngineSelectionState? _selectionState;
  bool _busy = false;
  bool _disposed = false;
  bool _initialized = false;
  bool _initializing = false;
  EngineUpdateChannel _channel = EngineUpdateChannel.stable;
  String? _stableReleaseVersion;

  bool get configured => _configured;
  bool get busy => _busy || _initializing;
  EngineUpdateChannel get channel => _channel;
  bool get usesOfficialMpvSource =>
      _isSelfManagedPlatform && _usesOfficialMpvSource;
  String get sourceLabel => !_isSelfManagedPlatform
      ? 'System-managed engine'
      : _usesOfficialMpvSource
      ? _channel == EngineUpdateChannel.stable
            ? MpvGithubRelease.stableSourceLabel
            : MpvGithubRelease.sourceLabel
      : 'Custom signed feed';
  bool get supportedPlatform =>
      _platformProvider() != EngineUpdatePlatform.unsupported;
  bool get selfManaged => _isSelfManagedPlatform;
  String get status => _status;
  double get progress => _progress;
  String? get error => _error;

  /// Explains why a partial custom engine feed was ignored and the official
  /// source kept, or null when nothing needs explaining.
  String? get configurationWarning => _configurationWarning;

  /// Explains why a complete custom engine feed was rejected, or null.
  String? get configurationError => _configurationError;
  EngineRelease? get release => _release;
  String? get stableReleaseVersion => _stableReleaseVersion;
  String get currentVersion => _currentVersion;
  String? get pendingVersion => _pendingVersion;
  bool get pendingBundled => _selectionState?.pendingBundled ?? false;
  bool get pendingRollback => _selectionState?.pendingRollback ?? false;

  bool get canRollback {
    final state = _selectionState;
    if (!_isSelfManagedPlatform ||
        state == null ||
        state.pending != null ||
        state.pendingBundled ||
        state.pendingBootInProgress) {
      return false;
    }
    if (state.previous != null && _isCompatibleInstall(state.previous!)) {
      return true;
    }
    return !state.activeIsBundled &&
        state.active != null &&
        _isCompatibleInstall(state.active!);
  }

  String? get rollbackVersion {
    if (!canRollback) return null;
    final previous = _selectionState!.previous;
    if (previous != null && _isCompatibleInstall(previous)) {
      return previous.version;
    }
    return _bundledVersion;
  }

  bool get rollbackTargetIsBundled =>
      canRollback &&
      (_selectionState!.previous == null ||
          !_isCompatibleInstall(_selectionState!.previous!));

  bool get _isSelfManagedPlatform =>
      _platformProvider() == EngineUpdatePlatform.windows;

  static Uri? _manifestUriFromEnvironment() {
    final value = _configuredManifest.trim();
    return value.isEmpty ? null : Uri.tryParse(value);
  }

  /// Loads the active and staged versions. This does not choose an engine for
  /// MediaKit, so bootstrap can still call [selectEngineForBoot] first.
  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _initialized = true;
    if (!_isSelfManagedPlatform) {
      _setState(status: 'systemManaged', progress: 0, error: null);
      return;
    }
    _initializing = true;
    notifyListeners();
    try {
      _channel = await _preferencesRepository.loadChannel();
      if (_disposed) return;
      final selection = await _repository.loadSelection();
      if (_disposed) return;
      _selectionState = selection;
      final active = selection.active;
      _currentVersion = selection.activeIsBundled
          ? _bundledVersion
          : active != null && _isCompatibleInstall(active)
          ? active.version
          : _bundledVersion;
      _pendingVersion = selection.pendingBundled
          ? _bundledVersion
          : selection.pending?.version;
      _setState(
        status: _pendingVersion != null
            ? 'readyToRestart'
            : (_configured ? 'idle' : 'unconfigured'),
        progress: 0,
        error: _configured ? null : _configurationError,
      );
    } on Object catch (error) {
      if (!_disposed) _fail(error);
    } finally {
      _initializing = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Saves the user's explicit upstream channel choice.
  ///
  /// A channel cannot change while a check or download is running, or while a
  /// verified engine is waiting for restart. That keeps a late response from
  /// one source from being shown as the result of another source.
  Future<bool> setChannel(EngineUpdateChannel channel) async {
    if (_disposed ||
        !_isSelfManagedPlatform ||
        !_usesOfficialMpvSource ||
        _busy ||
        _initializing ||
        _pendingVersion != null) {
      return false;
    }
    if (channel == _channel) return true;

    _busy = true;
    _setState(status: 'savingChannel', progress: 0, error: null);
    try {
      await _preferencesRepository.saveChannel(channel);
      if (_disposed) return false;
      _channel = channel;
      _stableReleaseVersion = null;
      _setState(status: 'idle', progress: 0, error: null, clearRelease: true);
      return true;
    } on Object catch (error) {
      if (!_disposed) _fail(error);
      return false;
    } finally {
      _finishOperation();
    }
  }

  /// Checks the configured signed feed or the official mpv Windows build.
  Future<void> check() async {
    if (_disposed || _busy || _initializing) return;
    if (!_isSelfManagedPlatform) {
      _setState(status: 'systemManaged', progress: 0, error: null);
      return;
    }
    if (!_configured) {
      _setState(
        status: 'unconfigured',
        progress: 0,
        error: _configurationError,
      );
      return;
    }
    if (_pendingVersion != null) {
      _setState(status: 'readyToRestart', progress: 0, error: null);
      return;
    }

    _busy = true;
    _stableReleaseVersion = null;
    final abort = Completer<void>();
    _activeRequests.add(abort);
    _setState(status: 'checking', progress: 0, error: null, clearRelease: true);
    try {
      app_version.SemanticVersion.parse(appVersion);
      app_version.SemanticVersion.parse(_currentVersion);
      app_version.SemanticVersion.parse(supportedMediaKitVersion);
      final EngineRelease checkedRelease;
      if (_usesOfficialMpvSource) {
        final stableChannel = _channel == EngineUpdateChannel.stable;
        final responseBytes = await _getBytes(
          stableChannel
              ? MpvGithubRelease.latestStableApiUri
              : MpvGithubRelease.apiUri,
          abort: abort,
          maxBytes: _maxManifestBytes,
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent':
                'Mpvson/${appVersion.replaceAll(RegExp(r'[\r\n]'), '')}',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        );
        if (_disposed) return;
        final responseText = utf8.decode(responseBytes, allowMalformed: false);
        if (stableChannel) {
          final stableRelease = MpvGithubRelease.parseLatestStable(
            responseText,
            appVersion: appVersion,
            mediaKitVersion: supportedMediaKitVersion,
          );
          _stableReleaseVersion = stableRelease.version;
          final package = stableRelease.engineRelease;
          if (package == null) {
            _setState(
              status: 'stableUnavailable',
              progress: 0,
              error: null,
              clearRelease: true,
            );
            return;
          }
          checkedRelease = package;
        } else {
          checkedRelease = MpvGithubRelease.parse(
            responseText,
            appVersion: appVersion,
            mediaKitVersion: supportedMediaKitVersion,
          );
        }
      } else {
        final manifestUri = _manifestUri;
        if (manifestUri == null) {
          throw const _EngineUpdateException('Engine manifest URL is invalid.');
        }
        _requireHttps(manifestUri, 'Engine manifest URL');
        final manifestBytes = await _getBytes(
          manifestUri,
          abort: abort,
          maxBytes: _maxManifestBytes,
        );
        if (_disposed) return;
        final manifest = EngineUpdateManifest.parse(
          utf8.decode(manifestBytes, allowMalformed: false),
        );
        final verified = await _verifyManifest(manifest);
        if (!verified) {
          throw const _EngineUpdateException(
            'Engine manifest signature is invalid.',
          );
        }
        checkedRelease = manifest.release;
      }
      if (checkedRelease.sizeBytes > _maxDownloadBytes) {
        throw const _EngineUpdateException(
          'Engine package exceeds the configured download limit.',
        );
      }
      _checkCompatibility(checkedRelease);

      final current = app_version.SemanticVersion.parse(_currentVersion);
      final latest = app_version.SemanticVersion.parse(
        checkedRelease.engineVersion,
      );
      final sourceComparison = latest.compareTo(current);
      if (sourceComparison > 0) {
        _setState(
          status: 'available',
          progress: 0,
          error: null,
          release: checkedRelease,
        );
      } else if (sourceComparison < 0) {
        _setState(
          status: 'newerInstalled',
          progress: 0,
          error: null,
          release: checkedRelease,
        );
      } else {
        _setState(
          status: 'upToDate',
          progress: 0,
          error: null,
          release: checkedRelease,
        );
      }
    } on Object catch (error) {
      if (!_disposed) _fail(error);
    } finally {
      _activeRequests.remove(abort);
      if (!abort.isCompleted) abort.complete();
      _finishOperation();
    }
  }

  /// Downloads, hashes, and extracts the selected ZIP into a versioned folder.
  Future<void> downloadAndStage() async {
    if (_disposed || busy) return;
    if (!_isSelfManagedPlatform) {
      _setState(status: 'systemManaged', progress: 0, error: null);
      return;
    }
    final selectedRelease = _release;
    if (selectedRelease == null || _status != 'available') return;

    _busy = true;
    final abort = Completer<void>();
    _activeRequests.add(abort);
    Directory? temporaryDirectory;
    _setState(status: 'downloading', progress: 0, error: null);
    try {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'mpvson-engine-package-',
      );
      final packageFile = File(p.join(temporaryDirectory.path, 'engine.zip'));
      await _downloadToFile(
        selectedRelease.downloadUri,
        packageFile,
        abort: abort,
        maxBytes: _maxDownloadBytes,
        expectedBytes: selectedRelease.sizeBytes,
        expectedSha256: selectedRelease.sha256,
      );
      if (_disposed) return;

      _setState(status: 'staging', progress: 1, error: null);
      if (_disposed) return;
      await _repository.stagePackage(
        version: selectedRelease.engineVersion,
        packageFile: packageFile,
        mediaKitVersion: selectedRelease.mediaKitVersion,
        minimumAppVersion: selectedRelease.minimumAppVersion,
        maximumAppVersionExclusive: selectedRelease.maximumAppVersionExclusive,
        shouldCancel: () => _disposed || abort.isCompleted,
      );
      if (_disposed) return;
      _pendingVersion = selectedRelease.engineVersion;
      _selectionState = await _repository.loadSelection();
      if (_disposed) return;
      _setState(status: 'readyToRestart', progress: 1, error: null);
    } on Object catch (error) {
      if (!_disposed) _fail(error);
    } finally {
      if (temporaryDirectory != null && await temporaryDirectory.exists()) {
        try {
          await temporaryDirectory.delete(recursive: true);
        } on Object {
          // The temporary package is outside the versioned engine store.
        }
      }
      _activeRequests.remove(abort);
      if (!abort.isCompleted) abort.complete();
      _finishOperation();
    }
  }

  /// Removes the staged pointer. Installed active and previous versions stay.
  Future<void> discardPending() async {
    if (_disposed || busy) return;
    if (!_isSelfManagedPlatform) {
      _setState(status: 'systemManaged', progress: 0, error: null);
      return;
    }
    _busy = true;
    notifyListeners();
    try {
      await _repository.discardPending();
      if (_disposed) return;
      _selectionState = await _repository.loadSelection();
      if (_disposed) return;
      _pendingVersion = null;
      _setState(
        status: _configured ? 'idle' : 'unconfigured',
        progress: 0,
        error: null,
        clearRelease: true,
      );
    } on Object catch (error) {
      if (!_disposed) _fail(error);
    } finally {
      _finishOperation();
    }
  }

  /// Bootstrap helper. Call before MediaKit initialization.
  Future<EngineBootSelection> selectEngineForBoot({
    String? bundledEnginePath,
  }) async {
    if (!_isSelfManagedPlatform) {
      return EngineBootSelection(
        libraryPath: bundledEnginePath,
        version: _bundledVersion,
        isBundled: bundledEnginePath != null,
        isPending: false,
      );
    }
    final selection = await _repository.selectEngineForBoot(
      bundledEnginePath: bundledEnginePath,
      bundledEngineVersion: _bundledVersion,
      isCompatible: _isCompatibleInstall,
    );
    if (selection.isPending) {
      _pendingVersion =
          selection.version ?? (selection.isBundled ? _bundledVersion : null);
      _setState(status: 'readyToRestart', progress: 0, error: null);
    } else {
      _pendingVersion = null;
      _currentVersion = selection.version ?? _bundledVersion;
      _setState(
        status: _configured ? 'idle' : 'unconfigured',
        progress: 0,
        error: null,
      );
    }
    _selectionState = await _repository.loadSelection();
    return selection;
  }

  /// Confirms the boot attempt after the selected library initializes.
  Future<void> confirmPendingBoot() async {
    if (!_isSelfManagedPlatform) return;
    final before = await _repository.loadSelection();
    final pendingVersion =
        _pendingVersion ??
        (before.pendingBundled ? _bundledVersion : before.pending?.version);
    await _repository.confirmPendingBoot();
    _currentVersion = pendingVersion ?? _bundledVersion;
    _pendingVersion = null;
    _selectionState = await _repository.loadSelection();
    _setState(
      status: _configured ? 'idle' : 'unconfigured',
      progress: 0,
      error: null,
    );
  }

  /// Clears a failed boot attempt and returns the previous install or bundle.
  Future<EngineBootSelection> rejectPendingBoot({
    String? bundledEnginePath,
  }) async {
    if (!_isSelfManagedPlatform) {
      return EngineBootSelection(
        libraryPath: bundledEnginePath,
        version: _bundledVersion,
        isBundled: bundledEnginePath != null,
        isPending: false,
      );
    }
    final selection = await _repository.rejectPendingBoot(
      bundledEnginePath: bundledEnginePath,
      bundledEngineVersion: _bundledVersion,
      isCompatible: _isCompatibleInstall,
    );
    _pendingVersion = null;
    _currentVersion = selection.version ?? _bundledVersion;
    _selectionState = await _repository.loadSelection();
    _setState(
      status: _configured ? 'idle' : 'unconfigured',
      progress: 0,
      error: null,
    );
    return selection;
  }

  /// Handles a failed MediaKit initialization for either a pending or active
  /// custom engine and persists the resulting fallback choice.
  Future<EngineBootSelection> rejectBootSelection(
    EngineBootSelection failed, {
    String? bundledEnginePath,
  }) async {
    if (!_isSelfManagedPlatform) {
      return EngineBootSelection(
        libraryPath: bundledEnginePath,
        version: _bundledVersion,
        isBundled: bundledEnginePath != null,
        isPending: false,
      );
    }
    final selection = await _repository.rejectBootSelection(
      failed,
      bundledEnginePath: bundledEnginePath,
      bundledEngineVersion: _bundledVersion,
      isCompatible: _isCompatibleInstall,
    );
    _pendingVersion = null;
    _currentVersion = selection.version ?? _bundledVersion;
    _selectionState = await _repository.loadSelection();
    _setState(
      status: _configured ? 'idle' : 'unconfigured',
      progress: 0,
      error: null,
    );
    return selection;
  }

  /// Queues the previous compatible engine, or the bundled build if there is
  /// no previous custom install, for the next process launch.
  Future<void> scheduleRollback({String? bundledEnginePath}) async {
    if (_disposed || busy) return;
    if (!_isSelfManagedPlatform) {
      _setState(status: 'systemManaged', progress: 0, error: null);
      return;
    }
    _busy = true;
    notifyListeners();
    try {
      final selection = await _repository.scheduleRollback(
        bundledEnginePath: bundledEnginePath,
        bundledEngineVersion: _bundledVersion,
        isCompatible: _isCompatibleInstall,
      );
      if (_disposed) return;
      _selectionState = await _repository.loadSelection();
      if (_disposed) return;
      _pendingVersion =
          selection.version ?? (selection.isBundled ? _bundledVersion : null);
      _setState(status: 'readyToRestart', progress: 0, error: null);
    } on Object catch (error) {
      if (!_disposed) _fail(error);
    } finally {
      _finishOperation();
    }
  }

  void _finishOperation() {
    _busy = false;
    if (!_disposed) notifyListeners();
  }

  Future<bool> _verifyManifest(EngineUpdateManifest manifest) async {
    final verifier = _signatureVerifier;
    if (verifier != null) {
      // A custom verifier owns key handling. A malformed configured key must
      // not prevent it from running, but it is still passed through when valid
      // so verifiers that use the configured key keep working.
      Uint8List publicKey;
      try {
        publicKey = _decodePublicKey();
      } on _EngineUpdateException {
        publicKey = Uint8List(0);
      }
      return verifier(
        message: manifest.canonicalPayload,
        signature: manifest.signature,
        publicKey: publicKey,
      );
    }
    final publicKey = _decodePublicKey();
    if (publicKey.length != 32) {
      throw const _EngineUpdateException(
        'Engine public key must be a base64 encoded 32 byte Ed25519 key.',
      );
    }
    final algorithm = Ed25519();
    return algorithm.verify(
      manifest.canonicalPayload,
      signature: Signature(
        manifest.signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  Uint8List _decodePublicKey() {
    if (_publicKeyBase64.isEmpty) return Uint8List(0);
    try {
      return Uint8List.fromList(base64Decode(_publicKeyBase64));
    } on FormatException {
      throw const _EngineUpdateException('Engine public key must be base64.');
    }
  }

  void _checkCompatibility(EngineRelease release) {
    if (release.mediaKitVersion != supportedMediaKitVersion) {
      throw _EngineUpdateException(
        'Engine package requires MediaKit ${release.mediaKitVersion}, '
        'but this app supports $supportedMediaKitVersion.',
      );
    }
    final runningApp = app_version.SemanticVersion.parse(appVersion);
    final minimum = app_version.SemanticVersion.parse(
      release.minimumAppVersion,
    );
    if (runningApp.compareTo(minimum) < 0) {
      throw _EngineUpdateException(
        'Engine package requires app version ${release.minimumAppVersion} or newer.',
      );
    }
    final maximumText = release.maximumAppVersionExclusive;
    if (maximumText != null &&
        runningApp.compareTo(app_version.SemanticVersion.parse(maximumText)) >=
            0) {
      throw _EngineUpdateException(
        'Engine package supports app versions below $maximumText.',
      );
    }
  }

  bool _isCompatibleInstall(EngineInstallRecord record) {
    try {
      if (record.mediaKitVersion != supportedMediaKitVersion) return false;
      final runningApp = app_version.SemanticVersion.parse(appVersion);
      final minimum = app_version.SemanticVersion.parse(
        record.minimumAppVersion,
      );
      if (runningApp.compareTo(minimum) < 0) return false;
      final maximumText = record.maximumAppVersionExclusive;
      if (maximumText != null &&
          runningApp.compareTo(
                app_version.SemanticVersion.parse(maximumText),
              ) >=
              0) {
        return false;
      }
      return true;
    } on FormatException {
      return false;
    }
  }

  Future<http.StreamedResponse> _sendRequest(
    Uri initialUri, {
    required Completer<void> abort,
    required int maxBytes,
    int? expectedBytes,
    Map<String, String> headers = const <String, String>{},
  }) async {
    var uri = initialUri;
    _requireHttps(uri, 'Request URL');
    for (var redirects = 0; redirects <= _maxRedirects; redirects++) {
      if (_disposed || abort.isCompleted) throw const _EngineCancelled();
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      )..followRedirects = false;
      request.headers.addAll(headers);
      final send = _client.send(request);
      send.then<void>((lateResponse) {
        if (_disposed || abort.isCompleted) _cancelResponse(lateResponse);
      }, onError: (Object _) {});
      var timedOut = false;
      final http.StreamedResponse response;
      try {
        response =
            await Future.any<http.StreamedResponse>([
              send,
              abort.future.then<http.StreamedResponse>(
                (_) => throw const _EngineCancelled(),
              ),
            ]).timeout(
              _requestTimeout,
              onTimeout: () {
                timedOut = true;
                if (!abort.isCompleted) abort.complete();
                throw const _EngineUpdateException('Engine request timed out.');
              },
            );
      } on Object {
        if (timedOut) {
          throw const _EngineUpdateException('Engine request timed out.');
        }
        if (_disposed) throw const _EngineCancelled();
        rethrow;
      }

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        await _cancelResponse(response);
        if (location == null || location.trim().isEmpty) {
          throw const _EngineUpdateException(
            'Engine server returned an invalid redirect.',
          );
        }
        uri = uri.resolve(location);
        _requireHttps(uri, 'Redirect URL');
        if (redirects == _maxRedirects) {
          throw const _EngineUpdateException(
            'Engine server redirected too many times.',
          );
        }
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        final isRateLimited =
            _usesOfficialMpvSource &&
            (uri == MpvGithubRelease.apiUri ||
                uri == MpvGithubRelease.latestStableApiUri) &&
            (response.statusCode == HttpStatus.forbidden ||
                response.statusCode == 429) &&
            (response.headers['x-ratelimit-remaining'] == '0' ||
                response.statusCode == 429);
        await _cancelResponse(response);
        if (isRateLimited) {
          throw const _EngineUpdateException(
            'GitHub API rate limit reached. Try again later.',
          );
        }
        throw _EngineUpdateException(
          'Engine request failed with HTTP ${response.statusCode}.',
        );
      }
      final contentLength = responseBodyLength(response);
      if (contentLength != null && contentLength > maxBytes) {
        await _cancelResponse(response);
        throw const _EngineUpdateException(
          'Engine response exceeds the size limit.',
        );
      }
      if (expectedBytes != null &&
          contentLength != null &&
          contentLength != expectedBytes) {
        await _cancelResponse(response);
        throw const _EngineUpdateException(
          'Engine package size does not match its declared size.',
        );
      }
      return response;
    }
    throw const _EngineUpdateException(
      'Engine server redirected too many times.',
    );
  }

  Future<Uint8List> _getBytes(
    Uri initialUri, {
    required Completer<void> abort,
    required int maxBytes,
    int? expectedBytes,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final response = await _sendRequest(
      initialUri,
      abort: abort,
      maxBytes: maxBytes,
      expectedBytes: expectedBytes,
      headers: headers,
    );
    return _readBody(
      response.stream,
      abort: abort,
      maxBytes: maxBytes,
      expectedBytes: expectedBytes,
      contentLength: responseBodyLength(response),
    );
  }

  Future<void> _downloadToFile(
    Uri initialUri,
    File destinationFile, {
    required Completer<void> abort,
    required int maxBytes,
    required int expectedBytes,
    required String expectedSha256,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final response = await _sendRequest(
      initialUri,
      abort: abort,
      maxBytes: maxBytes,
      expectedBytes: expectedBytes,
      headers: headers,
    );
    await _streamResponseBodyToFile(
      response.stream,
      destinationFile,
      abort: abort,
      maxBytes: maxBytes,
      expectedBytes: expectedBytes,
      expectedSha256: expectedSha256,
    );
  }

  Future<void> _streamResponseBodyToFile(
    Stream<List<int>> stream,
    File destinationFile, {
    required Completer<void> abort,
    required int maxBytes,
    required int expectedBytes,
    required String expectedSha256,
  }) async {
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    var received = 0;
    var finished = false;
    Timer? idleTimer;
    StreamSubscription<List<int>>? subscription;
    IOSink? sink;
    final hashAccumulator = _DigestSink();
    final hashInput = crypto.sha256.startChunkedConversion(hashAccumulator);

    void fail(Object error) {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      subscription?.cancel();
      if (!completer.isCompleted) completer.completeError(error);
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(_requestTimeout, () {
        fail(const _EngineUpdateException('Engine response stream timed out.'));
      });
    }

    void abortRead() => fail(const _EngineCancelled());
    _abortBodyReads.add(abortRead);

    try {
      sink = destinationFile.openWrite();
      resetIdleTimer();

      final createdSubscription = stream.listen(
        (chunk) {
          if (_disposed || abort.isCompleted) {
            fail(const _EngineCancelled());
            return;
          }
          resetIdleTimer();
          if (stopwatch.elapsed > _maxDownloadDuration) {
            fail(
              const _EngineUpdateException(
                'Engine response exceeded the time limit.',
              ),
            );
            return;
          }
          received += chunk.length;
          if (received > maxBytes || received > expectedBytes) {
            fail(
              const _EngineUpdateException(
                'Engine response exceeds the size limit.',
              ),
            );
            return;
          }
          hashInput.add(chunk);
          sink?.add(chunk);
          if (expectedBytes > 0) {
            _setProgress(received / expectedBytes);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          fail(error);
        },
        onDone: () async {
          if (finished) return;
          finished = true;
          idleTimer?.cancel();
          if (stopwatch.elapsed > _maxDownloadDuration) {
            completer.completeError(
              const _EngineUpdateException(
                'Engine response exceeded the time limit.',
              ),
            );
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

            if (received != expectedBytes) {
              completer.completeError(
                const _EngineUpdateException(
                  'Engine package size does not match its declared size.',
                ),
              );
              return;
            }

            final actualHash = hashAccumulator.digest.toString().toLowerCase();
            if (actualHash != expectedSha256.toLowerCase()) {
              completer.completeError(
                const _EngineUpdateException(
                  'Engine package failed its SHA-256 integrity check.',
                ),
              );
              return;
            }

            completer.complete();
          } on Object catch (error) {
            completer.completeError(error);
          }
        },
        cancelOnError: true,
      );

      subscription = createdSubscription;
      _activeSubscriptions.add(createdSubscription);

      await completer.future;
    } finally {
      idleTimer?.cancel();
      _abortBodyReads.remove(abortRead);
      if (subscription != null) {
        _activeSubscriptions.remove(subscription);
        await subscription.cancel();
      }
      final cleanupSink = sink;
      if (cleanupSink != null) {
        try {
          await cleanupSink.close();
        } on Object {
          // Sink close error on cleanup is ignored.
        }
      }
    }
  }

  Future<Uint8List> _readBody(
    Stream<List<int>> stream, {
    required Completer<void> abort,
    required int maxBytes,
    int? expectedBytes,
    int? contentLength,
  }) async {
    final completer = Completer<Uint8List>();
    final buffer = BytesBuilder(copy: false);
    final stopwatch = Stopwatch()..start();
    var received = 0;
    var finished = false;
    Timer? idleTimer;
    StreamSubscription<List<int>>? subscription;

    void fail(Object error) {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      subscription?.cancel();
      if (!completer.isCompleted) completer.completeError(error);
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(_requestTimeout, () {
        fail(const _EngineUpdateException('Engine response stream timed out.'));
      });
    }

    void abortRead() => fail(const _EngineCancelled());
    _abortBodyReads.add(abortRead);
    resetIdleTimer();
    final createdSubscription = stream.listen(
      (chunk) {
        if (_disposed || abort.isCompleted) {
          fail(const _EngineCancelled());
          return;
        }
        resetIdleTimer();
        if (stopwatch.elapsed > _maxDownloadDuration) {
          fail(
            const _EngineUpdateException(
              'Engine response exceeded the time limit.',
            ),
          );
          return;
        }
        received += chunk.length;
        if (received > maxBytes ||
            (expectedBytes != null && received > expectedBytes)) {
          fail(
            const _EngineUpdateException(
              'Engine response exceeds the size limit.',
            ),
          );
          return;
        }
        buffer.add(chunk);
        if (expectedBytes != null && expectedBytes > 0) {
          _setProgress(received / expectedBytes);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        fail(error);
      },
      onDone: () {
        if (finished) return;
        finished = true;
        idleTimer?.cancel();
        if (stopwatch.elapsed > _maxDownloadDuration) {
          completer.completeError(
            const _EngineUpdateException(
              'Engine response exceeded the time limit.',
            ),
          );
          return;
        }
        completer.complete(buffer.takeBytes());
      },
      cancelOnError: true,
    );
    subscription = createdSubscription;
    _activeSubscriptions.add(createdSubscription);
    try {
      final bytes = await completer.future;
      if (contentLength != null && bytes.length != contentLength) {
        throw const _EngineUpdateException(
          'Engine response ended before its declared length.',
        );
      }
      if (expectedBytes != null && bytes.length != expectedBytes) {
        throw const _EngineUpdateException(
          'Engine package size does not match its declared size.',
        );
      }
      return bytes;
    } finally {
      idleTimer?.cancel();
      _abortBodyReads.remove(abortRead);
      _activeSubscriptions.remove(subscription);
      await createdSubscription.cancel();
    }
  }

  Future<void> _cancelResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen((_) {}, onError: (Object _) {});
    await subscription.cancel();
  }

  void _requireHttps(Uri uri, String label) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw _EngineUpdateException(
        '$label must be HTTPS without credentials or fragments.',
      );
    }
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
    EngineRelease? release,
    bool clearRelease = false,
  }) {
    if (_disposed) return;
    if (status != null) _status = status;
    if (progress != null) _progress = progress.clamp(0, 1).toDouble();
    _error = error;
    if (release != null || clearRelease) _release = release;
    notifyListeners();
  }

  void _fail(Object error) {
    final message = error is _EngineUpdateException
        ? error.message
        : error is FormatException
        ? error.message
        : error is _EngineCancelled
        ? null
        : error.toString();
    if (message == null) return;
    _setState(status: 'error', progress: 0, error: message);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final abort in _activeRequests.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    for (final abortRead in _abortBodyReads.toList()) {
      abortRead();
    }
    for (final subscription in _activeSubscriptions.toList()) {
      subscription.cancel();
    }
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

class _EngineUpdateException implements Exception {
  const _EngineUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _EngineCancelled implements Exception {
  const _EngineCancelled();
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? _digest;
  crypto.Digest get digest => _digest!;
  @override
  void add(crypto.Digest data) => _digest = data;
  @override
  void close() {}
}
