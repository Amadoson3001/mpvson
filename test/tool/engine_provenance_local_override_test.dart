// Tests for the machine-local engine override written by `sync-active`
// (tool/engine_provenance.dart B-1 remediation).
//
// `sync-active` must never write into the tracked
// packaging/windows/engine-provenance.json: the active in-app module has no
// verifiable upstream provenance (it may even be a locally stripped build), so
// its digests only belong in the untracked windows/libmpv local override.
//
// These tests exercise the pure record builder; they do not launch processes.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/engine_provenance.dart';

void main() {
  group('buildLocalEngineOverride', () {
    final Map<String, Object?> override = buildLocalEngineOverride(
      version: '0.42.0',
      member: 'libmpv-2.dll',
      memberSha256:
          'b2514a19e714ba44a205d9dfd424d8fd6964c43e8dcaf0ad3d6816a1aafae926',
      memberSize: 123456,
      generatedAt: DateTime.utc(2026, 11, 5, 12, 30),
    );

    test('marks the record as a machine-local sync-active override', () {
      expect(override['schemaVersion'], 1);
      expect(override['source'], 'sync-active');
      expect(override['generatedAt'], '2026-11-05T12:30:00.000Z');
    });

    test('describes the engine in the same version vocabulary as the pin', () {
      final Object? engine = override['engine'];
      expect(engine, isA<Map<String, Object?>>());
      final Map<String, Object?> engineSection =
          engine! as Map<String, Object?>;
      expect(engineSection['version'], 'v0.42.0');
      expect(engineSection['describeVersion'], 'v0.42.0');
      expect(engineSection['runtimeVersion'], '0.42.0');
      expect(engineSection['baseVersion'], '0.42.0');
    });

    test('records the local module digest and size', () {
      final Object? artifact = override['artifact'];
      expect(artifact, isA<Map<String, Object?>>());
      final Map<String, Object?> artifactSection =
          artifact! as Map<String, Object?>;
      expect(artifactSection['member'], 'libmpv-2.dll');
      expect(
        artifactSection['memberSha256'],
        'b2514a19e714ba44a205d9dfd424d8fd6964c43e8dcaf0ad3d6816a1aafae926',
      );
      expect(artifactSection['memberSize'], 123456);
    });

    test('never fabricates upstream artifact provenance', () {
      // The old sync-active wrote a made-up release URL plus the previous
      // archive digest into the tracked record, which broke CMake and verify.
      final Map<String, Object?> artifactSection =
          override['artifact']! as Map<String, Object?>;
      expect(artifactSection.containsKey('url'), isFalse);
      expect(artifactSection.containsKey('assetName'), isFalse);
      expect(artifactSection.containsKey('sha256'), isFalse);
      expect(artifactSection.containsKey('licenseSha256'), isFalse);
      expect(override.containsKey('url'), isFalse);
      expect(jsonEncode(override), isNot(contains('releases/download')));
    });

    test(
      'keeps the intended in-app default version for deliberate follow-up',
      () {
        expect(override['bundledEngineVersion'], '0.42.0');
      },
    );
  });

  group('localEngineOverrideRelative', () {
    test('points at an untracked windows/ local file, never at the pin', () {
      expect(
        localEngineOverrideRelative,
        'windows/libmpv/engine-provenance.local.json',
      );
      expect(localEngineOverrideRelative, isNot(contains('packaging')));
    });
  });
}
