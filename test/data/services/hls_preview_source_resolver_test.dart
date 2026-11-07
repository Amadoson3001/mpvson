import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/hls_preview_source_resolver.dart';

const Duration _timeout = Duration(seconds: 10);

Future<HttpServer> _serveManifest(String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
    );
    request.response.write(body);
    await request.response.close();
  });
  return server;
}

void main() {
  test('skips unparseable variant lines instead of throwing', () async {
    final server = await _serveManifest(
      '#EXTM3U\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1280x720,CODECS="avc1.640028"\n'
      'http://[::1\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=640000,RESOLUTION=640x360,CODECS="avc1.42e00a"\n'
      '/low/variant.m3u8\n',
    );
    addTearDown(server.close);

    final result = await HlsPreviewSourceResolver().resolve(
      'http://127.0.0.1:${server.port}/master.m3u8',
      timeout: _timeout,
    );

    expect(result, isNotNull);
    expect(result!.path, '/low/variant.m3u8');
  });

  test('unparseable master URL resolves to null', () async {
    final result = await HlsPreviewSourceResolver().resolve(
      'http://[::1',
      timeout: _timeout,
    );
    expect(result, isNull);
  });

  test('non-manifest body resolves to null', () async {
    final server = await _serveManifest('<html>not a playlist</html>');
    addTearDown(server.close);

    final result = await HlsPreviewSourceResolver().resolve(
      'http://127.0.0.1:${server.port}/master.m3u8',
      timeout: _timeout,
    );
    expect(result, isNull);
  });

  test('picks the lowest-bandwidth video variant', () async {
    final server = await _serveManifest(
      '#EXTM3U\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028"\n'
      'high.m3u8\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=320x180,CODECS="avc1.42e00a"\n'
      'low.m3u8\n',
    );
    addTearDown(server.close);

    final result = await HlsPreviewSourceResolver().resolve(
      'http://127.0.0.1:${server.port}/master.m3u8',
      timeout: _timeout,
    );

    expect(result, isNotNull);
    expect(result!.path, '/low.m3u8');
  });

  test('UTF-8 manifests decode with the rest of the pipeline intact', () async {
    final body = utf8.encode(
      '#EXTM3U\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480,CODECS="avc1.42e00a"\n'
      'single.m3u8\n',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.add(body);
      await request.response.close();
    });

    final result = await HlsPreviewSourceResolver().resolve(
      'http://127.0.0.1:${server.port}/master.m3u8',
      timeout: _timeout,
    );

    expect(result, isNotNull);
    expect(result!.path, '/single.m3u8');
  });
}
