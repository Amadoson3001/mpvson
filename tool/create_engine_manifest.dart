import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:mpvson/domain/updates/engine_release.dart' as engine_release;
import 'package:mpvson/domain/updates/semantic_version.dart';
import 'package:path/path.dart' as p;

const int engineManifestSchemaVersion = 1;
const int maxEngineManifestBytes = 256 * 1024;
const int maxEngineManifestNotesLength = 80 * 1024;
const int maxEngineManifestUrlLength = 4096;
const int maxEngineZipBytes = 512 * 1024 * 1024;
const int maxEngineZipEntries = 4096;
const int maxEngineZipUncompressedBytes = 2 * 1024 * 1024 * 1024;

/// Resolves links and returns a normalized absolute path for collision checks.
Future<String> canonicalResolvedPath(File file) async {
  if (await file.exists()) {
    try {
      return p.canonicalize(await file.resolveSymbolicLinks());
    } on FileSystemException {
      // Fall through for dangling links and paths that cannot be resolved.
    }
  }

  if (await FileSystemEntity.isLink(file.path)) {
    try {
      final target = await Link(file.path).target();
      final resolvedTarget = p.isAbsolute(target)
          ? target
          : p.join(file.parent.path, target);
      return canonicalResolvedPath(File(resolvedTarget));
    } on FileSystemException {
      // Fall through and compare the normalized link path itself.
    }
  }

  var parent = file.parent;
  final segments = <String>[p.basename(file.path)];
  while (!await parent.exists() && parent.path != parent.parent.path) {
    segments.insert(0, p.basename(parent.path));
    parent = parent.parent;
  }
  if (await parent.exists()) {
    try {
      final resolvedParent = await parent.resolveSymbolicLinks();
      return p.canonicalize(p.joinAll([resolvedParent, ...segments]));
    } on FileSystemException {
      // Fall through to an absolute normalized path.
    }
  }
  return p.canonicalize(file.absolute.path);
}

/// Rejects an output path that aliases any input file, including through links.
Future<void> validateEngineManifestOutput({
  required File outputFile,
  required Iterable<File> inputFiles,
}) async {
  final outputPath = _pathKey(await canonicalResolvedPath(outputFile));
  for (final inputFile in inputFiles) {
    final inputPath = _pathKey(await canonicalResolvedPath(inputFile));
    if (outputPath == inputPath) {
      throw FileSystemException(
        'Manifest output path collides with an input file',
        outputFile.path,
      );
    }
  }
}

String _pathKey(String path) => Platform.isWindows ? path.toLowerCase() : path;

/// Produces a signed engine manifest for a complete Windows engine ZIP.
///
/// The private key file may contain a raw 32-byte Ed25519 seed, 64 hex digits,
/// or base64 encoding of the 32-byte seed. The private seed is never returned
/// in the manifest or written to standard output.
Future<Map<String, Object?>> createEngineManifest({
  required File engineZip,
  required Uri engineUri,
  required String engineVersion,
  required String mediaKitVersion,
  required String minimumAppVersion,
  String? maximumAppVersionExclusive,
  required String notes,
  required File signingKeyFile,
  File? outputFile,
  Iterable<File> additionalInputFiles = const <File>[],
  void Function(String base64PublicKey)? onPublicKey,
}) async {
  _validateVersion(engineVersion, 'Engine version');
  _validateVersion(mediaKitVersion, 'media_kit version');
  final minimum = _validateVersion(minimumAppVersion, 'Minimum app version');
  if (maximumAppVersionExclusive != null) {
    final maximum = _validateVersion(
      maximumAppVersionExclusive,
      'Maximum app version exclusive',
    );
    if (maximum.compareTo(minimum) <= 0) {
      throw const FormatException(
        'Maximum app version exclusive must be greater than the minimum app version.',
      );
    }
  }
  _requireHttps(engineUri, 'Engine URL');
  if (notes.length > maxEngineManifestNotesLength) {
    throw const FormatException(
      'Engine notes exceed the 80 KiB character limit.',
    );
  }
  final engineUrl = engineUri.toString();
  if (engineUrl.length > maxEngineManifestUrlLength) {
    throw const FormatException('Engine URL exceeds the 4096-character limit.');
  }

  if (outputFile != null) {
    await validateEngineManifestOutput(
      outputFile: outputFile,
      inputFiles: [engineZip, signingKeyFile, ...additionalInputFiles],
    );
  }

  if (!await engineZip.exists()) {
    throw FileSystemException('Engine ZIP does not exist', engineZip.path);
  }
  if (!await signingKeyFile.exists()) {
    throw FileSystemException('Signing key file does not exist');
  }

  await validateEngineArchive(engineZip);
  final artifactSize = await engineZip.length();
  final artifactHash = (await sha256.bind(engineZip.openRead()).single)
      .toString()
      .toLowerCase();
  final seed = _decodeSigningSeed(await signingKeyFile.readAsBytes());

  final payload = <String, Object?>{
    'engineVersion': engineVersion,
    'notes': notes,
    'mediaKitVersion': mediaKitVersion,
    'minimumAppVersion': minimumAppVersion,
    'maximumAppVersionExclusive': ?maximumAppVersionExclusive,
    'artifacts': <String, Object?>{
      'windows': <String, Object?>{
        'url': engineUrl,
        'sha256': artifactHash,
        'size': artifactSize,
      },
    },
  };

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  onPublicKey?.call(base64Encode(publicKey.bytes));
  final signature = await algorithm.sign(
    canonicalPayloadBytes(payload),
    keyPair: keyPair,
  );

  final manifest = <String, Object?>{
    'schemaVersion': engineManifestSchemaVersion,
    'payload': payload,
    'signature': base64Encode(signature.bytes),
  };
  encodeAndValidateEngineManifest(manifest);
  return manifest;
}

/// Validates names and types without extracting the ZIP to disk.
Future<void> validateEngineArchive(File engineZip) async {
  if (!await engineZip.exists()) {
    throw FileSystemException('Engine ZIP does not exist', engineZip.path);
  }
  final archiveBytes = await engineZip.length();
  if (archiveBytes == 0) {
    throw FormatException('Engine ZIP is empty: ${engineZip.path}');
  }
  if (archiveBytes > maxEngineZipBytes) {
    throw const FormatException(
      'Engine ZIP exceeds the 512 MiB download limit.',
    );
  }

  final input = InputFileStream(engineZip.path);
  final seenPaths = <String>{};
  final filePaths = <String>{};
  final directoryPaths = <String>{};
  var hasRootEngineDll = false;
  var entryCount = 0;
  var uncompressedBytes = 0;
  try {
    _preflightEngineArchive(input, archiveBytes);
    final archive = ZipDecoder().decodeStream(
      input,
      verify: true,
      callback: (entry) {
        entryCount++;
        if (entryCount > maxEngineZipEntries) {
          throw const FormatException(
            'Engine ZIP exceeds the 4096-entry limit.',
          );
        }
        if (entry.size < 0 ||
            entry.size > maxEngineZipUncompressedBytes - uncompressedBytes) {
          throw const FormatException(
            'Engine ZIP exceeds the 2 GiB uncompressed size limit.',
          );
        }
        uncompressedBytes += entry.size;

        final normalized = _validateArchiveEntryName(entry.name);
        final pathKey = normalized.toLowerCase();
        if (!seenPaths.add(pathKey)) {
          throw const FormatException(
            'Engine ZIP contains duplicate paths that differ only by case or trailing slash.',
          );
        }
        if (entry.isSymbolicLink ||
            entry.symbolicLink != null ||
            (entry.mode & 0xf000) == 0xa000) {
          throw const FormatException(
            'Engine ZIP must not contain symbolic links.',
          );
        }
        final entryType = entry.mode & 0xf000;
        if (entryType != 0 &&
            (entry.isDirectory ? entryType != 0x4000 : entryType != 0x8000)) {
          throw const FormatException(
            'Engine ZIP contains an unsupported special file.',
          );
        }

        final segments = normalized.split('/');
        for (var index = 1; index < segments.length; index++) {
          final parent = segments.take(index).join('/').toLowerCase();
          if (filePaths.contains(parent)) {
            throw const FormatException(
              'Engine ZIP contains a file used as a parent directory.',
            );
          }
          directoryPaths.add(parent);
        }

        if (entry.isDirectory) {
          if (filePaths.contains(pathKey)) {
            throw const FormatException(
              'Engine ZIP path is both a file and a directory.',
            );
          }
          directoryPaths.add(pathKey);
        } else {
          if (directoryPaths.contains(pathKey)) {
            throw const FormatException(
              'Engine ZIP path is both a file and a directory.',
            );
          }
          filePaths.add(pathKey);
        }

        if (normalized == 'libmpv-2.dll' && entry.isFile && entry.size > 0) {
          hasRootEngineDll = true;
        }
      },
    );
    if (!hasRootEngineDll) {
      throw const FormatException(
        'Engine ZIP must contain a non-empty libmpv-2.dll at its root.',
      );
    }
    await archive.clear();
  } on FormatException {
    rethrow;
  } on Object {
    throw FormatException(
      'Engine ZIP is invalid or unreadable: ${engineZip.path}',
    );
  } finally {
    await input.close();
  }
}

/// Checks central-directory metadata before ZipDecoder can inflate entries.
/// In archive 4.5.2, decoding a Unix symlink eagerly inflates its target before
/// invoking the callback, so callback-only limits do not protect this path.
void _preflightEngineArchive(InputFileStream input, int archiveBytes) {
  final directory = ZipDirectory()..read(input);
  final headers = directory.fileHeaders;
  final declaredCount = directory.totalCentralDirectoryEntries;
  if (headers.isEmpty ||
      declaredCount <= 0 ||
      declaredCount > maxEngineZipEntries ||
      headers.length != declaredCount ||
      directory.totalCentralDirectoryEntriesOnThisDisk != declaredCount ||
      directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0) {
    throw const FormatException('Engine ZIP has an invalid number of entries.');
  }

  final seenPaths = <String>{};
  final filePaths = <String>{};
  final directoryPaths = <String>{};
  var totalUncompressedBytes = 0;
  var hasRootEngineDll = false;
  for (final header in headers) {
    final entry = header.file;
    if (entry == null || entry.filename != header.filename) {
      throw const FormatException(
        'Engine ZIP central and local entry names do not match.',
      );
    }

    final mode = (header.externalFileAttributes >> 16) & 0xffff;
    final entryType = mode & 0xf000;
    final unixMade = (header.versionMadeBy >> 8) == 3;
    if (entryType == 0xa000 ||
        (header.externalFileAttributes & 0x400) != 0 ||
        (unixMade &&
            entryType != 0 &&
            entryType != 0x4000 &&
            entryType != 0x8000)) {
      throw const FormatException(
        'Engine ZIP contains a link or unsupported special file.',
      );
    }

    final normalized = _validateArchiveEntryName(header.filename);
    final pathKey = normalized.toLowerCase();
    if (!seenPaths.add(pathKey)) {
      throw const FormatException(
        'Engine ZIP contains duplicate paths that differ only by case or trailing slash.',
      );
    }
    final isDirectory = header.filename.endsWith('/');
    if (unixMade && entryType != 0 && ((entryType == 0x4000) != isDirectory)) {
      throw const FormatException(
        'Engine ZIP contains an entry with inconsistent file type metadata.',
      );
    }

    final uncompressedSize = entry.uncompressedSize;
    final compressedSize = entry.compressedSize;
    if (uncompressedSize < 0 ||
        compressedSize < 0 ||
        compressedSize > archiveBytes ||
        uncompressedSize >
            maxEngineZipUncompressedBytes - totalUncompressedBytes) {
      throw const FormatException(
        'Engine ZIP contains invalid sizes or exceeds the 2 GiB uncompressed size limit.',
      );
    }
    totalUncompressedBytes += uncompressedSize;

    final segments = normalized.split('/');
    for (var index = 1; index < segments.length; index++) {
      final parent = segments.take(index).join('/').toLowerCase();
      if (filePaths.contains(parent)) {
        throw const FormatException(
          'Engine ZIP contains a file used as a parent directory.',
        );
      }
      directoryPaths.add(parent);
    }
    if (isDirectory) {
      if (filePaths.contains(pathKey)) {
        throw const FormatException(
          'Engine ZIP path is both a file and a directory.',
        );
      }
      directoryPaths.add(pathKey);
    } else {
      if (directoryPaths.contains(pathKey)) {
        throw const FormatException(
          'Engine ZIP path is both a file and a directory.',
        );
      }
      filePaths.add(pathKey);
      if (normalized == 'libmpv-2.dll' && uncompressedSize > 0) {
        hasRootEngineDll = true;
      }
    }
  }

  if (!hasRootEngineDll) {
    throw const FormatException(
      'Engine ZIP must contain a non-empty libmpv-2.dll at its root.',
    );
  }
}

String _validateArchiveEntryName(String name) {
  if (name.isEmpty ||
      name.contains('\u0000') ||
      name.contains('\\') ||
      name.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(name)) {
    throw const FormatException(
      'Engine ZIP contains an absolute or malformed entry path.',
    );
  }

  final path = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
  final segments = path.split('/');
  if (path.isEmpty ||
      segments.any(
        (segment) =>
            segment.isEmpty ||
            segment == '.' ||
            segment == '..' ||
            segment.endsWith('.') ||
            segment.endsWith(' ') ||
            RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(segment) ||
            RegExp(
              r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[1-9]|LPT[1-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(segment),
      )) {
    throw const FormatException('Engine ZIP contains an unsafe entry path.');
  }
  return segments.join('/');
}

SemanticVersion _validateVersion(String value, String label) {
  try {
    return SemanticVersion.parse(value);
  } on FormatException {
    throw FormatException('$label must follow SemVer 2.0.0.');
  }
}

void _requireHttps(Uri uri, String label) {
  if (uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw FormatException(
      '$label must be an HTTPS URL without credentials or fragments.',
    );
  }
}

/// Returns the recursively key-sorted, compact JSON encoding used for signing.
List<int> canonicalPayloadBytes(Map<String, Object?> payload) =>
    utf8.encode(jsonEncode(_sortJson(payload)));

/// Encodes a manifest in its published form and validates it with the app's
/// parser before it can be written to disk.
String encodeAndValidateEngineManifest(Map<String, Object?> manifest) {
  const encoder = JsonEncoder.withIndent('  ');
  final encoded = '${encoder.convert(manifest)}\n';
  if (utf8.encode(encoded).length > maxEngineManifestBytes) {
    throw const FormatException(
      'Engine manifest exceeds the 256 KiB download limit.',
    );
  }
  engine_release.EngineUpdateManifest.parse(encoded);
  return encoded;
}

Object? _sortJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) {
      if (key is! String) {
        throw const FormatException(
          'Canonical JSON object keys must be strings.',
        );
      }
      return key;
    }).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _sortJson(value[key]),
    };
  }
  if (value is List) {
    return value.map(_sortJson).toList(growable: false);
  }
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw const FormatException('Value cannot be represented as JSON.');
}

List<int> _decodeSigningSeed(List<int> bytes) {
  if (bytes.length == 32) return bytes;

  String text;
  try {
    text = utf8.decode(bytes, allowMalformed: false).trim();
  } on FormatException {
    throw const FormatException(
      'Signing key file must contain a 32-byte seed, 64 hexadecimal digits, or base64 for a 32-byte seed.',
    );
  }

  List<int>? seed;
  if (RegExp(r'^[0-9A-Fa-f]{64}$').hasMatch(text)) {
    seed = <int>[
      for (var index = 0; index < text.length; index += 2)
        int.parse(text.substring(index, index + 2), radix: 16),
    ];
  } else {
    try {
      seed = base64Decode(text);
    } on FormatException {
      seed = null;
    }
  }

  if (seed == null || seed.length != 32) {
    throw const FormatException(
      'Signing key file must contain a 32-byte seed, 64 hexadecimal digits, or base64 for a 32-byte seed.',
    );
  }
  return seed;
}

/// Writes the manifest through a temporary file in the destination directory.
Future<void> writeEngineManifestAtomically(
  File outputFile,
  Map<String, Object?> manifest,
) async {
  final encoded = encodeAndValidateEngineManifest(manifest);
  await outputFile.parent.create(recursive: true);
  final randomSuffix = Random.secure().nextInt(1 << 32).toRadixString(16);
  final temporaryFile = File(
    p.join(
      outputFile.parent.path,
      '.${p.basename(outputFile.path)}.$pid-$randomSuffix.tmp',
    ),
  );
  try {
    await temporaryFile.writeAsBytes(utf8.encode(encoded), flush: true);
    await temporaryFile.rename(outputFile.path);
  } catch (_) {
    try {
      if (await temporaryFile.exists()) await temporaryFile.delete();
    } on FileSystemException {
      // Keep the original failure if cleanup also fails.
    }
    rethrow;
  }
}

/// Parses CLI options and rejects unknown, repeated, or incomplete options.
Map<String, String> parseEngineManifestArguments(List<String> arguments) {
  const allowed = <String>{
    'engine-zip',
    'engine-url',
    'engine-version',
    'media-kit-version',
    'min-app-version',
    'max-app-version-exclusive',
    'notes',
    'notes-file',
    'signing-key',
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
  for (final key in <String>[
    'engine-zip',
    'engine-url',
    'engine-version',
    'media-kit-version',
    'min-app-version',
    'signing-key',
  ]) {
    if (result[key]?.trim().isNotEmpty != true) {
      throw FormatException('Required option --$key is missing.');
    }
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

Future<void> main(List<String> arguments) async {
  try {
    final options = parseEngineManifestArguments(arguments);
    final engineZip = File(_required(options, 'engine-zip'));
    final signingKeyFile = File(_required(options, 'signing-key'));
    final notesFile = options['notes-file'] == null
        ? null
        : File(options['notes-file']!);
    final outputFile = File(options['output'] ?? 'engine-manifest.json');
    String? publicKeyBase64;
    final inputFiles = <File>[engineZip, signingKeyFile, ?notesFile];
    await validateEngineManifestOutput(
      outputFile: outputFile,
      inputFiles: inputFiles,
    );

    final notes = notesFile == null
        ? options['notes'] ?? ''
        : await notesFile.readAsString();
    final engineUrl = Uri.tryParse(_required(options, 'engine-url'));
    if (engineUrl == null) {
      throw const FormatException('Engine URL is invalid.');
    }
    final manifest = await createEngineManifest(
      engineZip: engineZip,
      engineUri: engineUrl,
      engineVersion: _required(options, 'engine-version'),
      mediaKitVersion: _required(options, 'media-kit-version'),
      minimumAppVersion: _required(options, 'min-app-version'),
      maximumAppVersionExclusive: options['max-app-version-exclusive'],
      notes: notes,
      signingKeyFile: signingKeyFile,
      outputFile: outputFile,
      additionalInputFiles: notesFile == null ? const <File>[] : [notesFile],
      onPublicKey: (value) {
        publicKeyBase64 = value;
      },
    );
    await writeEngineManifestAtomically(outputFile, manifest);

    final payload = manifest['payload']! as Map<String, Object?>;
    final artifacts = payload['artifacts']! as Map<String, Object?>;
    final windowsArtifact = artifacts['windows']! as Map<String, Object?>;
    final signature = manifest['signature']! as String;

    stdout.writeln('Wrote ${outputFile.absolute.path}');
    stdout.writeln('Engine version ${payload['engineVersion']}');
    stdout.writeln('ZIP SHA-256: ${windowsArtifact['sha256']}');
    stdout.writeln('Signature: $signature');
    stdout.writeln('Public key (base64): $publicKeyBase64');
  } on Object catch (error) {
    stderr.writeln('Could not create engine manifest: $error');
    stderr.writeln(_usage);
    exitCode = 64;
  }
}

const String _usage = '''Usage:
  dart run tool/create_engine_manifest.dart --engine-zip dist/mpvson-engine-windows-x64.zip
    --engine-url https://downloads.example.org/mpvson/engine/0.40.0/windows-x64.zip
    --engine-version 0.40.0 --media-kit-version 1.2.6 --min-app-version 0.1.0
    --signing-key secrets/engine-ed25519.seed --output dist/engine-stable.json
    [--max-app-version-exclusive 1.0.0] [--notes "Engine notes" | --notes-file notes.txt]

The ZIP must contain a non-empty libmpv-2.dll at its root. URLs must use HTTPS.''';
