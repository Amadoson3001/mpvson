import 'dart:io';

import 'package:mpvson/data/repositories/database/library_database.dart';
import 'package:mpvson/domain/models/library_models.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'mpvson-library-close-',
  );
  final databasePath = '${directory.path}${Platform.pathSeparator}library.db';
  try {
    final first = await LibraryDatabase.open(path: databasePath);
    final folder = LibraryFolderRecord(
      path: '${directory.path}${Platform.pathSeparator}media',
      addedAt: DateTime.utc(2026, 1, 1),
    );
    await first.insertFolder(folder);
    await Future.wait<void>(<Future<void>>[first.close(), first.close()]);

    var rejectedAfterClose = false;
    try {
      await first.getFolder(folder.path);
    } on StateError {
      rejectedAfterClose = true;
    }
    if (!rejectedAfterClose) {
      throw StateError('A closed database accepted another request.');
    }

    final reopened = await LibraryDatabase.open(path: databasePath);
    final stored = await reopened.getFolder(folder.path);
    if (stored == null || stored.path != folder.path) {
      throw StateError('Database close did not preserve the committed folder.');
    }
    await reopened.markFolderAvailability(folder.path, false);
    await reopened.close();

    final verified = await LibraryDatabase.open(path: databasePath);
    final unavailable = await verified.getFolder(folder.path);
    if (unavailable?.isAvailable != false) {
      throw StateError('A reopened database could not persist a new update.');
    }
    await verified.close();
    stdout.writeln('SQLite close regression passed.');
  } finally {
    await directory.delete(recursive: true);
  }
}
