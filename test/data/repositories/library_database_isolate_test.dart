import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/repositories/database/library_database.dart';

void main() {
  test(
    'killing the isolate mid-query fails pending calls promptly and close() finishes quickly',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      addTearDown(() {
        if (!db.isClosed) {
          return db.close();
        }
        return Future<void>.value();
      });

      // Sanity check that the connection works before the injected failure.
      await db.executeRaw('CREATE TABLE IF NOT EXISTS probe (x INTEGER);');

      // A query that is in flight when the isolate dies.
      final pendingQuery = db.queryMedia(limit: 10);
      // Give the request a chance to be delivered to the isolate.
      await Future<void>.delayed(Duration.zero);

      // Injected failure: the database isolate dies unexpectedly.
      db.debugIsolate.kill(priority: Isolate.immediate);

      // Pending calls must error promptly instead of hanging forever.
      await expectLater(
        pendingQuery.timeout(const Duration(seconds: 2)),
        throwsStateError,
      );

      // The connection must report itself closed and fail fast.
      expect(db.isClosed, isTrue);
      await expectLater(
        db.queryMedia(limit: 1).timeout(const Duration(seconds: 2)),
        throwsStateError,
      );

      // close() must finish promptly even though the isolate is gone.
      final watch = Stopwatch()..start();
      await db.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('close() did not finish within 2 seconds'),
      );
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );

  test(
    'a healthy close handshake still completes and marks the db closed',
    () async {
      final db = await LibraryDatabase.open(inMemory: true);
      await db.executeRaw('CREATE TABLE t (x INTEGER);');

      final watch = Stopwatch()..start();
      await db.close();
      watch.stop();

      expect(db.isClosed, isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await expectLater(db.executeRaw('SELECT 1;'), throwsStateError);
    },
  );
}
