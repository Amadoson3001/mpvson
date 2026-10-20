import 'semantic_version.dart';

/// A validated engine install directory stored by the installation repository.
final class EngineInstallRecord {
  const EngineInstallRecord({
    required this.version,
    required this.path,
    required this.sha256,
    required this.mediaKitVersion,
    required this.minimumAppVersion,
    this.maximumAppVersionExclusive,
  });

  final String version;
  final String path;
  final String sha256;
  final String mediaKitVersion;
  final String minimumAppVersion;
  final String? maximumAppVersionExclusive;

  Map<String, Object?> toJson() => {
    'version': version,
    'path': path,
    'sha256': sha256,
    'mediaKitVersion': mediaKitVersion,
    'minimumAppVersion': minimumAppVersion,
    'maximumAppVersionExclusive': maximumAppVersionExclusive,
  };

  static EngineInstallRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final version = value['version'];
    final path = value['path'];
    final sha256 = value['sha256'];
    final mediaKitVersion = value['mediaKitVersion'];
    final minimumAppVersion = value['minimumAppVersion'];
    final maximumAppVersionExclusive = value['maximumAppVersionExclusive'];
    if (version is! String ||
        path is! String ||
        sha256 is! String ||
        mediaKitVersion is! String ||
        minimumAppVersion is! String ||
        (maximumAppVersionExclusive != null &&
            maximumAppVersionExclusive is! String) ||
        version.isEmpty ||
        path.isEmpty ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      return null;
    }
    try {
      SemanticVersion.parse(version);
      SemanticVersion.parse(mediaKitVersion);
      SemanticVersion.parse(minimumAppVersion);
      if (maximumAppVersionExclusive != null) {
        SemanticVersion.parse(maximumAppVersionExclusive as String);
      }
    } on FormatException {
      return null;
    }
    return EngineInstallRecord(
      version: version,
      path: path,
      sha256: sha256.toLowerCase(),
      mediaKitVersion: mediaKitVersion,
      minimumAppVersion: minimumAppVersion,
      maximumAppVersionExclusive: maximumAppVersionExclusive as String?,
    );
  }
}

/// The engine version pointers persisted in the app support directory.
final class EngineSelectionState {
  const EngineSelectionState({
    this.active,
    this.previous,
    this.pending,
    this.pendingBootInProgress = false,
    this.activeIsBundled = false,
    this.pendingBundled = false,
    this.pendingRollback = false,
    this.lastRejectedVersion,
    this.bootAttemptToken,
  });

  final EngineInstallRecord? active;
  final EngineInstallRecord? previous;
  final EngineInstallRecord? pending;
  final bool pendingBootInProgress;
  final bool activeIsBundled;
  final bool pendingBundled;
  final bool pendingRollback;

  /// The engine version a startup rejected, kept so a recovered backup cannot
  /// select it again.
  final String? lastRejectedVersion;

  /// Random token generated for an active boot attempt to ensure only the
  /// process holding the corresponding boot lease can commit the result.
  final String? bootAttemptToken;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'active': active?.toJson(),
    'previous': previous?.toJson(),
    'pending': pending?.toJson(),
    'pendingBootInProgress': pendingBootInProgress,
    'activeIsBundled': activeIsBundled,
    'pendingBundled': pendingBundled,
    'pendingRollback': pendingRollback,
    'lastRejectedVersion': lastRejectedVersion,
    'bootAttemptToken': bootAttemptToken,
  };

  static EngineSelectionState? fromJson(Object? value) {
    if (value is! Map || value['schemaVersion'] != 1) return null;
    final bootInProgress = value['pendingBootInProgress'];
    if (bootInProgress is! bool) return null;
    final activeIsBundled = value['activeIsBundled'] ?? false;
    final pendingBundled = value['pendingBundled'] ?? false;
    final pendingRollback = value['pendingRollback'] ?? false;
    final lastRejectedVersion = value['lastRejectedVersion'];
    final bootAttemptToken = value['bootAttemptToken'];
    if (activeIsBundled is! bool ||
        pendingBundled is! bool ||
        pendingRollback is! bool ||
        (lastRejectedVersion != null && lastRejectedVersion is! String) ||
        (bootAttemptToken != null && bootAttemptToken is! String)) {
      return null;
    }
    final active = _optionalRecord(value, 'active');
    final previous = _optionalRecord(value, 'previous');
    final pending = _optionalRecord(value, 'pending');
    if (active == _invalid || previous == _invalid || pending == _invalid) {
      return null;
    }
    return EngineSelectionState(
      active: active as EngineInstallRecord?,
      previous: previous as EngineInstallRecord?,
      pending: pending as EngineInstallRecord?,
      pendingBootInProgress: bootInProgress,
      activeIsBundled: activeIsBundled,
      pendingBundled: pendingBundled,
      pendingRollback: pendingRollback,
      lastRejectedVersion: lastRejectedVersion as String?,
      bootAttemptToken: bootAttemptToken as String?,
    );
  }

  static const Object _invalid = Object();

  static Object? _optionalRecord(Map<Object?, Object?> value, String key) {
    final raw = value[key];
    if (raw == null) return null;
    return EngineInstallRecord.fromJson(raw) ?? _invalid;
  }
}

/// The library selected for the next MediaKit initialization.
final class EngineBootSelection {
  const EngineBootSelection({
    required this.libraryPath,
    required this.version,
    required this.isBundled,
    required this.isPending,
  });

  final String? libraryPath;
  final String? version;
  final bool isBundled;
  final bool isPending;
}
