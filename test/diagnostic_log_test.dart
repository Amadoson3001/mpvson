import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/diagnostic_log.dart';

void main() {
  group('diagnostic URL redaction', () {
    test('redacts embedded URLs from source, message, and error fields', () {
      final log = MemoryDiagnosticLog();

      log.record(
        'thumbnail',
        sourceId: 'worker https://user:pw@example.test/a?token=SOURCE_SECRET',
        message:
            'load(https://user:password@example.test/video?token=REVIEW_SECRET)',
        error: StateError('failed at https://u:p@example.test/b#ERROR_SECRET'),
      );

      final record = jsonDecode(log.records.single) as Map<String, Object?>;
      final serialized = log.records.single;

      expect(record['source'], contains('https://example.test/a'));
      expect(record['message'], contains('load(https://example.test/video)'));
      expect(record['error'], contains('https://example.test/b'));
      for (final secret in <String>[
        'SOURCE_SECRET',
        'REVIEW_SECRET',
        'ERROR_SECRET',
        'password',
        'user:pw',
      ]) {
        expect(serialized, isNot(contains(secret)), reason: secret);
      }
    });

    test('redacts before message truncation', () {
      final log = MemoryDiagnosticLog();
      final prefix = List<String>.filled(438, 'x').join();
      final message =
          '${prefix}load(https://user:password@example.test/video?token=REVIEW_SECRET)';

      log.record('thumbnail', message: message);

      final record = log.records.single;
      expect(record, contains('https://example.test/video'));
      expect(record, isNot(contains('token=')));
      expect(record, isNot(contains('REVIEW')));
      expect(record, isNot(contains('password')));
    });
  });
}
