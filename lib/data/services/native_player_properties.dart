import 'package:media_kit/media_kit.dart';

/// Applies a map of libmpv properties, ignoring individual set failures so a
/// missing option cannot abort the rest of the configure pass.
Future<void> applyNativePlayerProperties(
  NativePlayer player,
  Map<String, String> properties, {
  void Function(String key, Object error)? onError,
  Duration? timeout,
}) async {
  Future<void> set(String key, String value) async {
    try {
      final future = player.setProperty(key, value);
      if (timeout != null) {
        await future.timeout(timeout);
      } else {
        await future;
      }
    } on Object catch (error) {
      onError?.call(key, error);
    }
  }

  await Future.wait([
    for (final entry in properties.entries) set(entry.key, entry.value),
  ]);
}
