import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/domain/models/media_entry.dart';

void main() {
  group('MediaEntry.canonicalSource', () {
    test('drops a fragment without leaving a marker behind', () {
      // The engine never receives the fragment, so it must not make two
      // identities of the same stream differ.
      expect(
        MediaEntry.canonicalSource('https://media.example/live.m3u8#t=30'),
        'https://media.example/live.m3u8',
      );
    });

    test('keeps the query that identifies a stream', () {
      expect(
        MediaEntry.canonicalSource('https://media.example/live.m3u8?token=abc'),
        'https://media.example/live.m3u8?token=abc',
      );
    });

    test('matches the long-path form libmpv reports for a local file', () {
      final canonical = MediaEntry.canonicalSource(r'C:\Media\clip.mp4');
      expect(MediaEntry.canonicalSource(r'\\?\C:\Media\clip.mp4'), canonical);
      expect(
        MediaEntry.canonicalSource('file:///C:/Media/clip.mp4'),
        canonical,
      );
    });
  });

  group('MediaEntry.isNetworkUrl', () {
    test('separates stream addresses from local sources', () {
      expect(MediaEntry.isNetworkUrl('https://media.example/a.mp4'), isTrue);
      expect(MediaEntry.isNetworkUrl('HTTP://media.example/a.mp4'), isTrue);
      expect(MediaEntry.isNetworkUrl(r'C:\Media\a.mp4'), isFalse);
      expect(MediaEntry.isNetworkUrl('file:///C:/Media/a.mp4'), isFalse);
    });
  });

  group('MediaEntry.titleFromPath', () {
    test('uses the last decoded segment of a stream URL', () {
      expect(
        MediaEntry.titleFromPath('https://media.example/films/My%20Film.mkv'),
        'My Film.mkv',
      );
    });

    test('falls back to the host when a URL names no file', () {
      expect(
        MediaEntry.titleFromPath('https://media.example'),
        'media.example',
      );
    });

    test('keeps a malformed percent-encoded URL segment as its title', () {
      // `%FF` is a valid URI escape but not valid UTF-8. A display title must
      // not throw and discard the rest of the session row.
      final title = MediaEntry.titleFromPath(
        'https://media.example/bad%FF.mkv',
      );
      expect(title, isNotEmpty);
      expect(title, contains('bad'));
    });
  });

  group('MediaEntry.fromJson', () {
    test(
      'clamps unusable stored values instead of failing the launch path',
      () {
        final entry = MediaEntry.fromJson(<String, Object?>{
          'path': r'C:\Media\clip.mp4',
          'positionMs': -10,
          'durationMs': MediaEntry.maximumStoredMilliseconds * 2,
          'lastPlayed': 'not-a-date',
        });

        expect(entry.id, MediaEntry.canonicalSource(r'C:\Media\clip.mp4'));
        expect(entry.title, 'clip.mp4');
        expect(entry.position, Duration.zero);
        expect(
          entry.duration.inMilliseconds,
          MediaEntry.maximumStoredMilliseconds,
        );
        expect(entry.lastPlayed, DateTime.fromMillisecondsSinceEpoch(0));
      },
    );

    test('bounds an overlong stored title', () {
      final entry = MediaEntry.fromJson(<String, Object?>{
        'path': r'C:\Media\clip.mp4',
        'title': 'x' * (MediaEntry.maximumStoredTextLength + 500),
      });

      expect(entry.title.length, MediaEntry.maximumStoredTextLength);
    });

    test('round-trips through JSON', () {
      final entry = MediaEntry.fromJson(<String, Object?>{
        'id': 'queue-first',
        'path': 'https://media.example/first.mp4',
        'title': 'first.mp4',
        'positionMs': 1500,
        'durationMs': 2500,
        'lastPlayed': '2026-10-15T10:00:00.000',
      });

      final restored = MediaEntry.fromJson(entry.toJson());

      expect(restored.id, 'queue-first');
      expect(restored.path, 'https://media.example/first.mp4');
      expect(restored.position, const Duration(milliseconds: 1500));
      expect(restored.duration, const Duration(milliseconds: 2500));
      expect(restored.lastPlayed, entry.lastPlayed);
    });
  });
}
