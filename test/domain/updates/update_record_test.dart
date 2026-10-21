import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/updates/update_record.dart';
import 'package:path/path.dart' as p;

void main() {
  group('UpdateOwnershipStore', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'mpvson-update-record-test-',
      );
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('reuses a verified bundle when refreshing its record fails', () async {
      final store = UpdateOwnershipStore(directory);
      final bundle = File(p.join(directory.path, 'bundle.zip'));
      await bundle.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final hash = await UpdateOwnershipStore.computeSha256(bundle);
      await store.recordVerifiedDownload(
        version: '1.2.0',
        sha256: hash,
        bundleFile: bundle,
      );

      // Loading the record succeeds, but persisting the refreshed timestamp
      // fails. The already verified bundle must still be reused.
      final failingStore = UpdateOwnershipStore(
        _FailingCreateDirectory(directory.path),
      );
      final reused = await failingStore.findMatchingVerifiedBundle(
        version: '1.2.0',
        sha256: hash,
      );

      expect(reused?.path, bundle.path);
    });

    test('does not reuse a cached bundle whose contents changed', () async {
      final store = UpdateOwnershipStore(directory);
      final bundle = File(p.join(directory.path, 'bundle.zip'));
      await bundle.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final hash = await UpdateOwnershipStore.computeSha256(bundle);
      await store.recordVerifiedDownload(
        version: '1.2.0',
        sha256: hash,
        bundleFile: bundle,
      );

      await bundle.writeAsBytes(<int>[5, 6, 7, 8], flush: true);

      expect(
        await store.findMatchingVerifiedBundle(version: '1.2.0', sha256: hash),
        isNull,
      );
    });

    test('returns null when the recorded bundle is missing', () async {
      final store = UpdateOwnershipStore(directory);
      final bundle = File(p.join(directory.path, 'bundle.zip'));
      await bundle.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final hash = await UpdateOwnershipStore.computeSha256(bundle);
      await store.recordVerifiedDownload(
        version: '1.2.0',
        sha256: hash,
        bundleFile: bundle,
      );
      await bundle.delete();

      expect(
        await store.findMatchingVerifiedBundle(version: '1.2.0', sha256: hash),
        isNull,
      );
    });
  });
}

/// A [Directory] whose creation always fails while still exposing the real
/// path for reads. This makes a record-save failure deterministic.
final class _FailingCreateDirectory implements Directory {
  _FailingCreateDirectory(this.path);

  @override
  final String path;

  @override
  Future<Directory> create({bool recursive = false}) async {
    throw const FileSystemException('Injected record save failure.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
