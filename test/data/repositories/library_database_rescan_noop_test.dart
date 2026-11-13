import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/media_entry.dart';

Future<int> _updateCount(LibraryDatabase db) async {
  final rows = await db.selectRaw(
    'SELECT count(*) AS c FROM update_probe',
    const [],
  );
  return rows.single['c']! as int;
}

void main() {
  test(
    'identical discover rescan skips media UPDATE while genuine changes update',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      await db.executeRaw('CREATE TABLE update_probe (n INTEGER)');
      await db.executeRaw(
        'CREATE TRIGGER update_probe_t AFTER UPDATE ON media BEGIN '
        'INSERT INTO update_probe (n) VALUES (1); END',
      );

      const path = r'C:\bench\Artist - Title.mp3';
      final canonical = MediaEntry.canonicalSource(path);

      await db.batchUpsertDiscoveredFiles([path]);
      expect(await _updateCount(db), 0);

      // Rescanning identical path must not fire an UPDATE on media.
      await db.batchUpsertDiscoveredFiles([path]);
      expect(await _updateCount(db), 0);

      // Genuine state transitions must still update the row.
      await db.executeRaw(
        'UPDATE media SET is_available = 0 WHERE canonical_source = ?',
        [canonical],
      );
      await db.executeRaw('DELETE FROM update_probe');
      await db.batchUpsertDiscoveredFiles([path]);
      expect(await _updateCount(db), 1);

      await db.executeRaw(
        'UPDATE media SET is_in_library = 0 WHERE canonical_source = ?',
        [canonical],
      );
      await db.executeRaw('DELETE FROM update_probe');
      await db.batchUpsertDiscoveredFiles([path]);
      expect(await _updateCount(db), 1);

      // Path casing change with identical canonical key must update path.
      await db.executeRaw('DELETE FROM update_probe');
      await db.batchUpsertDiscoveredFiles([r'C:\bench\artist - title.mp3']);
      expect(await _updateCount(db), 1);

      // Missing artist gets backfilled from filename on rescan, while
      // non-"artist - title" paths with NULL artist remain a no-op.
      await db.executeRaw(
        'UPDATE media SET artist = NULL WHERE canonical_source = ?',
        [canonical],
      );
      await db.executeRaw('DELETE FROM update_probe');
      await db.batchUpsertDiscoveredFiles([r'C:\bench\artist - title.mp3']);
      expect(await _updateCount(db), 1);

      const plainPath = r'C:\bench\Instrumental.mp3';
      await db.executeRaw('DELETE FROM update_probe');
      await db.batchUpsertDiscoveredFiles([plainPath]);
      expect(await _updateCount(db), 0);
      await db.batchUpsertDiscoveredFiles([plainPath]);
      expect(await _updateCount(db), 0);
    },
  );
}
