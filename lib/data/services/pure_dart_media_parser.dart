import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/models/media_metadata.dart';

const int _maxTagBlockBytes = 16 * 1024 * 1024;
const int _maxTagFrameBytes = 8 * 1024 * 1024;
const int _maxArtworkBytes = 12 * 1024 * 1024;

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
