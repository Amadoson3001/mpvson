/// Upstream release track used by the Windows engine updater.
enum EngineUpdateChannel {
  stable,
  development;

  String get label => switch (this) {
    EngineUpdateChannel.stable => 'Stable',
    EngineUpdateChannel.development => 'Development',
  };

  static EngineUpdateChannel fromStorage(Object? value) => switch (value) {
    'development' => EngineUpdateChannel.development,
    _ => EngineUpdateChannel.stable,
  };
}
