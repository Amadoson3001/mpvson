import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/playback_source_identity.dart';

void main() {
  group('PlaybackSourceIdentity', () {
    test(
      'registerResolvedSource maps CDN or rendition URLs back to logical source',
      () {
        final identity = PlaybackSourceIdentity()
          ..activateObservation(supported: true);
        const pageUrl = 'https://www.youtube.com/watch?v=abc123';
        const cdnUrl =
            'https://rr1---sn-xyz.googlevideo.com/videoplayback?id=1';

        final boundary = identity.beginOpen(pageUrl);
        identity.registerResolvedSource(boundary, cdnUrl);

        final attached = identity.attachStarted(cdnUrl);
        expect(attached.boundary, equals(boundary));
        expect(attached.source, equals(pageUrl));
        expect(attached.verified, isTrue);
        expect(identity.pendingBoundary, isNull);
      },
    );

    test(
      'attachStarted ignores empty source strings and preserves pending boundary',
      () {
        final identity = PlaybackSourceIdentity()
          ..activateObservation(supported: true);
        const sourceUrl = 'https://example.com/video.mp4';

        final boundary = identity.beginOpen(sourceUrl);
        expect(identity.pendingBoundary, equals(boundary));

        final afterEmpty = identity.attachStarted('   ');
        expect(afterEmpty.boundary, equals(boundary));
        expect(afterEmpty.hasSource, isFalse);
        expect(identity.pendingBoundary, equals(boundary));

        final afterReal = identity.attachStarted(sourceUrl);
        expect(afterReal.boundary, equals(boundary));
        expect(afterReal.source, equals(sourceUrl));
        expect(identity.pendingBoundary, isNull);
      },
    );
  });
}
