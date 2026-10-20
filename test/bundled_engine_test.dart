import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/bundled_engine.dart';
import 'package:mpvson/domain/updates/mpv_github_release.dart';
import 'package:mpvson/domain/updates/semantic_version.dart';
import 'package:path/path.dart' as p;

// The Windows build verifies the engine package recorded in
// packaging/windows/engine-provenance.json and bundles it. These checks keep the
// runtime identity of that engine and the pinned record from drifting apart,
// which would make the bundled engine look like an available update or let the
// obsolete 2023 module back in.
void main() {
  late Map<String, Object?> record;

  setUpAll(() {
    final file = File(p.join('packaging', 'windows', 'engine-provenance.json'));
    expect(file.existsSync(), isTrue, reason: '${file.path} is missing');
    record = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  });

  Map<String, Object?> section(String name) =>
      record[name]! as Map<String, Object?>;

  test('bundled engine version matches the pinned package asset', () {
    final artifact = section('artifact');
    final engine = section('engine');
    final assetName = artifact['assetName']! as String;
    expect(
      bundledEngineVersion,
      MpvGithubRelease.engineVersionFromAssetName(assetName),
      reason:
          'The runtime bundled engine version and the build-time pin must name the same '
          'upstream package, or the updater misjudges the bundled engine.',
    );
    expect(
      bundledEngineVersion,
      engine['runtimeVersion'],
      reason: 'The record and the code must agree on the engine identity.',
    );
    // Both sides must be comparable as SemVer, which the updater requires.
    expect(
      SemanticVersion.parse(bundledEngineVersion).value,
      bundledEngineVersion,
    );
  });

  test('provenance record pins the current engine and its digests', () {
    final engine = section('engine');
    final artifact = section('artifact');
    final replaces = section('replaces');

    expect(engine['version'], isNot(replaces['version']));
    expect(
      replaces['version'],
      'v0.36.0-403-g652a1dd907',
      reason: 'The record must name the obsolete build it replaces.',
    );
    expect(engine['license'], contains('GPL'));

    final sha256 = RegExp(r'^[0-9a-f]{64}$');
    expect(sha256.hasMatch(artifact['sha256']! as String), isTrue);
    expect(sha256.hasMatch(artifact['memberSha256']! as String), isTrue);
    expect(sha256.hasMatch(artifact['licenseSha256']! as String), isTrue);
    expect(sha256.hasMatch(replaces['sha256']! as String), isTrue);

    expect(
      artifact['member'],
      'libmpv-2.dll',
      reason: 'The bundled module keeps the name the native bridge loads.',
    );
    expect(artifact['size'], isA<int>());
    expect(artifact['memberSize'], isA<int>());
    expect(
      (artifact['url']! as String).endsWith('/${artifact['assetName']}'),
      isTrue,
    );
    expect(
      artifact['memberSize'],
      greaterThan(replaces['size']! as int),
      reason: 'The pinned engine is the larger self-contained build.',
    );
  });

  test('the checked-in license text matches the pinned package digest', () {
    final artifact = section('artifact');
    final license = File(
      p.join('packaging', 'windows', 'LICENSE.libmpv-GPL.txt'),
    );
    expect(license.existsSync(), isTrue);
    expect(license.readAsStringSync(), contains('GNU GENERAL PUBLIC LICENSE'));
    expect(
      sha256.convert(license.readAsBytesSync()).toString(),
      artifact['licenseSha256'],
      reason:
          'The license text shipped next to the application must be the text '
          'recorded for the pinned package.',
    );
  });

  test('the pinned engine is newer than the module it replaces', () {
    final engine = section('engine');
    final replaces = section('replaces');
    expect(
      section('artifact')['assetName'],
      contains(engine['version']),
      reason: 'The pinned asset name must carry the recorded engine version.',
    );
    expect(
      engine['commit'],
      startsWith((engine['version']! as String).split('g').last),
    );
    expect(replaces['version'], startsWith('v0.36.0'));
    expect(
      SemanticVersion.parse(
        bundledEngineVersion,
      ).compareTo(SemanticVersion.parse('0.36.0')),
      greaterThan(0),
      reason:
          'The bundled engine must be newer than ${replaces['version']}, or the '
          'packaging regression is back.',
    );
  });
}
