import 'media_entry.dart';

/// Small, frequently written playback progress checkpoint.
///
/// Playback rewrites this instead of the whole session, so the queue, history
/// and settings are only encoded when they actually change. [revision] grows
/// monotonically so a checkpoint can never overwrite newer full-session state.
class SessionProgress {
  const SessionProgress({
    this.revision = 0,
    this.entryId,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  /// Schema version written by this release.
  static const int schemaVersion = 1;

  final int revision;

  /// Queue entry the progress belongs to, null when nothing is loaded.
  final String? entryId;
  final Duration position;
  final Duration duration;

  bool get isEmpty => entryId == null;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': schemaVersion,
    'revision': revision,
    'entryId': entryId,
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
  };

  /// Parses a checkpoint, returning null when it is unusable.
  static SessionProgress? tryFromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version is num && version > schemaVersion) return null;
    final rawId = json['entryId'];
    final entryId = rawId is String && rawId.isNotEmpty ? rawId : null;
    if (entryId == null) return null;
    final revision = _asInt(json['revision']);
    var duration = Duration(milliseconds: _asInt(json['durationMs']));
    if (duration >
        const Duration(milliseconds: MediaEntry.maximumStoredMilliseconds)) {
      duration = const Duration(
        milliseconds: MediaEntry.maximumStoredMilliseconds,
      );
    }
    var position = Duration(milliseconds: _asInt(json['positionMs']));
    if (duration > Duration.zero && position > duration) position = duration;
    return SessionProgress(
      revision: revision,
      entryId: entryId,
      position: position,
      duration: duration,
    );
  }

  static int _asInt(Object? value) {
    if (value is int) return value <= 0 ? 0 : value;
    if (value is num) {
      if (!value.isFinite || value <= 0) return 0;
      return value.round();
    }
    return 0;
  }
}
