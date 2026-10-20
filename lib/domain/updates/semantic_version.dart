/// A semantic version with SemVer 2.0.0 precedence rules.
///
/// Build metadata is retained in [value] but ignored when versions are
/// compared, as required by the specification.
final class SemanticVersion implements Comparable<SemanticVersion> {
  SemanticVersion._({
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

  /// The original, validated input, including any build metadata.
  final String value;

  /// Numeric core components are kept as strings to avoid integer overflow.
  final String major;
  final String minor;
  final String patch;
  final List<String> prerelease;

  static SemanticVersion parse(String value) {
    if (value.length > 200) {
      throw FormatException('Version is too long.', value);
    }

    final match = _pattern.firstMatch(value);
    if (match == null) {
      throw FormatException('Version must follow SemVer 2.0.0.', value);
    }

    final prereleaseText = match[4];
    final identifiers = prereleaseText?.split('.') ?? const <String>[];
    for (final identifier in identifiers) {
      if (_isNumeric(identifier) &&
          identifier.length > 1 &&
          identifier.startsWith('0')) {
        throw FormatException(
          'Numeric prerelease identifiers cannot have leading zeroes.',
          value,
        );
      }
    }

    return SemanticVersion._(
      value: value,
      major: match[1]!,
      minor: match[2]!,
      patch: match[3]!,
      prerelease: List<String>.unmodifiable(identifiers),
    );
  }

  @override
  int compareTo(SemanticVersion other) {
    var order = _compareNumericStrings(major, other.major);
    if (order != 0) return order;

    order = _compareNumericStrings(minor, other.minor);
    if (order != 0) return order;

    order = _compareNumericStrings(patch, other.patch);
    if (order != 0) return order;

    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;

    final commonLength = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var index = 0; index < commonLength; index++) {
      final left = prerelease[index];
      final right = other.prerelease[index];
      final leftNumeric = _isNumeric(left);
      final rightNumeric = _isNumeric(right);

      if (leftNumeric && rightNumeric) {
        order = _compareNumericStrings(left, right);
      } else if (leftNumeric != rightNumeric) {
        // Numeric identifiers have lower precedence than non-numeric ones.
        order = leftNumeric ? -1 : 1;
      } else {
        order = left.compareTo(right);
      }
      if (order != 0) return order;
    }

    return prerelease.length.compareTo(other.prerelease.length);
  }

  static bool _isNumeric(String value) => RegExp(r'^[0-9]+$').hasMatch(value);

  static int _compareNumericStrings(String left, String right) {
    if (left.length != right.length) {
      return left.length.compareTo(right.length);
    }
    return left.compareTo(right);
  }

  @override
  String toString() => value;
}
