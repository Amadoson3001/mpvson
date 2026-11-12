@Tags(['benchmark'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/library_models.dart';

import 'support/benchmark_report.dart';
import 'support/synthetic_library.dart';

/// Scale tiers for Phase 1 baselines.
const _tiers = <int>[1000, 10000, 50000];

Future<LibraryDatabase> _openDatabase() async {
  final db = await LibraryDatabase.open(inMemory: true);
  addTearDown(() {
    if (!db.isClosed) return db.close();
    return Future<void>.value();
  });
  return db;
}

Future<BenchmarkSample> _time(
  String scenario,
  int rowCount,
  Future<void> Function() action, {
  bool measureRss = false,
  String? detail,
}) async {
  if (measureRss) {
    // Let the GC settle so RSS deltas are less noisy.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final rssBefore = measureRss ? ProcessInfo.currentRss : null;
  final watch = Stopwatch()..start();
  await action();
  watch.stop();
  final rssAfter = measureRss ? ProcessInfo.currentRss : null;
  return BenchmarkSample(
    scenario: scenario,
    rowCount: rowCount,
    elapsedMs: watch.elapsedMilliseconds,
    rssBeforeBytes: rssBefore,
    rssAfterBytes: rssAfter,
    detail: detail,
  );
}

void main() {
  for (final rowCount in _tiers) {
    test('library database baseline ($rowCount rows)', () async {
      final db = await _openDatabase();
      final paths = syntheticPaths(rowCount);
      final samples = <BenchmarkSample>[];

      samples.add(
        await _time('discover_insert', rowCount, () async {
          await db.batchUpsertDiscoveredFiles(paths);
        }),
      );

      samples.add(
        await _time(
          'discover_rescan',
          rowCount,
          () async {
            await db.batchUpsertDiscoveredFiles(paths);
          },
          detail: 'same paths as insert (FTS trigger stress)',
        ),
      );

      // Warm query plans before measuring reads.
      await db.queryMedia(limit: 1);

      samples.add(
        await _time(
          'query_all_rows',
          rowCount,
          () async {
            final rows = await db.queryMedia();
            expect(rows.length, rowCount);
          },
          measureRss: true,
          detail: 'unpaged browse',
        ),
      );

      samples.add(
        await _time('query_audio_kind', rowCount, () async {
          final rows = await db.queryMedia(kind: MediaKind.audio);
          expect(rows.length, rowCount);
        }),
      );

      samples.add(
        await _time(
          'query_paged_250',
          rowCount,
          () async {
            final rows = await db.queryMedia(
              kind: MediaKind.audio,
              limit: 250,
              offset: 0,
            );
            expect(rows.length, rowCount < 250 ? rowCount : 250);
          },
          detail: 'paged browse first page',
        ),
      );

      samples.add(
        await _time('distinct_artists', rowCount, () async {
          final artists = await db.getDistinctArtists(kind: MediaKind.audio);
          expect(artists, isNotEmpty);
        }),
      );

      samples.add(
        await _time('distinct_albums', rowCount, () async {
          final albums = await db.getDistinctAlbums();
          expect(albums, isNotEmpty);
        }),
      );

      printBenchmarkReport(samples);
      await maybePersistBaseline(samples);
    });
  }
}
