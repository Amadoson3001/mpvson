import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mpvson/data/services/native_media_events.dart';

class _FakeNativePlayer extends Fake implements NativePlayer {
  final List<String> observedCalls = <String>[];
  final List<String> unobservedCalls = <String>[];
  String? failOnProperty;

  @override
  Future<void> observeProperty(
    String property,
    Future<void> Function(String value) callback, {
    bool waitForInitialization = true,
  }) async {
    if (property == failOnProperty) {
      throw Exception('Refused property $property');
    }
    observedCalls.add(property);
  }

  @override
  Future<void> unobserveProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    unobservedCalls.add(property);
  }
}

void main() {
  test(
    'unregisters all previously observed properties if registration fails mid-loop',
    () async {
      final native = _FakeNativePlayer();
      // Fail on the second property
      native.failOnProperty = NativePropertyNames.all[1];
      final player = Player(platformPlayer: native);
      final events = MediaKitNativeMediaEvents(player);

      final success = await events.start();
      expect(success, isFalse);

      // The first property was observed
      expect(native.observedCalls, [NativePropertyNames.all[0]]);
      // And cleanly unobserved when the second failed
      expect(native.unobservedCalls, [NativePropertyNames.all[0]]);
    },
  );

  test('unregisters all observed properties on disposal', () async {
    final native = _FakeNativePlayer();
    final player = Player(platformPlayer: native);
    final events = MediaKitNativeMediaEvents(player);

    final success = await events.start();
    expect(success, isTrue);
    expect(native.observedCalls.length, NativePropertyNames.all.length);
    expect(native.unobservedCalls, isEmpty);

    await events.dispose();
    expect(native.unobservedCalls.length, NativePropertyNames.all.length);
  });
}
