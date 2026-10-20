import 'dart:convert';
import 'dart:typed_data';

/// A Windows libmpv build described by an engine update source.
final class EngineRelease {
  const EngineRelease({
    required this.engineVersion,
    required this.notes,
    required this.mediaKitVersion,
    required this.minimumAppVersion,
    required this.maximumAppVersionExclusive,
    required this.downloadUri,
    required this.sha256,
    required this.sizeBytes,
  });

  final String engineVersion;
  final String notes;
  final String mediaKitVersion;
  final String minimumAppVersion;
  final String? maximumAppVersionExclusive;
  final Uri downloadUri;
  final String sha256;
  final int sizeBytes;
}

/// Parsed signed feed. The original payload is retained for signature checks.
final class EngineUpdateManifest {
  const EngineUpdateManifest({
    required this.release,
    required this.signature,
    required this.canonicalPayload,
  });

  static const int schemaVersion = 1;

  final EngineRelease release;
  final Uint8List signature;
  final Uint8List canonicalPayload;

  factory EngineUpdateManifest.parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException(
        'Engine manifest is not valid JSON: ${error.message}',
      );
    }

    final root = _stringMap(decoded, 'manifest');
    if (root['schemaVersion'] != schemaVersion) {
      throw const FormatException(
        'Unsupported engine manifest schema version.',
      );
    }
    final payload = _stringMap(root['payload'], 'payload');
    final engineVersion = _requiredString(payload, 'engineVersion', 200);
    _EngineSemanticVersion.parse(engineVersion);
    final notes = _optionalString(payload, 'notes', 80 * 1024) ?? '';
    final mediaKitVersion = _requiredString(payload, 'mediaKitVersion', 200);
    _EngineSemanticVersion.parse(mediaKitVersion);
    final minimumAppVersion = _requiredString(
      payload,
      'minimumAppVersion',
      200,
    );
    _EngineSemanticVersion.parse(minimumAppVersion);
    final maximumAppVersionExclusive = _optionalString(
      payload,
      'maximumAppVersionExclusive',
      200,
    );
    if (maximumAppVersionExclusive != null) {
      _EngineSemanticVersion.parse(maximumAppVersionExclusive);
    }

    final artifacts = _stringMap(payload['artifacts'], 'artifacts');
    final windows = _stringMap(artifacts['windows'], 'Windows artifact');
    final urlText = _requiredString(windows, 'url', 4096);
    final downloadUri = _httpsUri(urlText, 'Windows artifact URL');
    final hash = _requiredString(windows, 'sha256', 64);
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      throw const FormatException(
        'Engine artifact SHA-256 must be 64 hex digits.',
      );
    }
    final sizeBytes = windows['size'];
    if (sizeBytes is! int || sizeBytes <= 0) {
      throw const FormatException(
        'Engine artifact size must be a positive integer.',
      );
    }

    final signatureText = _requiredString(root, 'signature', 256);
    final Uint8List signature;
    try {
      signature = Uint8List.fromList(base64Decode(signatureText));
    } on FormatException {
      throw const FormatException('Engine manifest signature must be base64.');
    }
    if (signature.length != 64) {
      throw const FormatException(
        'Engine manifest signature must be 64 bytes.',
      );
    }

    final canonical = _canonicalJsonBytes(payload);
    return EngineUpdateManifest(
      release: EngineRelease(
        engineVersion: engineVersion,
        notes: notes,
        mediaKitVersion: mediaKitVersion,
        minimumAppVersion: minimumAppVersion,
        maximumAppVersionExclusive: maximumAppVersionExclusive,
        downloadUri: downloadUri,
        sha256: hash.toLowerCase(),
        sizeBytes: sizeBytes,
      ),
      signature: signature,
      canonicalPayload: canonical,
    );
  }

  static Uint8List _canonicalJsonBytes(Object? value) {
    return Uint8List.fromList(utf8.encode(jsonEncode(_sortJson(value))));
  }

  static Object? _sortJson(Object? value) {
    if (value is Map) {
      final keys = <String>[];
      for (final key in value.keys) {
        if (key is! String) {
          throw const FormatException('Manifest objects must use string keys.');
        }
        keys.add(key);
      }
      keys.sort();
      return <String, Object?>{
        for (final key in keys) key: _sortJson(value[key]),
      };
    }
    if (value is List) {
      return value.map(_sortJson).toList(growable: false);
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw const FormatException(
      'Manifest contains a value that cannot be signed.',
    );
  }

  static Uri _httpsUri(String value, String field) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw FormatException(
        '$field must be HTTPS without credentials or fragments.',
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
        'Engine manifest field "$key" is missing or invalid.',
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
      throw FormatException('Engine manifest field "$key" is invalid.');
    }
    return value;
  }

  static Map<String, Object?> _stringMap(Object? value, String label) {
    if (value is! Map) {
      throw FormatException('Engine manifest $label must be an object.');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('Engine manifest $label has a non-string key.');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }
}

/// Compares SemVer values without narrowing arbitrarily large numeric parts.
final class _EngineSemanticVersion
    implements Comparable<_EngineSemanticVersion> {
  _EngineSemanticVersion._({
    required this.value,
    required this.major,
    required this.minor,
    required this.patch,
    required this.prerelease,
  });

  static final RegExp _pattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

  final String value;
  final String major;
  final String minor;
  final String patch;
  final List<String> prerelease;

  static _EngineSemanticVersion parse(String value) {
    if (value.length > 200) {
      throw FormatException('Version is too long.', value);
    }
    final match = _pattern.firstMatch(value);
    if (match == null) {
      throw FormatException('Version must follow SemVer 2.0.0.', value);
    }
    final prerelease = match[4]?.split('.') ?? const <String>[];
    for (final id in prerelease) {
      if (_isNumeric(id) && id.length > 1 && id.startsWith('0')) {
        throw FormatException(
          'Numeric prerelease identifiers cannot have leading zeroes.',
          value,
        );
      }
    }
    return _EngineSemanticVersion._(
      value: value,
      major: match[1]!,
      minor: match[2]!,
      patch: match[3]!,
      prerelease: List<String>.unmodifiable(prerelease),
    );
  }

  @override
  int compareTo(_EngineSemanticVersion other) {
    var result = _compareNumeric(major, other.major);
    if (result != 0) return result;
    result = _compareNumeric(minor, other.minor);
    if (result != 0) return result;
    result = _compareNumeric(patch, other.patch);
    if (result != 0) return result;
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      if (prerelease.isEmpty == other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    final commonLength = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var index = 0; index < commonLength; index++) {
      final left = prerelease[index];
      final right = other.prerelease[index];
      final leftNumeric = _isNumeric(left);
      final rightNumeric = _isNumeric(right);
      if (leftNumeric && rightNumeric) {
        result = _compareNumeric(left, right);
      } else if (leftNumeric != rightNumeric) {
        result = leftNumeric ? -1 : 1;
      } else {
        result = left.compareTo(right);
      }
      if (result != 0) return result;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  static bool _isNumeric(String value) => RegExp(r'^[0-9]+$').hasMatch(value);

  static int _compareNumeric(String left, String right) {
    if (left.length != right.length) return left.length.compareTo(right.length);
    return left.compareTo(right);
  }

  @override
  String toString() => value;
}
