import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/bundled_engine.dart';
import 'package:mpvson/domain/updates/mpv_github_release.dart';

void main() {
  test('bundled runtime identity matches the pinned artifact and updater', () {
    final record =
        jsonDecode(
              File(
                'packaging/windows/engine-provenance.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final engine = record['engine'] as Map<String, dynamic>;
    final artifact = record['artifact'] as Map<String, dynamic>;
    final derivedVersion = MpvGithubRelease.engineVersionFromAssetName(
      artifact['assetName'] as String,
    );

    expect(engine['runtimeVersion'], derivedVersion);
    expect(bundledEngineVersion, derivedVersion);
  });
}
