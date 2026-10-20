/// Density choices for the playback controls.
enum ControlDensity {
  compact,
  normal;

  /// Reads a persisted value, falling back to the default for older or invalid
  /// session data.
  static ControlDensity fromPersisted(Object? value) =>
      value == 'normal' ? ControlDensity.normal : ControlDensity.compact;
}
