import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/thumbnail_service.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'a player factory failure does not strand later decoder requests',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'mpvson-thumbnail-service-test-',
      );
      final source = File(p.join(temporary.path, 'source.mp4'));
      await source.writeAsBytes(<int>[1, 2, 3]);

      var factoryCalls = 0;
      final service = MediaKitThumbnailService(
        cacheDirectory: Directory(p.join(temporary.path, 'cache')),
        operationTimeout: const Duration(milliseconds: 200),
        requestTimeoutGrace: const Duration(milliseconds: 200),
        playerFactory: () {
          factoryCalls++;
          throw StateError('Native player initialization failed');
        },
      );
      addTearDown(() async {
        await service.dispose().timeout(const Duration(seconds: 2));
        await temporary.delete(recursive: true);
      });

      final entry = MediaEntry.fromPath(source.path, id: 'source');
      expect(
        await service.load(entry).timeout(const Duration(seconds: 2)),
        isNull,
      );
      expect(
        await service.load(entry).timeout(const Duration(seconds: 2)),
        isNull,
      );
      expect(factoryCalls, 2);
    },
  );
}
