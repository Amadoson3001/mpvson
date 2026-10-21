import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/diagnostic_log.dart';

void main() {
  group('MemoryDiagnosticLog', () {
    test('zero capacity records nothing without throwing', () {
      final log = MemoryDiagnosticLog(capacity: 0);

      expect(() => log.record('capture', message: 'failed'), returnsNormally);
      expect(log.records, isEmpty);
    });

    test('redacts URLs in stages and source identifiers', () {
      final log = MemoryDiagnosticLog();
      const secretUrl =
          'https://user:password@example.com/video.mp4?token=private#part';

      log.record('opened $secretUrl', sourceId: secretUrl);

      final record = jsonDecode(log.records.single) as Map<String, Object?>;
      expect(record['stage'], 'opened https://example.com/video.mp4');
      expect(record['source'], 'https://example.com/video.mp4');
      expect(log.records.single, isNot(contains('password')));
      expect(log.records.single, isNot(contains('private')));
    });

    test('limits arbitrarily long stage and source fields', () {
      final log = MemoryDiagnosticLog();

      log.record('s' * 10000, sourceId: 'f' * 10000);

      final record = jsonDecode(log.records.single) as Map<String, Object?>;
      expect((record['stage']! as String).length, 501);
      expect((record['source']! as String).length, 501);
    });
  });
}
