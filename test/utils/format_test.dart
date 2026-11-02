import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/utils/format.dart';

void main() {
  group('formatDuration', () {
    test('0 seconds', () {
      expect(formatDuration(Duration.zero), '00:00');
      expect(formatDuration(Duration.zero, compactMinutes: true), '0:00');
    });

    test('59 seconds', () {
      expect(formatDuration(const Duration(seconds: 59)), '00:59');
      expect(
        formatDuration(const Duration(seconds: 59), compactMinutes: true),
        '0:59',
      );
    });

    test('60 seconds', () {
      expect(formatDuration(const Duration(seconds: 60)), '01:00');
      expect(
        formatDuration(const Duration(seconds: 60), compactMinutes: true),
        '1:00',
      );
    });

    test('3599 seconds (59 minutes 59 seconds)', () {
      expect(formatDuration(const Duration(seconds: 3599)), '59:59');
      expect(
        formatDuration(const Duration(seconds: 3599), compactMinutes: true),
        '59:59',
      );
    });

    test('3600 seconds (1 hour exact)', () {
      expect(formatDuration(const Duration(seconds: 3600)), '1:00:00');
      expect(
        formatDuration(const Duration(seconds: 3600), compactMinutes: true),
        '1:00:00',
      );
    });

    test('100 hours', () {
      expect(formatDuration(const Duration(hours: 100)), '100:00:00');
      expect(
        formatDuration(const Duration(hours: 100, minutes: 5, seconds: 9)),
        '100:05:09',
      );
    });

    test('negative durations', () {
      expect(formatDuration(-const Duration(seconds: 45)), '-00:45');
      expect(
        formatDuration(-const Duration(seconds: 45), compactMinutes: true),
        '-0:45',
      );
      expect(
        formatDuration(-const Duration(minutes: 5, seconds: 23)),
        '-05:23',
      );
      expect(
        formatDuration(-const Duration(hours: 1, minutes: 2, seconds: 3)),
        '-1:02:03',
      );
      expect(formatDuration(-const Duration(hours: 100)), '-100:00:00');
      expect(formatDuration(-const Duration(milliseconds: 500)), '-00:00');
      expect(
        formatDuration(
          -const Duration(milliseconds: 500),
          compactMinutes: true,
        ),
        '-0:00',
      );
    });
  });

  group('formatTime alias', () {
    test('matches formatDuration', () {
      expect(formatTime(const Duration(seconds: 75)), '01:15');
      expect(
        formatTime(const Duration(seconds: 75), compactMinutes: true),
        '1:15',
      );
      expect(formatTime(const Duration(hours: 2, seconds: 5)), '2:00:05');
    });
  });

  group('formatDurationSeconds', () {
    test('floating and integer seconds', () {
      expect(formatDurationSeconds(0), '00:00');
      expect(formatDurationSeconds(0, compactMinutes: true), '0:00');
      expect(formatDurationSeconds(59.4), '00:59');
      // 59.6 seconds has 59 whole seconds elapsed (media player truncation)
      expect(formatDurationSeconds(59.6), '00:59');
      expect(formatDurationSeconds(60.0), '01:00');
      expect(formatDurationSeconds(3600.0), '1:00:00');
      expect(formatDurationSeconds(-12.4), '-00:12');
    });
  });

  group('formatDurationMs', () {
    test('converts milliseconds properly', () {
      expect(formatDurationMs(0), '00:00');
      expect(formatDurationMs(1500), '00:01');
      expect(formatDurationMs(60000), '01:00');
      expect(formatDurationMs(3600000), '1:00:00');
      expect(formatDurationMs(-3661000), '-1:01:01');
    });
  });

  group('formatFileSize', () {
    test('formats binary sizes with appropriate unit', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(-100), '0 B');
      expect(formatFileSize(512), '512.0 B');
      expect(formatFileSize(1024), '1.0 KB');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(1048576), '1.0 MB');
      expect(formatFileSize(1073741824), '1.0 GB');
      expect(formatFileSize(1099511627776), '1.0 TB');
    });
  });
}
