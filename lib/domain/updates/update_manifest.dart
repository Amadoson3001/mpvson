import 'dart:convert';
import 'dart:io';

import 'release_info.dart';
import 'semantic_version.dart';

/// The supported desktop targets for release artifacts.
enum UpdatePlatform {
  windows('windows'),
  linux('linux');

  const UpdatePlatform(this.manifestKey);

  final String manifestKey;

  static UpdatePlatform get current {
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isLinux) return UpdatePlatform.linux;
    throw UnsupportedError('Updates are supported only for Windows and Linux.');
  }
}

/// A decoded, schema-versioned release manifest.
final class UpdateManifest {
  const UpdateManifest({required this.release});

  static const int schemaVersion = 1;

  final ReleaseInfo release;

  /// Parses schema version 1 and selects the artifact for [platform].
  factory UpdateManifest.parse(
    String source, {
    required UpdatePlatform platform,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('Manifest is not valid JSON: ${error.message}');
    }

    final root = _stringMap(decoded, 'manifest');
    if (root['schemaVersion'] is! int ||
        root['schemaVersion'] != schemaVersion) {
      throw const FormatException('Unsupported manifest schema version.');
    }

    final version = _requiredString(root, 'version', maxLength: 200);
    SemanticVersion.parse(version);
    final notes = _optionalString(root, 'notes', maxLength: 80 * 1024) ?? '';
    final engineVersion = _requiredString(
      root,
      'engineVersion',
      maxLength: 200,
    );
    final releaseUriValue = _optionalString(
      root,
      'releaseUrl',
      maxLength: 4096,
    );
    final releaseUri = releaseUriValue == null
        ? null
        : _httpsUri(releaseUriValue, 'releaseUrl');

    final artifacts = _stringMap(root['artifacts'], 'artifacts');
    final targetArtifact = _stringMap(
      artifacts[platform.manifestKey],
      '${platform.manifestKey} artifact',
    );
    final downloadValue = _requiredString(
      targetArtifact,
      'url',
      maxLength: 4096,
    );
    final downloadUri = _httpsUri(downloadValue, 'artifact url');
    final hash = _requiredString(targetArtifact, 'sha256', maxLength: 64);
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      throw const FormatException('Artifact SHA-256 must be 64 hex digits.');
    }

    return UpdateManifest(
      release: ReleaseInfo(
        version: version,
        notes: notes,
        engineVersion: engineVersion,
        downloadUri: downloadUri,
        sha256: hash.toLowerCase(),
        releaseUri: releaseUri,
      ),
    );
  }

  static Uri _httpsUri(String value, String field) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw FormatException('$field must be an HTTPS URL without credentials.');
    }
    return uri;
  }

  static String _requiredString(
    Map<String, Object?> map,
    String key, {
    required int maxLength,
  }) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty || value.length > maxLength) {
      throw FormatException('Manifest field "$key" is missing or invalid.');
    }
    return value;
  }

  static String? _optionalString(
    Map<String, Object?> map,
    String key, {
    required int maxLength,
  }) {
    final value = map[key];
    if (value == null) return null;
    if (value is! String || value.length > maxLength) {
      throw FormatException('Manifest field "$key" is invalid.');
    }
    return value;
  }

  static Map<String, Object?> _stringMap(Object? value, String label) {
    if (value is! Map<Object?, Object?>) {
      throw FormatException('Manifest $label must be an object.');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('Manifest $label has a non-string key.');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }
}
