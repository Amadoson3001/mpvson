import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mpvson/data/services/stream_manifest_service.dart';
import 'package:mpvson/domain/models/stream_rendition.dart';

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.handlers);

  final List<FutureOr<http.StreamedResponse> Function(http.BaseRequest request)>
  handlers;
  final List<Uri> requested = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requested.add(request.url);
    if (handlers.isEmpty) {
      fail('Unexpected request to ${request.url}');
    }
    return await handlers.removeAt(0)(request);
  }
}

http.StreamedResponse _response(
  int status, {
  String? body,
  List<int>? bytes,
  Map<String, String>? headers,
  String? location,
  String? contentType,
}) {
  final h = <String, String>{...?headers};
  if (location != null) h['location'] = location;
  if (contentType != null) h['content-type'] = contentType;
  final data = bytes ?? (body != null ? utf8.encode(body) : const <int>[]);
  return http.StreamedResponse(Stream.value(data), status, headers: h);
}

void main() {
  group('StreamRendition and StreamManifestInfo models', () {
    test('StreamRendition properties, equality, and copyWith', () {
      const rendition = StreamRendition(
        id: '1080p',
        label: '1080p',
        width: 1920,
        height: 1080,
        bitrate: 5000000,
        frameRate: 60.0,
        codec: 'avc1.64002a',
        url: 'https://cdn.example.com/1080p.m3u8',
        isAuto: false,
        isMuxed: true,
      );

      expect(rendition.id, '1080p');
      expect(rendition.label, '1080p');
      expect(rendition.width, 1920);
      expect(rendition.height, 1080);
      expect(rendition.bitrate, 5000000);
      expect(rendition.frameRate, 60.0);
      expect(rendition.codec, 'avc1.64002a');
      expect(rendition.url, 'https://cdn.example.com/1080p.m3u8');
      expect(rendition.isAuto, isFalse);
      expect(rendition.isMuxed, isTrue);
      expect(rendition.hasVideo, isTrue);

      final copy = rendition.copyWith(bitrate: 6000000);
      expect(copy.bitrate, 6000000);
      expect(copy.width, 1920);
      expect(copy, isNot(equals(rendition)));

      expect(StreamRendition.auto.isAuto, isTrue);
      expect(StreamRendition.auto.label, 'Auto');
    });

    test('StreamManifestInfo properties, equality, and fallback', () {
      final info = StreamManifestInfo(
        masterUrl: 'https://cdn.example.com/master.m3u8',
        format: StreamFormat.hls,
        isLive: true,
        variants: const [
          StreamRendition(id: '720p', label: '720p', height: 720),
        ],
        audioGroups: const ['audio-en'],
        subtitleGroups: const ['subs-en'],
        hasSeparateAudio: true,
        hasUnsupportedDrm: false,
      );

      expect(info.masterUrl, 'https://cdn.example.com/master.m3u8');
      expect(info.format, StreamFormat.hls);
      expect(info.isLive, isTrue);
      expect(info.variants.length, 1);
      expect(info.audioGroups, ['audio-en']);
      expect(info.subtitleGroups, ['subs-en']);
      expect(info.hasSeparateAudio, isTrue);
      expect(info.hasUnsupportedDrm, isFalse);

      final fallback = StreamManifestInfo.directFallback(
        'https://example.com/video.mp4',
      );
      expect(fallback.format, StreamFormat.direct);
      expect(fallback.masterUrl, 'https://example.com/video.mp4');
      expect(fallback.isLive, isFalse);
      expect(fallback.variants.single.label, 'Default');
      expect(fallback.variants.single.url, 'https://example.com/video.mp4');
    });
  });

  group('StreamManifestService - HLS Parsing', () {
    late StreamManifestService service;

    setUp(() {
      service = StreamManifestService();
    });

    test(
      'parses master playlist with multiple video renditions, resolutions, codecs, bitrates',
      () {
        const playlist = '''
#EXTM3U
#EXT-X-VERSION:4
#EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=4500000,RESOLUTION=1920x1080,FRAME-RATE=60.000,CODECS="avc1.64002a,mp4a.40.2"
1080p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,FRAME-RATE=30.000,CODECS="avc1.4d401f,mp4a.40.2"
720p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,FRAME-RATE=24.000,CODECS="avc1.42e01e,mp4a.40.2"
360p/index.m3u8
''';

        final baseUri = Uri.parse('https://cdn.example.com/live/master.m3u8');
        final manifest = service.parseHls(playlist, baseUri);

        expect(manifest.format, StreamFormat.hls);
        expect(manifest.isLive, isFalse);
        expect(manifest.hasSeparateAudio, isFalse);
        expect(manifest.variants.length, 3);

        final r1080 = manifest.variants[0];
        expect(r1080.id, '1080p');
        expect(r1080.label, '1080p');
        expect(r1080.width, 1920);
        expect(r1080.height, 1080);
        expect(r1080.bitrate, 4500000); // AVERAGE-BANDWIDTH preferred
        expect(r1080.frameRate, 60.0);
        expect(r1080.codec, 'avc1.64002a,mp4a.40.2');
        expect(r1080.url, 'https://cdn.example.com/live/1080p/index.m3u8');
        expect(r1080.isMuxed, isTrue);

        final r720 = manifest.variants[1];
        expect(r720.id, '720p');
        expect(r720.label, '720p');
        expect(r720.width, 1280);
        expect(r720.height, 720);
        expect(r720.bitrate, 2500000);
        expect(r720.frameRate, 30.0);
        expect(r720.url, 'https://cdn.example.com/live/720p/index.m3u8');

        final r360 = manifest.variants[2];
        expect(r360.id, '360p');
        expect(r360.label, '360p');
        expect(r360.width, 640);
        expect(r360.height, 360);
        expect(r360.bitrate, 800000);
        expect(r360.frameRate, 24.0);
        expect(r360.url, 'https://cdn.example.com/live/360p/index.m3u8');
      },
    );

    test(
      'extracts audio and subtitle rendition groups and distinguishes muxed status',
      () {
        const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-es",NAME="Spanish",DEFAULT=NO,AUTOSELECT=NO,URI="audio/es.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English Subs",DEFAULT=YES,URI="subs/en.vtt"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="French Subs",DEFAULT=NO,URI="subs/fr.vtt"
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,AUDIO="audio-aac",SUBTITLES="subs"
video/720p.m3u8
''';

        final baseUri = Uri.parse('https://example.com/stream/master.m3u8');
        final manifest = service.parseHls(playlist, baseUri);

        expect(manifest.audioGroups, ['audio-aac', 'audio-es']);
        expect(manifest.subtitleGroups, ['subs']);
        expect(manifest.hasSeparateAudio, isTrue);
        expect(manifest.variants.single.isMuxed, isFalse);
      },
    );

    test(
      'tolerates attribute quoting with commas, whitespace, and case variance',
      () {
        const playlist = '''
#EXTM3U
#EXT-X-STREAM-INF : BANDWIDTH = 2000000 , RESOLUTION = 1920x1080 , CODECS = "avc1.640028,mp4a.40.2" , FRAME-RATE = 29.970 , AUDIO = "group,with,comma" 
variants/1080p.m3u8
#EXT-X-MEDIA : TYPE = AUDIO , GROUP-ID = "group,with,comma" , NAME = "Surround 5.1, Main" , URI = "audio.m3u8" 
''';

        final baseUri = Uri.parse('https://example.com/master.m3u8');
        final manifest = service.parseHls(playlist, baseUri);

        expect(manifest.variants.length, 1);
        final variant = manifest.variants.first;
        expect(variant.width, 1920);
        expect(variant.height, 1080);
        expect(variant.bitrate, 2000000);
        expect(variant.codec, 'avc1.640028,mp4a.40.2');
        expect(variant.frameRate, 29.97);
        expect(manifest.audioGroups, ['group,with,comma']);
      },
    );

    test(
      'resolves relative URIs and applies parent query parameter inheritance',
      () {
        const playlist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
sub/720p.m3u8?child_tag=alpha&auth=child_secret
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
../other/360p.m3u8
''';

        final baseUri = Uri.parse(
          'https://cdn.example.com/stream/v1/master.m3u8?auth=master_secret&client_id=99',
        );
        final manifest = service.parseHls(playlist, baseUri);

        expect(manifest.variants.length, 2);

        // Child 720p preserves its own auth=child_secret and child_tag=alpha, and inherits client_id=99
        final v720 = manifest.variants[0];
        final uri720 = Uri.parse(v720.url!);
        expect(uri720.path, '/stream/v1/sub/720p.m3u8');
        expect(uri720.queryParameters['auth'], 'child_secret');
        expect(uri720.queryParameters['child_tag'], 'alpha');
        expect(uri720.queryParameters['client_id'], '99');

        // Child 360p inherits both auth=master_secret and client_id=99
        final v360 = manifest.variants[1];
        final uri360 = Uri.parse(v360.url!);
        expect(uri360.path, '/stream/other/360p.m3u8');
        expect(uri360.queryParameters['auth'], 'master_secret');
        expect(uri360.queryParameters['client_id'], '99');
      },
    );

    test('parses HLS media playlists (single rendition VOD vs live)', () {
      const vodPlaylist = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:9.009,
segment1.ts
#EXTINF:9.009,
segment2.ts
#EXT-X-ENDLIST
''';

      final vod = service.parseHls(
        vodPlaylist,
        Uri.parse('https://example.com/vod.m3u8'),
      );
      expect(vod.format, StreamFormat.hls);
      expect(vod.isLive, isFalse);
      expect(vod.variants.single.label, 'Source');
      expect(vod.variants.single.url, 'https://example.com/vod.m3u8');

      const livePlaylist = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:100
#EXTINF:6.0,
live100.ts
#EXTINF:6.0,
live101.ts
''';

      final live = service.parseHls(
        livePlaylist,
        Uri.parse('https://example.com/live.m3u8'),
      );
      expect(live.format, StreamFormat.hls);
      expect(live.isLive, isTrue);
      expect(live.variants.single.label, 'Live');
    });
  });

  group('StreamManifestService - DASH MPD Parsing', () {
    late StreamManifestService service;

    setUp(() {
      service = StreamManifestService();
    });

    test(
      'parses DASH MPD with representations, bandwidth, width/height, codecs, frameRate',
      () {
        const mpdXml = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1H">
  <Period id="p0">
    <AdaptationSet id="0" contentType="video" mimeType="video/mp4" codecs="avc1.640028">
      <Representation id="v1080" bandwidth="4500000" width="1920" height="1080" frameRate="30000/1001">
        <BaseURL>video/1080p.mp4</BaseURL>
      </Representation>
      <Representation id="v720" bandwidth="2200000" width="1280" height="720" frameRate="30">
        <BaseURL>video/720p.mp4</BaseURL>
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="1" contentType="audio" mimeType="audio/mp4" lang="en">
      <Representation id="a1" bandwidth="128000">
        <BaseURL>audio/en.mp4</BaseURL>
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="2" contentType="text" mimeType="text/vtt" lang="en">
      <Representation id="s1">
        <BaseURL>subs/en.vtt</BaseURL>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';

        final baseUri = Uri.parse(
          'https://media.example.com/dash/manifest.mpd',
        );
        final manifest = service.parseDash(mpdXml, baseUri);

        expect(manifest.format, StreamFormat.dash);
        expect(manifest.isLive, isFalse);
        expect(manifest.hasSeparateAudio, isTrue);
        expect(manifest.audioGroups, ['1']);
        expect(manifest.subtitleGroups, ['2']);
        expect(manifest.hasUnsupportedDrm, isFalse);
        expect(manifest.variants.length, 2);

        final v1080 = manifest.variants[0];
        expect(v1080.id, 'v1080');
        expect(v1080.label, '1080p');
        expect(v1080.width, 1920);
        expect(v1080.height, 1080);
        expect(v1080.bitrate, 4500000);
        expect(v1080.frameRate, closeTo(29.97, 0.01));
        expect(v1080.codec, 'avc1.640028');
        expect(v1080.url, 'https://media.example.com/dash/video/1080p.mp4');
        expect(v1080.isMuxed, isFalse);

        final v720 = manifest.variants[1];
        expect(v720.id, 'v720');
        expect(v720.label, '720p');
        expect(v720.width, 1280);
        expect(v720.height, 720);
        expect(v720.bitrate, 2200000);
        expect(v720.frameRate, 30.0);
        expect(v720.url, 'https://media.example.com/dash/video/720p.mp4');
      },
    );

    test('resolves hierarchical BaseURLs and detects live stream', () {
      const mpdXml = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic">
  <BaseURL>https://edge.example.com/live/</BaseURL>
  <Period id="p0">
    <BaseURL>stream1/</BaseURL>
    <AdaptationSet contentType="video">
      <BaseURL>video/</BaseURL>
      <Representation id="rep360" bandwidth="500000" width="640" height="360">
        <BaseURL>360.mp4</BaseURL>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';

      final manifest = service.parseDash(
        mpdXml,
        Uri.parse('https://origin.example.com/live.mpd'),
      );
      expect(manifest.isLive, isTrue);
      expect(
        manifest.variants.single.url,
        'https://edge.example.com/live/stream1/video/360.mp4',
      );
    });

    test('detects DRM / ContentProtection and marks hasUnsupportedDrm', () {
      const drmMpd = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
  <Period>
    <AdaptationSet contentType="video" mimeType="video/mp4">
      <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
      <Representation id="v1" bandwidth="1000000" width="1280" height="720"/>
    </AdaptationSet>
  </Period>
</MPD>
''';

      final manifest = service.parseDash(
        drmMpd,
        Uri.parse('https://example.com/drm.mpd'),
      );
      expect(manifest.hasUnsupportedDrm, isTrue);
    });

    test('rejects XXE external entity definitions safely', () {
      const xxeMpd = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE MPD [
  <!ENTITY xxe SYSTEM "file:///etc/passwd">
]>
<MPD type="static">
  <Period>
    <AdaptationSet contentType="video">
      <Representation id="1" bandwidth="1000">&xxe;</Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';

      final manifest = service.parseDash(
        xxeMpd,
        Uri.parse('https://example.com/xxe.mpd'),
      );
      // Returns fallback
      expect(manifest.format, StreamFormat.direct);
    });
  });

  group('StreamManifestService - Network Discovery and Resilience', () {
    test(
      'follows redirects and resolves child URLs against final redirected URI',
      () async {
        final client = _ScriptedClient([
          (req) => _response(302, location: 'https://redirect1.net/hop1'),
          (req) => _response(301, location: '/hop2/master.m3u8?session=abc'),
          (req) => _response(
            200,
            contentType: 'application/vnd.apple.mpegurl',
            body: '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
rendition.m3u8
''',
          ),
        ]);

        final service = StreamManifestService();
        final result = await service.discover(
          'https://initial.net/start',
          client: client,
        );

        expect(client.requested, [
          Uri.parse('https://initial.net/start'),
          Uri.parse('https://redirect1.net/hop1'),
          Uri.parse('https://redirect1.net/hop2/master.m3u8?session=abc'),
        ]);

        expect(result.format, StreamFormat.hls);
        expect(
          result.variants.single.url,
          'https://redirect1.net/hop2/rendition.m3u8?session=abc',
        );
      },
    );

    test(
      'aborts and returns direct fallback when exceeding max redirects',
      () async {
        final client = _ScriptedClient([
          (req) => _response(302, location: '/hop1'),
          (req) => _response(302, location: '/hop2'),
          (req) => _response(302, location: '/hop3'),
          (req) => _response(302, location: '/hop4'),
          (req) => _response(302, location: '/hop5'),
          (req) => _response(302, location: '/hop6'),
        ]);

        final service = StreamManifestService(maxRedirects: 4);
        final result = await service.discover(
          'https://example.com/loop',
          client: client,
        );

        expect(result.format, StreamFormat.direct);
        expect(result.masterUrl, 'https://example.com/loop');
      },
    );

    test(
      'returns direct fallback when redirect has missing location header',
      () async {
        final client = _ScriptedClient([
          (req) => _response(302), // No location header
        ]);

        final service = StreamManifestService();
        final result = await service.discover(
          'https://example.com/bad-redirect',
          client: client,
        );

        expect(result.format, StreamFormat.direct);
      },
    );

    test(
      'enforces bounded body limit and rejects oversized manifests',
      () async {
        final client = _ScriptedClient([
          (req) => _response(
            200,
            contentType: 'application/vnd.apple.mpegurl',
            bytes: List<int>.filled(300 * 1024, 65), // 300 KiB > 256 KiB limit
          ),
        ]);

        final service = StreamManifestService(maxHlsBytes: 256 * 1024);
        final result = await service.discover(
          'https://example.com/huge.m3u8',
          client: client,
        );

        expect(result.format, StreamFormat.direct);
      },
    );

    test('handles timeout and returns direct fallback', () async {
      final client = _ScriptedClient([
        (req) {
          final completer = Completer<http.StreamedResponse>();
          // Never complete to simulate hang
          return completer.future;
        },
      ]);

      final service = StreamManifestService();
      final result = await service.discover(
        'https://example.com/slow',
        client: client,
        timeout: const Duration(milliseconds: 50),
      );

      expect(result.format, StreamFormat.direct);
    });

    test('falls back gracefully on malformed XML or M3U8', () {
      final service = StreamManifestService();

      final badHls = service.parseHls(
        'Not an HLS file at all',
        Uri.parse('https://example.com/bad.m3u8'),
      );
      expect(badHls.format, StreamFormat.direct);

      final badXml = service.parseDash(
        '<MPD><UnclosedTag>',
        Uri.parse('https://example.com/bad.mpd'),
      );
      expect(badXml.format, StreamFormat.direct);

      final emptyXml = service.parseDash(
        '',
        Uri.parse('https://example.com/empty.mpd'),
      );
      expect(emptyXml.format, StreamFormat.direct);
    });

    test('caps advertised candidates to maxCandidates limit', () {
      final lines = <String>['#EXTM3U'];
      for (var i = 1; i <= 150; i++) {
        lines.add(
          '#EXT-X-STREAM-INF:BANDWIDTH=${i * 1000},RESOLUTION=${i * 10}x$i',
        );
        lines.add('variant_$i.m3u8');
      }

      final service = StreamManifestService(maxCandidates: 128);
      final manifest = service.parseHls(
        lines.join('\n'),
        Uri.parse('https://example.com/master.m3u8'),
      );

      expect(manifest.variants.length, 128);
    });
  });
}
