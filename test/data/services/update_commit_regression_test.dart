import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpvson/data/services/update_service.dart';
import 'package:mpvson/domain/updates/update_manifest.dart';
import 'package:mpvson/domain/updates/update_record.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'disposal during record commit keeps the committed verified archive',
    () async {
      final directory = await Directory.systemTemp.createTemp('update-commit-');
      final artifact = utf8.encode('verified application archive');
      final client = MockClient((request) async {
        if (request.url.path == '/manifest.json') {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'version': '0.2.0',
              'engineVersion': '0.41.0',
              'artifacts': {
                'windows': {
                  'url': 'https://example.org/app.zip',
                  'sha256': sha256.convert(artifact).toString(),
                },
              },
            }),
            HttpStatus.ok,
          );
        }
        return http.Response.bytes(artifact, HttpStatus.ok);
      });
      final service = UpdateService(
        client: client,
        manifestUri: Uri.parse('https://example.org/manifest.json'),
        supportDirectoryProvider: () async => directory,
        platformProvider: () => UpdatePlatform.windows,
      );
      final overrides = _PausedRecordCommit();
      addTearDown(() async {
        service.dispose();
        client.close();
        if (!overrides.release.isCompleted) overrides.release.complete();
        await directory.delete(recursive: true);
      });

      await IOOverrides.runWithIOOverrides(() async {
        await service.check();
        final downloading = service.download();
        await overrides.committed.future.timeout(const Duration(seconds: 3));
        service.dispose();
        overrides.release.complete();
        await downloading;
      }, overrides);

      final store = UpdateOwnershipStore(
        Directory(p.join(directory.path, 'updates')),
      );
      final records = await store.loadRecords();
      expect(records, hasLength(1));
      final retainedFile = File(
        p.join(store.directory.path, records.single.fileName),
      );
      expect(await retainedFile.exists(), isTrue);
      expect(await retainedFile.readAsBytes(), artifact);
    },
  );
}

final class _PausedRecordCommit extends IOOverrides {
  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return p.basename(path).startsWith('.updates.json.') &&
            path.endsWith('.tmp')
        ? _PausedRecordFile(file, this)
        : file;
  }
}

class _PausedRecordFile implements File {
  _PausedRecordFile(this.delegate, this.owner);
  final File delegate;
  final _PausedRecordCommit owner;

  @override
  String get path => delegate.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => delegate.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  Future<File> rename(String newPath) async {
    final renamed = await delegate.rename(newPath);
    owner.committed.complete();
    await owner.release.future;
    return renamed;
  }

  @override
  Future<bool> exists() => delegate.exists();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
