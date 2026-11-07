// Tests for engine-provenance digest acceptance (B-2 remediation).
//
// The pinned record must accept the upstream `memberSha256` OR the recorded
// `strippedMemberSha256` for the bundled libmpv-2.dll, because the release
// build strips the module with llvm-strip. `refresh` must clear the recorded
// stripped digest whenever the member digest changes.
//
// These tests are pure Dart; they do not launch processes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/engine_provenance.dart';

const String memberSha =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String strippedSha =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const String unrelatedSha =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

Map<String, Object?> recordWith({
  String? memberSha256 = memberSha,
  Object? topLevelStripped,
  Object? artifactStripped,
}) {
  return <String, Object?>{
    'schemaVersion': 1,
    'strippedMemberSha256': ?topLevelStripped,
    'artifact': <String, Object?>{
      'member': 'libmpv-2.dll',
      'memberSha256': ?memberSha256,
      'strippedMemberSha256': ?artifactStripped,
    },
  };
}

void main() {
  group('pinnedModuleDigests', () {
    test('accepts the upstream member digest', () {
      expect(pinnedModuleDigests(recordWith()), <String>[memberSha]);
    });

    test('also accepts a top-level stripped digest', () {
      final List<String> digests = pinnedModuleDigests(
        recordWith(topLevelStripped: strippedSha),
      );
      expect(digests, <String>[memberSha, strippedSha]);
    });

    test('also accepts an artifact-level stripped digest', () {
      final List<String> digests = pinnedModuleDigests(
        recordWith(artifactStripped: strippedSha),
      );
      expect(digests, <String>[memberSha, strippedSha]);
    });

    test('deduplicates identical digests', () {
      final List<String> digests = pinnedModuleDigests(
        recordWith(topLevelStripped: memberSha),
      );
      expect(digests, <String>[memberSha]);
    });

    test('ignores malformed digest values', () {
      final List<String> digests = pinnedModuleDigests(
        recordWith(
          memberSha256: null,
          topLevelStripped: 'not-a-digest',
          artifactStripped: 42,
        ),
      );
      expect(digests, isEmpty);
    });
  });

  group('bundleMatchesPinnedEngine', () {
    test('matches the upstream member digest', () {
      expect(bundleMatchesPinnedEngine(recordWith(), memberSha), isTrue);
    });

    test('matches a recorded stripped digest', () {
      expect(
        bundleMatchesPinnedEngine(
          recordWith(topLevelStripped: strippedSha),
          strippedSha,
        ),
        isTrue,
      );
    });

    test('rejects an unrelated digest', () {
      expect(
        bundleMatchesPinnedEngine(
          recordWith(topLevelStripped: strippedSha),
          unrelatedSha,
        ),
        isFalse,
      );
    });
  });

  group('inventoryMatchesPinnedEngine (simulated stripped build)', () {
    List<Map<String, Object?>> bundleFiles(String engineSha256) {
      return <Map<String, Object?>>[
        <String, Object?>{
          'path': 'libmpv-2.dll',
          'size': 100,
          'sha256': engineSha256,
          'role': 'engine',
        },
        <String, Object?>{
          'path': 'd3dcompiler_47.dll',
          'size': 10,
          'sha256': unrelatedSha,
          'role': 'renderer-companion',
        },
      ];
    }

    test('reports a match when the engine member is the stripped module', () {
      // The release build strips libmpv-2.dll, so the bundled digest differs
      // from the upstream member digest; the recorded stripped digest must
      // still validate it.
      final Map<String, Object?> record = recordWith(
        topLevelStripped: strippedSha,
      );
      expect(
        inventoryMatchesPinnedEngine(record, bundleFiles(strippedSha)),
        isTrue,
      );
    });

    test('reports a match for the unstripped upstream member', () {
      expect(
        inventoryMatchesPinnedEngine(recordWith(), bundleFiles(memberSha)),
        isTrue,
      );
    });

    test('reports no match when neither digest is present', () {
      final Map<String, Object?> record = recordWith(
        topLevelStripped: strippedSha,
      );
      expect(
        inventoryMatchesPinnedEngine(record, bundleFiles(unrelatedSha)),
        isFalse,
      );
    });
  });

  group('clearStaleStrippedDigests', () {
    test('clears stale stripped digests when the member digest changed', () {
      final Map<String, Object?> record = recordWith(
        topLevelStripped: strippedSha,
        artifactStripped: strippedSha,
      );
      final int removed = clearStaleStrippedDigests(
        record,
        previousMemberSha256: memberSha,
        newMemberSha256: 'd' * 64,
      );
      expect(removed, 2);
      expect(record.containsKey('strippedMemberSha256'), isFalse);
      expect(
        (record['artifact']! as Map<String, Object?>).containsKey(
          'strippedMemberSha256',
        ),
        isFalse,
      );
      // The new member digest itself is untouched.
      expect(
        (record['artifact']! as Map<String, Object?>)['memberSha256'],
        memberSha,
      );
    });

    test('keeps the stripped digest when the member digest is unchanged', () {
      final Map<String, Object?> record = recordWith(
        topLevelStripped: strippedSha,
      );
      final int removed = clearStaleStrippedDigests(
        record,
        previousMemberSha256: memberSha,
        newMemberSha256: memberSha,
      );
      expect(removed, 0);
      expect(record['strippedMemberSha256'], strippedSha);
    });

    test('clears when the previous member digest is unknown', () {
      final Map<String, Object?> record = recordWith(
        topLevelStripped: strippedSha,
      );
      expect(clearStaleStrippedDigests(record, newMemberSha256: 'd' * 64), 1);
      expect(record.containsKey('strippedMemberSha256'), isFalse);
    });
  });

  group('tracked engine record', () {
    test('exposes a member digest and valid stripped digest', () {
      final File recordFile = File('packaging/windows/engine-provenance.json');
      if (!recordFile.existsSync()) {
        fail('Missing tracked engine record: ${recordFile.path}');
      }
      final Map<String, Object?> record =
          jsonDecode(recordFile.readAsStringSync()) as Map<String, Object?>;
      final List<String> digests = pinnedModuleDigests(record);
      final Object? memberSha256 =
          (record['artifact']! as Map<String, Object?>)['memberSha256'];
      expect(digests, contains(memberSha256));
      for (final String digest in digests) {
        expect(digest, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
      // A stripped release bundle must verify against the tracked record.
      final Object? stripped = record['strippedMemberSha256'];
      if (stripped is String) {
        expect(bundleMatchesPinnedEngine(record, stripped), isTrue);
      }
    });
  });
}
