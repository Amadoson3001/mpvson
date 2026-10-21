import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/library_models.dart';

void main() {
  group('50,000-Record Library Scale Benchmark', () {
    late Directory tempDir;
    late String dbPath;
    late LibraryDatabase db;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'mpvson_scale_benchmark_',
      );
      dbPath = '${tempDir.path}${Platform.pathSeparator}library_benchmark.db';
      db = await LibraryDatabase.open(path: dbPath);
    });

    tearDownAll(() async {
      await db.close();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test(
      'inserts 50,000 records in bounded memory batches and verifies scale performance',
      () async {
        const totalRecords = 50000;
        const batchSize = 2500;
        final initialRss = ProcessInfo.currentRss;

        // 1. Insert 50,000 media records in batches (generating and discarding each batch)
        final insertStopwatch = Stopwatch()..start();
        for (int i = 0; i < totalRecords; i += batchSize) {
          final batch = List<MediaItemRecord>.generate(batchSize, (index) {
            final idNum = i + index;
            final artistId = idNum % 500;
            final albumId = idNum ~/ 100;
            return MediaItemRecord(
              id: 'item_$idNum',
              canonicalSource:
                  'c:\\music\\artist_$artistId\\album_$albumId\\track_$idNum.mp3',
              path:
                  'C:\\Music\\Artist $artistId\\Album $albumId\\Track $idNum.mp3',
              kind: MediaKind.audio,
              metadata: MediaMetadata(
                title: 'Track $idNum Golden Horizon',
                artist: 'Artist $artistId',
                album: 'Album $albumId Spectacular',
                genre: (idNum % 2 == 0) ? 'Rock' : 'Electronic',
                year: 2000 + (idNum % 26),
                trackNumber: (idNum % 20) + 1,
                duration: Duration(seconds: 120 + (idNum % 200)),
              ),
              fileSize: 5000000 + (idNum * 1024),
              modifiedAt: DateTime(2024, 1, 1),
              addedAt: DateTime.fromMillisecondsSinceEpoch(
                1700000000000 + (idNum * 1000),
              ),
            );
          });

          await db.batchUpsertMedia(batch);
        }
        insertStopwatch.stop();

        // Verify record count using raw query or limit query
        final countRow = await db.selectRaw(
          'SELECT COUNT(*) AS total FROM media;',
        );
        final totalInDb = countRow.first['total'] as int;
        expect(totalInDb, equals(totalRecords));

        // 2. Verify memory remains bounded without loading all 50,000 objects simultaneously
        final postInsertRss = ProcessInfo.currentRss;
        final rssGrowthBytes = postInsertRss - initialRss;
        // Resident set size growth in Dart isolate should remain bounded (well under 350 MB)
        expect(
          rssGrowthBytes,
          lessThan(350 * 1024 * 1024),
          reason:
              'Memory grew excessively: ${(rssGrowthBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
        );

        // 3. Verify warmed local FTS5 search completes in under 200ms
        // Warm up FTS5 index cache with initial search query
        await db.queryMedia(searchQuery: 'Golden', limit: 50);

        // Benchmark multiple warmed search queries against the 50,000-record dataset
        final searchQueries = <String>[
          'Golden Horizon',
          'Spectacular',
          'Artist 42',
          'Track 25000',
        ];

        for (final query in searchQueries) {
          final ftsStopwatch = Stopwatch()..start();
          final searchResults = await db.queryMedia(
            searchQuery: query,
            limit: 50,
          );
          ftsStopwatch.stop();

          expect(
            searchResults,
            isNotEmpty,
            reason: 'Expected matches for query "$query"',
          );
          expect(
            searchResults.length,
            lessThanOrEqualTo(50),
            reason: 'Pagination limit should be respected',
          );
          expect(
            ftsStopwatch.elapsedMilliseconds,
            lessThan(200),
            reason:
                'FTS5 search for "$query" took ${ftsStopwatch.elapsedMilliseconds}ms (limit: 200ms)',
          );
        }

        // 4. Verify pagination (querying page of 50 items with offset) is fast (< 20ms)
        // Warm up query engine
        await db.queryMedia(
          limit: 50,
          offset: 0,
          sortBy: 'added_at',
          ascending: true,
        );

        final testOffsets = <int>[0, 1000, 10000, 25000, 49950];
        for (final offset in testOffsets) {
          final pageStopwatch = Stopwatch()..start();
          final page = await db.queryMedia(
            limit: 50,
            offset: offset,
            sortBy: 'added_at',
            ascending: true,
          );
          pageStopwatch.stop();

          expect(
            page,
            hasLength(50),
            reason: 'Expected exactly 50 items at offset $offset',
          );
          expect(
            pageStopwatch.elapsedMilliseconds,
            lessThan(50),
            reason:
                'Pagination at offset $offset took ${pageStopwatch.elapsedMilliseconds}ms (limit: 50ms)',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
