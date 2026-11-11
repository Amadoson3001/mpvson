import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/library_models.dart';
import 'package:mpvson/domain/models/media_entry.dart';

LibraryFolderRecord _folder(String path) =>
    LibraryFolderRecord(path: path, addedAt: DateTime.now(), isAvailable: true);

void main() {
  test(
    'case-variant folder paths share one row on Windows',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      await db.insertFolder(_folder(r'C:\Music'));
      await db.insertFolder(_folder(r'c:\music'));
      await db.insertFolder(_folder(r'C:\MUSIC'));

      final folders = await db.getAllFolders();
      expect(
        folders.length,
        Platform.isWindows ? 1 : 3,
        reason: 'case-variant folder paths must dedupe on Windows',
      );
      if (Platform.isWindows) {
        expect(folders.single.path, 'c:\\music');
        expect(await db.getFolder(r'C:\Music'), isNotNull);
        expect(await db.getFolder(r'c:\MUSIC'), isNotNull);
      }
    },
    skip: !Platform.isWindows
        ? 'case-insensitive folder keys are a Windows behavior'
        : null,
  );

  test(
    'case-variant media sources share one row on Windows',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(db.close);

      Future<MediaItemRecord> record(String path) async {
        return MediaItemRecord(
          id: MediaEntry.canonicalSource('$path-1'),
          canonicalSource: MediaEntry.canonicalSource(path),
          path: path,
          kind: MediaKind.audio,
          addedAt: DateTime.now(),
        );
      }

      await db.insertMedia(await record(r'C:\Music\Song.mp3'));
      await db.insertMedia(await record(r'c:\music\song.MP3'));
      await db.insertMedia(await record(r'C:/Music/Song.mp3'));

      final rows = await db.selectRaw('SELECT COUNT(*) AS c FROM media');
      expect(
        rows.single['c'],
        Platform.isWindows ? 1 : 3,
        reason: 'case-variant media sources must dedupe on Windows',
      );
      if (Platform.isWindows) {
        final found = await db.getMediaByCanonicalSource(r'c:\MUSIC\SONG.mp3');
        expect(found, isNotNull);
      }
    },
    skip: !Platform.isWindows
        ? 'case-insensitive media keys are a Windows behavior'
        : null,
  );
}
