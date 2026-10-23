import 'control_density.dart';
import 'media_entry.dart';
import 'media_source.dart';
import 'playback_settings.dart';

/// Raised when a stored session is structurally unusable.
///
/// The repository treats this as "try the recovery copy" rather than "there is
/// no session", so a structurally invalid primary can never hide a good backup.
class SessionFormatException implements Exception {
  const SessionFormatException(this.message);

  final String message;

  @override
  String toString() => 'SessionFormatException: $message';
}

/// Serializable, stopped-at-launch playback state.
class PlaybackSession {
  const PlaybackSession({
    this.queue = const <MediaEntry>[],
    this.recent = const <MediaEntry>[],
    this.currentId,
    this.volume = 100,
    this.rate = 1,
    this.shuffle = false,
    this.repeatMode = 'off',
    this.controlDensity = ControlDensity.compact,
    this.playbackSettings = PlaybackSettings.defaults,
    this.saveNetworkUrls = false,
    this.historyEnabled = true,
    this.progressRevision = 0,
    this.storedVersion = schemaVersion,
  });

  /// Schema version written by this release.
  static const int schemaVersion = 4;

  /// Highest queue rows read from a stored session. A corrupt or hostile file
  /// cannot make the launch path unbounded.
  static const int maximumRows = 50000;

  /// Longest media duration accepted from a stored session.
  static const int maximumMilliseconds = MediaEntry.maximumStoredMilliseconds;

  final List<MediaEntry> queue;
  final List<MediaEntry> recent;
  final String? currentId;
  final double volume;
  final double rate;
  final bool shuffle;
  final String repeatMode;
  final ControlDensity controlDensity;
  final PlaybackSettings playbackSettings;

  /// Whether stream URLs may be written to local session files.
  final bool saveNetworkUrls;

  /// Whether new recent-file and playback-position activity is remembered.
  final bool historyEnabled;

  /// Revision of the progress checkpoint this session already contains, used to
  /// decide whether a newer checkpoint should override the stored position.
  final int progressRevision;

  /// Version of the file this session was read from.
  ///
  /// Always [schemaVersion] for sessions this release constructs, so a stored
  /// file can be recognized as needing a rewrite in the current schema.
  final int storedVersion;

  /// Whether the stored file predates the schema this release writes.
  bool get needsMigration => storedVersion != schemaVersion;

  int get currentIndex => queue.indexWhere((entry) => entry.id == currentId);

  /// Whether any stored entry is a network stream.
  bool get hasNetworkEntries =>
      queue.any((entry) => MediaEntry.isNetworkUrl(entry.path)) ||
      recent.any((entry) => MediaEntry.isNetworkUrl(entry.path));

  /// The same session with every stream URL removed.
  PlaybackSession withoutNetworkUrls() {
    final keptQueue = queue
        .where((entry) => !MediaEntry.isNetworkUrl(entry.path))
        .toList(growable: false);
    final keptRecent = recent
        .where((entry) => !MediaEntry.isNetworkUrl(entry.path))
        .toList(growable: false);
    return PlaybackSession(
      queue: keptQueue,
      recent: keptRecent,
      currentId: keptQueue.any((entry) => entry.id == currentId)
          ? currentId
          : null,
      volume: volume,
      rate: rate,
      shuffle: shuffle,
      repeatMode: repeatMode,
      controlDensity: controlDensity,
      playbackSettings: playbackSettings,
      saveNetworkUrls: false,
      historyEnabled: historyEnabled,
      progressRevision: progressRevision,
      storedVersion: storedVersion,
    );
  }

  PlaybackSession copyWith({
    List<MediaEntry>? queue,
    List<MediaEntry>? recent,
    String? currentId,
    bool clearCurrentId = false,
    double? volume,
    double? rate,
    bool? shuffle,
    String? repeatMode,
    ControlDensity? controlDensity,
    PlaybackSettings? playbackSettings,
    bool? saveNetworkUrls,
    bool? historyEnabled,
    int? progressRevision,
    int? storedVersion,
  }) {
    return PlaybackSession(
      queue: queue ?? this.queue,
      recent: recent ?? this.recent,
      currentId: clearCurrentId ? null : currentId ?? this.currentId,
      volume: volume ?? this.volume,
      rate: rate ?? this.rate,
      shuffle: shuffle ?? this.shuffle,
      repeatMode: repeatMode ?? this.repeatMode,
      controlDensity: controlDensity ?? this.controlDensity,
      playbackSettings: playbackSettings ?? this.playbackSettings,
      saveNetworkUrls: saveNetworkUrls ?? this.saveNetworkUrls,
      historyEnabled: historyEnabled ?? this.historyEnabled,
      progressRevision: progressRevision ?? this.progressRevision,
      storedVersion: storedVersion ?? this.storedVersion,
    );
  }

  factory PlaybackSession.fromJson(Map<String, Object?> json) {
    final version = _readVersion(json);
    final queue = _entries(json['queue'], field: 'queue');
    final recent = _entries(json['recent'], field: 'recent');
    final rawCurrentId = json['currentId'];
    final currentId =
        rawCurrentId is String && queue.any((entry) => entry.id == rawCurrentId)
        ? rawCurrentId
        : null;
    final rawRepeat = json['repeatMode'];
    final repeatMode = rawRepeat == 'all' || rawRepeat == 'one'
        ? rawRepeat as String
        : 'off';
    return PlaybackSession(
      queue: queue,
      recent: recent,
      currentId: currentId,
      volume: _boundedNumber(json['volume'], fallback: 100, min: 0, max: 100),
      rate: _boundedNumber(json['rate'], fallback: 1, min: 0.25, max: 4),
      shuffle: json['shuffle'] == true,
      repeatMode: repeatMode,
      controlDensity: ControlDensity.fromPersisted(json['controlDensity']),
      playbackSettings: PlaybackSettings.fromJson(json['playbackSettings']),
      // Version 1 predates the consent setting, so it implies no consent.
      saveNetworkUrls: version >= 2 && json['saveNetworkUrls'] == true,
      historyEnabled: json['historyEnabled'] != false,
      progressRevision: version >= 2
          ? _asInt(json['progressRevision']) ?? 0
          : 0,
      storedVersion: version,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': schemaVersion,
    'queue': queue.map((entry) => entry.toJson()).toList(growable: false),
    'recent': recent.map((entry) => entry.toJson()).toList(growable: false),
    'currentId': currentId,
    'volume': volume,
    'rate': rate,
    'shuffle': shuffle,
    'repeatMode': repeatMode,
    'controlDensity': controlDensity.name,
    'playbackSettings': playbackSettings.toJson(),
    'saveNetworkUrls': saveNetworkUrls,
    'historyEnabled': historyEnabled,
    'progressRevision': progressRevision,
  };

  static int _readVersion(Map<String, Object?> json) {
    final raw = json['version'];
    if (raw == null) {
      // Sessions written before the version field existed are version 1.
      return 1;
    }
    if (raw is! num || !raw.isFinite || raw != raw.roundToDouble()) {
      throw const SessionFormatException(
        'The session version is not a number.',
      );
    }
    final version = raw.toInt();
    if (version < 1) {
      throw const SessionFormatException('The session version is not valid.');
    }
    if (version > schemaVersion) {
      throw SessionFormatException(
        'The session was written by a newer Mpvson release (version $version).',
      );
    }
    return version;
  }

  static List<MediaEntry> _entries(Object? value, {required String field}) {
    if (value == null) {
      throw SessionFormatException('The session is missing its "$field" list.');
    }
    if (value is! List) {
      throw SessionFormatException('The session "$field" is not a list.');
    }
    final result = <MediaEntry>[];
    for (final item in value) {
      if (result.length >= maximumRows) break;
      if (item is! Map) continue;
      try {
        final entry = _normalizeEntry(
          MediaEntry.fromJson(Map<String, Object?>.from(item)),
        );
        if (entry != null) result.add(entry);
      } on Object {
        // Skip a malformed row while preserving the rest of the session.
      }
    }
    return List<MediaEntry>.unmodifiable(result);
  }

  /// Drops sources this release cannot open and clamps stored numbers.
  static MediaEntry? _normalizeEntry(MediaEntry entry) {
    final validation = MediaSource.validate(entry.path);
    if (!validation.isValid) return null;
    var duration = entry.duration;
    if (duration < Duration.zero) duration = Duration.zero;
    if (duration > const Duration(milliseconds: maximumMilliseconds)) {
      duration = const Duration(milliseconds: maximumMilliseconds);
    }
    var position = entry.position;
    if (position < Duration.zero) position = Duration.zero;
    if (duration > Duration.zero && position > duration) position = duration;
    final title = entry.title.trim();
    return entry.copyWith(
      path: MediaEntry.normalizeSourcePath(entry.path),
      title: title.isEmpty ? MediaEntry.titleFromPath(entry.path) : title,
      position: position,
      duration: duration,
      lastPlayed: entry.lastPlayed,
    );
  }

  static double _boundedNumber(
    Object? value, {
    required double fallback,
    required double min,
    required double max,
  }) {
    final number = value is num ? value.toDouble() : fallback;
    if (!number.isFinite) return fallback;
    return number.clamp(min, max).toDouble();
  }

  /// Reads a bounded non-negative integer, or null when the value is unusable.
  static int? _asInt(Object? value) {
    if (value is int) return value < 0 ? 0 : value;
    if (value is num) {
      if (!value.isFinite) return null;
      return value <= 0 ? 0 : value.toInt();
    }
    return null;
  }
}
