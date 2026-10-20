import 'dart:convert';

import 'engine_release.dart';
import 'semantic_version.dart';

/// Parses the rolling libmpv build published by mpv's first-party GitHub CI.
///
/// The API response is not signed. Integrity comes from GitHub's published
/// SHA-256 digest over HTTPS; deployments that need an independently signed
/// feed can continue using the custom manifest path.
final class MpvGithubRelease {
  MpvGithubRelease._();

  static final Uri latestStableApiUri = Uri.parse(
    'https://api.github.com/repos/mpv-player/mpv/releases/latest',
  );

  static final Uri apiUri = Uri.parse(
    'https://api.github.com/repos/mpv-player/mpv/releases/tags/git-release',
  );

  static const String stableSourceLabel = 'Official mpv stable releases';
  static const String sourceLabel = 'Official mpv development builds';
  static const String _expectedHtmlUrl =
      'https://github.com/mpv-player/mpv/releases/tag/git-release';
  static const String _stableReleasePagePrefix =
      'https://github.com/mpv-player/mpv/releases/tag/';

  static final RegExp _assetPattern = RegExp(
    r'^libmpv-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'-dev-g([0-9a-fA-F]{7,40})-([1-9][0-9]*)'
    r'-x86_64-w64-mingw32-gpl\.zip$',
  );
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
  static final RegExp _stableAssetPattern = RegExp(
    r'^libmpv-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'-x86_64-w64-mingw32-gpl\.zip$',
  );
  static final RegExp _stableTagPattern = RegExp(
    r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );

  /// Maps an upstream package asset name to the SemVer form the updater stores
  /// and compares. The bundled engine records the same form in
  /// `packaging/windows/engine-provenance.json`, so the runtime identity and the
  /// build-time pin stay comparable.
  static String engineVersionFromAssetName(String name) {
    final match = _assetPattern.firstMatch(name);
    if (match == null) {
      throw const FormatException(
        'Not an official x86_64 Windows GPL libmpv package name.',
      );
    }
    final version =
        '${match[1]}.${match[2]}.${match[3]}-dev.${match[5]}+g${match[4]}';
    SemanticVersion.parse(version);
    return version;
  }

  /// Extracts the stable SemVer from a first-party Windows GPL libmpv ZIP.
  static String stableEngineVersionFromAssetName(String name) {
    final match = _stableAssetPattern.firstMatch(name);
    if (match == null) {
      throw const FormatException(
        'Not a stable x86_64 Windows GPL libmpv package name.',
      );
    }
    final version = '${match[1]}.${match[2]}.${match[3]}';
    SemanticVersion.parse(version);
    return version;
  }

  /// Parses GitHub's latest stable release and selects only a compatible
  /// Windows x64 GPL libmpv ZIP. A release without that package is valid and
  /// returns [MpvStableReleaseInfo.engineRelease] as null.
  static MpvStableReleaseInfo parseLatestStable(
    String source, {
    required String appVersion,
    required String mediaKitVersion,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException(
        'GitHub release response is invalid JSON: ${error.message}',
      );
    }

    final release = _stringMap(decoded, 'release');
    final tag = _requiredString(release, 'tag_name', 128);
    final tagMatch = _stableTagPattern.firstMatch(tag);
    if (tagMatch == null ||
        release['draft'] != false ||
        release['prerelease'] != false) {
      throw const FormatException(
        'GitHub did not return a published mpv stable release.',
      );
    }
    final version = '${tagMatch[1]}.${tagMatch[2]}.${tagMatch[3]}';
    SemanticVersion.parse(version);

    final releasePage = _httpsUri(
      _requiredString(release, 'html_url', 2048),
      'release page URL',
    );
    if (releasePage.toString() != '$_stableReleasePagePrefix$tag') {
      throw const FormatException(
        'GitHub returned a release from an unexpected repository or tag.',
      );
    }
    final notes = _optionalString(release, 'body', 80 * 1024) ?? '';
    final rawAssets = release['assets'];
    if (rawAssets is! List || rawAssets.length > 256) {
      throw const FormatException('GitHub release has invalid assets.');
    }

    final candidates = <_StableAssetCandidate>[];
    for (final rawAsset in rawAssets) {
      if (rawAsset is! Map) {
        throw const FormatException(
          'GitHub release contains an invalid asset.',
        );
      }
      final asset = _stringMap(rawAsset, 'asset');
      final name = _optionalString(asset, 'name', 512);
      if (name == null || !_stableAssetPattern.hasMatch(name)) continue;
      if (stableEngineVersionFromAssetName(name) != version) continue;

      if (asset['state'] != 'uploaded') {
        throw const FormatException(
          'The stable mpv Windows package is not fully uploaded yet.',
        );
      }
      final size = asset['size'];
      if (size is! int || size <= 0) {
        throw const FormatException(
          'GitHub package size is missing or invalid.',
        );
      }
      final digestText = _requiredString(asset, 'digest', 72);
      if (!digestText.startsWith('sha256:')) {
        throw const FormatException(
          'GitHub package does not provide a SHA-256 digest.',
        );
      }
      final digest = digestText.substring('sha256:'.length);
      if (!_sha256Pattern.hasMatch(digest)) {
        throw const FormatException(
          'GitHub package SHA-256 digest is invalid.',
        );
      }

      final downloadUri = _httpsUri(
        _requiredString(asset, 'browser_download_url', 4096),
        'package download URL',
      );
      final expectedPath = '/mpv-player/mpv/releases/download/$tag/$name';
      if (downloadUri.host.toLowerCase() != 'github.com' ||
          (downloadUri.hasPort && downloadUri.port != 443) ||
          downloadUri.path != expectedPath ||
          downloadUri.hasQuery) {
        throw const FormatException(
          'GitHub returned a package URL outside the expected mpv release.',
        );
      }
      candidates.add(
        _StableAssetCandidate(
          downloadUri: downloadUri,
          sha256: digest.toLowerCase(),
          sizeBytes: size,
        ),
      );
    }

    if (candidates.length > 1) {
      throw const FormatException(
        'GitHub release contains ambiguous Windows libmpv build assets.',
      );
    }

    SemanticVersion.parse(appVersion);
    SemanticVersion.parse(mediaKitVersion);
    final candidate = candidates.isEmpty ? null : candidates.single;
    return MpvStableReleaseInfo(
      version: version,
      engineRelease: candidate == null
          ? null
          : EngineRelease(
              engineVersion: version,
              notes: notes,
              mediaKitVersion: mediaKitVersion,
              minimumAppVersion: appVersion,
              maximumAppVersionExclusive: null,
              downloadUri: candidate.downloadUri,
              sha256: candidate.sha256,
              sizeBytes: candidate.sizeBytes,
            ),
    );
  }

  /// Converts GitHub's release response into the updater's common release
  /// model. Only the x86_64 Windows GPL ZIP is eligible; executable installers,
  /// LGPL packages, ARM builds, and other architectures are never selected.
  static EngineRelease parse(
    String source, {
    required String appVersion,
    required String mediaKitVersion,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException(
        'GitHub release response is invalid JSON: ${error.message}',
      );
    }

    final release = _stringMap(decoded, 'release');
    if (release['tag_name'] != 'git-release' || release['draft'] != false) {
      throw const FormatException(
        'GitHub did not return a published mpv git-release build.',
      );
    }
    final releasePage = _httpsUri(
      _requiredString(release, 'html_url', 2048),
      'release page URL',
    );
    if (releasePage.toString() != _expectedHtmlUrl) {
      throw const FormatException(
        'GitHub returned a release from an unexpected repository or tag.',
      );
    }
    final notes = _optionalString(release, 'body', 80 * 1024) ?? '';
    final rawAssets = release['assets'];
    if (rawAssets is! List || rawAssets.isEmpty || rawAssets.length > 256) {
      throw const FormatException(
        'GitHub release has no valid uploaded assets.',
      );
    }

    final candidates = <_AssetCandidate>[];
    for (final rawAsset in rawAssets) {
      if (rawAsset is! Map) {
        throw const FormatException(
          'GitHub release contains an invalid asset.',
        );
      }
      final asset = _stringMap(rawAsset, 'asset');
      final name = _optionalString(asset, 'name', 512);
      if (name == null || !_assetPattern.hasMatch(name)) continue;

      final version = engineVersionFromAssetName(name);
      if (asset['state'] != 'uploaded') {
        throw const FormatException(
          'The official mpv Windows package is not fully uploaded yet.',
        );
      }
      final size = asset['size'];
      if (size is! int || size <= 0) {
        throw const FormatException(
          'GitHub package size is missing or invalid.',
        );
      }
      final digestText = _requiredString(asset, 'digest', 72);
      if (!digestText.startsWith('sha256:')) {
        throw const FormatException(
          'GitHub package does not provide a SHA-256 digest.',
        );
      }
      final digest = digestText.substring('sha256:'.length);
      if (!_sha256Pattern.hasMatch(digest)) {
        throw const FormatException(
          'GitHub package SHA-256 digest is invalid.',
        );
      }

      final downloadUri = _httpsUri(
        _requiredString(asset, 'browser_download_url', 4096),
        'package download URL',
      );
      final expectedPath =
          '/mpv-player/mpv/releases/download/git-release/$name';
      if (downloadUri.host.toLowerCase() != 'github.com' ||
          (downloadUri.hasPort && downloadUri.port != 443) ||
          downloadUri.path != expectedPath ||
          downloadUri.hasQuery) {
        throw const FormatException(
          'GitHub returned a package URL outside the expected mpv release.',
        );
      }
      candidates.add(
        _AssetCandidate(
          version: version,
          downloadUri: downloadUri,
          sha256: digest.toLowerCase(),
          sizeBytes: size,
        ),
      );
    }

    if (candidates.isEmpty) {
      throw const FormatException(
        'No uploaded x86_64 Windows GPL libmpv ZIP was found in the mpv build.',
      );
    }

    candidates.sort((left, right) {
      return SemanticVersion.parse(
        left.version,
      ).compareTo(SemanticVersion.parse(right.version));
    });
    final candidate = candidates.last;
    if (candidates.length > 1 &&
        SemanticVersion.parse(
              candidates[candidates.length - 2].version,
            ).compareTo(SemanticVersion.parse(candidate.version)) ==
            0) {
      throw const FormatException(
        'GitHub release contains ambiguous Windows libmpv build assets.',
      );
    }

    // This local feed is bound to the app and MediaKit versions that queried
    // it. MediaKit's native bridge performs the final runtime ABI check.
    SemanticVersion.parse(appVersion);
    SemanticVersion.parse(mediaKitVersion);
    return EngineRelease(
      engineVersion: candidate.version,
      notes: notes,
      mediaKitVersion: mediaKitVersion,
      minimumAppVersion: appVersion,
      maximumAppVersionExclusive: null,
      downloadUri: candidate.downloadUri,
      sha256: candidate.sha256,
      sizeBytes: candidate.sizeBytes,
    );
  }

  static Uri _httpsUri(String value, String label) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw FormatException(
        '$label must be HTTPS without credentials or fragments.',
      );
    }
    return uri;
  }

  static String _requiredString(
    Map<String, Object?> map,
    String key,
    int maxLength,
  ) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty || value.length > maxLength) {
      throw FormatException(
        'GitHub release field "$key" is missing or invalid.',
      );
    }
    return value;
  }

  static String? _optionalString(
    Map<String, Object?> map,
    String key,
    int maxLength,
  ) {
    final value = map[key];
    if (value == null) return null;
    if (value is! String || value.length > maxLength) {
      throw FormatException('GitHub release field "$key" is invalid.');
    }
    return value;
  }

  static Map<String, Object?> _stringMap(Object? value, String label) {
    if (value is! Map) {
      throw FormatException('GitHub release $label must be an object.');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('GitHub release $label has a non-string key.');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }
}

final class MpvStableReleaseInfo {
  const MpvStableReleaseInfo({required this.version, this.engineRelease});

  final String version;
  final EngineRelease? engineRelease;
}

final class _StableAssetCandidate {
  const _StableAssetCandidate({
    required this.downloadUri,
    required this.sha256,
    required this.sizeBytes,
  });

  final Uri downloadUri;
  final String sha256;
  final int sizeBytes;
}

final class _AssetCandidate {
  const _AssetCandidate({
    required this.version,
    required this.downloadUri,
    required this.sha256,
    required this.sizeBytes,
  });

  final String version;
  final Uri downloadUri;
  final String sha256;
  final int sizeBytes;
}
