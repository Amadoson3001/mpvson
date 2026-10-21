import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/playback_source_identity.dart';

void main() {
  group('PlaybackSourceIdentity', () {
    late PlaybackSourceIdentity identity;

    setUp(() {
      identity = PlaybackSourceIdentity(canonicalize: (source) => source);
    });

    test('idle property reports do not confirm the next source', () {
      identity.activateObservation(supported: true);

      // Native property registration reports current values, including an idle
      // player's old/empty track list and duration.
      identity.attachLoaded();
      final boundary = identity.beginOpen('movie.mkv');

      final started = identity.attachStarted('movie.mkv');

      expect(started.boundary, boundary);
      expect(started.loaded, isFalse);
      expect(identity.attachLoaded().loaded, isTrue);
    });

    test(
      'requesting the source before observation is active is not a load',
      () {
        final boundary = identity.beginOpen('movie.mkv');

        identity.activateObservation(supported: true);

        expect(identity.attached.hasSource, isFalse);
        expect(identity.unresolvedRequest?.boundary, boundary);

        final started = identity.attachStarted('movie.mkv');
        expect(started.boundary, boundary);
        expect(started.loaded, isFalse);
      },
    );

    test('identity-less loaded events cannot complete a pending source', () {
      identity.activateObservation(supported: true);
      identity.beginOpen('movie.mkv');

      identity.attachLoaded();
      final started = identity.attachStarted('movie.mkv');

      expect(started.loaded, isFalse);
      expect(identity.attachLoaded().loaded, isTrue);
    });

    test('previous source properties cannot confirm a reopened source', () {
      identity.activateObservation(supported: true);
      identity.beginOpen('movie.mkv');
      identity.attachStarted('movie.mkv');
      identity.attachLoaded();

      final reopenedBoundary = identity.beginOpen('movie.mkv');
      identity.attachLoaded();
      final reopened = identity.attachStarted('movie.mkv');

      expect(reopened.boundary, reopenedBoundary);
      expect(reopened.loaded, isFalse);
    });

    test('idle engine updates keep the stop request boundary', () {
      identity.activateObservation(supported: true);
      identity.beginOpen('movie.mkv');
      identity.attachStarted('movie.mkv');
      identity.attachLoaded();

      final stoppedBoundary = identity.beginStop();

      expect(identity.attached.boundary, stoppedBoundary);
      expect(identity.attached.hasSource, isFalse);
      expect(identity.attached.isEmpty, isTrue);
      expect(identity.attachLoaded().boundary, stoppedBoundary);
      expect(identity.attachEnded().boundary, stoppedBoundary);
    });
  });
}
