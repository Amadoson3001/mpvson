import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/media_source.dart';

void main() {
  group('MediaSource.validate', () {
    test('rejects an empty source with an explicit reason', () {
      final result = MediaSource.validate('   ');
      expect(result.isValid, isFalse);
      expect(result.error, contains('No media source'));
    });

    test('accepts a Windows drive path before any scheme handling', () {
      // `C:\Media\clip.mp4` parses as a URI with a one letter scheme, so it must
      // never be reported as an unsupported scheme.
      final result = MediaSource.validate(r'C:\Media\clip.mp4');
      expect(result.isValid, isTrue);
      expect(result.source, r'C:\Media\clip.mp4');
    });

    test('accepts HTTP and HTTPS sources that name a host', () {
      for (final source in <String>[
        'https://media.example/live.m3u8',
        'http://media.example:8080/movie.mp4?token=abc',
      ]) {
        final result = MediaSource.validate(source);
        expect(result.isValid, isTrue, reason: source);
        expect(result.source, source);
      }
    });

    test('rejects a stream URL without a host without echoing secrets', () {
      final result = MediaSource.validate('https://?token=secret-value');
      expect(result.isValid, isFalse);
      expect(result.error, contains('missing a host'));
      expect(result.error, isNot(contains('secret-value')));
    });

    test('accepts a file URI that names a file', () {
      final result = MediaSource.validate('file:///C:/Media/clip.mp4');
      expect(result.isValid, isTrue);
    });

    test('treats an unparseable string as a local path', () {
      // `file:` is not a valid URI, so it falls through to the local-path branch
      // and the player reports a missing file instead of an unsupported scheme.
      expect(MediaSource.validate('file:').source, 'file:');
    });

    test('rejects a malformed stream URL instead of a bogus local path', () {
      final result = MediaSource.validate(
        'https://media.example:not-a-port/movie.mp4',
      );
      expect(result.isValid, isFalse);
      expect(result.error, contains('stream URL'));
    });

    test('rejects a malformed unsupported scheme as such', () {
      final result = MediaSource.validate(
        'ftp://media.example:not-a-port/clip.mp4',
      );
      expect(result.isValid, isFalse);
      expect(result.error, contains('ftp'));
    });

    test('reports an unsupported scheme instead of a bogus local path', () {
      final result = MediaSource.validate('ftp://media.example/clip.mp4');
      expect(result.isValid, isFalse);
      expect(result.error, contains('ftp'));
    });
  });

  group('MediaSource.redact', () {
    test('strips credentials, query and fragment from stream URLs', () {
      expect(
        MediaSource.redact(
          'https://user:pw@media.example/live.m3u8?token=abc#frag',
        ),
        'https://media.example/live.m3u8',
      );
    });

    test('keeps the port that identifies a stream endpoint', () {
      expect(
        MediaSource.redact('http://media.example:8080/movie.mp4?token=abc'),
        'http://media.example:8080/movie.mp4',
      );
    });

    test('leaves local paths untouched', () {
      expect(MediaSource.redact(r'C:\Media\clip.mp4'), r'C:\Media\clip.mp4');
    });

    test('leaves non-network schemes untouched', () {
      expect(
        MediaSource.redact('file:///C:/Media/clip.mp4'),
        'file:///C:/Media/clip.mp4',
      );
    });

    test('redacts URLs embedded in text without spaces', () {
      expect(
        MediaSource.redact(
          'load(https://user:password@example.test/video?token=REVIEW_SECRET)',
        ),
        'load(https://example.test/video)',
      );
    });

    test('redacts punctuated, quoted, and multiline URLs', () {
      final text =
          'open "https://user:pw@one.test/a?token=FIRST_SECRET", '
          '(https://u:p@two.test/b#SECOND_SECRET).\n'
          'https://u:bad%ZZ@three.test/c?token=THIRD_SECRET';

      final redacted = MediaSource.redactText(text);

      expect(redacted, contains('"https://one.test/a",'));
      expect(redacted, contains('(https://two.test/b).'));
      expect(redacted, contains('https://three.test/c'));
      expect(redacted, isNot(contains('FIRST_SECRET')));
      expect(redacted, isNot(contains('SECOND_SECRET')));
      expect(redacted, isNot(contains('THIRD_SECRET')));
      expect(redacted, isNot(contains('bad%ZZ')));
    });
  });
}
