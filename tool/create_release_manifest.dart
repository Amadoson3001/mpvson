import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mpvson/domain/updates/semantic_version.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';
import 'package:path/path.dart' as p;

/// Resolves symbolic links and returns the canonical absolute normalized path for [file].
Future<String> canonicalResolvedPath(File file) async {
  if (await file.exists()) {
    try {
      final resolved = await file.resolveSymbolicLinks();
      return p.canonicalize(resolved);
    } catch (_) {}
  }
  if (await FileSystemEntity.isLink(file.path)) {
    try {
      final link = Link(file.path);
      final target = await link.target();
      final resolvedTarget = p.isAbsolute(target)
          ? target
          : p.join(file.parent.path, target);
      return await canonicalResolvedPath(File(resolvedTarget));
    } catch (_) {}
  }
  try {
    var current = file.parent;
    final segments = <String>[p.basename(file.path)];
    while (!await current.exists() && current.path != current.parent.path) {
      segments.insert(0, p.basename(current.path));
      current = current.parent;
    }
    if (await current.exists()) {
      final resolvedParent = await current.resolveSymbolicLinks();
      return p.canonicalize(p.joinAll([resolvedParent, ...segments]));
    }
  } catch (_) {}
  return p.canonicalize(file.absolute.path);
}

/// Verifies that [outputFile] does not collide with either [windowsFile] or [linuxFile],
/// resolving symbolic links and canonical paths.
Future<void> validateManifestOutput({
  required File outputFile,
  required File windowsFile,
  required File linuxFile,
}) async {
  final outputCanonical = await canonicalResolvedPath(outputFile);
  final windowsCanonical = await canonicalResolvedPath(windowsFile);
  if (outputCanonical == windowsCanonical) {
    throw FileSystemException(
      'Manifest output path collides with the Windows release artifact',
      outputFile.path,
    );
  }
  final linuxCanonical = await canonicalResolvedPath(linuxFile);
  if (outputCanonical == linuxCanonical) {
    throw FileSystemException(
      'Manifest output path collides with the Linux release artifact',
      outputFile.path,
    );
  }
}

/// Atomically writes [manifest] as formatted JSON to [outputFile] using a temporary file.
Future<void> writeManifestAtomically(
  File outputFile,
  Map<String, Object?> manifest,
) async {
  await outputFile.parent.create(recursive: true);
  final randomSuffix = Random.secure().nextInt(1 << 32).toRadixString(16);
  final tempFile = File(
    p.join(
      outputFile.parent.path,
      '.${p.basename(outputFile.path)}.$pid-$randomSuffix.tmp',
    ),
  );
  try {
    const encoder = JsonEncoder.withIndent('  ');
    await tempFile.writeAsString('${encoder.convert(manifest)}\n', flush: true);
    await tempFile.rename(outputFile.path);
  } catch (_) {
    try {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (_) {}
    rethrow;
  }
}

/// Generates the manifest published beside a tested Windows/Linux release.
Future<Map<String, Object?>> createReleaseManifest({
  required String version,
  required String engineVersion,
  required String notes,
  required Uri releaseUri,
  required File windowsFile,
  required Uri windowsUri,
  required File linuxFile,
  required Uri linuxUri,
  File? outputFile,
}) async {
  if (outputFile != null) {
    await validateManifestOutput(
      outputFile: outputFile,
      windowsFile: windowsFile,
      linuxFile: linuxFile,
    );
  }
  SemanticVersion.parse(version);
  final windowsHash = await _sha256(windowsFile);
  final linuxHash = await _sha256(linuxFile);

  final manifest = <String, Object?>{
    'schemaVersion': UpdateManifest.schemaVersion,
    'version': version,
    'notes': notes,
    'engineVersion': engineVersion,
    'releaseUrl': releaseUri.toString(),
    'artifacts': <String, Object?>{
      'windows': <String, Object?>{
        'url': windowsUri.toString(),
        'sha256': windowsHash,
      },
      'linux': <String, Object?>{
        'url': linuxUri.toString(),
        'sha256': linuxHash,
      },
    },
  };

  // Validate the generated output with the same strict parser used by the app.
  final encoded = jsonEncode(manifest);
  UpdateManifest.parse(encoded, platform: UpdatePlatform.windows);
  UpdateManifest.parse(encoded, platform: UpdatePlatform.linux);
  return manifest;
}

Future<String> _sha256(File file) async {
  if (!await file.exists()) {
    throw FileSystemException('Release artifact does not exist', file.path);
  }
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<void> main(List<String> arguments) async {
  try {
    final options = _parseArguments(arguments);
    final notes = options.containsKey('notes-file')
        ? await File(options['notes-file']!).readAsString()
        : options['notes'] ?? '';
    final windowsFile = File(_required(options, 'windows-file'));
    final linuxFile = File(_required(options, 'linux-file'));
    final outputPath = options['output'] ?? 'release-manifest.json';
    final output = File(outputPath);

    await validateManifestOutput(
      outputFile: output,
      windowsFile: windowsFile,
      linuxFile: linuxFile,
    );

    final manifest = await createReleaseManifest(
      version: _required(options, 'version'),
      engineVersion: _required(options, 'engine-version'),
      notes: notes,
      releaseUri: _httpsUri(_required(options, 'release-url'), 'release URL'),
      windowsFile: windowsFile,
      windowsUri: _httpsUri(_required(options, 'windows-url'), 'Windows URL'),
      linuxFile: linuxFile,
      linuxUri: _httpsUri(_required(options, 'linux-url'), 'Linux URL'),
      outputFile: output,
    );
    await writeManifestAtomically(output, manifest);

    final artifacts = manifest['artifacts']! as Map<String, Object?>;
    final windowsArtifact = artifacts['windows']! as Map<String, Object?>;
    final linuxArtifact = artifacts['linux']! as Map<String, Object?>;
    stdout.writeln('Wrote ${output.absolute.path}');
    stdout.writeln('Version ${manifest['version']}');
    stdout.writeln('Windows SHA-256: ${windowsArtifact['sha256']}');
    stdout.writeln('Linux SHA-256: ${linuxArtifact['sha256']}');
  } on Object catch (error) {
    stderr.writeln('Could not create release manifest: $error');
    stderr.writeln(_usage);
    exitCode = 64;
  }
}

const String _usage = '''Usage:
  dart run tool/create_release_manifest.dart --version 0.2.0 --engine-version 0.40.0
    --windows-file dist/mpvson-windows.zip --windows-url https://example.org/mpvson-windows.zip
    --linux-file dist/mpvson-linux.tar.gz --linux-url https://example.org/mpvson-linux.tar.gz
    --release-url https://example.org/releases/0.2.0
    [--notes "Release notes"] [--notes-file release-notes.txt] [--output dist/update-manifest.json]

Provide at most one of --notes and --notes-file. Artifact URLs must be HTTPS.''';

Map<String, String> _parseArguments(List<String> arguments) {
  const allowed = <String>{
    'version',
    'engine-version',
    'windows-file',
    'windows-url',
    'linux-file',
    'linux-url',
    'release-url',
    'notes',
    'notes-file',
    'output',
  };
  final result = <String, String>{};
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (!argument.startsWith('--')) {
      throw FormatException('Unexpected argument: $argument');
    }
    final key = argument.substring(2);
    if (!allowed.contains(key)) {
      throw FormatException('Unknown option: $argument');
    }
    if (result.containsKey(key)) {
      throw FormatException('Repeated option: $argument');
    }
    if (index + 1 == arguments.length ||
        arguments[index + 1].startsWith('--')) {
      throw FormatException('Option $argument requires a value.');
    }
    result[key] = arguments[++index];
  }
  if (result.containsKey('notes') && result.containsKey('notes-file')) {
    throw const FormatException('Use only one of --notes or --notes-file.');
  }
  return result;
}

String _required(Map<String, String> options, String key) {
  final value = options[key];
  if (value == null || value.trim().isEmpty) {
    throw FormatException('Required option --$key is missing.');
  }
  return value;
}

Uri _httpsUri(String value, String label) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw FormatException('$label must be an HTTPS URL without credentials.');
  }
  return uri;
}
