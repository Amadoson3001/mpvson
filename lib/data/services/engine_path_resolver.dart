import 'dart:io';

import 'package:path/path.dart' as p;

/// Authoritative resolver and formatter for the MPV engine binary and its version.
class EnginePathResolver {
  EnginePathResolver._();

  /// The standard Windows library name for libmpv.
  static const String windowsLibraryFileName = 'libmpv-2.dll';

  /// Resolves the default bundled engine path for the current platform executable.
  ///
  /// On Windows, looks for [windowsLibraryFileName] in the directory containing
  /// the running executable.
  /// Returns `null` on platforms where libmpv is system-provided or unbundled.
  static String? resolveBundledEnginePath({String? executablePath}) {
    if (!Platform.isWindows) return null;
    final exe = executablePath ?? Platform.resolvedExecutable;
    return p.join(File(exe).parent.path, windowsLibraryFileName);
  }

  /// Checks whether an engine library binary exists at [path].
  static Future<bool> engineExists(String? path) async {
    if (path == null || path.isEmpty) return false;
    return File(path).exists();
  }

  /// Synchronously checks whether an engine library binary exists at [path].
  static bool engineExistsSync(String? path) {
    if (path == null || path.isEmpty) return false;
    return File(path).existsSync();
  }

  /// Parses and cleans a raw engine version string reported by libmpv (e.g. from `mpv-version`).
  /// Strips leading `mpv` or `libmpv` prefixes and excess whitespace.
  static String cleanVersion(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    trimmed = trimmed
        .replaceAll(RegExp(r'^(?:mpv|libmpv)\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'-dev[-+.0-9a-zA-Z]*'), '')
        .trim();
    return trimmed;
  }

  /// Formats an engine version for UI display (e.g., "libmpv 0.38.0").
  static String formatVersion(String raw) {
    final clean = cleanVersion(raw);
    if (clean.isEmpty) return 'libmpv';
    return 'libmpv $clean';
  }
}
