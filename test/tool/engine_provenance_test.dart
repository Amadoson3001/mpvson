import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/engine_provenance.dart';

void main() {
  group('writeEngineFileAtomically', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'mpvson-engine-provenance-test-',
      );
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('replaces the destination without leftover temporary files', () async {
      final destination = File(p.join(directory.path, 'engine-record.json'));
      await destination.writeAsString('old', flush: true);

      await writeEngineFileAtomically(destination, utf8.encode('new record'));

      expect(await destination.readAsString(), 'new record');
      expect(
        directory.listSync().where(
          (entry) => p.basename(entry.path).endsWith('.tmp'),
        ),
        isEmpty,
      );
    });

    test(
      'leaves an existing destination untouched when the write fails',
      () async {
        // A directory at the destination makes the final rename fail after the
        // temporary file has been written.
        final destination = Directory(
          p.join(directory.path, 'engine-record.json'),
        )..createSync();
        var failed = false;

        try {
          await writeEngineFileAtomically(
            File(destination.path),
            utf8.encode('replacement'),
          );
        } on FileSystemException {
          failed = true;
        }

        expect(failed, isTrue);
        expect(destination.existsSync(), isTrue);
        expect(
          directory.listSync().where(
            (entry) => p.basename(entry.path).endsWith('.tmp'),
          ),
          isEmpty,
        );
      },
    );
  });
}
