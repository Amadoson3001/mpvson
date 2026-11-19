import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../domain/models/stream_rendition.dart';

/// Discovers and parses HLS and DASH manifests under bounded network, memory,
/// and redirection limits.
class StreamManifestService {
  StreamManifestService({
    this.httpClient,
    this.discoveryTimeout = const Duration(seconds: 2),
    this.maxRedirects = 5,
    this.maxHlsBytes = 256 * 1024,
    this.maxDashBytes = 512 * 1024,
    this.maxCandidates = 128,
  });

  final http.Client? httpClient;

  /// Maximum duration to wait during network manifest discovery.
  final Duration discoveryTimeout;

  /// Maximum allowed HTTP redirects before aborting discovery.
  final int maxRedirects;

  /// Maximum allowed decoded bytes for an HLS playlist (default 256 KiB).
  final int maxHlsBytes;

  /// Maximum allowed decoded bytes for a DASH MPD manifest (default 512 KiB).
  final int maxDashBytes;

  /// Maximum advertised rendition candidates retained.
  final int maxCandidates;

  /// Discovers and parses a remote stream manifest at [source].
  ///
  /// Enforces redirect bounds, response body size caps, and a timeout cap.
  /// If discovery fails, times out, or the source is not a recognized manifest,
  /// returns a fallback [StreamManifestInfo] with [StreamFormat.direct].
  Future<StreamManifestInfo> discover(
    String source, {
    http.Client? client,
    Duration? timeout,
  }) async {
    final initialUri = Uri.tryParse(source.trim());
    if (initialUri == null || !_isHttpUri(initialUri)) {
      return StreamManifestInfo.directFallback(source);
    }

    final effectiveTimeout = timeout ?? discoveryTimeout;
    final activeClient = client ?? httpClient ?? http.Client();
    final shouldCloseClient = client == null && httpClient == null;

    try {
      return await _discoverInternal(
        activeClient,
        initialUri,
        source,
      ).timeout(effectiveTimeout);
    } on TimeoutException {
      return StreamManifestInfo.directFallback(source);
    } catch (_) {
      return StreamManifestInfo.directFallback(source);
    } finally {
      if (shouldCloseClient) {
        activeClient.close();
      }
    }
  }

  Future<StreamManifestInfo> _discoverInternal(
    http.Client client,
    Uri initialUri,
    String originalSource,
  ) async {
    var currentUri = initialUri;
    http.StreamedResponse? finalResponse;

    for (
      var redirectCount = 0;
      redirectCount <= maxRedirects;
      redirectCount++
    ) {
      final request = http.Request('GET', currentUri);
      request.followRedirects = false;
      request.headers['User-Agent'] = 'mpvson/1.0';
      request.headers['Accept'] = '*/*';

      final http.StreamedResponse response;
      try {
        response = await client.send(request);
      } catch (_) {
        return StreamManifestInfo.directFallback(originalSource);
      }

      final isRedirect = const {
        301,
        302,
        303,
        307,
        308,
      }.contains(response.statusCode);
      if (isRedirect) {
        await response.stream.drain<void>().catchError((_) {});

        if (redirectCount >= maxRedirects) {
          return StreamManifestInfo.directFallback(originalSource);
        }

        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty) {
          return StreamManifestInfo.directFallback(originalSource);
        }

        final resolvedRedirect = currentUri.resolve(location.trim());
        if (!_isHttpUri(resolvedRedirect)) {
          return StreamManifestInfo.directFallback(originalSource);
        }

        currentUri = resolvedRedirect;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>().catchError((_) {});
        return StreamManifestInfo.directFallback(originalSource);
      }

      finalResponse = response;
      break;
    }

    if (finalResponse == null) {
      return StreamManifestInfo.directFallback(originalSource);
    }

    final contentType =
        finalResponse.headers['content-type']?.toLowerCase() ?? '';
    final path = currentUri.path.toLowerCase();

    final isLikelyDash =
        path.endsWith('.mpd') || contentType.contains('application/dash+xml');
    final isLikelyHls =
        path.endsWith('.m3u8') ||
        contentType.contains('application/vnd.apple.mpegurl') ||
        contentType.contains('application/x-mpegurl') ||
        contentType.contains('audio/x-mpegurl');

    final maxBytes = isLikelyDash
        ? maxDashBytes
        : (isLikelyHls ? maxHlsBytes : maxDashBytes);

    final bodyBytes = await _readBoundedStream(
      finalResponse.stream,
      maxBytes: maxBytes,
    );
    if (bodyBytes == null) {
      return StreamManifestInfo.directFallback(originalSource);
    }

    final bodyText = utf8.decode(bodyBytes, allowMalformed: true);

    if (isLikelyDash ||
        bodyText.contains('<MPD') ||
        bodyText.contains('<mpd')) {
      return parseDash(bodyText, currentUri, masterUrl: originalSource);
    }

    if (isLikelyHls || bodyText.trimLeft().startsWith('#EXTM3U')) {
      return parseHls(bodyText, currentUri, masterUrl: originalSource);
    }

    return StreamManifestInfo.directFallback(originalSource);
  }

  /// Parses an HLS Master or Media playlist from [content].
  ///
  /// Resolves relative variant URLs against [baseUri], preserving advertised
  /// parameters and applying parent query inheritance.
  StreamManifestInfo parseHls(
    String content,
    Uri baseUri, {
    String? masterUrl,
  }) {
    final effectiveMasterUrl = masterUrl ?? baseUri.toString();
    final trimmedContent = content.trimLeft();
    if (!trimmedContent.startsWith('#EXTM3U')) {
      return StreamManifestInfo.directFallback(effectiveMasterUrl);
    }

    final lines = const LineSplitter().convert(content);
    final isMaster = lines.any((l) => _isTag(l, '#EXT-X-STREAM-INF'));

    if (!isMaster) {
      final isMedia = lines.any(
        (l) => _isTag(l, '#EXTINF') || _isTag(l, '#EXT-X-TARGETDURATION'),
      );

      if (!isMedia) {
        return StreamManifestInfo.directFallback(effectiveMasterUrl);
      }

      final isLive = !lines.any((l) => _isTag(l, '#EXT-X-ENDLIST'));
      return StreamManifestInfo(
        masterUrl: effectiveMasterUrl,
        format: StreamFormat.hls,
        isLive: isLive,
        variants: [
          StreamRendition(
            id: 'stream',
            label: isLive ? 'Live' : 'Source',
            url: baseUri.toString(),
            isMuxed: true,
          ),
        ],
        audioGroups: const [],
        subtitleGroups: const [],
        hasSeparateAudio: false,
      );
    }

    // Master playlist: discover rendition groups and video variants
    final audioGroups = <String>[];
    final subtitleGroups = <String>[];
    var hasSeparateAudioUri = false;

    for (final rawLine in lines) {
      final payload = _tagPayload(rawLine, '#EXT-X-MEDIA');
      if (payload == null) continue;

      final attrs = parseHlsAttributes(payload);
      final type = attrs['TYPE']?.toUpperCase();
      final groupId = attrs['GROUP-ID'];
      final uri = attrs['URI'];

      if (type == 'AUDIO' && groupId != null && groupId.isNotEmpty) {
        if (!audioGroups.contains(groupId)) {
          audioGroups.add(groupId);
        }
        if (uri != null && uri.isNotEmpty) {
          hasSeparateAudioUri = true;
        }
      } else if (type == 'SUBTITLES' && groupId != null && groupId.isNotEmpty) {
        if (!subtitleGroups.contains(groupId)) {
          subtitleGroups.add(groupId);
        }
      }
    }

    final variants = <StreamRendition>[];
    final seenIds = <String>{};

    for (var i = 0; i < lines.length; i++) {
      final payload = _tagPayload(lines[i], '#EXT-X-STREAM-INF');
      if (payload == null) continue;

      final attrs = parseHlsAttributes(payload);

      // Find the next non-empty, non-comment line containing the variant URI
      String? variantUriLine;
      for (var j = i + 1; j < lines.length; j++) {
        final nextLine = lines[j].trim();
        if (nextLine.isEmpty || nextLine.startsWith('#')) continue;
        variantUriLine = nextLine;
        i = j;
        break;
      }

      if (variantUriLine == null) continue;

      final resolution = _parseResolution(attrs['RESOLUTION']);
      final width = resolution.$1;
      final height = resolution.$2;
      final bitrate = _positiveInt(
        attrs['AVERAGE-BANDWIDTH'] ?? attrs['BANDWIDTH'],
      );
      final frameRate = double.tryParse(attrs['FRAME-RATE'] ?? '');
      final codecs = attrs['CODECS'];
      final childUri = resolveChildUri(baseUri, variantUriLine);
      final audioGroup = attrs['AUDIO'];

      final label = _formatQualityLabel(
        width: width,
        height: height,
        bitrate: bitrate,
        frameRate: frameRate,
      );

      var variantId =
          attrs['HD-REPRESENTATION-ID'] ??
          (height != null
              ? '${height}p'
              : (width != null ? '${width}w' : 'var_${variants.length}'));
      if (seenIds.contains(variantId)) {
        variantId = '${variantId}_${bitrate ?? variants.length}';
      }
      seenIds.add(variantId);

      final isMuxed =
          !hasSeparateAudioUri &&
          (audioGroup == null || !audioGroups.contains(audioGroup));

      variants.add(
        StreamRendition(
          id: variantId,
          label: label,
          width: width,
          height: height,
          bitrate: bitrate,
          frameRate: frameRate,
          codec: codecs,
          url: childUri.toString(),
          isMuxed: isMuxed,
        ),
      );

      if (variants.length >= maxCandidates) break;
    }

    if (variants.isEmpty) {
      return StreamManifestInfo.directFallback(effectiveMasterUrl);
    }

    variants.sort(_compareRenditions);

    return StreamManifestInfo(
      masterUrl: effectiveMasterUrl,
      format: StreamFormat.hls,
      isLive: false,
      variants: variants,
      audioGroups: audioGroups,
      subtitleGroups: subtitleGroups,
      hasSeparateAudio: audioGroups.isNotEmpty,
    );
  }

  /// Parses a DASH MPD manifest from [content].
  ///
  /// Resolves hierarchical BaseURLs against [baseUri], checks for unsupported
  /// ContentProtection / DRM, and extracts representations.
  StreamManifestInfo parseDash(
    String content,
    Uri baseUri, {
    String? masterUrl,
  }) {
    final effectiveMasterUrl = masterUrl ?? baseUri.toString();

    // XXE safety: reject manifests attempting external entity expansion
    final hasExternalEntity = content.contains(
      RegExp(r'<!ENTITY[^>]+(?:SYSTEM|PUBLIC)', caseSensitive: false),
    );
    if (hasExternalEntity) {
      return StreamManifestInfo.directFallback(effectiveMasterUrl);
    }

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(content);
    } catch (_) {
      return StreamManifestInfo.directFallback(effectiveMasterUrl);
    }

    final root = doc.rootElement;
    if (root.name.local.toLowerCase() != 'mpd') {
      return StreamManifestInfo.directFallback(effectiveMasterUrl);
    }

    final isLive = root.getAttribute('type')?.toLowerCase() == 'dynamic';
    final hasDrm = doc.findAllElements('ContentProtection').isNotEmpty;

    var mpdBaseUri = baseUri;
    final mpdBaseUrl = root
        .findElements('BaseURL')
        .firstOrNull
        ?.innerText
        .trim();
    if (mpdBaseUrl != null && mpdBaseUrl.isNotEmpty) {
      mpdBaseUri = resolveChildUri(mpdBaseUri, mpdBaseUrl);
    }

    var periods = root.findElements('Period').toList();
    if (periods.isEmpty) {
      periods = [root];
    }

    final audioGroups = <String>[];
    final subtitleGroups = <String>[];
    final videoAdaptationSets = <(XmlElement, Uri)>[];

    for (final period in periods) {
      var periodBaseUri = mpdBaseUri;
      final periodBaseUrl = period
          .findElements('BaseURL')
          .firstOrNull
          ?.innerText
          .trim();
      if (periodBaseUrl != null && periodBaseUrl.isNotEmpty) {
        periodBaseUri = resolveChildUri(periodBaseUri, periodBaseUrl);
      }

      final adaptationSets = period.findElements('AdaptationSet').toList();
      for (final asElement in adaptationSets) {
        final mime = asElement.getAttribute('mimeType')?.toLowerCase() ?? '';
        final contentType =
            asElement.getAttribute('contentType')?.toLowerCase() ?? '';

        final isVideo = contentType == 'video' || mime.startsWith('video/');
        final isAudio = contentType == 'audio' || mime.startsWith('audio/');
        final isSub =
            contentType == 'text' ||
            contentType == 'subtitles' ||
            mime.contains('vtt') ||
            mime.contains('ttml');

        if (isAudio) {
          final id =
              asElement.getAttribute('id') ??
              asElement.getAttribute('lang') ??
              'audio_${audioGroups.length + 1}';
          if (!audioGroups.contains(id)) audioGroups.add(id);
        } else if (isSub) {
          final id =
              asElement.getAttribute('id') ??
              asElement.getAttribute('lang') ??
              'sub_${subtitleGroups.length + 1}';
          if (!subtitleGroups.contains(id)) subtitleGroups.add(id);
        } else if (isVideo) {
          videoAdaptationSets.add((asElement, periodBaseUri));
        } else {
          final reps = asElement.findElements('Representation');
          if (reps.any(
            (r) => (r.getAttribute('mimeType')?.toLowerCase() ?? '').startsWith(
              'video/',
            ),
          )) {
            videoAdaptationSets.add((asElement, periodBaseUri));
          } else if (reps.any(
            (r) => (r.getAttribute('mimeType')?.toLowerCase() ?? '').startsWith(
              'audio/',
            ),
          )) {
            final id =
                asElement.getAttribute('id') ??
                asElement.getAttribute('lang') ??
                'audio_${audioGroups.length + 1}';
            if (!audioGroups.contains(id)) audioGroups.add(id);
          }
        }
      }
    }

    final variants = <StreamRendition>[];
    final seenIds = <String>{};
    final hasSeparateAudio = audioGroups.isNotEmpty;

    for (final (adaptationSet, periodBaseUri) in videoAdaptationSets) {
      var asBaseUri = periodBaseUri;
      final asBaseUrl = adaptationSet
          .findElements('BaseURL')
          .firstOrNull
          ?.innerText
          .trim();
      if (asBaseUrl != null && asBaseUrl.isNotEmpty) {
        asBaseUri = resolveChildUri(asBaseUri, asBaseUrl);
      }

      final asCodecs = adaptationSet.getAttribute('codecs');
      final asWidth = int.tryParse(adaptationSet.getAttribute('width') ?? '');
      final asHeight = int.tryParse(adaptationSet.getAttribute('height') ?? '');
      final asFrameRate = _parseFrameRate(
        adaptationSet.getAttribute('frameRate'),
      );

      final representations = adaptationSet
          .findElements('Representation')
          .toList();
      for (final rep in representations) {
        var repBaseUri = asBaseUri;
        final repBaseUrl = rep
            .findElements('BaseURL')
            .firstOrNull
            ?.innerText
            .trim();
        if (repBaseUrl != null && repBaseUrl.isNotEmpty) {
          repBaseUri = resolveChildUri(repBaseUri, repBaseUrl);
        }

        final repId = rep.getAttribute('id') ?? 'rep_${variants.length + 1}';
        final bandwidth = _positiveInt(rep.getAttribute('bandwidth'));
        final width = int.tryParse(rep.getAttribute('width') ?? '') ?? asWidth;
        final height =
            int.tryParse(rep.getAttribute('height') ?? '') ?? asHeight;
        final frameRate =
            _parseFrameRate(rep.getAttribute('frameRate')) ?? asFrameRate;
        final codec = rep.getAttribute('codecs') ?? asCodecs;

        final label = _formatQualityLabel(
          width: width,
          height: height,
          bitrate: bandwidth,
          frameRate: frameRate,
        );

        var uniqueId = repId;
        if (seenIds.contains(uniqueId)) {
          uniqueId = '${uniqueId}_${bandwidth ?? variants.length}';
        }
        seenIds.add(uniqueId);

        final isMuxed = !hasSeparateAudio;

        variants.add(
          StreamRendition(
            id: uniqueId,
            label: label,
            width: width,
            height: height,
            bitrate: bandwidth,
            frameRate: frameRate,
            codec: codec,
            url: repBaseUri.toString(),
            isMuxed: isMuxed,
          ),
        );

        if (variants.length >= maxCandidates) break;
      }
      if (variants.length >= maxCandidates) break;
    }

    if (variants.isEmpty) {
      return StreamManifestInfo.directFallback(effectiveMasterUrl);
    }

    variants.sort(_compareRenditions);

    return StreamManifestInfo(
      masterUrl: effectiveMasterUrl,
      format: StreamFormat.dash,
      isLive: isLive,
      variants: variants,
      audioGroups: audioGroups,
      subtitleGroups: subtitleGroups,
      hasSeparateAudio: hasSeparateAudio,
      hasUnsupportedDrm: hasDrm,
    );
  }

  /// Resolves [child] relative to [baseUri], preserving advertised child query
  /// parameters and inheriting missing parent query parameters for same-origin
  /// requests.
  static Uri resolveChildUri(Uri baseUri, String child) {
    final trimmed = child.trim();
    final targetUri = Uri.tryParse(trimmed) ?? Uri();
    final resolved = baseUri.resolveUri(targetUri);

    if (baseUri.hasQuery && baseUri.queryParameters.isNotEmpty) {
      final isSameOriginOrRelative =
          !targetUri.hasScheme ||
          targetUri.host.isEmpty ||
          targetUri.host == baseUri.host;

      if (isSameOriginOrRelative) {
        final merged = Map<String, String>.from(baseUri.queryParameters);
        merged.addAll(targetUri.queryParameters);
        return resolved.replace(queryParameters: merged);
      }
    }

    return resolved;
  }

  /// Parses HLS attribute lists, honoring quoted values containing commas and
  /// trimming surrounding whitespace.
  static Map<String, String> parseHlsAttributes(String raw) {
    final result = <String, String>{};
    var index = 0;
    final length = raw.length;

    while (index < length) {
      while (index < length &&
          (raw[index] == ',' || raw[index].trim().isEmpty)) {
        index++;
      }
      if (index >= length) break;

      final keyStart = index;
      while (index < length && raw[index] != '=' && raw[index] != ',') {
        index++;
      }
      if (index >= length || raw[index] != '=') {
        break;
      }
      final key = raw.substring(keyStart, index).trim().toUpperCase();
      index++; // skip '='

      while (index < length && raw[index].trim().isEmpty) {
        index++;
      }
      if (index >= length) break;

      final value = StringBuffer();
      if (raw[index] == '"') {
        index++; // skip opening '"'
        while (index < length && raw[index] != '"') {
          value.write(raw[index++]);
        }
        if (index < length && raw[index] == '"') {
          index++; // skip closing '"'
        }
        while (index < length && raw[index] != ',') {
          index++;
        }
      } else {
        final valueStart = index;
        while (index < length && raw[index] != ',') {
          index++;
        }
        value.write(raw.substring(valueStart, index).trim());
      }

      if (key.isNotEmpty) {
        result[key] = value.toString();
      }
    }

    return result;
  }

  Future<List<int>?> _readBoundedStream(
    Stream<List<int>> stream, {
    required int maxBytes,
  }) async {
    final bytes = <int>[];
    try {
      await for (final chunk in stream) {
        if (bytes.length + chunk.length > maxBytes) {
          return null;
        }
        bytes.addAll(chunk);
      }
    } catch (_) {
      return null;
    }
    return bytes;
  }

  static bool _isHttpUri(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

  static bool _isTag(String line, String tagName) {
    final trimmed = line.trim();
    if (!trimmed.startsWith(tagName)) return false;
    final rest = trimmed.substring(tagName.length).trimLeft();
    return rest.startsWith(':') || rest.isEmpty;
  }

  static String? _tagPayload(String line, String tagName) {
    final trimmed = line.trim();
    if (!trimmed.startsWith(tagName)) return null;
    final rest = trimmed.substring(tagName.length).trimLeft();
    if (!rest.startsWith(':')) return null;
    return rest.substring(1).trim();
  }

  static (int?, int?) _parseResolution(String? value) {
    if (value == null) return (null, null);
    final match = RegExp(r'^(\d+)\s*[xX]\s*(\d+)$').firstMatch(value.trim());
    if (match == null) return (null, null);
    final w = int.tryParse(match.group(1)!);
    final h = int.tryParse(match.group(2)!);
    if (w == null || h == null || w <= 0 || h <= 0) return (null, null);
    return (w, h);
  }

  static int? _positiveInt(String? value) {
    if (value == null) return null;
    final parsed = int.tryParse(value.trim());
    return parsed == null || parsed <= 0 ? null : parsed;
  }

  static double? _parseFrameRate(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains('/')) {
      final parts = trimmed.split('/');
      if (parts.length == 2) {
        final num = double.tryParse(parts[0].trim());
        final den = double.tryParse(parts[1].trim());
        if (num != null && den != null && den > 0) {
          return num / den;
        }
      }
    }
    return double.tryParse(trimmed);
  }

  static String _formatQualityLabel({
    int? width,
    int? height,
    int? bitrate,
    double? frameRate,
  }) {
    if (height != null && height > 0) {
      return '${height}p';
    }
    if (width != null && width > 0) {
      return '${width}w';
    }
    if (bitrate != null && bitrate > 0) {
      if (bitrate >= 1000000) {
        final mbps = bitrate / 1000000;
        return mbps % 1 == 0
            ? '${mbps.toInt()} Mbps'
            : '${mbps.toStringAsFixed(1)} Mbps';
      }
      return '${(bitrate / 1000).round()} kbps';
    }
    return 'Unknown';
  }

  static int _compareRenditions(StreamRendition a, StreamRendition b) {
    final aHeight = a.height ?? 0;
    final bHeight = b.height ?? 0;
    if (aHeight != bHeight) return bHeight.compareTo(aHeight);
    final aBitrate = a.bitrate ?? 0;
    final bBitrate = b.bitrate ?? 0;
    if (aBitrate != bBitrate) return bBitrate.compareTo(aBitrate);
    return a.id.compareTo(b.id);
  }
}
