import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/engine_release.dart';
import 'package:mpvson/domain/updates/mpv_github_release.dart';

const _repoReleaseUrl =
    'https://github.com/mpv-player/mpv/releases/tag/git-release';
const _assetPathPrefix =
    'https://github.com/mpv-player/mpv/releases/download/git-release/';
const _stableAssetPathPrefix =
    'https://github.com/mpv-player/mpv/releases/download/v0.41.0/';
final _sha256 = List<String>.filled(64, 'a').join();

void main() {
  group('MpvGithubRelease', () {
    test('selects only the x64 GPL libmpv ZIP', () {
      final eligibleName = _assetName(run: '39050261656');
      final assets = <Map<String, Object?>>[
        {'name': _assetName(run: '39050261656', arch: 'aarch64')},
        {'name': _assetName(run: '39050261656', flavor: 'lgpl')},
        {'name': _assetName(run: '39050261656', suffix: '-v3')},
        {'name': 'mpv-x86_64-w64-mingw32-gpl-installer.exe'},
        _asset(eligibleName),
      ];

      final release = _parse(_releaseJson(assets: assets, prerelease: true));

      expect(release.engineVersion, '0.41.0-dev.39050261656+g01e2533f3');
      expect(release.downloadUri.toString(), '$_assetPathPrefix$eligibleName');
      expect(release.sha256, _sha256);
      expect(release.notes, 'mpv development build');
    });

    test('chooses the greatest workflow run for the same engine version', () {
      final older = _assetName(run: '39050261655', hash: '01e2533f2');
      final newer = _assetName(run: '39050261656', hash: '01e2533f3');

      final release = _parse(
        _releaseJson(assets: [_asset(newer), _asset(older)]),
      );

      expect(release.engineVersion, '0.41.0-dev.39050261656+g01e2533f3');
      expect(release.downloadUri.path.endsWith(newer), isTrue);
    });

    test('rejects duplicate builds with equal SemVer precedence', () {
      final first = _assetName(run: '39050261656', hash: '01e2533f3');
      final second = _assetName(run: '39050261656', hash: '01e2533f4');

      expect(
        () => _parse(_releaseJson(assets: [_asset(first), _asset(second)])),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects another repository, tag, or draft response', () {
      final asset = _asset(_assetName(run: '39050261656'));
      final cases = <String, String Function()>{
        'repository': () => _releaseJson(
          assets: [asset],
          htmlUrl:
              'https://github.com/someone-else/mpv/releases/tag/git-release',
        ),
        'tag': () => _releaseJson(assets: [asset], tag: 'stable'),
        'draft': () => _releaseJson(assets: [asset], draft: true),
      };

      for (final entry in cases.entries) {
        expect(
          () => _parse(entry.value()),
          throwsA(isA<FormatException>()),
          reason: 'should reject a response with a wrong ${entry.key}',
        );
      }
    });

    test(
      'rejects package metadata without a valid digest, size, or upload state',
      () {
        final name = _assetName(run: '39050261656');
        final missingDigest = _asset(name)..remove('digest');
        final wrongDigest = _asset(name)..['digest'] = 'sha512:$_sha256';
        final missingSize = _asset(name)..remove('size');
        final invalidSize = _asset(name)..['size'] = 0;
        final missingState = _asset(name)..remove('state');
        final incompleteState = _asset(name)..['state'] = 'new';
        final cases = <String, Map<String, Object?>>{
          'missing digest': missingDigest,
          'wrong digest algorithm': wrongDigest,
          'missing size': missingSize,
          'non-positive size': invalidSize,
          'missing upload state': missingState,
          'incomplete upload': incompleteState,
        };

        for (final entry in cases.entries) {
          expect(
            () => _parse(_releaseJson(assets: [entry.value])),
            throwsA(isA<FormatException>()),
            reason: 'should reject ${entry.key}',
          );
        }
      },
    );

    test('recognizes a stable tag with no compatible libmpv package', () {
      final release = MpvGithubRelease.parseLatestStable(
        _stableReleaseJson(
          assets: [
            {'name': 'mpv-v0.41.0-x86_64-w64-mingw32.zip'},
          ],
        ),
        appVersion: '1.0.0',
        mediaKitVersion: '1.2.6',
      );

      expect(release.version, '0.41.0');
      expect(release.engineRelease, isNull);
    });

    test('selects only the stable x64 GPL libmpv ZIP', () {
      final name = 'libmpv-v0.41.0-x86_64-w64-mingw32-gpl.zip';
      final release = MpvGithubRelease.parseLatestStable(
        _stableReleaseJson(
          assets: [
            {'name': 'mpv-v0.41.0-x86_64-w64-mingw32.zip'},
            _stableAsset(name),
          ],
        ),
        appVersion: '1.0.0',
        mediaKitVersion: '1.2.6',
      );

      expect(release.version, '0.41.0');
      expect(release.engineRelease?.engineVersion, '0.41.0');
      expect(
        release.engineRelease?.downloadUri.toString(),
        '$_stableAssetPathPrefix$name',
      );
      expect(release.engineRelease?.sha256, _sha256);
      expect(release.engineRelease?.sizeBytes, 64944819);
    });

    test('rejects a development tag as a stable release', () {
      expect(
        () => MpvGithubRelease.parseLatestStable(
          _stableReleaseJson(
            assets: const [],
            tag: 'git-release',
            htmlUrl:
                'https://github.com/mpv-player/mpv/releases/tag/git-release',
          ),
          appVersion: '1.0.0',
          mediaKitVersion: '1.2.6',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires stable package size and SHA-256 metadata', () {
      final name = 'libmpv-v0.41.0-x86_64-w64-mingw32-gpl.zip';
      final missingDigest = _stableAsset(name)..remove('digest');
      final wrongDigest = _stableAsset(name)..['digest'] = 'sha512:$_sha256';
      final missingSize = _stableAsset(name)..remove('size');

      for (final asset in [missingDigest, wrongDigest, missingSize]) {
        expect(
          () => MpvGithubRelease.parseLatestStable(
            _stableReleaseJson(assets: [asset]),
            appVersion: '1.0.0',
            mediaKitVersion: '1.2.6',
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });
  });
}

String _assetName({
  String run = '39050261656',
  String hash = '01e2533f3',
  String arch = 'x86_64',
  String flavor = 'gpl',
  String suffix = '',
}) {
  return 'libmpv-v0.41.0-dev-g$hash-$run-$arch-w64-mingw32-$flavor$suffix.zip';
}

Map<String, Object?> _asset(
  String name, {
  String? digest,
  Object? size = 64944819,
  Object? state = 'uploaded',
}) {
  return {
    'name': name,
    'state': state,
    'size': size,
    'digest': digest ?? 'sha256:$_sha256',
    'browser_download_url': '$_assetPathPrefix$name',
  };
}

String _releaseJson({
  required List<Map<String, Object?>> assets,
  String tag = 'git-release',
  String htmlUrl = _repoReleaseUrl,
  bool draft = false,
  bool prerelease = true,
}) {
  return jsonEncode({
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'html_url': htmlUrl,
    'body': 'mpv development build',
    'assets': assets,
  });
}

EngineRelease _parse(String source) => MpvGithubRelease.parse(
  source,
  appVersion: '1.0.0',
  mediaKitVersion: '1.2.6',
);

String _stableReleaseJson({
  required List<Map<String, Object?>> assets,
  String tag = 'v0.41.0',
  String? htmlUrl,
  bool draft = false,
  bool prerelease = false,
}) {
  return jsonEncode({
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'html_url':
        htmlUrl ?? 'https://github.com/mpv-player/mpv/releases/tag/$tag',
    'body': 'Stable mpv release',
    'assets': assets,
  });
}

Map<String, Object?> _stableAsset(String name) => {
  'name': name,
  'state': 'uploaded',
  'size': 64944819,
  'digest': 'sha256:$_sha256',
  'browser_download_url': '$_stableAssetPathPrefix$name',
};
