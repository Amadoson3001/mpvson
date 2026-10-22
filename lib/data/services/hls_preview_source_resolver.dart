import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Resolves an HTTP(S) HLS master playlist to its lowest-bandwidth video
/// variant so preview workers do not probe every rendition.
class HlsPreviewSourceResolver {
  HlsPreviewSourceResolver({
    HttpClient Function()? clientFactory,
    this.maxManifestBytes = 64 * 1024,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  static const int defaultMaxManifestBytes = 64 * 1024;
  static const int _maxRedirects = 5;
  static final RegExp _videoCodec = RegExp(
    r'^(?:avc[13]|hev1|hvc1|dvh1|dvhe|dvav|av01|vp0?8|vp09|theora|theo|mp4v\.)',
    caseSensitive: false,
  );

  final HttpClient Function() _clientFactory;
  final int maxManifestBytes;

  /// Returns a selected video variant URL, or null when [source] is not a
  /// supported master manifest. Network failures are reported to the caller.
  Future<Uri?> resolve(String source, {required Duration timeout}) async {
    final master = Uri.tryParse(source);
    if (!_isSupportedMasterUrl(master)) return null;
    if (timeout <= Duration.zero) {
      throw TimeoutException('No time remains to resolve the HLS master');
    }

    final client = _clientFactory();
    try {
      return await _resolveWithClient(client, master!).timeout(
        timeout,
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('Timed out resolving HLS master');
        },
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Uri?> _resolveWithClient(HttpClient client, Uri master) async {
    var currentUri = master;
    late HttpClientResponse response;
    for (var redirectCount = 0; ; redirectCount++) {
      final request = await client.getUrl(currentUri);
      request.followRedirects = false;
      response = await request.close();
      if (_hasCookies(response)) return null;
      final location = response.headers.value(HttpHeaders.locationHeader);
      final isRedirect = const {
        301,
        302,
        303,
        307,
        308,
      }.contains(response.statusCode);
      if (!isRedirect || location == null) break;
      if (redirectCount >= _maxRedirects) return null;
      final redirected = currentUri.resolve(location);
      if (!_isHttpUrl(redirected)) return null;
      currentUri = redirected;
    }

    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      return null;
    }

    final bytes = await _readBounded(response);
    if (bytes == null) return null;
    final text = utf8.decode(bytes, allowMalformed: true);
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty || lines.first.trim() != '#EXTM3U') return null;

    final variants = _parseVariants(lines, currentUri);
    if (variants.isEmpty) return null;
    variants.sort(_compareVariants);
    return variants.first.uri;
  }

  Future<List<int>?> _readBounded(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxManifestBytes) return null;
      bytes.addAll(chunk);
    }
    return bytes;
  }

  bool _hasCookies(HttpClientResponse response) =>
      response.cookies.isNotEmpty ||
      response.headers[HttpHeaders.setCookieHeader]?.isNotEmpty == true;

  bool _isHttpUrl(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;

  bool _hasVariableReference(String value) =>
      RegExp(r'\{\$[^}]+\}').hasMatch(value);

  bool _isSupportedMasterUrl(Uri? uri) =>
      uri != null &&
      _isHttpUrl(uri) &&
      uri.path.toLowerCase().endsWith('.m3u8');

  List<_HlsVariant> _parseVariants(List<String> lines, Uri baseUri) {
    final variants = <_HlsVariant>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      const prefix = '#EXT-X-STREAM-INF:';
      if (!line.startsWith(prefix)) continue;

      final attributes = _parseAttributes(line.substring(prefix.length));
      String? variantLine;
      for (var next = index + 1; next < lines.length; next++) {
        final candidate = lines[next].trim();
        if (candidate.isEmpty || candidate.startsWith('#')) continue;
        variantLine = candidate;
        index = next;
        break;
      }
      if (variantLine == null) continue;
      if (_hasVariableReference(variantLine)) continue;

      final resolution = _parseResolution(attributes['RESOLUTION']);
      final codecs = attributes['CODECS']
          ?.split(',')
          .map((codec) => codec.trim())
          .where((codec) => codec.isNotEmpty)
          .toList(growable: false);
      final hasVideoCodec = codecs?.any(_videoCodec.hasMatch) ?? false;
      if (resolution == null && !hasVideoCodec) continue;

      final uri = baseUri.resolveUri(Uri.parse(variantLine));
      if (!_isHttpUrl(uri)) continue;
      final bitrate = _positiveInt(
        attributes['AVERAGE-BANDWIDTH'] ?? attributes['BANDWIDTH'],
      );
      variants.add(
        _HlsVariant(
          uri: uri,
          bitrate: bitrate,
          pixelArea: resolution == null ? null : resolution.$1 * resolution.$2,
        ),
      );
    }
    return variants;
  }

  Map<String, String> _parseAttributes(String raw) {
    final result = <String, String>{};
    var index = 0;
    while (index < raw.length) {
      while (index < raw.length &&
          (raw[index] == ',' || raw[index].trim().isEmpty)) {
        index++;
      }
      final keyStart = index;
      while (index < raw.length && raw[index] != '=' && raw[index] != ',') {
        index++;
      }
      if (index >= raw.length || raw[index] != '=') break;
      final key = raw.substring(keyStart, index).trim().toUpperCase();
      index++;
      while (index < raw.length && raw[index].trim().isEmpty) {
        index++;
      }

      final value = StringBuffer();
      if (index < raw.length && raw[index] == '"') {
        index++;
        while (index < raw.length && raw[index] != '"') {
          value.write(raw[index++]);
        }
        if (index < raw.length) index++;
        while (index < raw.length && raw[index] != ',') {
          index++;
        }
      } else {
        final valueStart = index;
        while (index < raw.length && raw[index] != ',') {
          index++;
        }
        value.write(raw.substring(valueStart, index).trim());
      }
      if (key.isNotEmpty) result[key] = value.toString();
    }
    return result;
  }

  (int, int)? _parseResolution(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(value.trim());
    if (match == null) return null;
    final width = int.tryParse(match.group(1)!);
    final height = int.tryParse(match.group(2)!);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return (width, height);
  }

  int? _positiveInt(String? value) {
    if (value == null) return null;
    final parsed = int.tryParse(value.trim());
    return parsed == null || parsed <= 0 ? null : parsed;
  }

  int _compareVariants(_HlsVariant a, _HlsVariant b) {
    final aBitrate = a.bitrate;
    final bBitrate = b.bitrate;
    if (aBitrate != null && bBitrate != null && aBitrate != bBitrate) {
      return aBitrate.compareTo(bBitrate);
    }
    final aArea = a.pixelArea;
    final bArea = b.pixelArea;
    if (aArea != null && bArea != null && aArea != bArea) {
      return aArea.compareTo(bArea);
    }
    if (aBitrate == null && bBitrate != null) return 1;
    if (bBitrate == null && aBitrate != null) return -1;
    if (aArea == null && bArea != null) return 1;
    if (bArea == null && aArea != null) return -1;
    return a.uri.toString().compareTo(b.uri.toString());
  }
}

class _HlsVariant {
  const _HlsVariant({
    required this.uri,
    required this.bitrate,
    required this.pixelArea,
  });

  final Uri uri;
  final int? bitrate;
  final int? pixelArea;
}
