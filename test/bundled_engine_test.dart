import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/bundled_engine.dart';
import 'package:mpvson/domain/updates/mpv_github_release.dart';

void main() {
  test('bundled engine identity matches the pinned build record', () {
    final record =
        jsonDecode(
              File(
                'packaging/windows/engine-provenance.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final engine = record['engine'] as Map<String, dynamic>;
    final artifact = record['artifact'] as Map<String, dynamic>;

    expect(engine['runtimeVersion'], bundledEngineVersion);
    expect(
      MpvGithubRelease.engineVersionFromAssetName(
        artifact['assetName'] as String,
      ),
      bundledEngineVersion,
    );
  });
}
