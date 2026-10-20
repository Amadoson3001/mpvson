import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/native_media_events.dart';

void main() {
  group('interpretNativeProperty', () {
    test('reports a started source for the path property', () {
      final event = interpretNativeProperty('path', r'\\?\C:\Media\clip.mp4');
      expect(event, isNotNull);
      expect(event!.kind, NativeMediaEventKind.started);
      // The raw engine string is kept: the tracker canonicalizes it, so the
      // Windows long-path prefix libmpv reports must survive this layer.
      expect(event.source, r'\\?\C:\Media\clip.mp4');
    });

    test('ignores an empty path, which is how a stop is reported', () {
      expect(interpretNativeProperty('path', '   '), isNull);
    });

    test('treats a populated track list as a load confirmation', () {
      final event = interpretNativeProperty(
        'track-list',
        '[{"type":"video","id":1}]',
      );
      expect(event?.kind, NativeMediaEventKind.loaded);
      expect(interpretNativeProperty('track-list', ''), isNull);
      expect(interpretNativeProperty('track-list', '[]'), isNull);
      expect(interpretNativeProperty('track-list', '[{}]'), isNull);
      expect(interpretNativeProperty('track-list', '[null]'), isNull);
      expect(interpretNativeProperty('track-list', 'malformed'), isNull);
    });

    test('treats a positive duration as a load confirmation', () {
      expect(
        interpretNativeProperty('duration', '120.5')?.kind,
        NativeMediaEventKind.loaded,
      );
      expect(interpretNativeProperty('duration', '0'), isNull);
      expect(interpretNativeProperty('duration', 'not-a-number'), isNull);
      expect(interpretNativeProperty('duration', 'NaN'), isNull);
      expect(interpretNativeProperty('duration', 'Infinity'), isNull);
    });

    test('never confirms a load from the file-format property', () {
      // The probe recorded that this engine build does not notify it at all.
      expect(interpretNativeProperty('file-format', 'mov,mp4'), isNull);
      expect(NativePropertyNames.all, isNot(contains('file-format')));
    });

    test('treats eof-reached and idle-active as the end of a source', () {
      for (final property in <String>['eof-reached', 'idle-active']) {
        for (final truthy in <String>['yes', 'true', '1', ' YES ']) {
          expect(
            interpretNativeProperty(property, truthy)?.kind,
            NativeMediaEventKind.ended,
            reason: '$property=$truthy',
          );
        }
        for (final falsy in <String>['no', 'false', '0', '']) {
          expect(
            interpretNativeProperty(property, falsy),
            isNull,
            reason: '$property=$falsy',
          );
        }
      }
    });

    test('ignores a property it does not interpret', () {
      expect(interpretNativeProperty('volume', '100'), isNull);
    });

    test('observes every property the source lifecycle needs, once each', () {
      expect(NativePropertyNames.all, <String>[
        'path',
        'track-list',
        'duration',
        'eof-reached',
        'idle-active',
      ]);
      expect(
        NativePropertyNames.all.toSet().length,
        NativePropertyNames.all.length,
      );
    });
  });

  group('DisabledNativeMediaEvents', () {
    test('reports that the player cannot observe native events', () async {
      const events = DisabledNativeMediaEvents();
      expect(await events.start(), isFalse);
      expect(await events.events.isEmpty, isTrue);
      await events.dispose();
    });
  });
}
