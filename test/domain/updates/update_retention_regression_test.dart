import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/update_record.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'retains the current download after the system clock moves backward',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'update-retention-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = UpdateOwnershipStore(directory);
      final previous = <UpdateRecord>[];
      for (var index = 0; index < 2; index++) {
        final file = File(p.join(directory.path, 'old-$index.zip'));
        await file.writeAsBytes([index + 1]);
        previous.add(
          UpdateRecord(
            version: '1.$index.0',
            sha256: await UpdateOwnershipStore.computeSha256(file),
            fileName: p.basename(file.path),
            recordedAt: DateTime.utc(2100, 1, index + 1),
            fileSizeBytes: 1,
          ),
        );
      }
      await store.saveRecords(previous);
      final current = File(p.join(directory.path, 'current.zip'));
      await current.writeAsBytes([3]);

      await store.recordVerifiedDownload(
        version: '1.2.0',
        sha256: await UpdateOwnershipStore.computeSha256(current),
        bundleFile: current,
      );

      expect(await current.exists(), isTrue);
      final retained = await store.loadRecords();
      expect(
        retained.map((record) => record.fileName),
        contains('current.zip'),
      );
      expect(retained, hasLength(UpdateOwnershipStore.maxRetainedArchives));
    },
  );
}
