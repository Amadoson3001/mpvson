import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/media_catalog.dart';
import '../../domain/models/media_kind.dart';
import '../../domain/models/media_metadata.dart';
import 'media_probe_service.dart';

const int _maxTagBlockBytes = 16 * 1024 * 1024;
const int _maxTagFrameBytes = 8 * 1024 * 1024;
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

/// Represents a media track discovered during stream inspection.
class DiscoveredTrack {
  const DiscoveredTrack({
    required this.id,
    required this.isVideo,
    this.isAudio = false,
    this.isArtwork = false,
    this.codec,
    this.sampleRate,
    this.channels,
    this.bitrate,
    this.bitsPerSample,
    this.width,
    this.height,
  });

  final String id;
  final bool isVideo;
  final bool isAudio;
  final bool isArtwork;
  final String? codec;
  final int? sampleRate;
  final int? channels;
  final int? bitrate;
  final int? bitsPerSample;
  final int? width;
  final int? height;
}

/// Information discovered during media stream and tag inspection.
class DiscoveredMediaInfo {
  const DiscoveredMediaInfo({
    required this.tracks,
    required this.rawTags,
    this.duration = Duration.zero,
    this.hasEmbeddedArtwork = false,
    this.embeddedArtworkBytes,
    this.audioInfo,
  });

  final List<DiscoveredTrack> tracks;
  final Map<String, String> rawTags;
  final Duration duration;
  final bool hasEmbeddedArtwork;
  final Uint8List? embeddedArtworkBytes;
  final AudioTechnicalInfo? audioInfo;
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
class PureDartMediaParser {
  const PureDartMediaParser();

  /// Attempts to parse tags and artwork from known audio file containers.
  Future<DiscoveredMediaInfo?> parse(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      final length = await raf.length();
      if (length < 16) return null;

      final header = await raf.read(16);
      await raf.setPosition(0);

      // Check ID3v2
      if (header.length >= 3 &&
          header[0] == 0x49 &&
          header[1] == 0x44 &&
          header[2] == 0x33) {
        return await _parseId3v2(raf, length);
      }

      // Check FLAC ('fLaC')
      if (header.length >= 4 &&
          header[0] == 0x66 &&
          header[1] == 0x4C &&
          header[2] == 0x61 &&
          header[3] == 0x43) {
        return await _parseFlac(raf, length);
      }

      // Check MP4 / M4A (ftyp atom or moov atom)
      if (header.length >= 8) {
        final boxType = String.fromCharCodes(header.sublist(4, 8));
        if (boxType == 'ftyp' || boxType == 'moov') {
          return await _parseMp4(raf, length);
        }
      }

      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  Future<DiscoveredMediaInfo?> _parseId3v2(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    final headerBytes = await raf.read(10);
    if (headerBytes.length < 10) return null;

    final majorVersion = headerBytes[3];
    final tagSize = _readSyncSafeInt(headerBytes.sublist(6, 10));
    final endPos = (10 + tagSize)
        .clamp(0, fileLength.clamp(0, 10 + _maxTagBlockBytes))
        .toInt();

    final rawTags = <String, String>{};
    Uint8List? artworkBytes;
    bool hasArtwork = false;

    while (await raf.position() < endPos) {
      final frameHeaderLength = majorVersion >= 3 ? 10 : 6;
      final fHeader = await raf.read(frameHeaderLength);
      if (fHeader.length < frameHeaderLength) break;
      if (fHeader[0] == 0) break; // Padding reached

      String frameId;
      int frameSize;
      if (majorVersion >= 3) {
        frameId = String.fromCharCodes(fHeader.sublist(0, 4));
        frameSize = majorVersion == 4
            ? _readSyncSafeInt(fHeader.sublist(4, 8))
            : _readBigEndianInt32(fHeader.sublist(4, 8));
      } else {
        frameId = String.fromCharCodes(fHeader.sublist(0, 3));
        frameSize = (fHeader[3] << 16) | (fHeader[4] << 8) | fHeader[5];
      }

      final frameStart = await raf.position();
      if (frameSize <= 0 || frameStart + frameSize > endPos + 100) {
        break;
      }
      if (frameSize > _maxTagFrameBytes) {
        await raf.setPosition(frameStart + frameSize);
        continue;
      }

      final frameData = await raf.read(frameSize);
      if (frameData.length < frameSize) break;

      if (frameId.startsWith('T') && frameId != 'TXXX') {
        final text = _decodeId3Text(frameData);
        if (text != null && text.isNotEmpty) {
          rawTags[frameId] = text;
        }
      } else if (frameId == 'APIC' || frameId == 'PIC') {
        hasArtwork = true;
        artworkBytes = _extractId3ApicBytes(frameData);
      }
    }

    final tracks = <DiscoveredTrack>[
      const DiscoveredTrack(id: '1', isVideo: false, isAudio: true),
      if (hasArtwork)
        const DiscoveredTrack(
          id: 'artwork',
          isVideo: true,
          isAudio: false,
          isArtwork: true,
        ),
    ];

    return DiscoveredMediaInfo(
      tracks: tracks,
      rawTags: rawTags,
      hasEmbeddedArtwork: hasArtwork,
      embeddedArtworkBytes: artworkBytes,
    );
  }

  Future<DiscoveredMediaInfo?> _parseFlac(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    await raf.setPosition(4); // Skip 'fLaC'
    final rawTags = <String, String>{};
    Uint8List? artworkBytes;
    bool hasArtwork = false;
    Duration duration = Duration.zero;
    AudioTechnicalInfo? audioInfo;

    bool isLast = false;
    while (!isLast && await raf.position() < fileLength) {
      final header = await raf.read(4);
      if (header.length < 4) break;

      isLast = (header[0] & 0x80) != 0;
      final blockType = header[0] & 0x7F;
      final blockLength = (header[1] << 16) | (header[2] << 8) | header[3];

      if (blockLength < 0 || await raf.position() + blockLength > fileLength) {
        break;
      }
      final blockStart = await raf.position();
      final maxBlock = blockType == 6 ? _maxArtworkBytes : _maxTagBlockBytes;
      if (blockLength > maxBlock) {
        await raf.setPosition(blockStart + blockLength);
        continue;
      }

      final blockData = await raf.read(blockLength);
      if (blockData.length < blockLength) break;

      if (blockType == 0 && blockData.length >= 18) {
        // STREAMINFO
        final srPart1 = blockData[10];
        final srPart2 = blockData[11];
        final srPart3 = blockData[12];
        final sampleRate = (srPart1 << 12) | (srPart2 << 4) | (srPart3 >> 4);
        final channels = ((srPart3 >> 1) & 0x07) + 1;
        final bpsPart2 = blockData[13];
        final bitsPerSample = (((srPart3 & 0x01) << 4) | (bpsPart2 >> 4)) + 1;

        final totalSamples =
            ((bpsPart2 & 0x0F) * 0x100000000) +
            (blockData[14] << 24) +
            (blockData[15] << 16) +
            (blockData[16] << 8) +
            blockData[17];

        if (sampleRate > 0) {
          final microseconds = (totalSamples * 1000000 / sampleRate).round();
          duration = Duration(microseconds: microseconds);
        }

        audioInfo = AudioTechnicalInfo(
          codec: 'flac',
          sampleRate: sampleRate > 0 ? sampleRate : null,
          channels: channels,
          bitsPerSample: bitsPerSample,
        );
      } else if (blockType == 4) {
        // VORBIS_COMMENT
        _parseVorbisComment(blockData, rawTags);
      } else if (blockType == 6) {
        // PICTURE
        hasArtwork = true;
        artworkBytes = _extractFlacPicture(blockData);
      }
    }

    final tracks = <DiscoveredTrack>[
      DiscoveredTrack(
        id: '1',
        isVideo: false,
        isAudio: true,
        codec: audioInfo?.codec ?? 'flac',
        sampleRate: audioInfo?.sampleRate,
        channels: audioInfo?.channels,
      ),
      if (hasArtwork)
        const DiscoveredTrack(
          id: 'artwork',
          isVideo: true,
          isAudio: false,
          isArtwork: true,
        ),
    ];

    return DiscoveredMediaInfo(
      tracks: tracks,
      rawTags: rawTags,
      duration: duration,
      hasEmbeddedArtwork: hasArtwork,
      embeddedArtworkBytes: artworkBytes,
      audioInfo: audioInfo,
    );
  }

  Future<DiscoveredMediaInfo?> _parseMp4(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    final rawTags = <String, String>{};
    Uint8List? artworkBytes;
    bool hasArtwork = false;
    Duration duration = Duration.zero;

    // Scan top-level atoms looking for 'moov'
    while (await raf.position() + 8 <= fileLength) {
      final header = await raf.read(8);
      if (header.length < 8) break;
      final size = _readBigEndianInt32(header.sublist(0, 4));
      final type = String.fromCharCodes(header.sublist(4, 8));
      final atomDataSize = (size == 1 ? 0 : size) - 8;

      if (type == 'moov' && atomDataSize > 0) {
        final availableBytes = fileLength - await raf.position();
        if (atomDataSize > _maxTagBlockBytes || atomDataSize > availableBytes) {
          break;
        }
        final moovBytes = await raf.read(atomDataSize);
        _searchMp4Ilst(moovBytes, rawTags, (art) {
          hasArtwork = true;
          artworkBytes = art;
        });
        break;
      } else if (atomDataSize > 0) {
        await raf.setPosition(await raf.position() + atomDataSize);
      } else {
        break;
      }
    }

    final tracks = <DiscoveredTrack>[
      const DiscoveredTrack(
        id: '1',
        isVideo: false,
        isAudio: true,
        codec: 'aac',
      ),
      if (hasArtwork)
        const DiscoveredTrack(
          id: 'artwork',
          isVideo: true,
          isAudio: false,
          isArtwork: true,
        ),
    ];

    return DiscoveredMediaInfo(
      tracks: tracks,
      rawTags: rawTags,
      duration: duration,
      hasEmbeddedArtwork: hasArtwork,
      embeddedArtworkBytes: artworkBytes,
    );
  }

  void _parseVorbisComment(Uint8List data, Map<String, String> outTags) {
    if (data.length < 8) return;
    final vendorLen = _readLittleEndianInt32(data.sublist(0, 4));
    var offset = 4 + vendorLen;
    if (offset + 4 > data.length) return;

    final commentCount = _readLittleEndianInt32(
      data.sublist(offset, offset + 4),
    );
    offset += 4;

    for (var i = 0; i < commentCount && offset + 4 <= data.length; i++) {
      final len = _readLittleEndianInt32(data.sublist(offset, offset + 4));
      offset += 4;
      if (offset + len > data.length) break;

      final commentStr = utf8.decode(
        data.sublist(offset, offset + len),
        allowMalformed: true,
      );
      offset += len;

      final eqIdx = commentStr.indexOf('=');
      if (eqIdx > 0) {
        final key = commentStr.substring(0, eqIdx).trim();
        final val = commentStr.substring(eqIdx + 1).trim();
        outTags[key] = val;
      }
    }
  }

  Uint8List? _extractFlacPicture(Uint8List data) {
    try {
      if (data.length < 32) return null;
      var offset = 4; // Skip picture type
      final mimeLen = _readBigEndianInt32(data.sublist(offset, offset + 4));
      offset += 4 + mimeLen;
      if (offset + 4 > data.length) return null;

      final descLen = _readBigEndianInt32(data.sublist(offset, offset + 4));
      offset += 4 + descLen;
      offset += 16; // Skip width, height, depth, colors
      if (offset + 4 > data.length) return null;

      final dataLen = _readBigEndianInt32(data.sublist(offset, offset + 4));
      offset += 4;
      if (offset + dataLen > data.length) return null;

      return data.sublist(offset, offset + dataLen);
    } catch (_) {
      return null;
    }
  }

  void _searchMp4Ilst(
    Uint8List moov,
    Map<String, String> outTags,
    void Function(Uint8List artwork) onArtwork,
  ) {
    // Search for 'ilst' signature
    final ilstSignature = [0x69, 0x6C, 0x73, 0x74];
    final ilstIdx = _indexOfSublist(moov, ilstSignature);
    if (ilstIdx < 4) return;

    final ilstLen = _readBigEndianInt32(moov.sublist(ilstIdx - 4, ilstIdx));
    final ilstEnd = (ilstIdx - 4 + ilstLen).clamp(0, moov.length);

    var offset = ilstIdx + 4;
    while (offset + 8 <= ilstEnd) {
      final atomSize = _readBigEndianInt32(moov.sublist(offset, offset + 4));
      if (atomSize <= 8 || offset + atomSize > ilstEnd) break;

      final atomName = String.fromCharCodes(
        moov.sublist(offset + 4, offset + 8),
      );
      final atomData = moov.sublist(offset + 8, offset + atomSize);

      // Search for 'data' child atom
      final dataIdx = _indexOfSublist(atomData, [0x64, 0x61, 0x74, 0x61]);
      if (dataIdx >= 4 && dataIdx + 12 <= atomData.length) {
        final payload = atomData.sublist(dataIdx + 12);
        if (atomName == 'covr') {
          if (payload.length <= _maxArtworkBytes) onArtwork(payload);
        } else if (payload.length <= 1024 * 1024) {
          final text = utf8.decode(payload, allowMalformed: true).trim();
          if (text.isNotEmpty) {
            outTags[atomName] = text;
          }
        }
      }
      offset += atomSize;
    }
  }

  static String? _decodeId3Text(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final encoding = bytes[0];
    final content = bytes.sublist(1);
    try {
      if (encoding == 1 || encoding == 2) {
        // UTF-16
        final buffer = content.buffer.asUint16List(
          content.offsetInBytes,
          content.lengthInBytes ~/ 2,
        );
        return String.fromCharCodes(buffer).replaceAll('\u0000', '').trim();
      } else {
        // UTF-8 or Latin1
        return utf8
            .decode(content, allowMalformed: true)
            .replaceAll('\u0000', '')
            .trim();
      }
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _extractId3ApicBytes(Uint8List bytes) {
    try {
      if (bytes.length < 5) return null;
      var offset = 1; // skip encoding
      // Read MIME string
      while (offset < bytes.length && bytes[offset] != 0) {
        offset++;
      }
      offset++; // skip null terminator
      if (offset >= bytes.length) return null;
      offset++; // skip picture type
      // Read description
      while (offset < bytes.length && bytes[offset] != 0) {
        offset++;
      }
      offset++; // skip null terminator
      if (offset < bytes.length) {
        final length = bytes.length - offset;
        if (length <= _maxArtworkBytes) return bytes.sublist(offset);
      }
    } catch (_) {}
    return null;
  }

  static int _readSyncSafeInt(Uint8List bytes) {
    return ((bytes[0] & 0x7F) << 21) |
        ((bytes[1] & 0x7F) << 14) |
        ((bytes[2] & 0x7F) << 7) |
        (bytes[3] & 0x7F);
  }

  static int _readBigEndianInt32(Uint8List bytes) {
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }

  static int _readLittleEndianInt32(Uint8List bytes) {
    return (bytes[3] << 24) | (bytes[2] << 16) | (bytes[1] << 8) | bytes[0];
  }

  static int _indexOfSublist(Uint8List list, List<int> pattern) {
    if (pattern.isEmpty || list.length < pattern.length) return -1;
    for (var i = 0; i <= list.length - pattern.length; i++) {
      var found = true;
      for (var j = 0; j < pattern.length; j++) {
        if (list[i + j] != pattern[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }
}

/// MediaKit based probe engine using libmpv headless Player.
class MediaKitProbeEngine implements MediaProbeEngine {
  MediaKitProbeEngine({
    Player Function()? playerFactory,
    PureDartMediaParser? pureDartParser,
    this.playerIdleTimeout = const Duration(seconds: 15),
  }) : _playerFactory = playerFactory ?? _defaultPlayerFactory,
       _pureDartParser = pureDartParser ?? const PureDartMediaParser();

  final Player Function() _playerFactory;
  final PureDartMediaParser _pureDartParser;

  /// How long to retain the native metadata player after its last inspection.
  final Duration playerIdleTimeout;

  Player? _player;
  bool _disposed = false;
  Future<void> _nativeInspectionTail = Future<void>.value();
  Future<void>? _retiredPlayerDisposal;
  Timer? _playerIdleTimer;
  int _playerIdleGeneration = 0;
  int _pendingNativeInspections = 0;
  final Expando<Future<void>> _playerDisposals = Expando<Future<void>>(
    'probe player disposal',
  );

  static Player _defaultPlayerFactory() => Player(
    configuration: const PlayerConfiguration(
      title: 'Mpvson media probe decoder',
      vo: 'null',
      muted: true,
      osc: false,
      libass: false,
      bufferSize: 0,
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
  }) async {
    if (_disposed || (cancellationToken?.isCancelled ?? false)) return null;

    // Fast path: pure Dart tag & container inspection for audio
    final pureResult = await _pureDartParser.parse(filePath);
    if (pureResult != null && isAudioHint) {
      // Audio probe finishes as soon as audio metadata is available
      return pureResult;
    }

    final previousInspection = _nativeInspectionTail;
    final inspectionFinished = Completer<void>();
    _nativeInspectionTail = inspectionFinished.future;
    _pendingNativeInspections++;
    _cancelPlayerIdleTimer();
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

        // Wait for tracks with timeout; audio hints return immediately once audio track is present
        final watch = Stopwatch()..start();
        final waitLimit = isAudioHint
            ? const Duration(milliseconds: 600)
            : const Duration(seconds: 3);

        while (watch.elapsed < waitLimit) {
          if (_disposed || (cancellationToken?.isCancelled ?? false)) {
            return null;
          }

          final videoTracks = player.state.tracks.video
              .where((t) => t.id != 'auto' && t.id != 'no')
              .toList();
          final audioTracks = player.state.tracks.audio
              .where((t) => t.id != 'auto' && t.id != 'no')
              .toList();

          if (isAudioHint && audioTracks.isNotEmpty) {
            // Audio probes finish when audio metadata is available instead of waiting for video tracks.
            break;
          }
          if (!isAudioHint &&
              (videoTracks.isNotEmpty || audioTracks.isNotEmpty)) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
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

        final duration = player.state.duration > Duration.zero
            ? player.state.duration
            : (pureResult?.duration ?? Duration.zero);

        final hasEmbeddedArtwork =
            pureResult?.hasEmbeddedArtwork == true ||
            discoveredTracks.any((t) => t.isArtwork);

        final tags = <String, String>{
          if (pureResult != null) ...pureResult.rawTags,
        };

        AudioTechnicalInfo? audioInfo = pureResult?.audioInfo;
        if (audioTracks.isNotEmpty) {
          final a = audioTracks.first;
          audioInfo = AudioTechnicalInfo(
            codec: a.codec ?? audioInfo?.codec,
            sampleRate: a.samplerate ?? audioInfo?.sampleRate,
            channels: a.channelscount ?? audioInfo?.channels,
            bitrate: a.bitrate ?? audioInfo?.bitrate,
          );
        }

        return DiscoveredMediaInfo(
          tracks: discoveredTracks.isNotEmpty
              ? discoveredTracks
              : (pureResult?.tracks ?? const []),
          rawTags: tags,
          duration: duration,
          hasEmbeddedArtwork: hasEmbeddedArtwork,
          embeddedArtworkBytes: pureResult?.embeddedArtworkBytes,
          audioInfo: audioInfo,
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
      _pendingNativeInspections--;
      inspectionFinished.complete();
      final player = _player;
      if (player != null && _pendingNativeInspections == 0) {
        _schedulePlayerIdleRelease(player);
      }
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

  void _cancelPlayerIdleTimer() {
    _playerIdleGeneration++;
    _playerIdleTimer?.cancel();
    _playerIdleTimer = null;
  }

  void _schedulePlayerIdleRelease(Player player) {
    _cancelPlayerIdleTimer();
    final generation = _playerIdleGeneration;
    _playerIdleTimer = Timer(playerIdleTimeout, () {
      if (generation != _playerIdleGeneration) return;
      _playerIdleTimer = null;
      if (_disposed ||
          _pendingNativeInspections != 0 ||
          !identical(_player, player)) {
        return;
      }

      // Clear the shared slot before disposal begins. A later queued inspection
      // waits for this future before creating a replacement Player.
      _player = null;
      _retiredPlayerDisposal = _disposePlayer(player);
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelPlayerIdleTimer();
    final player = _player;
    _player = null;
    unawaited(
      _nativeInspectionTail
          .then((_) async {
            if (player != null) await _disposePlayer(player);
            final retiredPlayerDisposal = _retiredPlayerDisposal;
            if (retiredPlayerDisposal != null) await retiredPlayerDisposal;
          })
          .catchError((Object _) {}),
    );
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
    Duration playerIdleTimeout = const Duration(seconds: 15),
    Future<Uint8List> Function(Uint8List, {int maxDimension})? imageNormalizer,
    Player Function()? playerFactory,
  }) : _engine =
           engine ??
           MediaKitProbeEngine(
             playerFactory: playerFactory,
             playerIdleTimeout: playerIdleTimeout,
           ),
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

    final title = lookup(['title', 'tracktitle', 'songtitle', 'tit2', '©nam']);
    final artist = lookup(['artist', 'author', 'leadartist', 'tpe1', '©art']);
    final albumArtist = lookup([
      'albumartist',
      'album_artist',
      'album-artist',
      'album artist',
      'band',
      'tpe2',
      'aart',
    ]);
    final album = lookup(['album', 'talb', '©alb']);
    final genre = lookup(['genre', 'tcon', '©gen']);

    final yearStr = lookup([
      'year',
      'date',
      'tyer',
      'tdrc',
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
  static File? findNearbyArtwork(String mediaFilePath) {
    final file = File(mediaFilePath);
    final parentDir = file.parent;
    if (!parentDir.existsSync()) return null;

    const names = ['cover', 'front', 'folder', 'album', 'art'];
    const extensions = ['jpg', 'jpeg', 'png', 'webp', 'bmp'];

    // 1. Direct match
    for (final name in names) {
      for (final ext in extensions) {
        final candidate = File(p.join(parentDir.path, '$name.$ext'));
        if (candidate.existsSync()) {
          return candidate;
        }
      }
    }

    // 2. Directory enumeration for case-insensitive and prefix match
    try {
      final entries = parentDir.listSync(followLinks: false);
      for (final name in names) {
        for (final entry in entries) {
          if (entry is! File) continue;
          final base = p.basenameWithoutExtension(entry.path).toLowerCase();
          final ext = p
              .extension(entry.path)
              .toLowerCase()
              .replaceFirst('.', '');
          if (!extensions.contains(ext)) continue;
          if (base == name ||
              base.startsWith('$name-') ||
              base.startsWith('${name}_') ||
              base.startsWith('$name ')) {
            return entry;
          }
        }
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<ProbeResult> probe(String filePath, {int? priority}) {
    if (_disposed) {
      throw const ProbeCancelledException('Probe service has been disposed');
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Media file not found', filePath);
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
      if (info == null) {
        throw const ProbeInspectionFailedException();
      }

      final tracks = info.tracks;
      final rawTags = info.rawTags;
      final duration = info.duration;

      final kind = classifyMediaKind(
        request.filePath,
        tracks,
        hasAudioMetadata: rawTags.isNotEmpty,
      );

      final metadata = normalizeMetadata(
        rawTags: rawTags,
        duration: duration,
        audioInfo: info.audioInfo,
      );

      final hasArtwork =
          info.hasEmbeddedArtwork ||
          tracks.any((t) => t.isArtwork) ||
          info.embeddedArtworkBytes != null;

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
  Future<String?> resolveArtwork(
    String filePath, {
    bool embeddedOnly = false,
  }) async {
    if (_disposed) return null;

    final file = File(filePath);
    if (!file.existsSync()) return null;

    final stat = await file.stat();
    final cacheDir = await _getArtworkCacheDirectory();

    // Cache key derived from file path and modification timestamp
    final rawKey =
        'art:$filePath:${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    final key = sha256.convert(utf8.encode(rawKey)).toString();

    // 1. Check existing bounded cache record
    final cachedRecord = _artworkCache[key];
    if (cachedRecord != null) {
      final cachedFile = File(cachedRecord.path);
      if (cachedFile.existsSync()) {
        _touchCacheRecord(key);
        return cachedRecord.path;
      } else {
        _artworkCache.remove(key);
        _currentCacheBytes -= cachedRecord.bytes;
      }
    }

    // Check disk directly in case record wasn't in memory
    final diskFile = File(p.join(cacheDir.path, '$key.png'));
    if (diskFile.existsSync()) {
      final diskStat = await diskFile.stat();
      _recordCacheEntry(key, diskFile.path, diskStat.size);
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
        final nearby = findNearbyArtwork(filePath);
        if (nearby != null && nearby.existsSync()) {
          rawBytes = await _readBoundedFile(nearby, _maxArtworkBytes);
        }
      }

      if (rawBytes == null ||
          rawBytes.isEmpty ||
          token.isCancelled ||
          _disposed) {
        return null;
      }

      // 4. Bounded rendition up to maxArtworkDimension (1024px)
      final normalizedBytes = await _imageNormalizer(
        rawBytes,
        maxDimension: _maxArtworkDimension,
      );

      if (token.isCancelled || _disposed) return null;

      // 5. Save normalized artwork in application-cache directory
      final tempFile = File(p.join(cacheDir.path, '$key.tmp'));
      await tempFile.writeAsBytes(normalizedBytes, flush: true);
      final finalFile = await tempFile.rename(diskFile.path);

      _recordCacheEntry(key, finalFile.path, normalizedBytes.length);
      _pruneCache();

      return finalFile.path;
    } catch (_) {
      return null;
    } finally {
      _activeArtworkTokens.remove(token);
    }
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
    if (!artworkDir.existsSync()) {
      artworkDir.createSync(recursive: true);
    }
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
