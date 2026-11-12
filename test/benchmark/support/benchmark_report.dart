import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One timed operation in a library benchmark run.
class BenchmarkSample {
  BenchmarkSample({
    required this.scenario,
    required this.rowCount,
    required this.elapsedMs,
    this.rssBeforeBytes,
    this.rssAfterBytes,
    this.detail,
  });

  final String scenario;
  final int rowCount;
  final int elapsedMs;
  final int? rssBeforeBytes;
  final int? rssAfterBytes;
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'scenario': scenario,
    'rowCount': rowCount,
    'elapsedMs': elapsedMs,
    if (rssBeforeBytes != null) 'rssBeforeBytes': rssBeforeBytes,
    if (rssAfterBytes != null) 'rssAfterBytes': rssAfterBytes,
    if (detail != null) 'detail': detail,
  };
}

void printBenchmarkReport(List<BenchmarkSample> samples) {
  // ignore: avoid_print
  print('');
  // ignore: avoid_print
  print(
    '=== Library database benchmark (${samples.first.rowCount} rows context) ===',
  );
  for (final s in samples) {
    final mem = (s.rssBeforeBytes != null && s.rssAfterBytes != null)
        ? ' rssΔ=${_formatBytes(s.rssAfterBytes! - s.rssBeforeBytes!)}'
        : '';
    final extra = s.detail != null ? ' (${s.detail})' : '';
    // ignore: avoid_print
    print(
      '${s.scenario.padRight(28)} ${s.elapsedMs.toString().padLeft(8)} ms$mem$extra',
    );
  }
  // ignore: avoid_print
  print('');
}

String _formatBytes(int bytes) {
  if (bytes.abs() < 1024) return '${bytes}B';
  final kb = bytes / 1024;
  if (kb.abs() < 1024) return '${kb.toStringAsFixed(1)} KiB';
  return '${(kb / 1024).toStringAsFixed(2)} MiB';
}

Future<void> maybePersistBaseline(List<BenchmarkSample> samples) async {
  const record = bool.fromEnvironment('RECORD_BASELINE');
  if (!record || samples.isEmpty) return;

  final dir = Directory('build/benchmark');
  await dir.create(recursive: true);
  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final file = File(p.join(dir.path, 'baseline_$stamp.json'));
  final payload = <String, Object?>{
    'recordedAt': DateTime.now().toIso8601String(),
    'platform': Platform.operatingSystem,
    'samples': samples.map((s) => s.toJson()).toList(),
  };
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
  // ignore: avoid_print
  print('Wrote baseline to ${file.path}');
}
