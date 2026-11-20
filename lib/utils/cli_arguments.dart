import 'dart:io';

import 'package:path/path.dart' as p;

/// Result of parsing command-line arguments passed to Mpvson.
class ParsedCliArguments {
  const ParsedCliArguments({required this.enqueue, required this.sources});

  /// Whether `--enqueue` or `-e` was requested.
  final bool enqueue;

  /// Normalized local paths and preserved URIs to open.
  final List<String> sources;
}

/// Parses raw CLI [arguments] into an enqueue flag and normalized media sources.
///
/// Recognizes `--enqueue` / `-e`, honors `--` as end-of-options so filenames
/// starting with `-` can be opened safely, ignores flags such as
/// `--engine-recovery=...` before `--`, preserves URIs (`http://`, `https://`,
/// `file://`, etc.) verbatim, and resolves relative local paths to normalized
/// absolute paths.
ParsedCliArguments parseCliArguments(
  List<String> arguments, {
  bool? isWindows,
  String? workingDirectory,
}) {
  final windows = isWindows ?? Platform.isWindows;
  final pathContext = windows ? p.windows : p.posix;
  final cwd = workingDirectory ?? Directory.current.path;

  var enqueue = false;
  var endOfOptions = false;
  final sources = <String>[];

  for (final raw in arguments) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;

    if (!endOfOptions) {
      if (trimmed == '--') {
        endOfOptions = true;
        continue;
      }
      if (trimmed == '--enqueue' || trimmed == '-e') {
        enqueue = true;
        continue;
      }
      if (trimmed.startsWith('-') || (windows && trimmed == '/?')) {
        continue;
      }
    }

    if (trimmed.contains('://')) {
      sources.add(trimmed);
      continue;
    }

    final resolved = pathContext.isAbsolute(trimmed)
        ? pathContext.normalize(trimmed)
        : pathContext.normalize(pathContext.join(cwd, trimmed));
    sources.add(resolved);
  }

  return ParsedCliArguments(
    enqueue: enqueue,
    sources: List<String>.unmodifiable(sources),
  );
}
