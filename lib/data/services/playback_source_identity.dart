import '../../domain/models/media_entry.dart';

/// Identity of the playback attempt a snapshot belongs to.
///
/// [boundary] is the load attempt that requested the source. Events from an
/// earlier attempt carry an earlier boundary and must be rejected by the view
/// model instead of being attributed to the newest request.
class SourceAttachment {
  const SourceAttachment({
    this.boundary = 0,
    this.source,
    this.loaded = false,
    this.verified = false,
  });

  /// No source is attributable (idle engine, or events from a source that was
  /// never requested).
  static const SourceAttachment none = SourceAttachment();

  final int boundary;

  /// Canonical identity of the attached source, when known.
  final String? source;

  /// Whether position and duration from the engine may be trusted.
  final bool loaded;

  /// Whether the identity came from the native engine rather than from our own
  /// request. Observation-free platforms fall back to request attribution.
  final bool verified;

  bool get hasSource => source != null;
  bool get isEmpty => source == null;

  SourceAttachment copyWith({
    int? boundary,
    String? source,
    bool? loaded,
    bool? verified,
  }) {
    return SourceAttachment(
      boundary: boundary ?? this.boundary,
      source: source ?? this.source,
      loaded: loaded ?? this.loaded,
      verified: verified ?? this.verified,
    );
  }

  @override
  String toString() =>
      'SourceAttachment(boundary: $boundary, source: $source, loaded: $loaded, '
      'verified: $verified)';
}

/// Assigns playback-attempt identity to native engine events.
///
/// The engine can deliver callbacks for a source that is no longer requested: a
/// slow open, a queue edit such as appending, reordering or removing another
/// item, undo, or a rapid next/previous. Identity therefore follows the source
/// the engine reports (`started`), never the source the player last requested.
///
/// The tracker also owns the "is this source really open" gate: `loaded` stays
/// false for a new attempt until the engine confirms the content, so progress
/// from the previous source cannot be attributed to the new one.
class PlaybackSourceIdentity {
  PlaybackSourceIdentity({
    String Function(String source)? canonicalize,
    int remember = 32,
  }) : _canonicalize = canonicalize ?? MediaEntry.canonicalSource,
       _rememberLimit = remember;

  final String Function(String source) _canonicalize;
  final int _rememberLimit;

  /// Canonical source -> load attempt that requested it, oldest first.
  final Map<String, int> _requests = <String, int>{};
  final Map<String, int> _rawRequests = <String, int>{};

  int _boundary = 0;
  int? _pendingBoundary;

  SourceAttachment _request = SourceAttachment.none;
  SourceAttachment _native = SourceAttachment.none;

  /// Whether the native engine reports its own events.
  ///
  /// While false the tracker falls back to the requested source, which keeps
  /// platforms without property observation behaving exactly as before.
  bool observationActive = false;

  /// The attachment every outgoing snapshot is stamped with.
  SourceAttachment get attached {
    if (observationActive) return _native;
    return _request.copyWith(loaded: _request.hasSource);
  }

  /// The load attempt of the most recent request that the engine has not
  /// resolved yet, when there is one.
  int? get pendingBoundary => _pendingBoundary;

  /// The unresolved request's attachment.
  ///
  /// libmpv reports a failed load without ever notifying `path`, so this is the
  /// only identity that can describe a failure while a request is outstanding.
  SourceAttachment? get unresolvedRequest {
    if (_pendingBoundary == null || !_request.hasSource) return null;
    return _request;
  }

  /// Highest assigned attempt number.
  int get boundaryCounter => _boundary;

  /// Enables native attribution once observation is registered.
  ///
  /// A source requested before observation existed keeps its identity, so
  /// playback can be attributed as soon as the native `path` report arrives.
  /// A request by itself is not proof that the engine attached or loaded it.
  void activateObservation({required bool supported}) {
    observationActive = supported;
  }

  /// Registers a new load attempt for [source] and returns its boundary.
  int beginOpen(String source) {
    final canonical = _canonicalize(source);
    _boundary++;
    _remember(_requests, canonical, _boundary);
    _remember(_rawRequests, source, _boundary);
    _pendingBoundary = _boundary;
    _request = SourceAttachment(
      boundary: _boundary,
      source: canonical,
      loaded: false,
    );
    // Until the engine reports `path`, its properties may still belong to the
    // previous source, even when this request reopens the same path.
    _native = SourceAttachment(boundary: _boundary);
    return _boundary;
  }

  /// Marks that the engine will not attach a new source (stop/clear queue).
  int beginStop() {
    _boundary++;
    _request = SourceAttachment(boundary: _boundary);
    _native = SourceAttachment(boundary: _boundary);
    _pendingBoundary = null;
    return _boundary;
  }

  /// The engine reported it started loading a source.
  SourceAttachment attachStarted(String rawSource) {
    final canonical = _canonicalize(rawSource);
    var boundary = _requests[canonical] ?? _rawRequests[rawSource] ?? 0;
    if (boundary == 0 && _pendingBoundary != null) {
      // Some sources (percent-encoded stream URLs) canonicalize differently in
      // the engine than in the queue. A single unresolved request can only be
      // the load the engine is reporting.
      boundary = _pendingBoundary!;
      _remember(_requests, canonical, boundary);
    }
    if (boundary == 0) {
      // Unknown source: keep the previous attachment so the view model rejects
      // the events as stale instead of attaching them to the current attempt.
      return _native;
    }
    _native = SourceAttachment(
      boundary: boundary,
      source: canonical,
      loaded: false,
      verified: true,
    );
    if (boundary == _pendingBoundary) {
      _pendingBoundary = null;
    }
    return _native;
  }

  /// The engine confirmed the attached source is open.
  SourceAttachment attachLoaded() {
    // This signal has no source identity. Until `path` attaches a source it may
    // be a retained property value from the previous source or from startup.
    if (!_native.hasSource) return _native;
    _native = _native.copyWith(loaded: true);
    return _native;
  }

  /// The engine reached the end of the attached source.
  SourceAttachment attachEnded() => _native;

  void _remember(Map<String, int> target, String key, int boundary) {
    target.remove(key);
    target[key] = boundary;
    while (target.length > _rememberLimit) {
      target.remove(target.keys.first);
    }
  }
}
