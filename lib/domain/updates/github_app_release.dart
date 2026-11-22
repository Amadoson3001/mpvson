import 'dart:convert';

import 'bundled_engine.dart';
import 'release_info.dart';
import 'semantic_version.dart';
import 'update_manifest.dart';
import 'update_url.dart';

/// Result of parsing the official GitHub release metadata for Mpvson.
final class GitHubAppReleaseOutcome {
  const GitHubAppReleaseOutcome.manifest({
    required this.version,
    required this.manifestUri,
    this.notes = '',
    this.fallbackOutcome,
  }) : release = null,
       checksumsUri = null,
       selectedAssetName = null;

  const GitHubAppReleaseOutcome.asset({
    required this.version,
    required this.release,
    this.checksumsUri,
    this.selectedAssetName,
  }) : manifestUri = null,
       notes = '',
       fallbackOutcome = null;

  final String version;
  final Uri? manifestUri;
  final String notes;
  final GitHubAppReleaseOutcome? fallbackOutcome;
  final ReleaseInfo? release;

  /// Populated when the release asset omitted a native `digest` field and
  /// needs `SHA256SUMS` fetched over HTTPS to verify its hash.
  final Uri? checksumsUri;
  final String? selectedAssetName;
}

/// Parses GitHub's latest release JSON for `Amadoson3001/mpvson`.
final class GitHubAppRelease {
  GitHubAppRelease._();

  static const String repositorySlug = 'Amadoson3001/mpvson';
  static const String sourceLabel = 'Official GitHub Releases';

  static final Uri latestApiUri = Uri.parse(
    'https://api.github.com/repos/$repositorySlug/releases/latest',
  );
  static final Uri latestManifestUri = Uri.parse(
    'https://github.com/$repositorySlug/releases/latest/download/update-manifest.json',
  );
  static const String _releasePagePrefix =
      'https://github.com/$repositorySlug/releases/tag/';
  static const String _downloadPathPrefix =
      '/$repositorySlug/releases/download/';

  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

  /// Parses GitHub's `/releases/latest` response and selects either an attached
  /// `update-manifest.json` or the verified platform package for [platform].
  static GitHubAppReleaseOutcome parseLatest(
    String source, {
    required UpdatePlatform platform,
    bool preferInstaller = true,
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
    if (release['draft'] != false || release['prerelease'] != false) {
      throw const FormatException(
        'GitHub did not return a published stable Mpvson release.',
      );
    }

    final rawTag = _requiredString(release, 'tag_name', 128).trim();
    final version = rawTag.startsWith('v') || rawTag.startsWith('V')
        ? rawTag.substring(1)
        : rawTag;
    SemanticVersion.parse(version);

    final htmlUrl = _httpsUri(
      _requiredString(release, 'html_url', 2048),
      'release page URL',
    );
    if (htmlUrl.toString() != '$_releasePagePrefix$rawTag') {
      throw const FormatException(
        'GitHub returned a release from an unexpected repository or tag.',
      );
    }

    final notes = _optionalString(release, 'body', 80 * 1024) ?? '';
    final rawAssets = release['assets'];
    if (rawAssets is! List || rawAssets.isEmpty || rawAssets.length > 128) {
      throw const FormatException('GitHub release contains no valid assets.');
    }

    final expectedDownloadPrefix = '$_downloadPathPrefix$rawTag/';
    Uri? manifestUri;
    Uri? checksumsUri;
    final parsedAssets = <_GitHubAsset>[];

    for (final rawAsset in rawAssets) {
      if (rawAsset is! Map) {
        throw const FormatException('GitHub release has an invalid asset.');
      }
      final asset = _stringMap(rawAsset, 'asset');
      final name = _optionalString(asset, 'name', 256);
      if (name == null || name.trim().isEmpty) continue;
      if (asset['state'] != 'uploaded') continue;

      final downloadUri = _httpsUri(
        _requiredString(asset, 'browser_download_url', 4096),
        'asset download URL',
      );
      if (downloadUri.host.toLowerCase() != 'github.com' ||
          (downloadUri.hasPort && downloadUri.port != 443) ||
          downloadUri.hasQuery ||
          downloadUri.path != '$expectedDownloadPrefix$name') {
        throw const FormatException(
          'GitHub returned a download URL outside the expected release.',
        );
      }

      if (name == 'update-manifest.json') {
        manifestUri = downloadUri;
        continue;
      }
      if (name == 'SHA256SUMS') {
        checksumsUri = downloadUri;
        continue;
      }

      String? sha256Hex;
      final digest = _optionalString(asset, 'digest', 80);
      if (digest != null && digest.startsWith('sha256:')) {
        final hex = digest.substring('sha256:'.length).trim();
        if (_sha256Pattern.hasMatch(hex)) {
          sha256Hex = hex.toLowerCase();
        }
      }

      parsedAssets.add(
        _GitHubAsset(name: name, downloadUri: downloadUri, sha256: sha256Hex),
      );
    }

    final preferredNames = switch (platform) {
      UpdatePlatform.windows =>
        preferInstaller
            ? const <String>['MpvsonSetup.exe', 'mpvson-windows-x64.zip']
            : const <String>['mpvson-windows-x64.zip', 'MpvsonSetup.exe'],
      UpdatePlatform.linux => const <String>['mpvson-linux-x64.tar.gz'],
    };

    _GitHubAsset? selected;
    for (final candidateName in preferredNames) {
      for (final asset in parsedAssets) {
        if (asset.name == candidateName) {
          selected = asset;
          break;
        }
      }
      if (selected != null) break;
    }

    GitHubAppReleaseOutcome? assetFallback;
    if (selected != null && (selected.sha256 != null || checksumsUri != null)) {
      assetFallback = GitHubAppReleaseOutcome.asset(
        version: version,
        selectedAssetName: selected.name,
        checksumsUri: selected.sha256 == null ? checksumsUri : null,
        release: ReleaseInfo(
          version: version,
          notes: notes,
          engineVersion: bundledEngineVersion,
          downloadUri: selected.downloadUri,
          sha256: selected.sha256 ?? ('0' * 64),
          releaseUri: htmlUrl,
        ),
      );
    }

    if (manifestUri != null &&
        (platform != UpdatePlatform.windows ||
            preferInstaller ||
            !parsedAssets.any((a) => a.name == 'mpvson-windows-x64.zip'))) {
      return GitHubAppReleaseOutcome.manifest(
        version: version,
        manifestUri: manifestUri,
        notes: notes,
        fallbackOutcome: assetFallback,
      );
    }

    if (selected == null) {
      throw FormatException(
        'No ${platform.manifestKey} release package was found for v$version.',
      );
    }

    if (selected.sha256 == null && checksumsUri == null) {
      throw FormatException(
        'Release package ${selected.name} has no published SHA-256 digest.',
      );
    }

    return assetFallback!;
  }

  /// Extracts the lowercase SHA-256 digest for [assetName] from `SHA256SUMS`.
  static String parseSha256Sums(String body, {required String assetName}) {
    for (final rawLine in LineSplitter.split(body)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = RegExp(
        r'^([0-9a-fA-F]{64})\s+\*?([^\r\n]+)$',
      ).firstMatch(line);
      if (match == null) continue;
      final hash = match.group(1)!.toLowerCase();
      final name = match.group(2)!.trim();
      if (name == assetName) return hash;
    }
    throw FormatException(
      'SHA256SUMS does not include an entry for "$assetName".',
    );
  }

  static Uri _httpsUri(String value, String label) {
    final uri = Uri.tryParse(value);
    if (uri == null || !isSafeHttpsUri(uri)) {
      throw FormatException('$label must use HTTPS without credentials.');
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
    if (value is! Map<Object?, Object?>) {
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

final class _GitHubAsset {
  const _GitHubAsset({
    required this.name,
    required this.downloadUri,
    this.sha256,
  });

  final String name;
  final Uri downloadUri;
  final String? sha256;
}
