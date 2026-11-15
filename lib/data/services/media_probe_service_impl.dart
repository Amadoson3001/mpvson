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
    this.fps,
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
  final double? fps;
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
    this.videoInfo,
  });

  final List<DiscoveredTrack> tracks;
  final Map<String, String> rawTags;
  final Duration duration;
  final bool hasEmbeddedArtwork;
  final Uint8List? embeddedArtworkBytes;
  final AudioTechnicalInfo? audioInfo;
  final VideoTechnicalInfo? videoInfo;
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
    if (!await file.exists()) return null;

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

      if (header.length >= 4 &&
          header[0] == 0x4f &&
          header[1] == 0x67 &&
          header[2] == 0x67 &&
          header[3] == 0x53) {
        return await _parseOgg(raf, length);
      }

      // Check EBML / Matroska / WebM (0x1A 0x45 0xDF 0xA3)
      if (header.length >= 4 &&
          header[0] == 0x1A &&
          header[1] == 0x45 &&
          header[2] == 0xDF &&
          header[3] == 0xA3) {
        return await _parseMatroska(raf, length);
      }

      // Check MP4 / M4A / MOV (ftyp atom or moov atom)
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
        artworkBytes = _extractId3ApicBytes(
          frameData,
          version22: frameId == 'PIC',
        );
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
      final atomStart = await raf.position();
      final header = await raf.read(8);
      if (header.length < 8) break;
      var size = _readBigEndianInt32(header.sublist(0, 4));
      final type = String.fromCharCodes(header.sublist(4, 8));
      var headerSize = 8;
      if (size == 1) {
        final extended = await raf.read(8);
        if (extended.length < 8) break;
        final high = _readBigEndianInt32(extended.sublist(0, 4));
        final low = _readBigEndianInt32(extended.sublist(4, 8));
        if (high > 0x7fffffff) break;
        size = (high << 32) | low;
        headerSize = 16;
      } else if (size == 0) {
        size = fileLength - atomStart;
      }
      if (size < headerSize || atomStart + size > fileLength) break;
      final atomDataSize = size - headerSize;

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
        return _parseMp4MoovDetails(
          moovBytes,
          rawTags: rawTags,
          hasArtwork: hasArtwork,
          artworkBytes: artworkBytes,
        );
      } else {
        await raf.setPosition(atomStart + size);
      }
    }

    return DiscoveredMediaInfo(
      tracks: const [],
      rawTags: rawTags,
      duration: duration,
      hasEmbeddedArtwork: hasArtwork,
      embeddedArtworkBytes: artworkBytes,
    );
  }

  static void _walkMp4Boxes(
    Uint8List bytes,
    int start,
    int end,
    void Function(String type, int dataStart, int dataEnd) onBox,
  ) {
    var pos = start;
    while (pos + 8 <= end) {
      final rawSize = _readUint32BE(bytes, pos);
      final type = String.fromCharCodes(bytes, pos + 4, pos + 8);
      var hdr = 8;
      int size = rawSize;
      if (rawSize == 1) {
        if (pos + 16 > end) break;
        final hi = _readUint32BE(bytes, pos + 8);
        final lo = _readUint32BE(bytes, pos + 12);
        if (hi > 0x7fffffff) break;
        size = (hi << 32) | lo;
        hdr = 16;
      } else if (rawSize == 0) {
        size = end - pos;
      }
      if (size < hdr || pos + size > end) break;
      onBox(type, pos + hdr, pos + size);
      pos += size;
    }
  }

  static int _readUint16BE(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

  static int _readUint32BE(Uint8List b, int o) =>
      ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) &
      0xFFFFFFFF;

  static int _readUint64BE(Uint8List b, int o) =>
      (_readUint32BE(b, o) << 32) | _readUint32BE(b, o + 4);

  static String _normalizeMp4Codec(String fourCc, {required bool isVideo}) {
    final lower = fourCc.trim().toLowerCase();
    if (isVideo) {
      switch (lower) {
        case 'avc1':
        case 'avc2':
        case 'avc3':
        case 'avc4':
          return 'h264';
        case 'hvc1':
        case 'hev1':
          return 'hevc';
        case 'vp08':
          return 'vp8';
        case 'vp09':
          return 'vp9';
        case 'av01':
          return 'av1';
        case 'mp4v':
          return 'mpeg4';
        default:
          return lower;
      }
    }
    switch (lower) {
      case 'mp4a':
        return 'aac';
      case 'ac-3':
        return 'ac3';
      case 'ec-3':
        return 'eac3';
      case 'opus':
        return 'opus';
      case 'alac':
        return 'alac';
      case 'flac':
        return 'flac';
      case 'mlpa':
        return 'truehd';
      default:
        return lower;
    }
  }

  static int? _readMp4BtrtAvgBitrate(
    Uint8List bytes,
    int subStart,
    int subEnd,
  ) {
    int? bitrate;
    _walkMp4Boxes(bytes, subStart, subEnd, (type, s, e) {
      if (type == 'btrt' && e - s >= 12) {
        final avg = _readUint32BE(bytes, s + 8);
        if (avg > 0) bitrate = avg;
      } else if (type == 'wave' || type == 'sinf') {
        bitrate ??= _readMp4BtrtAvgBitrate(bytes, s, e);
      }
    });
    return bitrate;
  }

  DiscoveredMediaInfo _parseMp4MoovDetails(
    Uint8List moov, {
    required Map<String, String> rawTags,
    required bool hasArtwork,
    required Uint8List? artworkBytes,
  }) {
    var movieDuration = Duration.zero;
    final tracks = <DiscoveredTrack>[];
    VideoTechnicalInfo? videoInfo;
    AudioTechnicalInfo? audioInfo;

    _walkMp4Boxes(moov, 0, moov.length, (type, start, end) {
      if (type == 'mvhd' && end - start >= 20) {
        final version = moov[start];
        int timescale = 0;
        int durUnits = 0;
        if (version == 0 && end - start >= 20) {
          timescale = _readUint32BE(moov, start + 12);
          durUnits = _readUint32BE(moov, start + 16);
        } else if (version == 1 && end - start >= 32) {
          timescale = _readUint32BE(moov, start + 20);
          durUnits = _readUint64BE(moov, start + 24);
        }
        if (timescale > 0 && durUnits > 0) {
          movieDuration = Duration(
            milliseconds: ((durUnits * 1000) / timescale).round(),
          );
        }
      } else if (type == 'trak') {
        int? tkhdWidth;
        int? tkhdHeight;
        int mdTimescale = 0;
        int mdDurUnits = 0;
        String? handlerType;
        String? codec;
        int? width;
        int? height;
        int? sampleRate;
        int? channels;
        int? bitrate;
        int totalSamples = 0;

        _walkMp4Boxes(moov, start, end, (tBox, ts, te) {
          if (tBox == 'tkhd' && te - ts >= 84) {
            final version = moov[ts];
            final wOff = version == 1 ? ts + 88 : ts + 76;
            final hOff = version == 1 ? ts + 92 : ts + 80;
            if (hOff + 4 <= te) {
              final w = _readUint32BE(moov, wOff) >> 16;
              final h = _readUint32BE(moov, hOff) >> 16;
              if (w > 0 && h > 0) {
                tkhdWidth = w;
                tkhdHeight = h;
              }
            }
          } else if (tBox == 'mdia') {
            _walkMp4Boxes(moov, ts, te, (mBox, ms, me) {
              if (mBox == 'mdhd' && me - ms >= 20) {
                final version = moov[ms];
                if (version == 0 && me - ms >= 20) {
                  mdTimescale = _readUint32BE(moov, ms + 12);
                  mdDurUnits = _readUint32BE(moov, ms + 16);
                } else if (version == 1 && me - ms >= 32) {
                  mdTimescale = _readUint32BE(moov, ms + 20);
                  mdDurUnits = _readUint64BE(moov, ms + 24);
                }
              } else if (mBox == 'hdlr' && me - ms >= 12) {
                handlerType = String.fromCharCodes(moov, ms + 8, ms + 12);
              } else if (mBox == 'minf') {
                _walkMp4Boxes(moov, ms, me, (nBox, ns, ne) {
                  if (nBox != 'stbl') return;
                  _walkMp4Boxes(moov, ns, ne, (sBox, ss, se) {
                    if (sBox == 'stsd' && se - ss >= 16) {
                      final entryCount = _readUint32BE(moov, ss + 4);
                      if (entryCount <= 0) return;
                      final entryStart = ss + 8;
                      if (entryStart + 8 > se) return;
                      final entrySize = _readUint32BE(moov, entryStart);
                      final entryEnd = (entryStart + entrySize).clamp(
                        entryStart,
                        se,
                      );
                      final fourCc = String.fromCharCodes(
                        moov,
                        entryStart + 4,
                        entryStart + 8,
                      );
                      if (handlerType == 'vide') {
                        codec = _normalizeMp4Codec(fourCc, isVideo: true);
                        if (entryStart + 36 <= entryEnd) {
                          final w = _readUint16BE(moov, entryStart + 32);
                          final h = _readUint16BE(moov, entryStart + 34);
                          if (w > 0 && h > 0) {
                            width = w;
                            height = h;
                          }
                        }
                        if (entryStart + 86 < entryEnd) {
                          bitrate ??= _readMp4BtrtAvgBitrate(
                            moov,
                            entryStart + 86,
                            entryEnd,
                          );
                        }
                      } else if (handlerType == 'soun') {
                        codec = _normalizeMp4Codec(fourCc, isVideo: false);
                        if (entryStart + 36 <= entryEnd) {
                          final ch = _readUint16BE(moov, entryStart + 24);
                          final sr = _readUint32BE(moov, entryStart + 32) >> 16;
                          if (ch > 0) channels = ch;
                          if (sr > 0) sampleRate = sr;
                        }
                        if (entryStart + 36 < entryEnd) {
                          bitrate ??= _readMp4BtrtAvgBitrate(
                            moov,
                            entryStart + 36,
                            entryEnd,
                          );
                        }
                      }
                    } else if (sBox == 'stts' && se - ss >= 8) {
                      final entryCount = _readUint32BE(
                        moov,
                        ss + 4,
                      ).clamp(0, 4096);
                      var pOff = ss + 8;
                      var sum = 0;
                      for (var i = 0; i < entryCount && pOff + 8 <= se; i++) {
                        sum += _readUint32BE(moov, pOff);
                        pOff += 8;
                      }
                      totalSamples = sum;
                    }
                  });
                });
              }
            });
          }
        });

        if (handlerType == 'vide') {
          width ??= tkhdWidth;
          height ??= tkhdHeight;
          double? fps;
          if (totalSamples > 0 && mdTimescale > 0 && mdDurUnits > 0) {
            final computed = (totalSamples * mdTimescale) / mdDurUnits;
            if (computed >= 0.5 && computed <= 240.0) {
              fps = double.parse(computed.toStringAsFixed(3));
            }
          }
          tracks.add(
            DiscoveredTrack(
              id: 'video-${tracks.length}',
              isVideo: true,
              codec: codec,
              width: width,
              height: height,
              fps: fps,
              bitrate: bitrate,
            ),
          );
          videoInfo ??= VideoTechnicalInfo(
            codec: codec,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
          );
        } else if (handlerType == 'soun') {
          tracks.add(
            DiscoveredTrack(
              id: 'audio-${tracks.length}',
              isVideo: false,
              isAudio: true,
              codec: codec,
              sampleRate: sampleRate,
              channels: channels,
              bitrate: bitrate,
            ),
          );
          audioInfo ??= AudioTechnicalInfo(
            codec: codec,
            sampleRate: sampleRate,
            channels: channels,
            bitrate: bitrate,
          );
        }
      }
    });

    return DiscoveredMediaInfo(
      tracks: tracks,
      rawTags: rawTags,
      duration: movieDuration,
      hasEmbeddedArtwork: hasArtwork,
      embeddedArtworkBytes: artworkBytes,
      audioInfo: audioInfo,
      videoInfo: (videoInfo != null && !videoInfo!.isEmpty) ? videoInfo : null,
    );
  }

  Future<DiscoveredMediaInfo?> _parseMatroska(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    Future<(int id, int size, int dataOffset)?> readElementHeaderAt(
      int pos,
    ) async {
      if (pos >= fileLength) return null;
      await raf.setPosition(pos);
      final peek = await raf.read(12);
      if (peek.isEmpty) return null;

      final idRes = _readEbmlVint(peek, 0, maskLeadingBit: false, maxLen: 4);
      if (idRes == null) return null;
      final sizeRes = _readEbmlVint(
        peek,
        idRes.$2,
        maskLeadingBit: true,
        maxLen: 8,
      );
      if (sizeRes == null) return null;
      return (idRes.$1, sizeRes.$1, pos + idRes.$2 + sizeRes.$2);
    }

    var cursor = 0;
    int? segmentStart;
    int segmentEnd = fileLength;
    for (var i = 0; i < 8 && cursor < fileLength; i++) {
      final el = await readElementHeaderAt(cursor);
      if (el == null) return null;
      final (id, size, dataStart) = el;
      if (id == 0x18538067) {
        segmentStart = dataStart;
        segmentEnd = size >= 0
            ? (dataStart + size).clamp(0, fileLength)
            : fileLength;
        break;
      }
      if (size < 0) break;
      cursor = dataStart + size;
    }
    if (segmentStart == null) return null;

    var timecodeScale = 1000000;
    double? rawDuration;
    final rawTags = <String, String>{};
    final tracks = <DiscoveredTrack>[];
    VideoTechnicalInfo? videoInfo;
    AudioTechnicalInfo? audioInfo;
    var sawInfo = false;
    var sawTracks = false;

    cursor = segmentStart;
    for (var i = 0; i < 64 && cursor < segmentEnd; i++) {
      final el = await readElementHeaderAt(cursor);
      if (el == null) break;
      final (id, size, dataStart) = el;
      // Stop once Clusters begin or both Info and Tracks are loaded.
      if (id == 0x1F43B675 || (sawInfo && sawTracks)) break;

      if (id == 0x1549A966 && size > 0 && size <= 1024 * 1024) {
        sawInfo = true;
        await raf.setPosition(dataStart);
        final infoBytes = await raf.read(size);
        _walkEbmlChildren(infoBytes, 0, infoBytes.length, (cid, cs, ce) {
          if (cid == 0x2AD7B1) {
            final v = _readEbmlUint(infoBytes, cs, ce);
            if (v > 0) timecodeScale = v;
          } else if (cid == 0x4489) {
            rawDuration = _readEbmlFloat(infoBytes, cs, ce);
          } else if (cid == 0x7BA9 && ce > cs) {
            final title = utf8
                .decode(infoBytes.sublist(cs, ce), allowMalformed: true)
                .trim();
            if (title.isNotEmpty) rawTags['title'] = title;
          }
        });
      } else if (id == 0x1654AE6B && size > 0 && size <= 2 * 1024 * 1024) {
        sawTracks = true;
        await raf.setPosition(dataStart);
        final tracksBytes = await raf.read(size);
        _walkEbmlChildren(tracksBytes, 0, tracksBytes.length, (cid, cs, ce) {
          if (cid != 0xAE) return;
          int? trackType;
          String? codecId;
          int? defaultDurationNs;
          int? width;
          int? height;
          double? sampleRate;
          int? channels;
          int? bitDepth;

          _walkEbmlChildren(tracksBytes, cs, ce, (tid, ts, te) {
            if (tid == 0x83) {
              trackType = _readEbmlUint(tracksBytes, ts, te);
            } else if (tid == 0x86) {
              codecId = ascii
                  .decode(tracksBytes.sublist(ts, te), allowInvalid: true)
                  .split('\u0000')
                  .first
                  .trim();
            } else if (tid == 0x23E383) {
              defaultDurationNs = _readEbmlUint(tracksBytes, ts, te);
            } else if (tid == 0xE0) {
              _walkEbmlChildren(tracksBytes, ts, te, (vid, vs, ve) {
                if (vid == 0xB0) {
                  width = _readEbmlUint(tracksBytes, vs, ve);
                } else if (vid == 0xBA) {
                  height = _readEbmlUint(tracksBytes, vs, ve);
                }
              });
            } else if (tid == 0xE1) {
              _walkEbmlChildren(tracksBytes, ts, te, (aid, as0, ae) {
                if (aid == 0xB5) {
                  sampleRate = _readEbmlFloat(tracksBytes, as0, ae);
                } else if (aid == 0x9F) {
                  channels = _readEbmlUint(tracksBytes, as0, ae);
                } else if (aid == 0x6264) {
                  bitDepth = _readEbmlUint(tracksBytes, as0, ae);
                }
              });
            }
          });

          final normalizedCodec = _normalizeMatroskaCodec(codecId);
          if (trackType == 1) {
            double? fps;
            if (defaultDurationNs != null && defaultDurationNs! > 0) {
              final computed = 1e9 / defaultDurationNs!;
              if (computed >= 0.5 && computed <= 240.0) {
                fps = double.parse(computed.toStringAsFixed(3));
              }
            }
            tracks.add(
              DiscoveredTrack(
                id: 'video-${tracks.length}',
                isVideo: true,
                codec: normalizedCodec,
                width: width,
                height: height,
                fps: fps,
              ),
            );
            videoInfo ??= VideoTechnicalInfo(
              codec: normalizedCodec,
              width: width,
              height: height,
              fps: fps,
            );
          } else if (trackType == 2) {
            final sr = sampleRate?.round();
            tracks.add(
              DiscoveredTrack(
                id: 'audio-${tracks.length}',
                isVideo: false,
                isAudio: true,
                codec: normalizedCodec,
                sampleRate: sr,
                channels: channels,
                bitsPerSample: bitDepth,
              ),
            );
            audioInfo ??= AudioTechnicalInfo(
              codec: normalizedCodec,
              sampleRate: sr,
              channels: channels,
              bitsPerSample: bitDepth,
            );
          }
        });
      }

      if (size < 0) break;
      cursor = dataStart + size;
    }

    final duration = (rawDuration != null && rawDuration! > 0)
        ? Duration(
            milliseconds: ((rawDuration! * timecodeScale) / 1000000.0).round(),
          )
        : Duration.zero;

    if (tracks.isEmpty && duration == Duration.zero && rawTags.isEmpty) {
      return null;
    }
    return DiscoveredMediaInfo(
      tracks: tracks,
      rawTags: rawTags,
      duration: duration,
      audioInfo: audioInfo,
      videoInfo: (videoInfo != null && !videoInfo!.isEmpty) ? videoInfo : null,
    );
  }

  static (int value, int length)? _readEbmlVint(
    Uint8List bytes,
    int offset, {
    required bool maskLeadingBit,
    required int maxLen,
  }) {
    if (offset >= bytes.length) return null;
    final first = bytes[offset];
    if (first == 0) return null;
    var len = 1;
    var mask = 0x80;
    while (len <= maxLen && (first & mask) == 0) {
      mask >>= 1;
      len++;
    }
    if (len > maxLen || offset + len > bytes.length) return null;
    var value = maskLeadingBit ? (first & (mask - 1)) : first;
    var allOnes = maskLeadingBit && value == (mask - 1);
    for (var i = 1; i < len; i++) {
      final b = bytes[offset + i];
      if (b != 0xFF) allOnes = false;
      value = (value << 8) | b;
    }
    if (maskLeadingBit && allOnes) {
      return (-1, len);
    }
    return (value, len);
  }

  static void _walkEbmlChildren(
    Uint8List bytes,
    int start,
    int end,
    void Function(int id, int dataStart, int dataEnd) onChild,
  ) {
    var pos = start;
    while (pos < end) {
      final idRes = _readEbmlVint(bytes, pos, maskLeadingBit: false, maxLen: 4);
      if (idRes == null) break;
      final sizeRes = _readEbmlVint(
        bytes,
        pos + idRes.$2,
        maskLeadingBit: true,
        maxLen: 8,
      );
      if (sizeRes == null || sizeRes.$1 < 0) break;
      final dataStart = pos + idRes.$2 + sizeRes.$2;
      final dataEnd = dataStart + sizeRes.$1;
      if (dataEnd > end) break;
      onChild(idRes.$1, dataStart, dataEnd);
      pos = dataEnd;
    }
  }

  static int _readEbmlUint(Uint8List bytes, int start, int end) {
    var value = 0;
    for (var i = start; i < end; i++) {
      value = (value << 8) | bytes[i];
    }
    return value;
  }

  static double? _readEbmlFloat(Uint8List bytes, int start, int end) {
    final len = end - start;
    if (len == 4) {
      return ByteData.sublistView(bytes, start, end).getFloat32(0, Endian.big);
    }
    if (len == 8) {
      return ByteData.sublistView(bytes, start, end).getFloat64(0, Endian.big);
    }
    return null;
  }

  static String? _normalizeMatroskaCodec(String? codecId) {
    if (codecId == null || codecId.isEmpty) return null;
    if (codecId.startsWith('V_MPEG4/ISO/AVC')) return 'h264';
    if (codecId.startsWith('V_MPEGH/ISO/HEVC')) return 'hevc';
    if (codecId.startsWith('V_VP9')) return 'vp9';
    if (codecId.startsWith('V_VP8')) return 'vp8';
    if (codecId.startsWith('V_AV1')) return 'av1';
    if (codecId.startsWith('V_MPEG2')) return 'mpeg2video';
    if (codecId.startsWith('V_MPEG4/ISO/')) return 'mpeg4';
    if (codecId.startsWith('A_AAC')) return 'aac';
    if (codecId.startsWith('A_OPUS')) return 'opus';
    if (codecId.startsWith('A_VORBIS')) return 'vorbis';
    if (codecId == 'A_AC3') return 'ac3';
    if (codecId == 'A_EAC3') return 'eac3';
    if (codecId == 'A_FLAC') return 'flac';
    if (codecId.startsWith('A_DTS')) return 'dts';
    if (codecId.startsWith('A_TRUEHD')) return 'truehd';
    if (codecId == 'A_MPEG/L3') return 'mp3';
    if (codecId.startsWith('A_PCM/')) return 'pcm';
    return codecId.toLowerCase();
  }

  Future<DiscoveredMediaInfo?> _parseOgg(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    final packet = BytesBuilder(copy: false);
    var bytesRead = 0;
    for (
      var page = 0;
      page < 512 && await raf.position() + 27 <= fileLength;
      page++
    ) {
      final header = await raf.read(27);
      if (header.length != 27 ||
          header[0] != 0x4f ||
          header[1] != 0x67 ||
          header[2] != 0x67 ||
          header[3] != 0x53) {
        return null;
      }
      final segments = await raf.read(header[26]);
      if (segments.length != header[26]) return null;
      final bodyLength = segments.fold<int>(0, (sum, length) => sum + length);
      final body = await raf.read(bodyLength);
      if (body.length != bodyLength) return null;
      bytesRead += 27 + segments.length + bodyLength;
      if (bytesRead > _maxTagBlockBytes) return null;
      var offset = 0;
      for (final length in segments) {
        packet.add(body.sublist(offset, offset + length));
        offset += length;
        if (packet.length > _maxTagBlockBytes) return null;
        if (length == 255) continue;
        final bytes = packet.takeBytes();
        final vorbis =
            bytes.length >= 7 &&
            bytes[0] == 3 &&
            ascii.decode(bytes.sublist(1, 7), allowInvalid: true) == 'vorbis';
        final opus =
            bytes.length >= 8 &&
            ascii.decode(bytes.sublist(0, 8), allowInvalid: true) == 'OpusTags';
        if (!vorbis && !opus) continue;
        final tags = <String, String>{};
        _parseVorbisComment(bytes.sublist(vorbis ? 7 : 8), tags);
        Uint8List? artwork;
        for (final entry in tags.entries) {
          if (entry.key.toUpperCase() != 'METADATA_BLOCK_PICTURE' ||
              entry.value.length > _maxTagBlockBytes) {
            continue;
          }
          try {
            final picture = base64.decode(entry.value);
            if (picture.length <= _maxArtworkBytes) {
              artwork = _extractFlacPicture(picture);
            }
          } catch (_) {}
          break;
        }
        return DiscoveredMediaInfo(
          tracks: const [
            DiscoveredTrack(id: 'audio', isVideo: false, isAudio: true),
          ],
          rawTags: tags,
          hasEmbeddedArtwork: artwork != null,
          embeddedArtworkBytes: artwork,
        );
      }
    }
    return null;
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
        } else if ((atomName == 'trkn' || atomName == 'disk') &&
            payload.length >= 6) {
          final number = (payload[2] << 8) | payload[3];
          final total = (payload[4] << 8) | payload[5];
          if (number > 0) {
            outTags[atomName] = total > 0 ? '$number/$total' : '$number';
          }
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
        var offset = 0;
        var littleEndian = false;
        if (content.length >= 2 && content[0] == 0xff && content[1] == 0xfe) {
          littleEndian = true;
          offset = 2;
        } else if (content.length >= 2 &&
            content[0] == 0xfe &&
            content[1] == 0xff) {
          offset = 2;
        }
        final units = <int>[];
        for (var i = offset; i + 1 < content.length; i += 2) {
          final unit = littleEndian
              ? content[i] | (content[i + 1] << 8)
              : (content[i] << 8) | content[i + 1];
          if (unit == 0) break;
          units.add(unit);
        }
        return String.fromCharCodes(units).trim();
      }
      final text = encoding == 0
          ? latin1.decode(content)
          : utf8.decode(content, allowMalformed: true);
      return text.split('\u0000').first.trim();
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _extractId3ApicBytes(
    Uint8List bytes, {
    bool version22 = false,
  }) {
    try {
      if (bytes.length < 5) return null;
      final encoding = bytes[0];
      var offset = 1;
      if (version22) {
        offset += 3; // ID3v2.2 stores a three-byte image format.
      } else {
        while (offset < bytes.length && bytes[offset] != 0) {
          offset++;
        }
        offset++; // MIME terminator
      }
      if (offset >= bytes.length) return null;
      offset++; // skip picture type
      if (encoding == 1 || encoding == 2) {
        while (offset + 1 < bytes.length &&
            (bytes[offset] != 0 || bytes[offset + 1] != 0)) {
          offset += 2;
        }
        offset += 2;
      } else {
        while (offset < bytes.length && bytes[offset] != 0) {
          offset++;
        }
        offset++;
      }
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
