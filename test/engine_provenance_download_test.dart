import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../tool/verified_artifact_download.dart';

void main() {
  late Directory directory;
  late File destination;
  final bytes = <int>[1, 2, 3, 4];
  final digest = sha256.convert(bytes).toString();
  final uri = Uri.parse(
    'https://github.com/mpv-player/mpv/releases/download/pin/libmpv.zip',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'mpvson-provenance-test-',
    );
    destination = File('${directory.path}/pinned.zip');
    await destination.writeAsString('previous verified artifact');
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> run(
    http.Client client, {
    int? size,
    String? hash,
    Duration idle = const Duration(seconds: 1),
    Duration deadline = const Duration(seconds: 2),
  }) async {
    try {
      await downloadProvenanceArtifact(
        client: client,
        uri: uri,
        destination: destination,
        expectedSize: size ?? bytes.length,
        expectedSha256: hash ?? digest,
        idleTimeout: idle,
        deadline: deadline,
      );
    } finally {
      client.close();
    }
  }

  Future<void> expectPreserved() async {
    expect(await destination.readAsString(), 'previous verified artifact');
    expect(
      await directory.list().length,
      1,
      reason: 'Private partial files must be removed.',
    );
  }

  test(
    'replaces the cache only after checking streamed bytes and hash',
    () async {
      await run(
        MockClient.streaming((request, _) async {
          expect(request.followRedirects, isFalse);
          return http.StreamedResponse(
            Stream.fromIterable([bytes.sublist(0, 2), bytes.sublist(2)]),
            200,
          );
        }),
      );
      expect(await destination.readAsBytes(), bytes);
      expect(await directory.list().length, 1);
    },
  );

  test(
    'rejects chunked overflow before persisting the oversized chunk',
    () async {
      await expectLater(
        run(
          MockClient.streaming(
            (_, _) async => http.StreamedResponse(
              Stream.fromIterable([
                bytes,
                <int>[5],
              ]),
              200,
            ),
          ),
        ),
        throwsA(isA<HttpException>()),
      );
      await expectPreserved();
    },
  );

  test(
    'rejects short bodies, wrong hashes and Content-Length mismatches',
    () async {
      for (final response in <http.StreamedResponse>[
        http.StreamedResponse(Stream.value(bytes.sublist(1)), 200),
        http.StreamedResponse(Stream.value(<int>[4, 3, 2, 1]), 200),
        http.StreamedResponse(Stream.value(bytes), 200, contentLength: 5),
      ]) {
        await expectLater(
          run(MockClient.streaming((_, _) async => response)),
          throwsA(isA<HttpException>()),
        );
        await expectPreserved();
      }
    },
  );

  test('follows a bounded HTTPS GitHub asset redirect', () async {
    var requests = 0;
    await run(
      MockClient.streaming((request, _) async {
        requests++;
        if (requests == 1) {
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {
              'location':
                  'https://release-assets.githubusercontent.com/asset/pinned.zip',
            },
          );
        }
        expect(request.url.host, 'release-assets.githubusercontent.com');
        return http.StreamedResponse(Stream.value(bytes), 200);
      }),
    );
    expect(requests, 2);
    expect(await destination.readAsBytes(), bytes);
  });

  test('rejects downgrade, foreign host and credential redirects', () async {
    for (final target in <String>[
      'http://github.com/asset.zip',
      'https://github.com.evil.test/asset.zip',
      'https://user:secret@github.com/asset.zip',
    ]) {
      var requests = 0;
      await expectLater(
        run(
          MockClient.streaming((_, _) async {
            requests++;
            return http.StreamedResponse(
              const Stream.empty(),
              302,
              headers: {'location': target},
            );
          }),
        ),
        throwsA(isA<HttpException>()),
      );
      expect(requests, 1);
      await expectPreserved();
    }
  });

  test('bounds redirect loops', () async {
    var requests = 0;
    await expectLater(
      run(
        MockClient.streaming((_, _) async {
          requests++;
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {'location': '/loop'},
          );
        }),
      ),
      throwsA(isA<HttpException>()),
    );
    expect(requests, 5);
    await expectPreserved();
  });

  test(
    'times out a stalled request and removes its partial directory',
    () async {
      final pending = Completer<http.StreamedResponse>();
      await expectLater(
        run(
          MockClient.streaming((_, _) => pending.future),
          idle: const Duration(milliseconds: 30),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await expectPreserved();
      pending.complete(http.StreamedResponse(const Stream.empty(), 200));
    },
  );

  test('times out a stalled body and cancels its stream', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    await expectLater(
      run(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(stream.stream, 200),
        ),
        idle: const Duration(milliseconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(cancelled, isTrue);
    await stream.close();
    await expectPreserved();
  });

  test('rejects invalid pins before requesting or writing anything', () async {
    for (final size in <int>[0, -1, 512 * 1024 * 1024 + 1]) {
      await expectLater(
        run(
          MockClient.streaming(
            (_, _) async => throw StateError('must not request'),
          ),
          size: size,
        ),
        throwsArgumentError,
      );
      await expectPreserved();
    }
  });

  test(
    'enforces the total deadline even while body chunks keep arriving',
    () async {
      var cancelled = false;
      Timer? writer;
      late StreamController<List<int>> stream;
      stream = StreamController<List<int>>(
        onListen: () {
          writer = Timer.periodic(
            const Duration(milliseconds: 10),
            (_) => stream.add(<int>[]),
          );
        },
        onCancel: () {
          cancelled = true;
          writer?.cancel();
        },
      );
      // Empty chunks count as activity but must not extend the overall deadline.
      try {
        await expectLater(
          run(
            MockClient.streaming(
              (_, _) async => http.StreamedResponse(stream.stream, 200),
            ),
            idle: const Duration(milliseconds: 100),
            deadline: const Duration(milliseconds: 45),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(cancelled, isTrue);
        await expectPreserved();
      } finally {
        writer?.cancel();
        await stream.close();
      }
    },
  );
}
