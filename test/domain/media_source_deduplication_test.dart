import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/media_catalog.dart';
import 'package:mpvson/domain/models/media_entry.dart';
import 'package:mpvson/domain/models/media_kind.dart';
import 'package:mpvson/domain/models/media_source.dart';

void main() {
  group('MediaSource deduplication and validation', () {
    test(
      'local paths fold case on Windows and keep distinct on non-Windows',
      () {
        const path1 = r'C:\Media\Video.MP4';
        const path2 = r'c:\media\video.mp4';

        final keyWin1 = MediaSource.deduplicationKey(path1, isWindows: true);
        final keyWin2 = MediaSource.deduplicationKey(path2, isWindows: true);
        expect(keyWin1, equals(keyWin2));

        final keyLinux1 = MediaSource.deduplicationKey(
          '/media/Video.MP4',
          isWindows: false,
        );
        final keyLinux2 = MediaSource.deduplicationKey(
          '/media/video.mp4',
          isWindows: false,
        );
        expect(keyLinux1, isNot(equals(keyLinux2)));
      },
    );

    test(
      'network URLs preserve case-sensitive paths, tokens, and query parameters',
      () {
        const url1 =
            'https://example.com/Stream/Token_AbCd?sig=XYZ123&q=foo+bar';
        const url2 =
            'https://example.com/Stream/Token_abcd?sig=xyz123&q=foo+bar';
        const url3 =
            'https://example.com/Stream/Token_AbCd?sig=XYZ123&q=foo+bar#t=30';

        final key1 = MediaSource.deduplicationKey(url1, isWindows: true);
        final key2 = MediaSource.deduplicationKey(url2, isWindows: true);
        final key3 = MediaSource.deduplicationKey(url3, isWindows: true);

        // Distinct case-sensitive URLs are NOT collapsed even on Windows.
        expect(key1, isNot(equals(key2)));
        // Fragment is omitted so seeking / timestamp fragments deduplicate to the same source.
        expect(key1, equals(key3));
        // Raw string query is preserved verbatim (including +, case, order).
        expect(key1, equals(url1));
      },
    );

    test('preserves %2F and repeated query keys without re-encoding', () {
      const complexUrl =
          'https://cdn.example.org/path%2Fsubpath?tag=alpha&tag=beta&token=A+B';
      final validation = MediaSource.validate(complexUrl);
      expect(validation.isValid, isTrue);
      expect(validation.source, equals(complexUrl));

      final key = MediaSource.deduplicationKey(complexUrl);
      expect(key, equals(complexUrl));
    });

    test('MediaEntry canonicalSource matches deduplicationKey', () {
      const url = 'https://example.com/live/master.m3u8?auth=SecretKey#frag';
      expect(
        MediaEntry.canonicalSource(url),
        equals(MediaSource.deduplicationKey(url)),
      );
    });

    test(
      'MediaCatalog.kindFromExtension recognizes video and audio with signed tokens',
      () {
        const signedVideoUrl =
            'https://cdn.example.org/stream.mp4?expire=1893456000&sig=XyZ_99';
        const signedAudioUrl =
            'https://cdn.example.org/track.m4a?token=abc-123#frag';
        const unknownUrl = 'https://cdn.example.org/manifest?id=42';

        expect(
          MediaCatalog.kindFromExtension(signedVideoUrl),
          equals(MediaKind.video),
        );
        expect(
          MediaCatalog.kindFromExtension(signedAudioUrl),
          equals(MediaKind.audio),
        );
        expect(
          MediaCatalog.kindFromExtension(unknownUrl),
          equals(MediaKind.unknown),
        );
      },
    );

    test('redact strips path, credentials, query parameters and tokens', () {
      const sensitiveUrl =
          'https://user:pass@cdn.example.org:8080/secret/path/video.mp4?token=secret123&exp=999#tag';
      final redacted = MediaSource.redact(sensitiveUrl);
      expect(redacted, equals('https://cdn.example.org:8080'));
    });

    test('redactText scrubs URLs and sensitive headers from messages', () {
      const logMessage =
          'Engine error: failed to fetch https://cdn.example.org/private/stream.m3u8?key=ABC with Authorization: Bearer secret-token-xyz';
      final redacted = MediaSource.redactText(logMessage);
      expect(redacted, contains('https://cdn.example.org'));
      expect(redacted, isNot(contains('/private/stream.m3u8')));
      expect(redacted, isNot(contains('key=ABC')));
      expect(redacted, isNot(contains('secret-token-xyz')));
      expect(redacted, contains('Authorization: [REDACTED]'));
    });
  });
}
