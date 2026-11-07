import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';

MediaItemRecord _record(
  String path, {
  bool isFavorite = false,
  int playCount = 0,
  DateTime? lastPlayedAt,
}) {
  final canonical = MediaEntry.canonicalSource(path);
  return MediaItemRecord(
    id: MediaEntry.canonicalSource('$path-$playCount-$isFavorite'),
    canonicalSource: canonical,
    path: path,
    kind: MediaKind.audio,
    metadata: const MediaMetadata(
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
    ),
    fileSize: 123,
    isFavorite: isFavorite,
    addedAt: DateTime.now(),
    lastPlayedAt: lastPlayedAt,
    playCount: playCount,
  );
}

void main() {
  test(
    'insertMedia re-adds a soft-deleted file and preserves play history',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      const path = r'C:\Music\song.mp3';
      final lastPlayed = DateTime.now();
      await db.insertMedia(
        _record(path, isFavorite: true, playCount: 7, lastPlayedAt: lastPlayed),
      );

      // Soft-delete the row (as removing a folder does).
      await db.executeRaw(
        'UPDATE media SET is_in_library = 0 WHERE canonical_source = ?',
        [MediaEntry.canonicalSource(path)],
      );
      final afterDelete = await db.getMediaByCanonicalSource(path);
      expect(afterDelete, isNotNull);

      // Re-adding the same file must bring it back into the library.
      await db.insertMedia(_record(path));

      final reAdded = await db.getMediaByCanonicalSource(path);
      expect(reAdded, isNotNull);
      expect(reAdded!.isFavorite, isTrue, reason: 'favorite must be preserved');
      expect(reAdded.playCount, 7, reason: 'play count must be preserved');
      expect(
        reAdded.lastPlayedAt,
        DateTime.fromMillisecondsSinceEpoch(lastPlayed.millisecondsSinceEpoch),
        reason: 'last played timestamp must be preserved',
      );
      final flags = await db.selectRaw(
        'SELECT is_in_library FROM media LIMIT 1',
      );
      expect(
        flags.single['is_in_library'],
        1,
        reason: 'the re-added row must be back in the library',
      );
    },
  );

  test(
    'batchUpsertMedia re-adds a soft-deleted file and preserves play history',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      const path = r'C:\Music\album\track02.flac';
      await db.batchUpsertMedia(<MediaItemRecord>[
        _record(path, isFavorite: true, playCount: 3),
      ]);
      await db.executeRaw(
        'UPDATE media SET is_in_library = 0 WHERE canonical_source = ?',
        [MediaEntry.canonicalSource(path)],
      );

      await db.batchUpsertMedia(<MediaItemRecord>[_record(path)]);

      final reAdded = await db.getMediaByCanonicalSource(path);
      expect(reAdded, isNotNull);
      expect(reAdded!.isFavorite, isTrue);
      expect(reAdded.playCount, 3);
      final flags = await db.selectRaw(
        'SELECT is_in_library FROM media LIMIT 1',
      );
      expect(flags.single['is_in_library'], 1);
    },
  );

  test(
    'a fresh row inserted without history still gets zeroed counters',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      await db.insertMedia(_record(r'C:\Music\new.mp3'));
      final row = await db.getMediaByCanonicalSource(r'C:\Music\new.mp3');
      expect(row, isNotNull);
      expect(row!.playCount, 0);
      expect(row.isFavorite, isFalse);
    },
  );
}
