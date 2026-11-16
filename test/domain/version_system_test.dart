import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/app_version.dart';
import 'package:mpvson/domain/updates/semantic_version.dart';
import 'package:path/path.dart' as p;

import '../../tool/version.dart' as version_tool;

void main() {
  group('App version system', () {
    test('repository version files stay synchronized', () {
      final problems = version_tool.checkRepositoryVersions(
        Directory.current.path,
      );
      expect(problems, isEmpty);

      final pubspec = version_tool.readPubspecVersion(Directory.current.path);
      expect(AppVersion.pubspecVersion, pubspec.full);
      expect(AppVersion.defaultSemantic, pubspec.semantic);
      expect(AppVersion.buildNumber, pubspec.buildNumber);
      expect(AppVersion.current, pubspec.semantic);
      expect(() => SemanticVersion.parse(AppVersion.current), returnsNormally);
    });

    test(
      'computeBumpedVersion handles major, minor, patch, and build bumps',
      () {
        final base = version_tool.ParsedPubspecVersion.parse('0.1.0+1');

        final patch = version_tool.computeBumpedVersion(
          base,
          version_tool.BumpKind.patch,
        );
        expect(patch.full, '0.1.1+2');

        final minor = version_tool.computeBumpedVersion(
          patch,
          version_tool.BumpKind.minor,
        );
        expect(minor.full, '0.2.0+3');

        final major = version_tool.computeBumpedVersion(
          minor,
          version_tool.BumpKind.major,
          prerelease: 'rc.1',
          resetBuild: true,
        );
        expect(major.full, '1.0.0-rc.1+1');

        final build = version_tool.computeBumpedVersion(
          major,
          version_tool.BumpKind.build,
        );
        expect(build.full, '1.0.0-rc.1+2');
      },
    );

    test(
      'syncRepositoryVersions repairs drifted files in a workspace copy',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'mpvson-version-test-',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        File(p.join(tempDir.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('name: mpvson\nversion: 1.2.3+9\n');
        File(p.join(tempDir.path, 'lib/domain/updates/app_version.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            File('lib/domain/updates/app_version.dart').readAsStringSync(),
          );
        File(p.join(tempDir.path, 'lib/domain/updates/bundled_engine.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            File('lib/domain/updates/bundled_engine.dart').readAsStringSync(),
          );
        File(p.join(tempDir.path, 'packaging/windows/installer.iss'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            File('packaging/windows/installer.iss').readAsStringSync(),
          );
        File(p.join(tempDir.path, 'packaging/windows/README.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            File('packaging/windows/README.txt').readAsStringSync(),
          );
        File(p.join(tempDir.path, 'packaging/windows/engine-provenance.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            File('packaging/windows/engine-provenance.json').readAsStringSync(),
          );

        expect(version_tool.checkRepositoryVersions(tempDir.path), isNotEmpty);

        final updated = version_tool.syncRepositoryVersions(tempDir.path);
        expect(
          updated,
          containsAll(<String>[
            'lib/domain/updates/app_version.dart',
            'packaging/windows/installer.iss',
            'packaging/windows/README.txt',
          ]),
        );
        expect(version_tool.checkRepositoryVersions(tempDir.path), isEmpty);
      },
    );
  });
}
