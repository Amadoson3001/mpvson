// Version management and synchronization tool for Mpvson.
//
// `pubspec.yaml` holds the canonical application version (`version: X.Y.Z+N`)
// and `packaging/windows/engine-provenance.json` holds the pinned bundled
// engine version (`engine.runtimeVersion`). This tool keeps runtime constants
// and packaging files synchronized with those two records.
//
// Usage:
//   dart run tool/version.dart show
//   dart run tool/version.dart check
//   dart run tool/version.dart sync
//   dart run tool/version.dart bump <major|minor|patch|build> [--prerelease <id>] [--reset-build] [--dry-run]
//   dart run tool/version.dart set <X.Y.Z[-pre][+N]> [--dry-run]
import 'dart:convert';
import 'dart:io';

import 'package:mpvson/domain/updates/semantic_version.dart';
import 'package:path/path.dart' as p;

const String _pubspecRelative = 'pubspec.yaml';
const String _appVersionRelative = 'lib/domain/updates/app_version.dart';
const String _bundledEngineRelative = 'lib/domain/updates/bundled_engine.dart';
const String _installerRelative = 'packaging/windows/installer.iss';
const String _windowsReadmeRelative = 'packaging/windows/README.txt';
const String _engineProvenanceRelative =
    'packaging/windows/engine-provenance.json';

final RegExp _pubspecVersionLine = RegExp(
  r'^version:\s*([^\s#]+)\s*(?:#.*)?$',
  multiLine: true,
);
final RegExp _installerVersionLine = RegExp(
  r'^#define\s+MyAppVersion\s+"([^"]+)"\s*$',
  multiLine: true,
);
final RegExp _readmeHeaderLine = RegExp(
  r'^Mpvson\s+([^\r\n]+)$',
  multiLine: true,
);
final RegExp _readmeEngineLine = RegExp(
  r'^(Bundled playback engine:\s+libmpv\s+mpv\s+v)([^\s,]+)(,.*)$',
  multiLine: true,
);
final RegExp _bundledEngineDefaultLine = RegExp(
  r"defaultValue:\s*'([^']+)'",
  multiLine: true,
);
final RegExp _appVersionPubspecLine = RegExp(
  r"static const String pubspecVersion = '([^']+)';",
);
final RegExp _appVersionSemanticLine = RegExp(
  r"static const String defaultSemantic = '([^']+)';",
);
final RegExp _appVersionBuildLine = RegExp(
  r'static const int buildNumber = (\d+);',
);

/// Parsed `pubspec.yaml` version (`X.Y.Z[-prerelease]+build`).
final class ParsedPubspecVersion {
  const ParsedPubspecVersion({
    required this.full,
    required this.semantic,
    required this.major,
    required this.minor,
    required this.patch,
    required this.prerelease,
    required this.buildNumber,
  });

  final String full;
  final String semantic;
  final int major;
  final int minor;
  final int patch;
  final String? prerelease;
  final int buildNumber;

  /// Parses a Flutter `pubspec.yaml` version such as `0.1.0+1` or `1.2.0-rc.1+4`.
  factory ParsedPubspecVersion.parse(String raw) {
    final trimmed = raw.trim();
    final plusIndex = trimmed.indexOf('+');
    final semanticPart = plusIndex == -1
        ? trimmed
        : trimmed.substring(0, plusIndex);
    final buildPart = plusIndex == -1 ? null : trimmed.substring(plusIndex + 1);
    final parsed = SemanticVersion.parse(semanticPart);
    final major = int.parse(parsed.major);
    final minor = int.parse(parsed.minor);
    final patch = int.parse(parsed.patch);
    final int build;
    if (buildPart == null) {
      build = 1;
    } else {
      final parsedBuild = int.tryParse(buildPart);
      if (parsedBuild == null || parsedBuild < 1) {
        throw FormatException(
          'Build number after "+" must be a positive integer.',
          raw,
        );
      }
      build = parsedBuild;
    }
    final prerelease = parsed.prerelease.isEmpty
        ? null
        : parsed.prerelease.join('.');
    return ParsedPubspecVersion(
      full: '$semanticPart+$build',
      semantic: semanticPart,
      major: major,
      minor: minor,
      patch: patch,
      prerelease: prerelease,
      buildNumber: build,
    );
  }
}

enum BumpKind { major, minor, patch, build }

/// Computes the next [ParsedPubspecVersion] for [kind].
ParsedPubspecVersion computeBumpedVersion(
  ParsedPubspecVersion current,
  BumpKind kind, {
  String? prerelease,
  bool resetBuild = false,
}) {
  var major = current.major;
  var minor = current.minor;
  var patch = current.patch;
  var nextPrerelease = prerelease;

  switch (kind) {
    case BumpKind.major:
      major += 1;
      minor = 0;
      patch = 0;
    case BumpKind.minor:
      minor += 1;
      patch = 0;
    case BumpKind.patch:
      patch += 1;
    case BumpKind.build:
      nextPrerelease ??= current.prerelease;
  }

  final nextBuild = resetBuild && kind != BumpKind.build
      ? 1
      : current.buildNumber + 1;
  final preSuffix = (nextPrerelease == null || nextPrerelease.trim().isEmpty)
      ? ''
      : '-${nextPrerelease.trim()}';
  final semantic = '$major.$minor.$patch$preSuffix';
  return ParsedPubspecVersion.parse('$semantic+$nextBuild');
}

/// Reads the canonical app version from `pubspec.yaml` under [root].
ParsedPubspecVersion readPubspecVersion(String root) {
  final file = File(p.join(root, _pubspecRelative));
  if (!file.existsSync()) {
    throw FileSystemException('Missing pubspec.yaml', file.path);
  }
  final match = _pubspecVersionLine.firstMatch(file.readAsStringSync());
  if (match == null) {
    throw FormatException('pubspec.yaml is missing a "version:" line.');
  }
  return ParsedPubspecVersion.parse(match.group(1)!);
}

/// Reads the pinned bundled engine SemVer from `engine-provenance.json`.
String readPinnedEngineVersion(String root) {
  final file = File(p.join(root, _engineProvenanceRelative));
  if (!file.existsSync()) {
    throw FileSystemException('Missing engine provenance file', file.path);
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw const FormatException(
      'engine-provenance.json must be a JSON object.',
    );
  }
  final engine = decoded['engine'];
  if (engine is! Map<String, Object?>) {
    throw const FormatException('engine-provenance.json is missing "engine".');
  }
  final version = engine['runtimeVersion'];
  if (version is! String || version.trim().isEmpty) {
    throw const FormatException(
      'engine-provenance.json is missing "engine.runtimeVersion".',
    );
  }
  SemanticVersion.parse(version);
  return version;
}

/// Verifies all version-bearing files under [root] match `pubspec.yaml` and
/// `engine-provenance.json`. Returns a list of mismatch descriptions.
List<String> checkRepositoryVersions(String root) {
  final problems = <String>[];
  final app = readPubspecVersion(root);
  final engineVersion = readPinnedEngineVersion(root);

  // 1. lib/domain/updates/app_version.dart
  final appVersionFile = File(p.join(root, _appVersionRelative));
  if (!appVersionFile.existsSync()) {
    problems.add('Missing $_appVersionRelative');
  } else {
    final text = appVersionFile.readAsStringSync();
    final pubMatch = _appVersionPubspecLine.firstMatch(text);
    final semMatch = _appVersionSemanticLine.firstMatch(text);
    final buildMatch = _appVersionBuildLine.firstMatch(text);
    if (pubMatch?.group(1) != app.full) {
      problems.add(
        '$_appVersionRelative pubspecVersion is "${pubMatch?.group(1)}" instead of "${app.full}".',
      );
    }
    if (semMatch?.group(1) != app.semantic) {
      problems.add(
        '$_appVersionRelative defaultSemantic is "${semMatch?.group(1)}" instead of "${app.semantic}".',
      );
    }
    if (int.tryParse(buildMatch?.group(1) ?? '') != app.buildNumber) {
      problems.add(
        '$_appVersionRelative buildNumber is "${buildMatch?.group(1)}" instead of "${app.buildNumber}".',
      );
    }
  }

  // 2. lib/domain/updates/bundled_engine.dart
  final bundledFile = File(p.join(root, _bundledEngineRelative));
  if (!bundledFile.existsSync()) {
    problems.add('Missing $_bundledEngineRelative');
  } else {
    final match = _bundledEngineDefaultLine.firstMatch(
      bundledFile.readAsStringSync(),
    );
    if (match?.group(1) != engineVersion) {
      problems.add(
        '$_bundledEngineRelative defaultValue is "${match?.group(1)}" instead of "$engineVersion" from $_engineProvenanceRelative.',
      );
    }
  }

  // 3. packaging/windows/installer.iss
  final installerFile = File(p.join(root, _installerRelative));
  if (!installerFile.existsSync()) {
    problems.add('Missing $_installerRelative');
  } else {
    final match = _installerVersionLine.firstMatch(
      installerFile.readAsStringSync(),
    );
    if (match?.group(1) != app.semantic) {
      problems.add(
        '$_installerRelative MyAppVersion is "${match?.group(1)}" instead of "${app.semantic}".',
      );
    }
  }

  // 4. packaging/windows/README.txt
  final readmeFile = File(p.join(root, _windowsReadmeRelative));
  if (!readmeFile.existsSync()) {
    problems.add('Missing $_windowsReadmeRelative');
  } else {
    final text = readmeFile.readAsStringSync();
    final headerMatch = _readmeHeaderLine.firstMatch(text);
    if (headerMatch?.group(1)?.trim() != app.semantic) {
      problems.add(
        '$_windowsReadmeRelative header version is "${headerMatch?.group(1)}" instead of "${app.semantic}".',
      );
    }
    final engineMatch = _readmeEngineLine.firstMatch(text);
    if (engineMatch?.group(2)?.trim() != engineVersion) {
      problems.add(
        '$_windowsReadmeRelative mentions libmpv mpv v${engineMatch?.group(2)} instead of v$engineVersion.',
      );
    }
  }

  return problems;
}

/// Synchronizes version-bearing files under [root] from `pubspec.yaml` and
/// `engine-provenance.json`. Returns the relative paths of updated files.
List<String> syncRepositoryVersions(String root, {bool dryRun = false}) {
  final app = readPubspecVersion(root);
  final engineVersion = readPinnedEngineVersion(root);
  final updated = <String>[];

  void updateFile(String relative, String Function(String content) transform) {
    final file = File(p.join(root, relative));
    if (!file.existsSync()) {
      throw FileSystemException(
        'Missing target file for version sync',
        file.path,
      );
    }
    final original = file.readAsStringSync();
    final next = transform(original);
    if (next != original) {
      updated.add(relative);
      if (!dryRun) {
        file.writeAsStringSync(next);
      }
    }
  }

  // 1. lib/domain/updates/app_version.dart
  updateFile(_appVersionRelative, (content) {
    var out = content.replaceFirstMapped(
      _appVersionPubspecLine,
      (_) => "static const String pubspecVersion = '${app.full}';",
    );
    out = out.replaceFirstMapped(
      _appVersionSemanticLine,
      (_) => "static const String defaultSemantic = '${app.semantic}';",
    );
    out = out.replaceFirstMapped(
      _appVersionBuildLine,
      (_) => 'static const int buildNumber = ${app.buildNumber};',
    );
    return out;
  });

  // 2. packaging/windows/installer.iss
  updateFile(_installerRelative, (content) {
    if (!_installerVersionLine.hasMatch(content)) {
      throw FormatException('$_installerRelative is missing MyAppVersion.');
    }
    return content.replaceFirstMapped(
      _installerVersionLine,
      (_) => '#define MyAppVersion "${app.semantic}"',
    );
  });

  // 3. packaging/windows/README.txt
  updateFile(_windowsReadmeRelative, (content) {
    var out = content;
    if (!_readmeHeaderLine.hasMatch(out)) {
      throw FormatException(
        '$_windowsReadmeRelative is missing Mpvson header.',
      );
    }
    out = out.replaceFirstMapped(
      _readmeHeaderLine,
      (_) => 'Mpvson ${app.semantic}',
    );
    if (_readmeEngineLine.hasMatch(out)) {
      out = out.replaceFirstMapped(
        _readmeEngineLine,
        (m) => '${m[1]}$engineVersion${m[3]}',
      );
    }
    return out;
  });

  return updated;
}

/// Writes [next] into `pubspec.yaml` and synchronizes dependent files.
List<String> writePubspecAndSync(
  String root,
  ParsedPubspecVersion next, {
  bool dryRun = false,
}) {
  final pubspecFile = File(p.join(root, _pubspecRelative));
  final content = pubspecFile.readAsStringSync();
  if (!_pubspecVersionLine.hasMatch(content)) {
    throw FormatException('$_pubspecRelative is missing a "version:" line.');
  }
  final updatedPubspec = content.replaceFirstMapped(
    _pubspecVersionLine,
    (_) => 'version: ${next.full}',
  );
  final changed = <String>[];
  if (updatedPubspec != content) {
    changed.add(_pubspecRelative);
    if (!dryRun) {
      pubspecFile.writeAsStringSync(updatedPubspec);
    }
  }
  if (!dryRun) {
    changed.addAll(syncRepositoryVersions(root, dryRun: false));
  }
  return changed;
}

Future<void> main(List<String> arguments) async {
  try {
    final parsed = _CliArgs.parse(arguments);
    final root = parsed.root ?? _defaultRoot();

    switch (parsed.command) {
      case 'show':
        final app = readPubspecVersion(root);
        final engine = readPinnedEngineVersion(root);
        stdout.writeln('App version   : ${app.full}');
        stdout.writeln('Semantic      : ${app.semantic}');
        stdout.writeln('Build number  : ${app.buildNumber}');
        stdout.writeln('Bundled engine: $engine');
      case 'check':
        final problems = checkRepositoryVersions(root);
        if (problems.isEmpty) {
          final app = readPubspecVersion(root);
          final engine = readPinnedEngineVersion(root);
          stdout.writeln(
            'Versions synchronized (app ${app.full}, bundled engine $engine).',
          );
          return;
        }
        stderr.writeln('Version mismatch detected:');
        for (final problem in problems) {
          stderr.writeln(' - $problem');
        }
        stderr.writeln('Run: dart run tool/version.dart sync');
        exitCode = 1;
      case 'sync':
        final changed = syncRepositoryVersions(root, dryRun: parsed.dryRun);
        if (changed.isEmpty) {
          stdout.writeln('All versioned files are already up to date.');
        } else {
          final prefix = parsed.dryRun ? 'Would update' : 'Updated';
          for (final file in changed) {
            stdout.writeln('$prefix: $file');
          }
        }
      case 'bump':
        if (parsed.target == null) {
          throw const FormatException(
            'bump requires <major|minor|patch|build>.',
          );
        }
        final kind = switch (parsed.target) {
          'major' => BumpKind.major,
          'minor' => BumpKind.minor,
          'patch' => BumpKind.patch,
          'build' => BumpKind.build,
          final other => throw FormatException('Unknown bump target: $other'),
        };
        final current = readPubspecVersion(root);
        final next = computeBumpedVersion(
          current,
          kind,
          prerelease: parsed.prerelease,
          resetBuild: parsed.resetBuild,
        );
        final changed = writePubspecAndSync(root, next, dryRun: parsed.dryRun);
        stdout.writeln('Version: ${current.full} -> ${next.full}');
        for (final file in changed) {
          stdout.writeln(
            '${parsed.dryRun ? 'Would update' : 'Updated'}: $file',
          );
        }
      case 'set':
        if (parsed.target == null) {
          throw const FormatException('set requires <X.Y.Z[-pre][+N]>.');
        }
        final current = readPubspecVersion(root);
        final raw = parsed.target!.trim();
        final next = raw.contains('+')
            ? ParsedPubspecVersion.parse(raw)
            : ParsedPubspecVersion.parse('$raw+${current.buildNumber + 1}');
        final changed = writePubspecAndSync(root, next, dryRun: parsed.dryRun);
        stdout.writeln('Version: ${current.full} -> ${next.full}');
        for (final file in changed) {
          stdout.writeln(
            '${parsed.dryRun ? 'Would update' : 'Updated'}: $file',
          );
        }
      case 'help':
      case '--help':
      case '-h':
        _printUsage();
      default:
        throw FormatException('Unknown command "${parsed.command}".');
    }
  } on Object catch (error) {
    stderr.writeln('Error: $error');
    _printUsage();
    exitCode = 64;
  }
}

String _defaultRoot() => p.dirname(p.dirname(Platform.script.toFilePath()));

void _printUsage() => stdout.writeln('''
Usage: dart run tool/version.dart <command> [options]

Commands:
  show                                Print current app and engine versions.
  check                               Verify all files match pubspec.yaml.
  sync                                Sync constants & packaging from pubspec.yaml.
  bump <major|minor|patch|build>      Bump version in pubspec.yaml and sync.
  set <X.Y.Z[-pre][+N]>               Set explicit version in pubspec.yaml and sync.

Options:
  --prerelease <id>   Optional SemVer prerelease tag (for bump).
  --reset-build       Reset build number to +1 on major/minor/patch bumps.
  --dry-run           Preview changes without modifying files.
  --root <dir>        Repository root (defaults to parent of tool/).
''');

final class _CliArgs {
  const _CliArgs({
    required this.command,
    this.target,
    this.prerelease,
    this.resetBuild = false,
    this.dryRun = false,
    this.root,
  });

  final String command;
  final String? target;
  final String? prerelease;
  final bool resetBuild;
  final bool dryRun;
  final String? root;

  static _CliArgs parse(List<String> args) {
    if (args.isEmpty) return const _CliArgs(command: 'show');
    final command = args.first;
    String? target;
    String? prerelease;
    var resetBuild = false;
    var dryRun = false;
    String? root;

    for (var i = 1; i < args.length; i++) {
      final arg = args[i];
      switch (arg) {
        case '--prerelease':
          if (i + 1 >= args.length) {
            throw const FormatException('--prerelease requires a value.');
          }
          prerelease = args[++i];
        case '--reset-build':
          resetBuild = true;
        case '--dry-run':
          dryRun = true;
        case '--root':
          if (i + 1 >= args.length) {
            throw const FormatException('--root requires a directory.');
          }
          root = args[++i];
        default:
          if (arg.startsWith('-')) {
            throw FormatException('Unknown flag: $arg');
          }
          if (target != null) {
            throw FormatException('Unexpected positional argument: $arg');
          }
          target = arg;
      }
    }
    return _CliArgs(
      command: command,
      target: target,
      prerelease: prerelease,
      resetBuild: resetBuild,
      dryRun: dryRun,
      root: root,
    );
  }
}
