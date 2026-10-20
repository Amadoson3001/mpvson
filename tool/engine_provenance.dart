// Provenance tooling for the pinned libmpv engine that ships with Mpvson.
//
// The engine is described once in packaging/windows/engine-provenance.json and
// consumed by the Windows CMake configure step, which downloads the exact
// artifact, verifies every digest and bundles the verified module. This tool
// owns the surrounding workflow:
//
//   dart run tool/engine_provenance.dart verify
//     Re-checks the record, the checked-in license text, the build cache and the
//     built bundle. Exits non-zero on any mismatch.
//
//   dart run tool/engine_provenance.dart refresh --accept <version>
//     Reads the upstream release metadata, requires the operator to name the
//     version they intend to pin, downloads that package, recomputes every
//     digest and rewrites the record.
//
//   dart run tool/engine_provenance.dart inventory
//     Writes build/windows/x64/engine/engine-inventory.json for release provenance.
//
// mpv publishes Windows libmpv modules only under the rolling git-release tag,
// so the pinned version changes whenever upstream rebuilds. Refreshing is a
// deliberate, reviewable step: the record always states the exact version, the
// commit, the build date and the artifact digest that were verified.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'verified_artifact_download.dart';

const String _recordRelative = 'packaging/windows/engine-provenance.json';
const String _licenseRelative = 'packaging/windows/LICENSE.libmpv-GPL.txt';
const String _cacheRelative = 'build/windows/x64/engine';
const String _bundleRelative = 'build/windows/x64/runner/Release';
const String _releaseApi =
    'https://api.github.com/repos/mpv-player/mpv/releases/tags/git-release';
const String _releasePage =
    'https://github.com/mpv-player/mpv/releases/tag/git-release';

/// The x64 MinGW GPL libmpv asset of the rolling upstream development release.
final RegExp _assetPattern = RegExp(
  r'^libmpv-v(\d+\.\d+\.\d+)-dev-g([0-9a-f]+)-(\d+)-x86_64-w64-mingw32-gpl\.zip$',
);

/// Files that still come from media_kit_libs_windows_video and serve the video
/// renderer's ANGLE path rather than the engine.
const List<String> _companionFiles = <String>[
  'd3dcompiler_47.dll',
  'libEGL.dll',
  'libGLESv2.dll',
  'vk_swiftshader.dll',
  'vulkan-1.dll',
  'zlib.dll',
];

Future<void> main(List<String> arguments) async {
  final String command = arguments.isEmpty ? 'verify' : arguments.first;
  final _Options options = _Options.parse(arguments.skip(1).toList());
  final String root = options.root ?? _repositoryRoot();

  switch (command) {
    case 'verify':
      exitCode = await _verify(root) ? 0 : 1;
    case 'refresh':
      exitCode = await _refresh(root, options) ? 0 : 1;
    case 'inventory':
      exitCode = await _inventory(root, options) ? 0 : 1;
    case 'help':
    case '--help':
    case '-h':
      _printUsage();
    default:
      stderr.writeln('Unknown command "$command".');
      _printUsage();
      exitCode = 64;
  }
}

void _printUsage() => stdout.writeln('''
Usage: dart run tool/engine_provenance.dart <command> [options]

Commands:
  verify                              Verify the record, license, cache and bundle.
  refresh --accept <version>          Re-pin the engine from upstream metadata.
  inventory                           Write build/engine/engine-inventory.json.

Options:
  --root <dir>        Repository root (defaults to the location of this tool).
  --dry-run           Report what refresh would change without writing files.
''');

String _repositoryRoot() => p.dirname(p.dirname(Platform.script.toFilePath()));

Map<String, Object?> _readJson(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw FormatException('$path does not hold a JSON object.');
  }
  return decoded;
}

Map<String, Object?> _section(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! Map<String, Object?>) {
    throw FormatException('The engine record is missing the "$key" object.');
  }
  return value;
}

String _requireString(
  Map<String, Object?> json,
  String key, {
  String? section,
}) {
  final Map<String, Object?> source = section == null
      ? json
      : _section(json, section);
  final Object? value = source[key];
  if (value is! String || value.isEmpty) {
    throw FormatException(
      'The engine record needs the string "${section == null ? key : '$section.$key'}".',
    );
  }
  return value;
}

int _requireInt(Map<String, Object?> json, String key, {String? section}) {
  final Map<String, Object?> source = section == null
      ? json
      : _section(json, section);
  final Object? value = source[key];
  if (value is! int) {
    throw FormatException(
      'The engine record needs the integer "${section == null ? key : '$section.$key'}".',
    );
  }
  return value;
}

String _sha256OfFile(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();

/// Runs [body] on every recorded digest pair and reports mismatches.
bool _verifyRecordShape(Map<String, Object?> record, List<String> problems) {
  void checkDigest(String value, String label) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      problems.add('$label is not a lower-case SHA-256 digest: "$value"');
    }
  }

  final Map<String, Object?> artifact = _section(record, 'artifact');
  checkDigest(
    _requireString(record, 'sha256', section: 'artifact'),
    'artifact.sha256',
  );
  checkDigest(
    _requireString(record, 'memberSha256', section: 'artifact'),
    'artifact.memberSha256',
  );
  checkDigest(
    _requireString(record, 'licenseSha256', section: 'artifact'),
    'artifact.licenseSha256',
  );
  final String url = _requireString(record, 'url', section: 'artifact');
  if (!url.startsWith('https://github.com/mpv-player/mpv/releases/download/')) {
    problems.add(
      'artifact.url is not an immutable upstream HTTPS release asset: $url',
    );
  }
  final String assetName = _requireString(
    record,
    'assetName',
    section: 'artifact',
  );
  if (!_assetPattern.hasMatch(assetName)) {
    problems.add(
      'artifact.assetName is not the x64 MinGW GPL libmpv asset this project pins: $assetName',
    );
  }
  if (!url.endsWith('/$assetName')) {
    problems.add(
      'artifact.url does not end with artifact.assetName ($assetName).',
    );
  }
  final String member = _requireString(record, 'member', section: 'artifact');
  if (member != 'libmpv-2.dll') {
    problems.add('artifact.member must be libmpv-2.dll, found "$member".');
  }
  final int artifactSize = _requireInt(record, 'size', section: 'artifact');
  if (artifactSize <= 0) problems.add('artifact.size must be positive.');
  final int memberSize = _requireInt(record, 'memberSize', section: 'artifact');
  if (memberSize <= 0) problems.add('artifact.memberSize must be positive.');

  final Map<String, Object?> engine = _section(record, 'engine');
  final String version = _requireString(record, 'version', section: 'engine');
  if (!version.startsWith('v')) {
    problems.add('engine.version must start with "v": "$version"');
  }
  final String runtimeVersion = _requireString(
    record,
    'runtimeVersion',
    section: 'engine',
  );
  if (!RegExp(
    r'^\d+\.\d+\.\d+-dev\.\d+\+g[0-9a-f]+$',
  ).hasMatch(runtimeVersion)) {
    problems.add(
      'engine.runtimeVersion must be the SemVer form the updater stores: "$runtimeVersion"',
    );
  }
  final String describeVersion = _requireString(
    record,
    'describeVersion',
    section: 'engine',
  );
  if (!describeVersion.startsWith('v')) {
    problems.add(
      'engine.describeVersion must start with "v": "$describeVersion"',
    );
  }
  if (!_requireString(
    record,
    'assetName',
    section: 'artifact',
  ).contains(version)) {
    problems.add(
      'artifact.assetName does not carry the recorded engine version "$version".',
    );
  }
  final String baseVersion = _requireString(
    record,
    'baseVersion',
    section: 'engine',
  );
  if (!baseVersion.startsWith('v') && !RegExp(r'^\d').hasMatch(baseVersion)) {
    problems.add('engine.baseVersion looks wrong: "$baseVersion"');
  }
  final Map<String, Object?> replaces = _section(record, 'replaces');
  checkDigest(
    _requireString(record, 'sha256', section: 'replaces'),
    'replaces.sha256',
  );
  final String replacedVersion = _requireString(
    record,
    'version',
    section: 'replaces',
  );
  if (replacedVersion == version) {
    problems.add(
      'The pinned engine still names the replaced 2023 build as its own version.',
    );
  }
  if (artifact.isEmpty || engine.isEmpty || replaces.isEmpty) {
    problems.add(
      'The engine record must describe the engine, its artifact and what it replaces.',
    );
  }
  return problems.isEmpty;
}

Future<bool> _verify(String root) async {
  final String recordPath = p.join(root, _recordRelative);
  final List<String> problems = <String>[];
  if (!File(recordPath).existsSync()) {
    stderr.writeln('Missing engine record: $recordPath');
    return false;
  }
  final Map<String, Object?> record = _readJson(recordPath);
  if (record['schemaVersion'] != 1) {
    problems.add(
      'Unsupported record schemaVersion ${record['schemaVersion']}.',
    );
  }
  if (!_verifyRecordShape(record, problems)) {
    problems.forEach(stderr.writeln);
    return false;
  }

  final String assetName = _requireString(
    record,
    'assetName',
    section: 'artifact',
  );
  final int artifactSize = _requireInt(record, 'size', section: 'artifact');
  final String artifactSha = _requireString(
    record,
    'sha256',
    section: 'artifact',
  );
  final int memberSize = _requireInt(record, 'memberSize', section: 'artifact');
  final String memberSha = _requireString(
    record,
    'memberSha256',
    section: 'artifact',
  );
  final String licenseSha = _requireString(
    record,
    'licenseSha256',
    section: 'artifact',
  );
  final String member = _requireString(record, 'member', section: 'artifact');
  final String version = _requireString(record, 'version', section: 'engine');

  stdout.writeln('Record      : $recordPath');
  stdout.writeln(
    'Engine      : ${_requireString(record, 'version', section: 'engine')}'
    ' (${_requireString(record, 'builtOn', section: 'engine')})',
  );
  stdout.writeln('Artifact    : $assetName');
  stdout.writeln('Artifact SHA: $artifactSha');
  stdout.writeln('Module SHA  : $memberSha');

  final String licensePath = p.join(root, _licenseRelative);
  if (!File(licensePath).existsSync()) {
    problems.add(
      'The checked-in upstream license text is missing: $licensePath',
    );
  } else {
    final String actual = _sha256OfFile(licensePath);
    if (actual != licenseSha) {
      problems.add(
        '$licensePath has SHA-256 $actual instead of the recorded $licenseSha.',
      );
    } else {
      stdout.writeln('License     : verified ($_licenseRelative)');
    }
  }

  final String cacheDir = p.join(root, _cacheRelative);
  final File cachedArtifact = File(p.join(cacheDir, assetName));
  if (cachedArtifact.existsSync()) {
    final int size = cachedArtifact.lengthSync();
    final String actual = _sha256OfFile(cachedArtifact.path);
    if (size != artifactSize || actual != artifactSha) {
      problems.add(
        'Cached archive ${cachedArtifact.path} is $size bytes with SHA-256 $actual, '
        'but the record pins $artifactSize bytes and $artifactSha.',
      );
    } else {
      stdout.writeln('Cache archive: verified (${_megabytes(size)})');
    }
  } else {
    stdout.writeln('Cache archive: absent (the build downloads it on demand)');
  }

  final File cachedModule = File(p.join(cacheDir, version, member));
  if (cachedModule.existsSync()) {
    final int size = cachedModule.lengthSync();
    final String actual = _sha256OfFile(cachedModule.path);
    if (size != memberSize || actual != memberSha) {
      problems.add(
        'Cached module ${cachedModule.path} is $size bytes with SHA-256 $actual, '
        'but the record pins $memberSize bytes and $memberSha.',
      );
    } else {
      stdout.writeln('Cache module : verified (${_megabytes(size)})');
    }
  } else {
    stdout.writeln('Cache module : absent (the build extracts it on demand)');
  }

  final File bundled = File(p.join(root, _bundleRelative, member));
  if (bundled.existsSync()) {
    final String actual = _sha256OfFile(bundled.path);
    if (actual != memberSha) {
      problems.add(
        'The built bundle ships the wrong engine: ${bundled.path} has SHA-256 $actual '
        'instead of the pinned $memberSha.',
      );
    } else {
      stdout.writeln('Bundle       : verified (${bundled.path})');
    }
  } else {
    stdout.writeln(
      'Bundle       : not built yet (${p.join(_bundleRelative, member)})',
    );
  }

  if (problems.isEmpty) {
    stdout.writeln('Engine provenance verified.');
    return true;
  }
  stderr.writeln('');
  stderr.writeln('Engine provenance problems:');
  for (final String problem in problems) {
    stderr.writeln(' - $problem');
  }
  return false;
}

Future<bool> _refresh(String root, _Options options) async {
  final String accepted = options.accept ?? '';
  if (accepted.isEmpty) {
    stderr.writeln(
      'refresh requires --accept <version>, for example --accept v0.41.0-1206-gfffe7a23a.',
    );
    stderr.writeln(
      'The version is the engine version upstream reports for the build you reviewed at $_releasePage.',
    );
    return false;
  }
  final String recordPath = p.join(root, _recordRelative);
  final Map<String, Object?> record = _readJson(recordPath);

  stdout.writeln('Reading upstream release metadata: $_releaseApi');
  final http.Client client = http.Client();
  try {
    final http.Response response = await client.get(
      Uri.parse(_releaseApi),
      headers: const <String, String>{'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) {
      stderr.writeln(
        'Upstream metadata request failed with HTTP ${response.statusCode}.',
      );
      return false;
    }
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      stderr.writeln('Upstream metadata is not a JSON object.');
      return false;
    }
    final Object? assets = decoded['assets'];
    if (assets is! List<Object?>) {
      stderr.writeln('Upstream metadata carries no asset list.');
      return false;
    }
    Map<String, Object?>? chosen;
    String? chosenVersion;
    String? chosenCommit;
    String? chosenBuild;
    for (final Object? asset in assets) {
      if (asset is! Map<String, Object?>) continue;
      final Object? name = asset['name'];
      if (name is! String) continue;
      final RegExpMatch? match = _assetPattern.firstMatch(name);
      if (match == null) continue;
      chosen = asset;
      chosenVersion = match.group(1);
      chosenCommit = match.group(2);
      chosenBuild = match.group(3);
      break;
    }
    if (chosen == null ||
        chosenVersion == null ||
        chosenCommit == null ||
        chosenBuild == null) {
      stderr.writeln(
        'No x64 MinGW GPL libmpv asset is published for that release.',
      );
      return false;
    }
    final String name = chosen['name']! as String;
    final String version = 'v$chosenVersion-dev-g$chosenCommit';
    final String describeVersion =
        'v$chosenVersion-$chosenBuild-g$chosenCommit';
    final String runtimeVersion =
        '$chosenVersion-dev.$chosenBuild+g$chosenCommit';
    if (version != accepted) {
      stderr.writeln(
        'Refusing to pin an unreviewed version: upstream publishes "$version" (asset $name), '
        'but --accept named "$accepted".',
      );
      stderr.writeln(
        'Re-run with --accept $version after reviewing $_releasePage.',
      );
      return false;
    }
    final Object? size = chosen['size'];
    final Object? digest = chosen['digest'];
    final Object? url = chosen['browser_download_url'];
    if (size is! int ||
        size <= 0 ||
        size > 512 * 1024 * 1024 ||
        digest is! String ||
        url is! String) {
      stderr.writeln(
        'The upstream asset does not carry a size, digest and download URL.',
      );
      return false;
    }
    final String digestValue = digest.startsWith('sha256:')
        ? digest.substring('sha256:'.length)
        : digest;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digestValue)) {
      stderr.writeln(
        'Upstream published no usable SHA-256 digest for $name: "$digest".',
      );
      return false;
    }

    final String cacheDir = p.join(root, _cacheRelative);
    final File cached = File(p.join(cacheDir, name));
    if (!cached.existsSync() ||
        cached.lengthSync() != size ||
        _sha256OfFile(cached.path) != digestValue) {
      stdout.writeln('Downloading $name (${_megabytes(size)})');
      var reported = 0;
      await downloadProvenanceArtifact(
        client: client,
        uri: Uri.parse(url),
        destination: cached,
        expectedSize: size,
        expectedSha256: digestValue,
        onProgress: (received) {
          final megabytes = received ~/ (16 * 1024 * 1024);
          if (megabytes > reported) {
            reported = megabytes;
            stdout.writeln(
              '  ${received ~/ (1024 * 1024)} MiB / ${_megabytes(size)}',
            );
          }
        },
      );
    }
    final int actualSize = cached.lengthSync();
    final String actualSha = _sha256OfFile(cached.path);
    if (actualSize != size || actualSha != digestValue) {
      stderr.writeln(
        'Downloaded $name is $actualSize bytes with SHA-256 $actualSha, '
        'but upstream published $size bytes and $digestValue.',
      );
      return false;
    }

    final String licenseRelative = _licenseRelative;
    final File licenseFile = File(p.join(root, licenseRelative));
    final Map<String, Object?> refreshed = <String, Object?>{
      'version': version,
      'describeVersion': describeVersion,
      'runtimeVersion': runtimeVersion,
      'baseVersion': chosenVersion,
      'commit': await _resolveCommit(client, chosenCommit) ?? chosenCommit,
      'builtOn': _todayUtc(),
      'clientApiVersion': _requireString(
        record,
        'clientApiVersion',
        section: 'engine',
      ),
    };

    final Map<String, Object?> artifact = <String, Object?>{
      'url': url,
      'releaseApi': _releaseApi,
      'assetName': name,
      'format': 'zip',
      'size': size,
      'sha256': digestValue,
      'member': 'libmpv-2.dll',
      'licenseMember': 'LICENSE.GPL',
    };

    // The package is small enough to inspect in one pass, and reading the
    // member is how the module digest is recomputed.
    final Archive archive = ZipDecoder().decodeStream(
      InputFileStream(cached.path),
    );
    final ArchiveFile? module = archive.findFile('libmpv-2.dll');
    if (module == null) {
      stderr.writeln('$name does not contain a root libmpv-2.dll.');
      return false;
    }
    final List<int> moduleBytes = module.content as List<int>;
    artifact['memberSize'] = moduleBytes.length;
    artifact['memberSha256'] = sha256.convert(moduleBytes).toString();
    final ArchiveFile? license = archive.findFile('LICENSE.GPL');
    if (license == null) {
      stderr.writeln('$name does not contain the upstream LICENSE.GPL.');
      return false;
    }
    final List<int> licenseBytes = license.content as List<int>;
    artifact['licenseSize'] = licenseBytes.length;
    artifact['licenseSha256'] = sha256.convert(licenseBytes).toString();

    final Map<String, Object?> output = Map<String, Object?>.of(record)
      ..['engine'] = <String, Object?>{
        ..._section(record, 'engine'),
        ...refreshed,
      }
      ..['artifact'] = artifact;

    stdout.writeln('');
    stdout.writeln('Refreshed pin:');
    stdout.writeln('  engine.version        $version');
    stdout.writeln('  engine.describeVersion $describeVersion');
    stdout.writeln('  engine.runtimeVersion $runtimeVersion');
    stdout.writeln('  artifact.size         $size');
    stdout.writeln('  artifact.sha256       $digestValue');
    stdout.writeln('  artifact.memberSize   ${artifact['memberSize']}');
    stdout.writeln('  artifact.memberSha256 ${artifact['memberSha256']}');
    stdout.writeln('  artifact.licenseSha256 ${artifact['licenseSha256']}');

    if (options.dryRun) {
      stdout.writeln('');
      stdout.writeln(
        '--dry-run: the record and the license text were not written.',
      );
      return true;
    }

    if (!licenseFile.existsSync() ||
        _sha256OfFile(licenseFile.path) != artifact['licenseSha256']) {
      licenseFile.writeAsBytesSync(licenseBytes, flush: true);
      stdout.writeln('  updated $licenseRelative');
    }
    // Refresh the cache copy of the module so the next build reuses it.
    final Directory moduleDirectory = Directory(p.join(cacheDir, version))
      ..createSync(recursive: true);
    File(
      p.join(moduleDirectory.path, 'libmpv-2.dll'),
    ).writeAsBytesSync(moduleBytes, flush: true);
    File(recordPath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
      flush: true,
    );
    stdout.writeln('  updated ${p.relative(recordPath, from: root)}');
    stdout.writeln('');
    stdout.writeln(
      'Review the diff, rebuild Windows, and re-run the native playback tests.',
    );
    return true;
  } finally {
    client.close();
  }
}

Future<String?> _resolveCommit(http.Client client, String shortCommit) async {
  try {
    final http.Response response = await client.get(
      Uri.parse(
        'https://api.github.com/repos/mpv-player/mpv/commits/$shortCommit',
      ),
      headers: const <String, String>{'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) return null;
    final Object? decoded = jsonDecode(response.body);
    if (decoded is Map<String, Object?> && decoded['sha'] is String) {
      return decoded['sha']! as String;
    }
  } on Object {
    return null;
  }
  return null;
}

Future<bool> _inventory(String root, _Options options) async {
  final String recordPath = p.join(root, _recordRelative);
  final Map<String, Object?> record = _readJson(recordPath);
  final List<String> problems = <String>[];
  if (!_verifyRecordShape(record, problems)) {
    problems.forEach(stderr.writeln);
    return false;
  }
  final String bundleDirectory =
      options.releaseDir ?? p.join(root, _bundleRelative);
  final String member = _requireString(record, 'member', section: 'artifact');
  final List<Map<String, Object?>> files = <Map<String, Object?>>[];
  for (final String name in <String>[member, ..._companionFiles]) {
    final File file = File(p.join(bundleDirectory, name));
    if (!file.existsSync()) {
      problems.add('The built bundle is missing $name ($bundleDirectory).');
      continue;
    }
    files.add(<String, Object?>{
      'path': name,
      'size': file.lengthSync(),
      'sha256': _sha256OfFile(file.path),
      'role': name == member ? 'engine' : 'renderer-companion',
    });
  }
  if (problems.isNotEmpty) {
    problems.forEach(stderr.writeln);
    return false;
  }
  final String engineSha = _requireString(
    record,
    'memberSha256',
    section: 'artifact',
  );
  final Map<String, Object?> inventory = <String, Object?>{
    'schemaVersion': 1,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'engine': <String, Object?>{
      'version': _requireString(record, 'version', section: 'engine'),
      'commit': _requireString(record, 'commit', section: 'engine'),
      'license': _requireString(record, 'license', section: 'engine'),
      'record': _recordRelative,
      'artifactUrl': _requireString(record, 'url', section: 'artifact'),
      'artifactSha256': _requireString(record, 'sha256', section: 'artifact'),
    },
    'files': files,
    'matchesPinnedEngine': files.any(
      (Map<String, Object?> file) => file['sha256'] == engineSha,
    ),
  };
  final Directory outDirectory = Directory(p.join(root, _cacheRelative))
    ..createSync(recursive: true);
  final File out = File(p.join(outDirectory.path, 'engine-inventory.json'))
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(inventory)}\n',
      flush: true,
    );
  stdout.writeln('Wrote ${out.path}');
  for (final Map<String, Object?> file in files) {
    stdout.writeln(
      '  ${file['path']}  ${_megabytes(file['size']! as int)}  ${file['sha256']}',
    );
  }
  return true;
}

String _megabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';

String _todayUtc() {
  final DateTime now = DateTime.now().toUtc();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

class _Options {
  const _Options({
    this.root,
    this.accept,
    this.releaseDir,
    this.dryRun = false,
  });

  final String? root;
  final String? accept;
  final String? releaseDir;
  final bool dryRun;

  static _Options parse(List<String> arguments) {
    String? root;
    String? accept;
    String? releaseDir;
    bool dryRun = false;
    for (int index = 0; index < arguments.length; index++) {
      final String argument = arguments[index];
      String? valueFor(String name) {
        if (index + 1 >= arguments.length) return null;
        final String value = arguments[index + 1];
        if (value.startsWith('--')) return null;
        index++;
        return value;
      }

      switch (argument) {
        case '--root':
          root = valueFor(argument) ?? root;
        case '--accept':
          accept = valueFor(argument) ?? accept;
        case '--release-dir':
          releaseDir = valueFor(argument) ?? releaseDir;
        case '--dry-run':
          dryRun = true;
        default:
          stderr.writeln('Ignoring unknown option "$argument".');
      }
    }
    return _Options(
      root: root,
      accept: accept,
      releaseDir: releaseDir,
      dryRun: dryRun,
    );
  }
}
