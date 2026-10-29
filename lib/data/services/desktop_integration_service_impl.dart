import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/models/media_entry.dart';
import '../../domain/models/open_request.dart';
import '../../ui/player/player_controller.dart';
import '../repositories/app_preferences_repository.dart';
import '../repositories/media_library_repository.dart';
import 'desktop_integration_service.dart';
import 'media_probe_service.dart';
import 'open_request_coordinator.dart';

/// Implementation of [DesktopIntegrationService] bridging OS platform channels,
/// [PlayerController], and [OpenRequestCoordinator].
class DesktopIntegrationServiceImpl extends DesktopIntegrationService {
  DesktopIntegrationServiceImpl({
    this._controller,
    this._openRequestCoordinator,
    this._preferences,
    this._mediaProbeService,
    MethodChannel? singleInstanceChannel,
    MethodChannel? mediaControlsChannel,
    MethodChannel? powerChannel,
    this._urlLauncher,
    MediaLibraryRepository? libraryRepository,
  }) : singleInstanceChannel =
           singleInstanceChannel ??
           const MethodChannel('mpvson/single_instance'),
       mediaControlsChannel =
           mediaControlsChannel ?? const MethodChannel('mpvson/media_controls'),
       powerChannel = powerChannel ?? const MethodChannel('mpvson/power') {
    _libraryRepository = libraryRepository;
  }

  final MethodChannel singleInstanceChannel;
  final MethodChannel mediaControlsChannel;
  final MethodChannel powerChannel;
  final Future<bool> Function(Uri uri)? _urlLauncher;

  PlayerController? _controller;
  OpenRequestCoordinator? _openRequestCoordinator;
  AppPreferencesRepository? _preferences;
  final MediaProbeService? _mediaProbeService;
  MediaLibraryRepository? _libraryRepository;

  SystemPlaybackStatus _playbackStatus = SystemPlaybackStatus.stopped;
  MediaMetadata _currentMetadata = MediaMetadata.empty;
  String? _lastPlaybackSignature;
  bool _isAwakeInhibited = false;

  bool _initialized = false;
  bool _disposed = false;

  String? _currentTrackId;
  String? _lastSyncedEntryId;
  String? _lastSyncedTitle;

  bool? _lastCanPlay;
  bool? _lastCanPause;
  bool? _lastCanSeek;
  bool? _lastCanGoNext;
  bool? _lastCanGoPrevious;
  bool? _lastIsVideoPlaying;

  @override
  SystemPlaybackStatus get playbackStatus => _playbackStatus;

  @override
  MediaMetadata get currentMetadata => _currentMetadata;

  @override
  bool get isAwakeInhibited => _isAwakeInhibited;

  PlayerController? get controller => _controller;
  OpenRequestCoordinator? get openRequestCoordinator => _openRequestCoordinator;
  AppPreferencesRepository? get preferences => _preferences;
  MediaProbeService? get mediaProbeService => _mediaProbeService;

  void attachController(PlayerController controller) {
    if (_controller == controller) return;
    detachController();
    _controller = controller;
    if (_initialized && !_disposed) {
      _controller!.addListener(_onControllerChanged);
      _syncAll();
    }
  }

  void detachController() {
    if (_controller != null) {
      _controller!.removeListener(_onControllerChanged);
      _controller = null;
      if (_initialized && !_disposed) {
        _syncPlaybackState();
        _syncPowerLock();
      }
    }
  }

  void attachCoordinator(OpenRequestCoordinator coordinator) {
    _openRequestCoordinator = coordinator;
  }

  void attachPreferences(AppPreferencesRepository preferences) {
    if (_preferences == preferences) return;
    if (_preferences != null) {
      _preferences!.removeListener(_onPreferencesChanged);
    }
    _preferences = preferences;
    if (_initialized && !_disposed) {
      _preferences!.addListener(_onPreferencesChanged);
      _syncPowerLock();
    }
  }

  @override
  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;

    singleInstanceChannel.setMethodCallHandler(_handleSingleInstanceCall);
    mediaControlsChannel.setMethodCallHandler(_handleMediaControlsCall);
    powerChannel.setMethodCallHandler(_handlePowerCall);

    if (_controller != null) {
      _controller!.addListener(_onControllerChanged);
      _syncAll();
    }

    if (_preferences != null) {
      _preferences!.addListener(_onPreferencesChanged);
    }
  }

  @override
  Future<void> updatePlaybackState({
    required SystemPlaybackStatus status,
    required Duration position,
    required Duration duration,
    required double playbackRate,
  }) async {
    _playbackStatus = status;
    try {
      await mediaControlsChannel
          .invokeMethod('updatePlaybackState', <String, Object?>{
            'status': status.name,
            'position': position.inMilliseconds,
            'positionMs': position.inMilliseconds,
            'duration': duration.inMilliseconds,
            'durationMs': duration.inMilliseconds,
            'playbackRate': playbackRate,
            'rate': playbackRate,
          });
    } on MissingPluginException {
      // Platform channel not registered in test or unhandled platform.
    } on PlatformException {
      // Ignore platform errors.
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  Future<void> updateMetadata(MediaMetadata metadata) async {
    _currentMetadata = metadata;
    try {
      await mediaControlsChannel
          .invokeMethod('updateMetadata', <String, Object?>{
            'trackId': _currentTrackId,
            'title': metadata.title,
            'artist': metadata.artist ?? metadata.effectiveArtist,
            'album': metadata.album ?? metadata.effectiveAlbum,
            'albumArtist': metadata.albumArtist,
            'artworkPath': metadata.artworkUri,
            'artworkUri': metadata.artworkUri,
            'duration': metadata.duration.inMilliseconds,
            'durationMs': metadata.duration.inMilliseconds,
          });
    } on MissingPluginException {
      // Platform channel not registered.
    } on PlatformException {
      // Ignore platform errors.
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  Future<void> updateCapabilities({
    bool canPlay = true,
    bool canPause = true,
    bool canSeek = true,
    bool canGoNext = true,
    bool canGoPrevious = true,
  }) async {
    try {
      await mediaControlsChannel
          .invokeMethod('updateCapabilities', <String, Object?>{
            'canPlay': canPlay,
            'canPause': canPause,
            'canSeek': canSeek,
            'canGoNext': canGoNext,
            'canGoPrevious': canGoPrevious,
          });
    } on MissingPluginException {
      // Platform channel not registered.
    } on PlatformException {
      // Ignore platform errors.
    }
  }

  @override
  Future<void> setKeepAwake(bool enable, {required bool isVideoPlaying}) async {
    _isAwakeInhibited = enable;
    try {
      await powerChannel.invokeMethod('setKeepAwake', <String, Object?>{
        'enable': enable,
        'isVideoPlaying': isVideoPlaying,
        'assertionType': enable
            ? (isVideoPlaying ? 'display' : 'system')
            : 'none',
      });
    } on MissingPluginException {
      // Platform channel not registered.
    } on PlatformException {
      // Ignore platform errors.
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  Future<void> openDefaultAppsSettings() async {
    try {
      final result = await mediaControlsChannel.invokeMethod<bool>(
        'openDefaultAppsSettings',
      );
      if (result == true) return;
    } on MissingPluginException {
      // Fallback to URL launch or process start.
    } on PlatformException {
      // Fallback to URL launch or process start.
    }

    const settingsUriString = 'ms-settings:defaultapps';
    final uri = Uri.parse(settingsUriString);

    final launcher = _urlLauncher;
    if (launcher != null) {
      try {
        final launched = await launcher(uri);
        if (launched) return;
      } on Object {
        // Fall through to system fallback.
      }
    }

    try {
      if (await canLaunchUrl(uri)) {
        final launched = await launchUrl(uri);
        if (launched) return;
      }
    } on Object {
      // Fall through to Process run.
    }

    if (Platform.isWindows) {
      try {
        await Process.run('explorer.exe', [settingsUriString]);
      } on Object {
        // Best effort.
      }
    }
  }

  void sync() {
    _syncAll();
  }

  void _syncAll() {
    if (_disposed) return;
    _syncPlaybackState();
    _syncMetadata();
    _syncCapabilities();
    _syncPowerLock();
  }

  void _onControllerChanged() {
    if (_disposed || _controller == null) return;
    _syncAll();
  }

  void _onPreferencesChanged() {
    if (_disposed) return;
    _syncPowerLock();
  }

  void _syncPlaybackState() {
    if (_disposed) return;
    if (_controller == null) {
      if (_playbackStatus != SystemPlaybackStatus.stopped) {
        updatePlaybackState(
          status: SystemPlaybackStatus.stopped,
          position: Duration.zero,
          duration: Duration.zero,
          playbackRate: 1.0,
        );
      }
      return;
    }

    final SystemPlaybackStatus newStatus;
    if (_controller!.isClosing ||
        _controller!.closingState != ControllerClosingState.running) {
      newStatus = SystemPlaybackStatus.closed;
    } else if (_controller!.isPlaying) {
      newStatus = SystemPlaybackStatus.playing;
    } else if (_controller!.current == null || !_controller!.hasMedia) {
      newStatus = SystemPlaybackStatus.stopped;
    } else {
      newStatus = SystemPlaybackStatus.paused;
    }

    final pos = _controller!.position;
    final dur = _controller!.duration;
    final rate = _controller!.rate;
    // The controller notifies for many reasons that do not change what the OS
    // media session shows; only forward actual changes.
    final signature =
        '${newStatus.name}|${pos.inMilliseconds}|${dur.inMilliseconds}|'
        '${rate.toStringAsFixed(3)}';
    if (signature == _lastPlaybackSignature) return;
    _lastPlaybackSignature = signature;

    updatePlaybackState(
      status: newStatus,
      position: pos,
      duration: dur,
      playbackRate: rate,
    );
  }

  void _syncMetadata() {
    if (_disposed) return;
    if (_controller == null || _controller!.current == null) {
      if (_currentMetadata != MediaMetadata.empty) {
        _currentTrackId = null;
        _lastSyncedEntryId = null;
        _lastSyncedTitle = null;
        updateMetadata(MediaMetadata.empty);
      }
      return;
    }

    final entry = _controller!.current!;
    if (_lastSyncedEntryId != entry.id || _lastSyncedTitle != entry.title) {
      _lastSyncedEntryId = entry.id;
      _lastSyncedTitle = entry.title;
      _currentTrackId =
          '/dev/mpvson/mpvson/track/t${utf8.encode(entry.id).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';

      final metadata = _buildMetadataForEntry(entry, _controller!.duration);
      updateMetadata(metadata);
      _probeMetadataIfAvailable(entry);
    }
  }

  MediaMetadata _buildMetadataForEntry(
    MediaEntry entry,
    Duration controllerDuration,
  ) {
    var title = entry.title;
    final lastDot = title.lastIndexOf('.');
    if (lastDot > 0 &&
        !entry.path.startsWith('http://') &&
        !entry.path.startsWith('https://')) {
      final ext = title.substring(lastDot).toLowerCase();
      const knownExtensions = <String>{
        '.mp3',
        '.flac',
        '.wav',
        '.aac',
        '.ogg',
        '.m4a',
        '.wma',
        '.opus',
        '.alac',
        '.aiff',
        '.ape',
        '.dsf',
        '.mp4',
        '.mkv',
        '.avi',
        '.mov',
        '.wmv',
        '.flv',
        '.webm',
        '.m4v',
        '.ts',
        '.3gp',
        '.vob',
        '.ogv',
      };
      if (knownExtensions.contains(ext)) {
        title = title.substring(0, lastDot);
      }
    }

    String? artist;
    String? album;

    if (title.contains(' - ')) {
      final parts = title.split(' - ');
      if (parts.length >= 2) {
        artist = parts[0].trim();
        title = parts.sublist(1).join(' - ').trim();
      }
    }

    return MediaMetadata(
      title: title,
      artist: artist,
      album: album,
      duration: controllerDuration > Duration.zero
          ? controllerDuration
          : entry.duration,
    );
  }

  void _probeMetadataIfAvailable(MediaEntry entry) async {
    final controller = _controller;
    if (controller == null) return;
    // Library rows already carry parsed tags, so reading the record avoids
    // starting a second native probe while the requested song is loading.
    final library = _libraryRepository;
    if (library != null && library.isReady) {
      try {
        final record = await library.getMediaByCanonicalSource(entry.path);
        if (_disposed || controller.current?.id != entry.id) return;
        if (record != null) {
          updateMetadata(
            record.metadata.copyWith(
              duration: controller.duration > Duration.zero
                  ? controller.duration
                  : record.metadata.duration,
            ),
          );
          return;
        }
      } on Object {
        // Fall through to probing files that are not in the library.
      }
    }
    final probe = _mediaProbeService;
    if (probe == null) return;
    try {
      final probed = await probe.probe(entry.path);
      if (!_disposed && controller.current?.id == entry.id) {
        updateMetadata(probed.metadata);
      }
    } on Object {
      // Best-effort metadata probing.
    }
  }

  void _syncCapabilities() {
    if (_disposed) return;
    if (_controller == null) {
      updateCapabilities(
        canPlay: false,
        canPause: false,
        canSeek: false,
        canGoNext: false,
        canGoPrevious: false,
      );
      return;
    }

    final canPlay =
        _controller!.current != null || _controller!.queue.isNotEmpty;
    final canPause = _controller!.isPlaying;
    final canSeek = _controller!.duration > Duration.zero;
    final canGoNext = _controller!.queue.length > 1;
    final canGoPrevious = _controller!.queue.length > 1;

    if (canPlay != _lastCanPlay ||
        canPause != _lastCanPause ||
        canSeek != _lastCanSeek ||
        canGoNext != _lastCanGoNext ||
        canGoPrevious != _lastCanGoPrevious) {
      _lastCanPlay = canPlay;
      _lastCanPause = canPause;
      _lastCanSeek = canSeek;
      _lastCanGoNext = canGoNext;
      _lastCanGoPrevious = canGoPrevious;

      updateCapabilities(
        canPlay: canPlay,
        canPause: canPause,
        canSeek: canSeek,
        canGoNext: canGoNext,
        canGoPrevious: canGoPrevious,
      );
    }
  }

  void _syncPowerLock() {
    if (_disposed) return;
    if (_controller == null) {
      if (_isAwakeInhibited) {
        setKeepAwake(false, isVideoPlaying: false);
      }
      return;
    }

    final keepAwakePref =
        _preferences?.preferences.keepAwakeDuringPlayback ?? true;
    final isPlaying =
        _controller!.isPlaying &&
        !_controller!.isClosing &&
        _controller!.closingState == ControllerClosingState.running;

    final isVideo =
        _controller!.isVideo && _controller!.videoOutputPolicy.visible;
    final shouldKeepAwake = keepAwakePref && isPlaying && isVideo;

    if (shouldKeepAwake != _isAwakeInhibited ||
        (shouldKeepAwake && isVideo != _lastIsVideoPlaying)) {
      _lastIsVideoPlaying = isVideo;
      setKeepAwake(shouldKeepAwake, isVideoPlaying: isVideo);
    }
  }

  Future<dynamic> _handleSingleInstanceCall(MethodCall call) async {
    final args = call.arguments;
    final paths = <String>[];
    OpenIntent intent = OpenIntent.normal;

    if (args is List) {
      for (final item in args) {
        final s = item?.toString().trim();
        if (s == '--enqueue') intent = OpenIntent.enqueue;
        if (s != null && s.isNotEmpty && !s.startsWith('--')) {
          paths.add(s);
        }
      }
    } else if (args is Map) {
      final rawPaths = args['paths'] ?? args['sources'] ?? args['arguments'];
      if (rawPaths is List) {
        for (final item in rawPaths) {
          final s = item?.toString().trim();
          if (s != null && s.isNotEmpty && !s.startsWith('--')) {
            paths.add(s);
          }
        }
      } else if (rawPaths is String) {
        final s = rawPaths.trim();
        if (s.isNotEmpty && !s.startsWith('--')) {
          paths.add(s);
        }
      }
      final rawIntent = args['intent'] as String?;
      if (rawIntent != null) {
        for (final v in OpenIntent.values) {
          if (v.name == rawIntent) {
            intent = v;
            break;
          }
        }
      }
    } else if (args is String) {
      final s = args.trim();
      if (s.isNotEmpty && !s.startsWith('--')) {
        paths.add(s);
      }
    }

    if (paths.isNotEmpty) {
      if (_openRequestCoordinator != null) {
        final request = OpenRequest(
          id: 'single_instance_${DateTime.now().microsecondsSinceEpoch}',
          sources: paths,
          intent: intent,
          origin: OpenOrigin.osActivation,
          timestamp: DateTime.now(),
        );
        return (await _openRequestCoordinator!.handleOpenRequest(
              request,
            )).status ==
            OpenStatus.accepted;
      } else if (_controller != null) {
        await _controller!.openPaths(
          paths,
          append: intent == OpenIntent.enqueue,
        );
        return true;
      }
    }
    return true;
  }

  Future<dynamic> _handleMediaControlsCall(MethodCall call) async {
    switch (call.method) {
      case 'play':
        if (_controller != null && !_controller!.isPlaying) {
          await _controller!.togglePlayPause();
        }
        return true;
      case 'pause':
        if (_controller != null && _controller!.isPlaying) {
          await _controller!.togglePlayPause();
        }
        return true;
      case 'toggle':
      case 'togglePlayPause':
        if (_controller != null) {
          await _controller!.togglePlayPause();
        }
        return true;
      case 'next':
      case 'skipNext':
        if (_controller != null) {
          await _controller!.next();
        }
        return true;
      case 'prev':
      case 'previous':
      case 'skipPrevious':
        if (_controller != null) {
          await _controller!.previous();
        }
        return true;
      case 'stop':
        await _controller?.stop();
        return true;
      case 'setRate':
        final value = (call.arguments as Map?)?['rate'];
        if (value is num) await _controller?.setRate(value.toDouble());
        return true;
      case 'setVolume':
        final value = (call.arguments as Map?)?['volume'];
        if (value is num) await _controller?.setVolume(value.toDouble() * 100);
        return true;
      case 'setShuffle':
        final value = (call.arguments as Map?)?['shuffle'];
        if (value is bool) await _controller?.setShuffle(value);
        return true;
      case 'setLoopStatus':
        final value = (call.arguments as Map?)?['loopStatus'];
        final mode = switch (value) {
          'Track' => 'one',
          'Playlist' => 'all',
          'None' => 'off',
          _ => null,
        };
        if (mode != null) await _controller?.setRepeatMode(mode);
        return true;
      case 'seek':
        return await _handleSeekCommand(call.arguments);
      default:
        throw MissingPluginException('Not implemented for ${call.method}');
    }
  }

  Future<bool> _handleSeekCommand(dynamic args) async {
    if (_controller == null) return false;
    final current = _controller!.current;
    if (current == null) return false;

    Duration? targetPosition;
    String? targetTrackId;
    Duration? expectedDuration;

    if (args is Duration) {
      targetPosition = args;
    } else if (args is num) {
      targetPosition = Duration(milliseconds: args.toInt());
    } else if (args is Map) {
      final num? posMs = args['positionMs'] as num? ?? args['position'] as num?;
      if (posMs != null) {
        targetPosition = Duration(milliseconds: posMs.toInt());
      }
      targetTrackId =
          args['trackId'] as String? ??
          args['entryId'] as String? ??
          args['id'] as String? ??
          args['path'] as String? ??
          args['source'] as String?;
      final num? durMs = args['durationMs'] as num? ?? args['duration'] as num?;
      if (durMs != null) {
        expectedDuration = Duration(milliseconds: durMs.toInt());
      }
    }

    if (targetPosition == null) return false;

    // Stale check 1: Target track identifier does not match current track
    if (targetTrackId != null) {
      if (targetTrackId != current.id &&
          targetTrackId != current.path &&
          targetTrackId != current.title &&
          targetTrackId != _currentTrackId) {
        return false;
      }
    }

    // Stale check 2: Expected duration mismatch
    if (expectedDuration != null && _controller!.duration > Duration.zero) {
      final diff =
          (expectedDuration.inMilliseconds -
                  _controller!.duration.inMilliseconds)
              .abs();
      if (diff > 2000) {
        return false;
      }
    }

    await _controller!.seek(targetPosition);
    return true;
  }

  Future<dynamic> _handlePowerCall(MethodCall call) async {
    switch (call.method) {
      case 'getIsAwakeInhibited':
      case 'isInhibited':
        return _isAwakeInhibited;
      default:
        return null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    if (_isAwakeInhibited) {
      _isAwakeInhibited = false;
      try {
        powerChannel.invokeMethod('setKeepAwake', <String, Object?>{
          'enable': false,
          'isVideoPlaying': false,
          'assertionType': 'none',
        });
      } on Object {
        // Ignore on dispose.
      }
    }

    if (_controller != null) {
      _controller!.removeListener(_onControllerChanged);
      _controller = null;
    }
    if (_preferences != null) {
      _preferences!.removeListener(_onPreferencesChanged);
      _preferences = null;
    }

    singleInstanceChannel.setMethodCallHandler(null);
    mediaControlsChannel.setMethodCallHandler(null);
    powerChannel.setMethodCallHandler(null);

    super.dispose();
  }
}
