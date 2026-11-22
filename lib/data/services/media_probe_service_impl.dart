import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/media_catalog.dart';
import '../../domain/models/media_kind.dart';
import '../../domain/models/media_metadata.dart';
import 'media_probe_service.dart';

import 'pure_dart_media_parser.dart';

export 'pure_dart_media_parser.dart'
    show DiscoveredMediaInfo, DiscoveredTrack, PureDartMediaParser;

const int _maxArtworkBytes = 12 * 1024 * 1024;

Future<Uint8List?> _readBoundedFile(File file, int maxBytes) async {
  RandomAccessFile? handle;
  try {
    handle = await file.open(mode: FileMode.read);
    if (await handle.length() > maxBytes) return null;
    final bytes = await handle.read(maxBytes + 1);
    return bytes.length <= maxBytes ? bytes : null;
  } finally {
    await handle?.close();
  }
}

/// Lightweight cancellation token for probe and artwork operations.
class CancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners) {
      try {
        listener();
      } catch (_) {}
    }
    _listeners.clear();
  }

  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

/// Extraction boundary for media probing, supporting pluggable or mocked engines.
abstract interface class MediaProbeEngine {
  Future<DiscoveredMediaInfo?> inspect(
    String filePath, {
    required bool isAudioHint,
    CancellationToken? cancellationToken,
  });

  Future<Uint8List?> extractEmbeddedArtwork(
    String filePath, {
    CancellationToken? cancellationToken,
  });

  void dispose();
}

/// Pure Dart parser for ID3v2, FLAC, and MP4 embedded metadata & artwork.
class MediaKitProbeEngine implements MediaProbeEngine {
  MediaKitProbeEngine({
    Player Function()? playerFactory,
    PureDartMediaParser? pureDartParser,
  }) : _playerFactory = playerFactory ?? _defaultPlayerFactory,
       _pureDartParser = pureDartParser ?? const PureDartMediaParser();

  final Player Function() _playerFactory;
  final PureDartMediaParser _pureDartParser;

  Player? _player;
  bool _disposed = false;
  Future<void> _nativeInspectionTail = Future<void>.value();
  Future<void>? _retiredPlayerDisposal;
  final Expando<Future<void>> _playerDisposals = Expando<Future<void>>(
    'probe player disposal',
  );
  Timer? _idleDisposeTimer;
  int _activeInspections = 0;
  static const Duration _idleDisposeDelay = Duration(seconds: 5);

  void _scheduleIdleDispose() {
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = Timer(_idleDisposeDelay, () {
      _idleDisposeTimer = null;
      if (_disposed || _activeInspections > 0) return;
      final player = _player;
      if (player == null) return;
      _player = null;
      unawaited(_disposePlayer(player));
    });
  }

  static Player _defaultPlayerFactory() => Player(
    configuration: const PlayerConfiguration(
      title: 'Mpvson media probe decoder',
      vo: 'null',
      muted: true,
      osc: false,
      libass: false,
      bufferSize: 2 * 1024 * 1024,
    ),
  );

  Player _getOrCreatePlayer() {
    if (_player != null) return _player!;
    return _player = _playerFactory();
  }

  @override
  Future<DiscoveredMediaInfo?> inspect(
    String filePath, {
    required bool isAudioHint,
    CancellationToken? cancellationToken,
  }) {
    _idleDisposeTimer?.cancel();
    _activeInspections++;
    return _inspect(
      filePath,
      isAudioHint: isAudioHint,
      cancellationToken: cancellationToken,
    ).whenComplete(() {
      _activeInspections--;
      if (!_disposed && _player != null && _activeInspections == 0) {
        _scheduleIdleDispose();
      }
    });
  }

  Future<DiscoveredMediaInfo?> _inspect(
    String filePath, {
    required bool isAudioHint,
    CancellationToken? cancellationToken,
  }) async {
    if (_disposed || (cancellationToken?.isCancelled ?? false)) return null;

    // Fast path: pure Dart tag & container inspection for audio and video.
    final pureResult = await _pureDartParser.parse(filePath);
    final hasCompleteTechnicalInfo =
        pureResult != null &&
        (isAudioHint
            ? pureResult.audioInfo != null
            : (pureResult.videoInfo != null && !pureResult.videoInfo!.isEmpty));
    if (pureResult != null &&
        pureResult.duration > Duration.zero &&
        hasCompleteTechnicalInfo) {
      // Skip native inspection when the container supplied stream details.
      return pureResult;
    }

    final previousInspection = _nativeInspectionTail;
    final inspectionFinished = Completer<void>();
    _nativeInspectionTail = inspectionFinished.future;
    await previousInspection;
    try {
      final retiredPlayerDisposal = _retiredPlayerDisposal;
      if (retiredPlayerDisposal != null) {
        await retiredPlayerDisposal;
        if (identical(_retiredPlayerDisposal, retiredPlayerDisposal)) {
          _retiredPlayerDisposal = null;
        }
      }
      if (_disposed || (cancellationToken?.isCancelled ?? false)) {
        return pureResult;
      }

      // The probe engine reuses one native Player, so native inspection must
      // stay serialized even when the service runs several file probes at once.
      Player? player;
      try {
        player = _getOrCreatePlayer();
      } catch (_) {
        return pureResult;
      }

      var playerRetired = false;
      try {
        try {
          await player
              .open(Media(filePath), play: false)
              .timeout(const Duration(seconds: 4));
        } on TimeoutException {
          playerRetired = true;
          if (identical(_player, player)) _player = null;
          _retiredPlayerDisposal = _disposePlayer(player);
          return pureResult;
        }

        final native = player.platform;
        Future<String?> readNativeProperty(String name) async {
          if (native is! NativePlayer) return null;
          try {
            final value =
                (await native
                        .getProperty(name)
                        .timeout(const Duration(seconds: 1)))
                    .trim();
            return value.isEmpty || value == 'unavailable' || value == 'no'
                ? null
                : value;
          } catch (_) {
            return null;
          }
        }

        // Player.open resets its state before loading the next source. Wait
        // for its asynchronous track and duration notifications to arrive
        // using streams directly instead of polling on a 50ms timer.
        final waitLimit = isAudioHint
            ? const Duration(milliseconds: 600)
            : const Duration(seconds: 3);

        final activePlayer = player;
        bool tracksAndDurationReady() {
          final state = activePlayer.state;
          if (state.duration <= Duration.zero) return false;
          if (isAudioHint) {
            for (final t in state.tracks.audio) {
              if (t.id != 'auto' && t.id != 'no' && t.codec != null) {
                return true;
              }
            }
            return false;
          }
          for (final t in state.tracks.video) {
            if (t.id != 'auto' && t.id != 'no') return true;
          }
          for (final t in state.tracks.audio) {
            if (t.id != 'auto' && t.id != 'no') return true;
          }
          return false;
        }

        if (!tracksAndDurationReady() &&
            !_disposed &&
            !(cancellationToken?.isCancelled ?? false)) {
          final readyCompleter = Completer<void>();
          void completeIfReady() {
            if (readyCompleter.isCompleted) return;
            if (_disposed ||
                (cancellationToken?.isCancelled ?? false) ||
                tracksAndDurationReady()) {
              readyCompleter.complete();
            }
          }

          final tracksSub = activePlayer.stream.tracks.listen(
            (_) => completeIfReady(),
          );
          final durationSub = activePlayer.stream.duration.listen(
            (_) => completeIfReady(),
          );
          Timer? cancelPoll;
          if (cancellationToken != null) {
            cancelPoll = Timer.periodic(
              const Duration(milliseconds: 50),
              (_) => completeIfReady(),
            );
          }
          try {
            // Re-check once after attaching listeners to close the microtask
            // window between the initial check and stream subscription.
            completeIfReady();
            if (!readyCompleter.isCompleted) {
              await readyCompleter.future.timeout(waitLimit, onTimeout: () {});
            }
          } finally {
            cancelPoll?.cancel();
            await tracksSub.cancel();
            await durationSub.cancel();
          }
        }
        if (_disposed || (cancellationToken?.isCancelled ?? false)) {
          return null;
        }

        final videoTracks = player.state.tracks.video
            .where((t) => t.id != 'auto' && t.id != 'no')
            .toList();
        final audioTracks = player.state.tracks.audio
            .where((t) => t.id != 'auto' && t.id != 'no')
            .toList();

        final discoveredTracks = <DiscoveredTrack>[
          for (final t in videoTracks)
            DiscoveredTrack(
              id: t.id,
              isVideo: true,
              isAudio: false,
              isArtwork: t.albumart == true || t.image == true,
              codec: t.codec,
              width: t.w,
              height: t.h,
            ),
          for (final t in audioTracks)
            DiscoveredTrack(
              id: t.id,
              isVideo: false,
              isAudio: true,
              codec: t.codec,
              sampleRate: t.samplerate,
              channels: t.channelscount,
              bitrate: t.bitrate,
            ),
        ];

        if (discoveredTracks.isEmpty && native is NativePlayer) {
          final count =
              int.tryParse(
                await readNativeProperty('track-list/count') ?? '',
              ) ??
              0;
          for (var index = 0; index < count && index < 32; index++) {
            final type = await readNativeProperty('track-list/$index/type');
            if (type != 'audio' && type != 'video') continue;
            final artwork =
                type == 'video' &&
                ((await readNativeProperty('track-list/$index/albumart')) ==
                        'yes' ||
                    (await readNativeProperty('track-list/$index/image')) ==
                        'yes');
            discoveredTracks.add(
              DiscoveredTrack(
                id: '$index',
                isVideo: type == 'video',
                isAudio: type == 'audio',
                isArtwork: artwork,
                codec: await readNativeProperty('track-list/$index/codec'),
                width: type == 'video'
                    ? int.tryParse(
                        await readNativeProperty('track-list/$index/demux-w') ??
                            '',
                      )
                    : null,
                height: type == 'video'
                    ? int.tryParse(
                        await readNativeProperty('track-list/$index/demux-h') ??
                            '',
                      )
                    : null,
                fps: type == 'video'
                    ? double.tryParse(
                        await readNativeProperty(
                              'track-list/$index/demux-fps',
                            ) ??
                            '',
                      )
                    : null,
                sampleRate: type == 'audio'
                    ? int.tryParse(
                        await readNativeProperty(
                              'track-list/$index/demux-samplerate',
                            ) ??
                            '',
                      )
                    : null,
                channels: type == 'audio'
                    ? int.tryParse(
                        await readNativeProperty(
                              'track-list/$index/demux-channel-count',
                            ) ??
                            '',
                      )
                    : null,
                bitrate: int.tryParse(
                  await readNativeProperty('track-list/$index/demux-bitrate') ??
                      '',
                ),
              ),
            );
          }
        }

        final duration = player.state.duration > Duration.zero
            ? player.state.duration
            : (pureResult?.duration ?? Duration.zero);

        final hasEmbeddedArtwork =
            pureResult?.hasEmbeddedArtwork == true ||
            discoveredTracks.any((t) => t.isArtwork);

        final tags = <String, String>{
          if (pureResult != null) ...pureResult.rawTags,
        };
        if (native is NativePlayer) {
          final rawMeta = await readNativeProperty('metadata');
          if (rawMeta != null && rawMeta.startsWith('{')) {
            try {
              final decoded = jsonDecode(rawMeta);
              if (decoded is Map) {
                for (final entry in decoded.entries) {
                  final k = entry.key.toString().trim();
                  final v = entry.value?.toString().trim() ?? '';
                  if (k.isNotEmpty && v.isNotEmpty && !tags.containsKey(k)) {
                    tags[k] = v;
                  }
                }
              }
            } catch (_) {}
          }
        }

        VideoTechnicalInfo? videoInfo = pureResult?.videoInfo;
        final videoTrack = discoveredTracks
            .where((track) => track.isVideo && !track.isArtwork)
            .firstOrNull;
        if (videoTrack != null) {
          var vWidth = videoTrack.width ?? videoInfo?.width;
          var vHeight = videoTrack.height ?? videoInfo?.height;
          var vFps = videoTrack.fps ?? videoInfo?.fps;
          var vBitrate = videoTrack.bitrate ?? videoInfo?.bitrate;
          if (native is NativePlayer) {
            if (vFps == null || vFps <= 0) {
              vFps = double.tryParse(
                await readNativeProperty('container-fps') ?? '',
              );
            }
            if (vBitrate == null || vBitrate <= 0) {
              vBitrate = int.tryParse(
                await readNativeProperty('video-bitrate') ?? '',
              );
            }
            if (vWidth == null || vWidth <= 0) {
              vWidth = int.tryParse(
                await readNativeProperty('video-params/w') ?? '',
              );
            }
            if (vHeight == null || vHeight <= 0) {
              vHeight = int.tryParse(
                await readNativeProperty('video-params/h') ?? '',
              );
            }
          }
          videoInfo = VideoTechnicalInfo(
            codec: videoTrack.codec ?? videoInfo?.codec,
            width: (vWidth != null && vWidth > 0) ? vWidth : videoInfo?.width,
            height: (vHeight != null && vHeight > 0)
                ? vHeight
                : videoInfo?.height,
            fps: (vFps != null && vFps > 0) ? vFps : videoInfo?.fps,
            bitrate: (vBitrate != null && vBitrate > 0)
                ? vBitrate
                : videoInfo?.bitrate,
          );
        }

        AudioTechnicalInfo? audioInfo = pureResult?.audioInfo;
        final audioTrack = discoveredTracks
            .where((track) => track.isAudio)
            .firstOrNull;
        if (audioTrack != null) {
          audioInfo = AudioTechnicalInfo(
            codec: audioTrack.codec ?? audioInfo?.codec,
            sampleRate: audioTrack.sampleRate ?? audioInfo?.sampleRate,
            channels: audioTrack.channels ?? audioInfo?.channels,
            bitrate: audioTrack.bitrate ?? audioInfo?.bitrate,
            bitsPerSample: audioInfo?.bitsPerSample,
          );
        }
        if (isAudioHint && audioInfo?.codec == null && native is NativePlayer) {
          final count =
              int.tryParse(
                await readNativeProperty('track-list/count') ?? '',
              ) ??
              0;
          for (var index = 0; index < count && index < 32; index++) {
            if (await readNativeProperty('track-list/$index/type') != 'audio') {
              continue;
            }
            audioInfo = AudioTechnicalInfo(
              codec:
                  await readNativeProperty('track-list/$index/codec') ??
                  audioInfo?.codec,
              sampleRate:
                  int.tryParse(
                    await readNativeProperty(
                          'track-list/$index/demux-samplerate',
                        ) ??
                        '',
                  ) ??
                  audioInfo?.sampleRate,
              channels:
                  int.tryParse(
                    await readNativeProperty(
                          'track-list/$index/demux-channel-count',
                        ) ??
                        '',
                  ) ??
                  audioInfo?.channels,
              bitrate:
                  int.tryParse(
                    await readNativeProperty(
                          'track-list/$index/demux-bitrate',
                        ) ??
                        '',
                  ) ??
                  audioInfo?.bitrate,
              bitsPerSample: audioInfo?.bitsPerSample,
            );
            break;
          }
        }

        return DiscoveredMediaInfo(
          tracks: discoveredTracks.isNotEmpty
              ? discoveredTracks
              : (isAudioHint ? pureResult?.tracks ?? const [] : const []),
          rawTags: tags,
          duration: duration,
          hasEmbeddedArtwork: hasEmbeddedArtwork,
          embeddedArtworkBytes: pureResult?.embeddedArtworkBytes,
          audioInfo: audioInfo,
          videoInfo: videoInfo,
        );
      } catch (_) {
        return pureResult;
      } finally {
        if (!playerRetired) {
          try {
            await player.stop();
          } catch (_) {}
        }
      }
    } finally {
      inspectionFinished.complete();
    }
  }

  @override
  Future<Uint8List?> extractEmbeddedArtwork(
    String filePath, {
    CancellationToken? cancellationToken,
  }) async {
    if (_disposed || (cancellationToken?.isCancelled ?? false)) return null;

    final pureResult = await _pureDartParser.parse(filePath);
    if (_disposed || (cancellationToken?.isCancelled ?? false)) return null;
    if (pureResult?.embeddedArtworkBytes != null) {
      return pureResult!.embeddedArtworkBytes;
    }
    return null;
  }

  Future<void> _disposePlayer(Player player) =>
      _playerDisposals[player] ??= player.dispose().catchError((Object _) {});

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _idleDisposeTimer?.cancel();
    _idleDisposeTimer = null;
    final player = _player;
    _player = null;
    if (player != null) {
      unawaited(
        _nativeInspectionTail
            .then((_) => _disposePlayer(player))
            .catchError((Object _) {}),
      );
    }
  }
}

/// Helper that tracks a pending or running probe request in the priority queue.
class _ProbeRequest implements Comparable<_ProbeRequest> {
  _ProbeRequest({
    required this.id,
    required this.filePath,
    required this.priority,
    required this.completer,
    required this.cancellationToken,
  });

  final int id;
  final String filePath;
  final int priority;
  final Completer<ProbeResult> completer;
  final CancellationToken cancellationToken;

  @override
  int compareTo(_ProbeRequest other) {
    // Higher priority first; equal priority = FIFO
    final p = other.priority.compareTo(priority);
    if (p != 0) return p;
    return id.compareTo(other.id);
  }
}

/// Represents an artwork cache record in the LRU cache.
class _ArtworkCacheRecord {
  _ArtworkCacheRecord({
    required this.key,
    required this.path,
    required this.bytes,
    required this.lastAccessed,
  });

  final String key;
  final String path;
  final int bytes;
  DateTime lastAccessed;
}

/// Full implementation of [MediaProbeService].
class MediaProbeServiceImpl implements MediaProbeService {
  MediaProbeServiceImpl({
    MediaProbeEngine? engine,
    Directory? cacheDirectory,
    Future<Directory> Function()? cacheDirectoryProvider,
    int maxArtworkDimension = 1024,
    int maxCacheEntries = 100,
    int maxCacheBytes = 64 * 1024 * 1024,
    int maxConcurrentProbes = 2,
    Future<Uint8List> Function(Uint8List, {int maxDimension})? imageNormalizer,
    Player Function()? playerFactory,
  }) : _engine = engine ?? MediaKitProbeEngine(playerFactory: playerFactory),
       _providedCacheDirectory = cacheDirectory,
       // ignore: prefer_initializing_formals
       _cacheDirectoryProvider = cacheDirectoryProvider,
       // ignore: prefer_initializing_formals
       _maxArtworkDimension = maxArtworkDimension,
       // ignore: prefer_initializing_formals
       _maxCacheEntries = maxCacheEntries,
       // ignore: prefer_initializing_formals
       _maxCacheBytes = maxCacheBytes,
       // ignore: prefer_initializing_formals
       _maxConcurrentProbes = maxConcurrentProbes,
       _imageNormalizer = imageNormalizer ?? _defaultImageNormalizer;

  final MediaProbeEngine _engine;
  final Directory? _providedCacheDirectory;
  final Future<Directory> Function()? _cacheDirectoryProvider;
  final int _maxArtworkDimension;
  final int _maxCacheEntries;
  final int _maxCacheBytes;
  final int _maxConcurrentProbes;
  final Future<Uint8List> Function(Uint8List, {int maxDimension})
  _imageNormalizer;

  final List<_ProbeRequest> _pendingProbes = <_ProbeRequest>[];
  final List<_ProbeRequest> _activeProbes = <_ProbeRequest>[];
  final List<CancellationToken> _activeArtworkTokens = <CancellationToken>[];
  final Map<String, Future<String?>> _artworkRequests =
      <String, Future<String?>>{};
  final Map<String, Future<File?>> _nearbyArtworkLookups =
      <String, Future<File?>>{};
  static const int _maximumNearbyArtworkDirectories = 128;

  /// Negative (failure) cache for artwork lookups, keyed by
  /// `'<contentKey>|<embeddedOnly>'` so a failure while resolving
  /// embedded-only artwork never poisons the full lookup and vice versa.
  final Map<String, DateTime> _artworkFailures = <String, DateTime>{};
  static const int _maximumArtworkFailureEntries = 512;
  static const Duration _artworkFailureTtl = Duration(minutes: 10);

  /// How old an on-disk artwork cache file may become before the startup
  /// prune removes it.
  static const Duration _startupArtworkPruneAge = Duration(days: 30);

  final LinkedHashMap<String, _ArtworkCacheRecord> _artworkCache =
      LinkedHashMap<String, _ArtworkCacheRecord>();
  int _currentCacheBytes = 0;

  int _nextRequestId = 0;
  bool _disposed = false;
  Directory? _resolvedCacheDir;

  /// Distinguishes media kind based on file extension and stream tracks.
  static MediaKind classifyMediaKind(
    String filePath,
    List<DiscoveredTrack> tracks, {
    bool hasAudioMetadata = false,
  }) {
    final hint = MediaCatalog.kindFromExtension(filePath);

    final videoTracks = tracks.where((t) => t.isVideo).toList();
    final audioTracks = tracks.where((t) => t.isAudio).toList();

    final ordinaryVideoTracks = videoTracks.where((t) => !t.isArtwork).toList();
    final artworkVideoTracks = videoTracks.where((t) => t.isArtwork).toList();

    // Ordinary video tracks classify as MediaKind.video.
    if (ordinaryVideoTracks.isNotEmpty) {
      return MediaKind.video;
    }

    // Audio with embedded album art must be classified as MediaKind.audio.
    // Artwork-only video tracks must NEVER classify a song as video.
    if (audioTracks.isNotEmpty || artworkVideoTracks.isNotEmpty) {
      return MediaKind.audio;
    }

    // Fall back to extension hint or metadata hint
    if (hint == MediaKind.audio ||
        (hasAudioMetadata && hint != MediaKind.video)) {
      return MediaKind.audio;
    }
    if (hint == MediaKind.video) {
      return MediaKind.video;
    }

    return MediaKind.unknown;
  }

  /// Normalizes metadata tags case-insensitively and parses numbers, dates, and audio info.
  static MediaMetadata normalizeMetadata({
    required Map<String, String> rawTags,
    required Duration duration,
    AudioTechnicalInfo? audioInfo,
    VideoTechnicalInfo? videoInfo,
    String? artworkUri,
  }) {
    // Normalize keys: lowercased and stripped of non-alphanumeric characters
    final normalized = <String, String>{};
    for (final entry in rawTags.entries) {
      final key = entry.key.trim().toLowerCase();
      final stripped = key.replaceAll(RegExp(r'[^a-z0-9]'), '');
      final val = entry.value.trim();
      if (val.isEmpty) continue;
      normalized[key] = val;
      if (stripped.isNotEmpty) {
        normalized[stripped] = val;
      }
    }

    String? lookup(List<String> keys) {
      for (final k in keys) {
        final lower = k.toLowerCase();
        final stripped = lower.replaceAll(RegExp(r'[^a-z0-9]'), '');
        final val = normalized[lower] ?? normalized[stripped];
        if (val != null && val.isNotEmpty) return val;
      }
      return null;
    }

    final title = lookup([
      'title',
      'tracktitle',
      'songtitle',
      'tit2',
      'tt2',
      '©nam',
    ]);
    final artist = lookup([
      'artist',
      'author',
      'leadartist',
      'tpe1',
      'tp1',
      '©art',
    ]);
    final albumArtist = lookup([
      'albumartist',
      'album_artist',
      'album-artist',
      'album artist',
      'band',
      'tpe2',
      'tp2',
      'aart',
    ]);
    final album = lookup(['album', 'talb', 'tal', '©alb']);
    final genre = lookup(['genre', 'tcon', 'tco', '©gen']);

    final yearStr = lookup([
      'year',
      'date',
      'tyer',
      'tdrc',
      'tye',
      'originaldate',
      'originalyear',
      'original_year',
      '©day',
    ]);
    final year = _parseYear(yearStr);

    final trackStr = lookup([
      'track',
      'tracknumber',
      'track_number',
      'track-number',
      'trck',
      'trk',
      'trkn',
    ]);
    final trackNumber = _parseFirstInt(trackStr);

    final discStr = lookup([
      'disc',
      'discnumber',
      'disc_number',
      'disc-number',
      'disk',
      'tpos',
      'tpa',
    ]);
    final discNumber = _parseFirstInt(discStr);

    // Audio technical info tag fallback
    final tagCodec = lookup(['codec', 'audiocodec', 'audio_codec']);
    final tagSampleRate = _parseFirstInt(
      lookup(['samplerate', 'sample_rate', 'sample-rate']),
    );
    final tagChannels = _parseFirstInt(
      lookup(['channels', 'channelscount', 'audio_channels']),
    );
    final tagBitrate = _parseFirstInt(
      lookup(['bitrate', 'audio_bitrate', 'audio-bitrate']),
    );

    final effectiveAudioInfo = AudioTechnicalInfo(
      codec: audioInfo?.codec ?? tagCodec,
      sampleRate: audioInfo?.sampleRate ?? tagSampleRate,
      channels: audioInfo?.channels ?? tagChannels,
      bitrate: audioInfo?.bitrate ?? tagBitrate,
      bitsPerSample: audioInfo?.bitsPerSample,
    );

    return MediaMetadata(
      title: title,
      artist: artist,
      albumArtist: albumArtist,
      album: album,
      genre: genre,
      year: year,
      trackNumber: trackNumber,
      discNumber: discNumber,
      duration: duration,
      artworkUri: artworkUri,
      audioInfo:
          (effectiveAudioInfo.codec != null ||
              effectiveAudioInfo.sampleRate != null ||
              effectiveAudioInfo.channels != null)
          ? effectiveAudioInfo
          : null,
      videoInfo: (videoInfo != null && !videoInfo.isEmpty) ? videoInfo : null,
    );
  }

  static int? _parseYear(String? dateStr) {
    if (dateStr == null) return null;
    final match = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(dateStr);
    if (match != null) {
      return int.tryParse(match.group(0)!);
    }
    final digits = RegExp(r'\d{4}').firstMatch(dateStr);
    if (digits != null) {
      return int.tryParse(digits.group(0)!);
    }
    return null;
  }

  static int? _parseFirstInt(String? str) {
    if (str == null) return null;
    final match = RegExp(r'^\s*(\d+)').firstMatch(str);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }

  /// Locates nearby cover, front, or folder artwork files in the same directory.
  static Future<File?> findNearbyArtwork(String mediaFilePath) async {
    final file = File(mediaFilePath);
    final parentDir = file.parent;
    if (!await parentDir.exists()) return null;

    const names = ['cover', 'front', 'folder', 'album', 'art'];
    final extensions = MediaCatalog.imageExtensions;

    // 1. Direct match
    for (final name in names) {
      for (final ext in extensions) {
        final candidate = File(p.join(parentDir.path, '$name.$ext'));
        if (await candidate.exists()) {
          return candidate;
        }
      }
    }

    // 2. Directory enumeration for case-insensitive and prefix match
    try {
      await for (final entry in parentDir.list(followLinks: false)) {
        if (entry is! File) continue;
        final base = p.basenameWithoutExtension(entry.path).toLowerCase();
        final ext = p.extension(entry.path).toLowerCase().replaceFirst('.', '');
        if (!extensions.contains(ext)) continue;
        if (names.any(
          (name) =>
              base == name ||
              base.startsWith('$name-') ||
              base.startsWith('${name}_') ||
              base.startsWith('$name '),
        )) {
          return entry;
        }
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) async {
    if (_disposed) {
      throw const ProbeCancelledException('Probe service has been disposed');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Media file not found', filePath);
    }
    if (_disposed) {
      throw const ProbeCancelledException('Probe service has been disposed');
    }

    final completer = Completer<ProbeResult>();
    final token = CancellationToken();
    final request = _ProbeRequest(
      id: _nextRequestId++,
      filePath: filePath,
      priority: priority ?? 0,
      completer: completer,
      cancellationToken: token,
    );

    _pendingProbes.add(request);
    _pendingProbes.sort();
    _pumpProbes();

    return completer.future;
  }

  void _pumpProbes() {
    if (_disposed) return;
    while (_activeProbes.length < _maxConcurrentProbes &&
        _pendingProbes.isNotEmpty) {
      final request = _pendingProbes.removeAt(0);
      if (request.cancellationToken.isCancelled) {
        if (!request.completer.isCompleted) {
          request.completer.completeError(const ProbeCancelledException());
        }
        continue;
      }
      _activeProbes.add(request);
      _executeProbe(request);
    }
  }

  Future<void> _executeProbe(_ProbeRequest request) async {
    try {
      if (request.cancellationToken.isCancelled) {
        throw const ProbeCancelledException();
      }

      final file = File(request.filePath);
      final stat = await file.stat();

      final isAudioHint =
          MediaCatalog.kindFromExtension(request.filePath) == MediaKind.audio;

      final info = await _engine.inspect(
        request.filePath,
        isAudioHint: isAudioHint,
        cancellationToken: request.cancellationToken,
      );

      if (request.cancellationToken.isCancelled) {
        throw const ProbeCancelledException();
      }

      final tracks = info?.tracks ?? const <DiscoveredTrack>[];
      final rawTags = info?.rawTags ?? const <String, String>{};
      final duration = info?.duration ?? Duration.zero;

      final kind = classifyMediaKind(
        request.filePath,
        tracks,
        hasAudioMetadata: rawTags.isNotEmpty,
      );

      final hasArtwork =
          info?.hasEmbeddedArtwork == true ||
          tracks.any((t) => t.isArtwork) ||
          info?.embeddedArtworkBytes != null;

      String? artworkUri;
      if (isAudioHint || hasArtwork) {
        try {
          artworkUri = await resolveArtwork(request.filePath);
        } catch (_) {
          // Missing or unsupported artwork must not prevent indexing.
        }
      }
      if (request.cancellationToken.isCancelled) {
        throw const ProbeCancelledException();
      }
      final metadata = normalizeMetadata(
        rawTags: rawTags,
        duration: duration,
        audioInfo: info?.audioInfo,
        videoInfo: info?.videoInfo,
        artworkUri: artworkUri,
      );

      final result = ProbeResult(
        canonicalSource: p.canonicalize(request.filePath),
        path: request.filePath,
        kind: kind,
        metadata: metadata,
        fileSize: stat.size,
        modifiedAt: stat.modified,
        hasEmbeddedArtwork: hasArtwork,
      );

      if (!request.completer.isCompleted) {
        request.completer.complete(result);
      }
    } catch (e, st) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(e, st);
      }
    } finally {
      _activeProbes.remove(request);
      _pumpProbes();
    }
  }

  @override
  Future<String?> resolveArtwork(String filePath, {bool embeddedOnly = false}) {
    final key = '${p.canonicalize(filePath)}|$embeddedOnly';
    final active = _artworkRequests[key];
    if (active != null) return active;
    final future = _resolveArtwork(filePath, embeddedOnly: embeddedOnly);
    _artworkRequests[key] = future;
    return future.whenComplete(() {
      if (identical(_artworkRequests[key], future)) {
        _artworkRequests.remove(key);
      }
    });
  }

  Future<String?> _resolveArtwork(
    String filePath, {
    required bool embeddedOnly,
  }) async {
    if (_disposed) return null;

    final file = File(filePath);
    if (!await file.exists()) return null;

    final stat = await file.stat();
    final cacheDir = await _getArtworkCacheDirectory();

    // Cache key derived from file path and modification timestamp. The
    // effective key carries the lookup mode so embedded-only and full
    // lookups never share cache entries, failure records, or temp files.
    final rawKey =
        'art:$filePath:${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    final key = sha256.convert(utf8.encode(rawKey)).toString();
    final effectiveKey = '$key|$embeddedOnly';

    // 0. Skip probing when this mode failed recently.
    if (_hasRecentArtworkFailure(effectiveKey)) return null;

    // 1. Check existing bounded cache record
    final cachedRecord = _artworkCache[effectiveKey];
    if (cachedRecord != null) {
      final cachedFile = File(cachedRecord.path);
      if (await cachedFile.exists()) {
        _touchCacheRecord(effectiveKey);
        return cachedRecord.path;
      } else {
        _artworkCache.remove(effectiveKey);
        _currentCacheBytes -= cachedRecord.bytes;
      }
    }

    // Check disk directly in case record wasn't in memory
    final diskFile = File(
      p.join(cacheDir.path, '${_diskKeyFor(effectiveKey)}.png'),
    );
    if (await diskFile.exists()) {
      final diskStat = await diskFile.stat();
      _recordCacheEntry(effectiveKey, diskFile.path, diskStat.size);
      return diskFile.path;
    }

    final token = CancellationToken();
    _activeArtworkTokens.add(token);

    try {
      // 2. Try embedded artwork first
      Uint8List? rawBytes = await _engine.extractEmbeddedArtwork(
        filePath,
        cancellationToken: token,
      );

      // 3. Fallback to nearby artwork if not embedded-only
      if ((rawBytes == null || rawBytes.isEmpty) && !embeddedOnly) {
        final nearby = await _findNearbyArtwork(filePath);
        if (nearby != null && await nearby.exists()) {
          rawBytes = await _readBoundedFile(nearby, _maxArtworkBytes);
        }
      }

      if (token.isCancelled || _disposed) return null;
      if (rawBytes == null || rawBytes.isEmpty) {
        _recordArtworkFailure(effectiveKey);
        return null;
      }

      // 4. Bounded rendition up to maxArtworkDimension (1024px)
      final normalizedBytes = await _imageNormalizer(
        rawBytes,
        maxDimension: _maxArtworkDimension,
      );

      if (token.isCancelled || _disposed) return null;
      if (normalizedBytes.isEmpty) {
        _recordArtworkFailure(effectiveKey);
        return null;
      }

      // 5. Save normalized artwork in application-cache directory. The temp
      // name is mode-specific so concurrent embedded-only and full lookups
      // cannot clobber each other's temp file.
      final tempFile = File(
        p.join(cacheDir.path, '${_diskKeyFor(effectiveKey)}.tmp'),
      );
      await tempFile.writeAsBytes(normalizedBytes, flush: true);
      final finalFile = await tempFile.rename(diskFile.path);

      _clearArtworkFailure(effectiveKey);
      _recordCacheEntry(effectiveKey, finalFile.path, normalizedBytes.length);
      _pruneCache();

      return finalFile.path;
    } catch (_) {
      _recordArtworkFailure(effectiveKey);
      return null;
    } finally {
      _activeArtworkTokens.remove(token);
    }
  }

  Future<File?> _findNearbyArtwork(String filePath) {
    final directory = p.dirname(filePath);
    final active = _nearbyArtworkLookups[directory];
    if (active != null) return active;
    if (_nearbyArtworkLookups.length >= _maximumNearbyArtworkDirectories) {
      _nearbyArtworkLookups.remove(_nearbyArtworkLookups.keys.first);
    }
    late final Future<File?> lookup;
    lookup = findNearbyArtwork(filePath).then((file) {
      // Missing artwork can be added later, so only positive directory
      // lookups are retained.
      if (file == null && identical(_nearbyArtworkLookups[directory], lookup)) {
        _nearbyArtworkLookups.remove(directory);
      }
      return file;
    });
    _nearbyArtworkLookups[directory] = lookup;
    return lookup;
  }

  void _touchCacheRecord(String key) {
    final record = _artworkCache.remove(key);
    if (record != null) {
      record.lastAccessed = DateTime.now();
      _artworkCache[key] = record;
    }
  }

  void _recordCacheEntry(String key, String path, int bytes) {
    final existing = _artworkCache.remove(key);
    if (existing != null) {
      _currentCacheBytes -= existing.bytes;
    }
    _artworkCache[key] = _ArtworkCacheRecord(
      key: key,
      path: path,
      bytes: bytes,
      lastAccessed: DateTime.now(),
    );
    _currentCacheBytes += bytes;
    _pruneCache();
  }

  void _pruneCache() {
    while (_artworkCache.length > _maxCacheEntries ||
        _currentCacheBytes > _maxCacheBytes) {
      if (_artworkCache.isEmpty) break;
      final oldestKey = _artworkCache.keys.first;
      final oldest = _artworkCache.remove(oldestKey);
      if (oldest != null) {
        _currentCacheBytes -= oldest.bytes;
        try {
          final file = File(oldest.path);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
    }
  }

  /// Filesystem-safe disk key for an artwork cache entry. `|` is not valid in
  /// Windows file names, so the effective key is hashed again for disk use.
  static String _diskKeyFor(String effectiveKey) =>
      sha256.convert(utf8.encode(effectiveKey)).toString();

  bool _hasRecentArtworkFailure(String effectiveKey) {
    final failedAt = _artworkFailures[effectiveKey];
    if (failedAt == null) return false;
    if (DateTime.now().isBefore(failedAt.add(_artworkFailureTtl))) return true;
    _artworkFailures.remove(effectiveKey);
    return false;
  }

  void _recordArtworkFailure(String effectiveKey) {
    if (_artworkFailures.length >= _maximumArtworkFailureEntries) {
      _artworkFailures.remove(_artworkFailures.keys.first);
    }
    _artworkFailures[effectiveKey] = DateTime.now();
  }

  void _clearArtworkFailure(String effectiveKey) {
    _artworkFailures.remove(effectiveKey);
  }

  /// One-time LRU-style prune run when the artwork cache directory is first
  /// resolved: removes orphaned `.tmp` files left by previous sessions and
  /// cache entries that have not been touched within
  /// [_startupArtworkPruneAge].
  Future<void> _pruneStartupCache(Directory directory) async {
    try {
      final cutoff = DateTime.now().subtract(_startupArtworkPruneAge);
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        final isTemp = name.endsWith('.tmp');
        if (!isTemp && !name.endsWith('.png')) continue;
        try {
          if (isTemp) {
            await entity.delete();
            continue;
          }
          final stat = await entity.stat();
          if (stat.type == FileSystemEntityType.file &&
              stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } on FileSystemException {
          // Pruning must never fail an artwork lookup.
        }
      }
    } on Object {
      // Startup pruning is best-effort.
    }
  }

  Future<Directory> _getArtworkCacheDirectory() async {
    if (_resolvedCacheDir != null) return _resolvedCacheDir!;

    Directory baseDir;
    if (_providedCacheDirectory != null) {
      baseDir = _providedCacheDirectory;
    } else if (_cacheDirectoryProvider != null) {
      baseDir = await _cacheDirectoryProvider();
    } else {
      try {
        baseDir = await getApplicationCacheDirectory();
      } catch (_) {
        baseDir = Directory.systemTemp;
      }
    }

    final artworkDir = Directory(p.join(baseDir.path, 'artwork_cache'));
    await artworkDir.create(recursive: true);
    await _pruneStartupCache(artworkDir);
    return _resolvedCacheDir = artworkDir;
  }

  static Future<Uint8List> _defaultImageNormalizer(
    Uint8List bytes, {
    int maxDimension = 1024,
  }) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;

      if (width <= maxDimension && height <= maxDimension) {
        return bytes;
      }

      int targetWidth = width;
      int targetHeight = height;
      if (width >= height) {
        targetWidth = maxDimension;
        targetHeight = ((height * maxDimension) / width).round().clamp(
          1,
          maxDimension,
        );
      } else {
        targetHeight = maxDimension;
        targetWidth = ((width * maxDimension) / height).round().clamp(
          1,
          maxDimension,
        );
      }

      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData != null) {
        return byteData.buffer.asUint8List();
      }
    } catch (_) {
      throw const FormatException('Could not normalize the artwork image.');
    } finally {
      try {
        frame?.image.dispose();
      } catch (_) {}
      try {
        codec?.dispose();
      } catch (_) {}
      try {
        descriptor?.dispose();
      } catch (_) {}
      try {
        buffer?.dispose();
      } catch (_) {}
    }
    throw const FormatException('Could not normalize the artwork image.');
  }

  @override
  void cancelAll() {
    for (final request in _pendingProbes) {
      request.cancellationToken.cancel();
      if (!request.completer.isCompleted) {
        request.completer.completeError(const ProbeCancelledException());
      }
    }
    _pendingProbes.clear();

    for (final request in _activeProbes.toList()) {
      request.cancellationToken.cancel();
      if (!request.completer.isCompleted) {
        request.completer.completeError(const ProbeCancelledException());
      }
    }
    for (final token in _activeArtworkTokens.toList()) {
      token.cancel();
    }
    _activeArtworkTokens.clear();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll();
    _engine.dispose();
  }
}
