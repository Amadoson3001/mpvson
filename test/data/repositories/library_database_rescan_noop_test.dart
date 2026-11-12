import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/media_entry.dart';

Future<int> _ftsRowCount(LibraryDatabase db) async {
  final rows = await db.selectRaw(
    'SELECT count(*) AS c FROM media_fts',
    const [],
  );
  return rows.single['c']! as int;
}

void main() {
  test(
    'identical discover rescan skips row update and avoids FTS churn',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      const path = r'C:\bench\Artist - Title.mp3';
      final canonical = MediaEntry.canonicalSource(path);

      await db.batchUpsertDiscoveredFiles([path]);
      final afterInsert = await db.selectRaw(
        'SELECT added_at FROM media WHERE canonical_source = ?',
        [canonical],
      );
      final addedAt = afterInsert.single['added_at'] as int;
      final ftsAfterInsert = await _ftsRowCount(db);

      await db.batchUpsertDiscoveredFiles([path]);
      final afterRescan = await db.selectRaw(
        'SELECT added_at FROM media WHERE canonical_source = ?',
        [canonical],
      );
      final ftsAfterRescan = await _ftsRowCount(db);

      expect(afterRescan.single['added_at'], addedAt);
      expect(ftsAfterRescan, ftsAfterInsert);
    },
  );
}
