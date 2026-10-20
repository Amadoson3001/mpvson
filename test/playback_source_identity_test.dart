import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/playback_source_identity.dart';

void main() {
  /// Uses an identity canonicalizer so the assertions describe the tracker
  /// rather than this platform's path normalization rules.
  PlaybackSourceIdentity tracker({int remember = 32}) => PlaybackSourceIdentity(
    canonicalize: (String source) => source,
    remember: remember,
  );

  const first = 'https://media.example/first.mp4';
  const second = 'https://media.example/second.mp4';

  group('request attribution without native observation', () {
    test('falls back to the source the player requested', () {
      final identity = tracker();

      final boundary = identity.beginOpen(first);

      expect(boundary, 1);
      expect(identity.attached.boundary, 1);
      expect(identity.attached.source, first);
      // The engine was asked to open this source and reported nothing against
      // it, so position data from it is trusted.
      expect(identity.attached.loaded, isTrue);
      expect(identity.attached.verified, isFalse);
    });

    test('starts every attempt on a new boundary', () {
      final identity = tracker();
      expect(identity.beginOpen(first), 1);
      expect(identity.beginOpen(first), 2);
      expect(identity.beginStop(), 3);
      expect(identity.boundaryCounter, 3);
    });
  });

  group('native attribution', () {
    test('keeps no source until the engine reports one', () {
      final identity = tracker()..activateObservation(supported: true);

      identity.beginOpen(first);

      expect(identity.attached.source, isNull);
      expect(identity.attached.boundary, 0);
      expect(identity.attached.loaded, isFalse);
      expect(identity.pendingBoundary, 1);
    });

    test('attributes a started source to the attempt that requested it', () {
      final identity = tracker()..activateObservation(supported: true);
      identity.beginOpen(first);
      identity.beginOpen(second);

      final attachment = identity.attachStarted(first);

      expect(attachment.boundary, 1);
      expect(attachment.source, first);
      expect(attachment.verified, isTrue);
      // Starting the older source says nothing about the newer request.
      expect(identity.pendingBoundary, 2);
      expect(identity.attached.source, first);
    });

    test('keeps the current attachment for a source never requested', () {
      final identity = tracker()..activateObservation(supported: true);
      identity.beginOpen(first);
      identity.attachStarted(first);

      final attachment = identity.attachStarted(
        'https://media.example/other.mp4',
      );

      // No boundary is invented, so the view model rejects the events as stale
      // instead of attaching them to the running attempt.
      expect(attachment.boundary, 1);
      expect(attachment.source, first);
    });

    test(
      'uses the single outstanding request for a differently spelled source',
      () {
        final identity = tracker()..activateObservation(supported: true);
        identity.beginOpen('https://media.example/movie.mp4');

        // libmpv can report a normalized form of a queued URL.
        final attachment = identity.attachStarted(
          'https://media.example/movie.mp4?token=1',
        );

        expect(attachment.boundary, 1);
        expect(identity.pendingBoundary, isNull);
      },
    );

    test('remembers a load confirmation that overtakes the start event', () {
      final identity = tracker()..activateObservation(supported: true);
      identity.beginOpen(first);

      // Nothing is attached yet, so the confirmation cannot describe anything.
      expect(identity.attachLoaded().loaded, isFalse);

      expect(identity.attachStarted(first).loaded, isTrue);
    });

    test('trusts position data only after the load is confirmed', () {
      final identity = tracker()..activateObservation(supported: true);
      identity.beginOpen(first);

      expect(identity.attachStarted(first).loaded, isFalse);
      expect(identity.attached.loaded, isFalse);
      expect(identity.attachLoaded().loaded, isTrue);
      expect(identity.attached.loaded, isTrue);
    });

    test('rebinds a reopened source to the newest attempt', () {
      final identity = tracker()..activateObservation(supported: true);
      identity.beginOpen(first);
      identity.attachStarted(first);
      identity.attachLoaded();

      final boundary = identity.beginOpen(first);

      expect(boundary, 2);
      expect(identity.attached.boundary, 2);
      // Reopening reloads the same source, so the attempt stays unconfirmed
      // until the engine reports it again.
      expect(identity.attached.loaded, isFalse);
      expect(identity.pendingBoundary, isNull);
      expect(identity.attachStarted(first).loaded, isFalse);
    });

    test('clears the attachment when playback stops', () {
      final identity = tracker()..activateObservation(supported: true);
      identity.beginOpen(first);
      identity.attachStarted(first);
      identity.attachLoaded();

      final boundary = identity.beginStop();

      expect(identity.attached.source, isNull);
      expect(identity.attached.loaded, isFalse);
      expect(identity.unresolvedRequest, isNull);
      expect(boundary, 2);
      // A late event from the stopped source keeps its old boundary, which is
      // below the stop boundary the view model now requires.
      expect(identity.attachStarted(first).boundary, lessThan(boundary));
    });

    test('reports the outstanding request for an unattributed failure', () {
      final identity = tracker()..activateObservation(supported: true);

      identity.beginOpen(first);

      // libmpv refuses a load without ever notifying `path`, so this identity is
      // the only one that can describe the failure.
      expect(identity.unresolvedRequest, isNotNull);
      expect(identity.unresolvedRequest!.boundary, 1);
      expect(identity.unresolvedRequest!.source, first);

      identity.attachStarted(first);

      expect(identity.unresolvedRequest, isNull);
    });

    test('keeps a source requested before observation was activated', () {
      final identity = tracker();
      identity.beginOpen(first);

      identity.activateObservation(supported: true);

      expect(identity.attached.source, first);
      expect(identity.attached.loaded, isTrue);
      expect(identity.pendingBoundary, isNull);
    });

    test('keeps request attribution when observation is unsupported', () {
      final identity = tracker()..activateObservation(supported: false);
      identity.beginOpen(first);

      expect(identity.attached.source, first);
      expect(identity.attached.loaded, isTrue);
    });

    test('forgets the oldest attempts so memory stays bounded', () {
      final identity = tracker(remember: 2)
        ..activateObservation(supported: true);
      identity.beginOpen(first);
      identity.beginOpen(second);
      identity.attachStarted(second);
      identity.beginOpen('https://media.example/third.mp4');
      identity.attachStarted('https://media.example/third.mp4');

      // `first` was evicted, so its late event keeps the current attachment.
      expect(
        identity.attachStarted(first).source,
        'https://media.example/third.mp4',
      );
    });
  });
}
