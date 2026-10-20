import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/session_progress.dart';

void main() {
  group('SessionProgress', () {
    test('round-trips through JSON', () {
      const progress = SessionProgress(
        revision: 7,
        entryId: 'queue-first',
        position: Duration(minutes: 12, seconds: 30),
        duration: Duration(hours: 2),
      );

      final restored = SessionProgress.tryFromJson(progress.toJson());

      expect(restored, isNotNull);
      expect(restored!.revision, 7);
      expect(restored.entryId, 'queue-first');
      expect(restored.position, const Duration(minutes: 12, seconds: 30));
      expect(restored.duration, const Duration(hours: 2));
      expect(restored.isEmpty, isFalse);
    });

    test('writes the schema version this release reads', () {
      expect(
        const SessionProgress().toJson()['version'],
        SessionProgress.schemaVersion,
      );
    });

    test('rejects a checkpoint written by a newer release', () {
      final json = const SessionProgress(
        revision: 1,
        entryId: 'queue-first',
        position: Duration(seconds: 5),
      ).toJson();
      json['version'] = SessionProgress.schemaVersion + 1;

      expect(SessionProgress.tryFromJson(json), isNull);
    });

    test('rejects a checkpoint that names no entry', () {
      expect(
        SessionProgress.tryFromJson(const SessionProgress().toJson()),
        isNull,
      );
      expect(
        SessionProgress.tryFromJson(<String, Object?>{
          'version': SessionProgress.schemaVersion,
          'revision': 4,
          'entryId': '',
        }),
        isNull,
      );
    });

    test('clamps a stored duration and a position beyond it', () {
      final restored = SessionProgress.tryFromJson(<String, Object?>{
        'version': SessionProgress.schemaVersion,
        'revision': 3,
        'entryId': 'queue-first',
        'positionMs': MediaEntry.maximumStoredMilliseconds * 2,
        'durationMs': MediaEntry.maximumStoredMilliseconds * 3,
      });

      expect(restored, isNotNull);
      expect(
        restored!.duration.inMilliseconds,
        MediaEntry.maximumStoredMilliseconds,
      );
      expect(restored.position, restored.duration);
    });

    test('treats unusable numbers as zero instead of overflowing', () {
      final restored = SessionProgress.tryFromJson(<String, Object?>{
        'version': SessionProgress.schemaVersion,
        'revision': double.nan,
        'entryId': 'queue-first',
        'positionMs': -5000,
        'durationMs': 'not a number',
      });

      expect(restored, isNotNull);
      expect(restored!.revision, 0);
      expect(restored.position, Duration.zero);
      expect(restored.duration, Duration.zero);
    });

    test('keeps a position while no duration is known yet', () {
      final restored = SessionProgress.tryFromJson(<String, Object?>{
        'version': SessionProgress.schemaVersion,
        'revision': 1,
        'entryId': 'queue-first',
        'positionMs': 9000,
      });

      expect(restored!.position, const Duration(seconds: 9));
      expect(restored.duration, Duration.zero);
    });
  });
}
