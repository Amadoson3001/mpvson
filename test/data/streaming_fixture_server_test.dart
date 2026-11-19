import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/streaming_fixture_server.dart';

void main() {
  late StreamingFixtureServer server;
  late http.Client client;

  setUp(() async {
    server = await StreamingFixtureServer.startServer();
    client = http.Client();
  });

  tearDown(() async {
    client.close();
    await server.stop();
  });

  group('StreamingFixtureServer - Lifecycle & Ledger', () {
    test('starts and reports valid address and port', () {
      expect(server.isRunning, isTrue);
      expect(server.port, greaterThan(0));
      expect(server.address.isLoopback, isTrue);
      expect(server.baseUrl, 'http://127.0.0.1:${server.port}');
      expect(
        server.urlFor('/video.mp4').toString(),
        'http://127.0.0.1:${server.port}/video.mp4',
      );
    });

    test('records incoming requests in ledger with metadata', () async {
      final target = server.urlFor('/video.mp4', {'test': '123'});
      final response = await client.get(
        target,
        headers: {'X-Test-Header': 'mpvson-fixture'},
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(server.requestCount, 1);

      final recorded = server.lastRequest;
      expect(recorded, isNotNull);
      expect(recorded!.method, 'GET');
      expect(recorded.path, '/video.mp4');
      expect(recorded.queryParameters['test'], '123');
      expect(recorded.header('x-test-header'), 'mpvson-fixture');
      expect(recorded.hasHeader('x-test-header'), isTrue);
      expect(recorded.clientIp, isNotEmpty);
      expect(recorded.timestamp, isNotNull);
    });

    test('filters requests by path and clears ledger', () async {
      await client.get(server.urlFor('/video.mp4'));
      await client.get(server.urlFor('/hls/master.m3u8'));
      await client.get(server.urlFor('/video.mp4'));

      expect(server.requestCount, 3);
      expect(server.requestsFor('/video.mp4'), hasLength(2));
      expect(server.requestsFor('/hls/master.m3u8'), hasLength(1));
      expect(server.lastRequestFor('/video.mp4')!.path, '/video.mp4');

      server.clearLedger();
      expect(server.requestCount, 0);
      expect(server.ledger, isEmpty);
      expect(server.lastRequest, isNull);
    });
  });

  group('StreamingFixtureServer - Media Routes & Atoms', () {
    test('serves fast-start MP4 with ftyp and moov before mdat', () async {
      final response = await client.get(server.urlFor('/video.mp4'));

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'video/mp4');
      expect(response.headers['accept-ranges'], 'bytes');

      final bytes = response.bodyBytes;
      expect(bytes.length, server.videoMp4Bytes.length);

      // Verify atom layout: ftyp at offset 4, moov before mdat
      final ftypTag = utf8.decode(bytes.sublist(4, 8));
      expect(ftypTag, 'ftyp');

      final ftypSize = ByteData.sublistView(bytes).getUint32(0); // typically 32
      final moovTag = utf8.decode(bytes.sublist(ftypSize + 4, ftypSize + 8));
      expect(moovTag, 'moov');

      final moovSize = ByteData.sublistView(bytes).getUint32(ftypSize);
      final mdatOffset = ftypSize + moovSize;
      final mdatTag = utf8.decode(
        bytes.sublist(mdatOffset + 4, mdatOffset + 8),
      );
      expect(mdatTag, 'mdat');
    });

    test(
      'serves extensionless MP4 route with video/mp4 content type',
      () async {
        final response = await client.get(server.urlFor('/media/stream-1234'));

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['content-type'], 'video/mp4');
        expect(response.headers['accept-ranges'], 'bytes');
        expect(response.bodyBytes, equals(server.videoMp4Bytes));
      },
    );

    test('handles HEAD requests without returning body', () async {
      final request = http.Request('HEAD', server.urlFor('/video.mp4'));
      final streamed = await client.send(request);
      final response = await http.Response.fromStream(streamed);

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'video/mp4');
      expect(response.headers['accept-ranges'], 'bytes');
      expect(
        response.headers['content-length'],
        server.videoMp4Bytes.length.toString(),
      );
      expect(response.bodyBytes, isEmpty);
    });
  });

  group('StreamingFixtureServer - Byte Range Requests (RFC 7233)', () {
    test('serves closed byte range (start-end)', () async {
      final response = await client.get(
        server.urlFor('/video.mp4'),
        headers: {'Range': 'bytes=0-99'},
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers['accept-ranges'], 'bytes');
      expect(
        response.headers['content-range'],
        'bytes 0-99/${server.videoMp4Bytes.length}',
      );
      expect(response.headers['content-length'], '100');
      expect(response.bodyBytes, server.videoMp4Bytes.sublist(0, 100));

      final recorded = server.lastRequest;
      expect(recorded?.rangeHeader, 'bytes=0-99');
      expect(recorded?.requestedRange, const ByteRange(0, 99));
    });

    test('serves open prefix range (start-)', () async {
      final total = server.videoMp4Bytes.length;
      final start = total - 50;
      final response = await client.get(
        server.urlFor('/video.mp4'),
        headers: {'Range': 'bytes=$start-'},
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers['content-range'],
        'bytes $start-${total - 1}/$total',
      );
      expect(response.headers['content-length'], '50');
      expect(response.bodyBytes, server.videoMp4Bytes.sublist(start, total));
    });

    test('serves suffix range (-suffix)', () async {
      final total = server.videoMp4Bytes.length;
      final response = await client.get(
        server.urlFor('/video.mp4'),
        headers: {'Range': 'bytes=-80'},
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers['content-range'],
        'bytes ${total - 80}-${total - 1}/$total',
      );
      expect(response.headers['content-length'], '80');
      expect(
        response.bodyBytes,
        server.videoMp4Bytes.sublist(total - 80, total),
      );
    });

    test('clamps range when end exceeds resource length', () async {
      final total = server.videoMp4Bytes.length;
      final response = await client.get(
        server.urlFor('/video.mp4'),
        headers: {'Range': 'bytes=10-${total + 1000}'},
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers['content-range'], 'bytes 10-${total - 1}/$total');
      expect(response.bodyBytes, server.videoMp4Bytes.sublist(10, total));
    });

    test('returns 416 Range Not Satisfiable for out of bounds range', () async {
      final total = server.videoMp4Bytes.length;
      final response = await client.get(
        server.urlFor('/video.mp4'),
        headers: {'Range': 'bytes=${total + 100}-${total + 200}'},
      );

      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(response.headers['content-range'], 'bytes */$total');
      expect(response.bodyBytes, isEmpty);
    });

    test(
      'returns 416 Range Not Satisfiable for invalid range (start > end)',
      () async {
        final response = await client.get(
          server.urlFor('/video.mp4'),
          headers: {'Range': 'bytes=50-20'},
        );

        expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
        expect(
          response.headers['content-range'],
          'bytes */${server.videoMp4Bytes.length}',
        );
      },
    );

    test(
      'simulates server that ignores range when ignoreRangeRequests is true',
      () async {
        server.ignoreRangeRequests = true;
        final response = await client.get(
          server.urlFor('/video.mp4'),
          headers: {'Range': 'bytes=0-99'},
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.bodyBytes.length, server.videoMp4Bytes.length);
        expect(response.headers['content-range'], isNull);
      },
    );
  });

  group('StreamingFixtureServer - Bandwidth Shaping & Throttling', () {
    test('shapes transfer rate with transferDelayPerChunk', () async {
      server.chunkSize = 512;
      server.transferDelayPerChunk = const Duration(milliseconds: 20);
      final stopwatch = Stopwatch()..start();
      final response = await client.get(
        server.urlFor('/video.mp4'),
        headers: {'Range': 'bytes=0-1535'}, // 3 chunks of 512 bytes
      );
      stopwatch.stop();

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.bodyBytes.length, 1536);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(35));
    });

    test('throttles transfer rate with throttleBytesPerSecond', () async {
      server.throttleBytesPerSecond = 5000; // 5 KB/s
      server.chunkSize = 500;
      final stopwatch = Stopwatch()..start();
      final response = await client.get(
        server.urlFor('/video.mp4'),
        headers: {'Range': 'bytes=0-999'}, // 1000 bytes ~ 200ms
      );
      stopwatch.stop();

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.bodyBytes.length, 1000);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(80));
    });

    test('delays response when pauseBeforeResponse is configured', () async {
      server.pauseBeforeResponse = const Duration(milliseconds: 100);
      final stopwatch = Stopwatch()..start();
      final response = await client.get(server.urlFor('/video.mp4'));
      stopwatch.stop();

      expect(response.statusCode, HttpStatus.ok);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(90));
    });

    test('un-stalls hanging request via resumeStall()', () async {
      Future<http.Response>? pendingRequest;
      try {
        pendingRequest = client.get(server.urlFor('/stalled'));
        // Give the request a moment to reach the server and stall
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Unblock via server API
        server.resumeStall();

        final response = await pendingRequest;
        expect(response.statusCode, HttpStatus.ok);
      } finally {
        if (pendingRequest != null) {
          await pendingRequest.catchError((_) => http.Response('', 500));
        }
      }
    });
  });

  group('StreamingFixtureServer - Redirects & Expiration', () {
    test('redirects with default 302 to /video.mp4', () async {
      final request = http.Request('GET', server.urlFor('/redirect'))
        ..followRedirects = false;
      final streamed = await client.send(request);
      final response = await http.Response.fromStream(streamed);

      expect(response.statusCode, HttpStatus.found);
      expect(response.headers['location'], '/video.mp4');
    });

    test('redirects with custom status and target', () async {
      final request = http.Request(
        'GET',
        server.urlFor('/redirect', {
          'to': '/media/stream-1234',
          'status': '307',
        }),
      )..followRedirects = false;
      final streamed = await client.send(request);
      final response = await http.Response.fromStream(streamed);

      expect(response.statusCode, HttpStatus.temporaryRedirect);
      expect(response.headers['location'], '/media/stream-1234');
    });

    test('validates signed URL with valid unexpired token', () async {
      final futureExpiry =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
      final response = await client.get(
        server.urlFor('/signed', {
          'token': 'valid-token',
          'expires': futureExpiry.toString(),
        }),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['status'], 'ok');
    });

    test('rejects expired signed URL with 403 Forbidden', () async {
      final pastExpiry = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 300;
      final response = await client.get(
        server.urlFor('/signed', {
          'token': 'valid-token',
          'expires': pastExpiry.toString(),
        }),
      );

      expect(response.statusCode, HttpStatus.forbidden);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      expect(body['error'], 'Forbidden');
    });

    test('rejects signed URL with incorrect token', () async {
      final futureExpiry =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
      final response = await client.get(
        server.urlFor('/signed', {
          'token': 'invalid-secret',
          'expires': futureExpiry.toString(),
        }),
      );

      expect(response.statusCode, HttpStatus.forbidden);
    });

    test('serves media on signed URL when media=true', () async {
      final futureExpiry =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
      final response = await client.get(
        server.urlFor('/signed', {
          'token': 'valid-token',
          'expires': futureExpiry.toString(),
          'media': 'true',
        }),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'video/mp4');
      expect(response.bodyBytes, equals(server.videoMp4Bytes));
    });
  });

  group('StreamingFixtureServer - HLS Routes', () {
    test(
      'serves valid HLS master playlist with audio, subtitles, and video renditions',
      () async {
        final response = await client.get(server.urlFor('/hls/master.m3u8'));

        expect(response.statusCode, HttpStatus.ok);
        expect(
          response.headers['content-type'],
          contains('application/vnd.apple.mpegurl'),
        );

        final text = response.body;
        expect(text, startsWith('#EXTM3U'));
        // Audio rendition group
        expect(text, contains('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac"'));
        // Subtitle rendition group
        expect(text, contains('#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs"'));
        // Video streams with RESOLUTION, BANDWIDTH, CODECS
        expect(text, contains('RESOLUTION=640x360'));
        expect(text, contains('BANDWIDTH=800000'));
        expect(text, contains('360p.m3u8'));
        expect(text, contains('RESOLUTION=1280x720'));
        expect(text, contains('BANDWIDTH=2500000'));
        expect(text, contains('720p.m3u8'));
        expect(text, contains('RESOLUTION=1920x1080'));
        expect(text, contains('BANDWIDTH=5000000'));
        expect(text, contains('1080p.m3u8'));
      },
    );

    test('serves HLS variant playlist with VOD segment references', () async {
      final response = await client.get(server.urlFor('/hls/720p.m3u8'));

      expect(response.statusCode, HttpStatus.ok);
      final text = response.body;
      expect(text, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
      expect(text, contains('#EXT-X-TARGETDURATION:6'));
      expect(text, contains('seg-720p-0.ts'));
      expect(text, contains('seg-720p-1.ts'));
      expect(text, contains('#EXT-X-ENDLIST'));
    });

    test('serves rolling live HLS playlist with sliding sequence', () async {
      server.liveSequence = 10;
      server.liveWindowSize = 3;

      var response = await client.get(server.urlFor('/hls/live.m3u8'));
      var text = response.body;
      expect(text, contains('#EXT-X-MEDIA-SEQUENCE:10'));
      expect(text, contains('seg-live-10.ts'));
      expect(text, contains('seg-live-11.ts'));
      expect(text, contains('seg-live-12.ts'));
      expect(text, isNot(contains('#EXT-X-ENDLIST')));

      // Advance sequence manually
      server.advanceLiveSequence(5);
      response = await client.get(server.urlFor('/hls/live.m3u8'));
      text = response.body;
      expect(text, contains('#EXT-X-MEDIA-SEQUENCE:15'));
      expect(text, contains('seg-live-15.ts'));
      expect(text, isNot(contains('seg-live-10.ts')));

      // Test auto-advance
      server.autoAdvanceLiveSequence = true;
      response = await client.get(server.urlFor('/hls/live.m3u8'));
      expect(response.body, contains('#EXT-X-MEDIA-SEQUENCE:15'));
      response = await client.get(server.urlFor('/hls/live.m3u8'));
      expect(response.body, contains('#EXT-X-MEDIA-SEQUENCE:16'));
    });

    test('serves MPEG-TS segments with sync bytes', () async {
      final response = await client.get(server.urlFor('/hls/seg-360p-0.ts'));

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], 'video/mp2t');
      final bytes = response.bodyBytes;
      expect(bytes, hasLength(server.tsSegmentBytes.length));
      // First byte of every 188-byte packet is sync byte 0x47
      expect(bytes[0], 0x47);
      expect(bytes[188], 0x47);
    });

    test('serves WebVTT subtitles', () async {
      final response = await client.get(server.urlFor('/hls/subs_en.vtt'));

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers['content-type'], contains('text/vtt'));
      expect(response.body, startsWith('WEBVTT'));
    });
  });

  group('StreamingFixtureServer - DASH MPD Manifest', () {
    test(
      'serves valid DASH MPD manifest with video and audio AdaptationSets',
      () async {
        final response = await client.get(server.urlFor('/dash/manifest.mpd'));

        expect(response.statusCode, HttpStatus.ok);
        expect(
          response.headers['content-type'],
          contains('application/dash+xml'),
        );

        final xml = response.body;
        expect(xml, contains('<MPD'));
        expect(xml, contains('minBufferTime="PT2S"'));
        expect(xml, contains('<Period'));
        // Video AdaptationSet
        expect(xml, contains('contentType="video"'));
        expect(
          xml,
          contains(
            'Representation id="v-360p" bandwidth="800000" width="640" height="360"',
          ),
        );
        expect(
          xml,
          contains(
            'Representation id="v-720p" bandwidth="2500000" width="1280" height="720"',
          ),
        );
        // Audio AdaptationSet
        expect(xml, contains('contentType="audio"'));
        expect(xml, contains('Representation id="a-en"'));
      },
    );
  });

  group('StreamingFixtureServer - Error, Stalled, & Abort Routes', () {
    test('returns standard HTTP error status codes', () async {
      for (final code in [403, 404, 408, 429, 500, 503]) {
        final response = await client.get(server.urlFor('/error/$code'));
        expect(response.statusCode, code);
        if (code == 429) {
          expect(response.headers['retry-after'], '5');
        } else if (code == 503) {
          expect(response.headers['retry-after'], '2');
        }
      }
    });

    test('handles stalled route with delay query param', () async {
      final stopwatch = Stopwatch()..start();
      final response = await client.get(
        server.urlFor('/stalled', {'delayMs': '150'}),
      );
      stopwatch.stop();

      expect(response.statusCode, HttpStatus.ok);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(140));
    });

    test('abruptly terminates connection on /abort', () async {
      // Direct raw socket or HttpClient will detect abrupt disconnect
      final rawClient = HttpClient();
      try {
        final request = await rawClient.getUrl(server.urlFor('/abort'));
        final response = await request.close();
        await expectLater(
          response.drain<void>(),
          throwsA(isA<HttpException>()),
        );
      } finally {
        rawClient.close(force: true);
      }
    });

    test('supports custom route registration', () async {
      server.registerRoute('/custom/data', (req) async {
        req.response.statusCode = HttpStatus.accepted;
        req.response.write('custom response');
        await req.response.close();
      });

      final response = await client.get(server.urlFor('/custom/data'));
      expect(response.statusCode, HttpStatus.accepted);
      expect(response.body, 'custom response');
    });
  });
}
