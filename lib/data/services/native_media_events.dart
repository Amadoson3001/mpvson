import 'dart:async';
import 'dart:convert';

import 'package:media_kit/media_kit.dart';

/// What the native playback engine reports for a source.
enum NativeMediaEventKind {
  /// libmpv started loading a source. The event carries the source it started.
  started,

  /// libmpv confirmed the started source is open (its content is readable).
  loaded,

  /// libmpv reached the end of the attached source.
  ended,
}

/// A native engine notification about the source it has attached.
class NativeMediaEvent {
  const NativeMediaEvent.started(this.source)
    : kind = NativeMediaEventKind.started;
  const NativeMediaEvent.loaded()
    : kind = NativeMediaEventKind.loaded,
      source = '';
  const NativeMediaEvent.ended()
    : kind = NativeMediaEventKind.ended,
      source = '';

  final NativeMediaEventKind kind;

  /// Raw source string reported by the engine for [NativeMediaEventKind.started]
  /// (may include a Windows long-path prefix or a URL), empty otherwise.
  final String source;

  @override
  String toString() => 'NativeMediaEvent(${kind.name}, $source)';
}

/// Property names observed on the native player.
///
/// `path` is notified by libmpv for every load, including reopening the same
/// source. `file-format` never notified in the probe, so the loaded
/// confirmation uses the demuxer's track list and duration instead.
abstract final class NativePropertyNames {
  static const String path = 'path';
  static const String trackList = 'track-list';
  static const String duration = 'duration';
  static const String eofReached = 'eof-reached';
  static const String idleActive = 'idle-active';

  /// Every property the adapter observes, in registration order.
  static const List<String> all = <String>[
    path,
    trackList,
    duration,
    eofReached,
    idleActive,
  ];
}

/// Interprets one observed libmpv property change.
///
/// Returns null when the change carries no source lifecycle information. The
/// rules and their native evidence are documented in
/// `docs/native-source-probe.md`.
NativeMediaEvent? interpretNativeProperty(String property, String value) {
  switch (property) {
    case NativePropertyNames.path:
      final source = value.trim();
      return source.isEmpty ? null : NativeMediaEvent.started(source);
    case NativePropertyNames.trackList:
      try {
        final tracks = jsonDecode(value);
        return tracks is List &&
                tracks.any((track) => track is Map && track.isNotEmpty)
            ? const NativeMediaEvent.loaded()
            : null;
      } on FormatException {
        return null;
      }
    case NativePropertyNames.duration:
      final seconds = double.tryParse(value.trim());
      return seconds == null || !seconds.isFinite || seconds <= 0
          ? null
          : const NativeMediaEvent.loaded();
    case NativePropertyNames.eofReached:
    case NativePropertyNames.idleActive:
      return _isYes(value) ? const NativeMediaEvent.ended() : null;
    default:
      return null;
  }
}

bool _isYes(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized == 'yes' || normalized == 'true' || normalized == '1';
}

/// Narrow, repository-owned view of the native engine's source lifecycle.
///
/// media_kit exposes property observation on its native player but no
/// source-identity events. Mpvson owns this small adapter so playback state can
/// be attributed to the source the engine actually has attached instead of the
/// source the player last requested.
abstract interface class NativeMediaEvents {
  /// Started, loaded and ended notifications in engine order.
  Stream<NativeMediaEvent> get events;

  /// Registers the native observers.
  ///
  /// Returns false when the current player implementation cannot report native
  /// events, in which case playback falls back to request-based attribution.
  Future<bool> start();

  Future<void> dispose();
}

/// Used when a player implementation has no native event channel.
class DisabledNativeMediaEvents implements NativeMediaEvents {
  const DisabledNativeMediaEvents();

  @override
  Stream<NativeMediaEvent> get events => const Stream<NativeMediaEvent>.empty();

  @override
  Future<bool> start() async => false;

  @override
  Future<void> dispose() async {}
}

/// Reads the observed libmpv properties of a media_kit native player.
class MediaKitNativeMediaEvents implements NativeMediaEvents {
  MediaKitNativeMediaEvents(this._player);

  final Player _player;
  final StreamController<NativeMediaEvent> _events =
      StreamController<NativeMediaEvent>.broadcast(sync: true);
  bool _started = false;
  bool _disposed = false;

  @override
  Stream<NativeMediaEvent> get events => _events.stream;

  @override
  Future<bool> start() async {
    if (_disposed) return false;
    if (_started) return true;
    final platform = _player.platform;
    if (platform is! NativePlayer) return false;
    try {
      for (final property in NativePropertyNames.all) {
        if (_disposed) return false;
        await platform.observeProperty(property, (value) async {
          _handle(property, value);
        });
      }
    } on Object {
      // An engine build that refuses one of the properties keeps playback
      // working through request-based attribution.
      return false;
    }
    _started = true;
    return true;
  }

  void _handle(String property, String value) {
    if (_disposed) return;
    final event = interpretNativeProperty(property, value);
    if (event == null) return;
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _events.close();
    } on Object {
      // Teardown must not throw when the native player is already gone.
    }
  }
}
