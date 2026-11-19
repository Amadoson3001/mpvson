import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A recorded HTTP request captured in [StreamingFixtureServer]'s journal.
class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.uri,
    required this.path,
    required this.headers,
    required this.timestamp,
    required this.clientIp,
    this.rangeHeader,
    this.requestedRange,
  });

  /// The HTTP method (e.g. 'GET', 'HEAD', 'POST').
  final String method;

  /// The full URI requested.
  final Uri uri;

  /// The path component of [uri].
  final String path;

  /// Request headers with lower-cased keys.
  final Map<String, List<String>> headers;

  /// When the request was received.
  final DateTime timestamp;

  /// Client IP address that initiated the request.
  final String clientIp;

  /// Raw `Range` header value if present.
  final String? rangeHeader;

  /// Parsed byte range if valid `bytes=...` header was provided.
  final ByteRange? requestedRange;

  /// Helper to get the first value of a header by name (case-insensitive).
  String? header(String name) => headers[name.toLowerCase()]?.firstOrNull;

  /// Helper to check if a header was sent.
  bool hasHeader(String name) => headers.containsKey(name.toLowerCase());

  /// Query parameters of the request.
  Map<String, String> get queryParameters => uri.queryParameters;

  @override
  String toString() => '$method $path (from $clientIp at $timestamp)';
}

/// Represents a closed byte range [start, end] inclusive.
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;
  final int end;

  /// Number of bytes in this range.
  int get length => end - start + 1;

  /// Formats this range for the `Content-Range` header against [totalLength].
  String toContentRangeHeader(int totalLength) =>
      'bytes $start-$end/$totalLength';

  @override
  String toString() => 'ByteRange($start-$end)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ByteRange &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  /// Parses a `Range` header string like `bytes=0-499`, `bytes=500-`, or `bytes=-500`
  /// against a resource of [totalLength] bytes.
  ///
  /// Returns `null` if no range header is supplied or header doesn't start with `bytes=`.
  /// Throws [RangeNotSatisfiableException] if the range cannot be satisfied.
  static ByteRange? parse(String? rangeHeader, int totalLength) {
    if (rangeHeader == null || rangeHeader.trim().isEmpty) return null;

    final trimmed = rangeHeader.trim();
    if (!trimmed.startsWith('bytes=')) return null;

    final spec = trimmed.substring('bytes='.length).trim();
    // In case of multiple ranges (e.g. "0-50, 100-150"), use the first range.
    final firstSpec = spec.split(',').first.trim();
    final parts = firstSpec.split('-');
    if (parts.length != 2) {
      throw RangeNotSatisfiableException(totalLength);
    }

    final startStr = parts[0].trim();
    final endStr = parts[1].trim();

    // Suffix range: "-500" -> last 500 bytes
    if (startStr.isEmpty) {
      if (endStr.isEmpty) throw RangeNotSatisfiableException(totalLength);
      final suffix = int.tryParse(endStr);
      if (suffix == null || suffix <= 0) {
        throw RangeNotSatisfiableException(totalLength);
      }
      if (totalLength == 0) {
        throw RangeNotSatisfiableException(totalLength);
      }
      final start = (suffix > totalLength) ? 0 : (totalLength - suffix);
      final end = totalLength - 1;
      return ByteRange(start, end);
    }

    // Prefix range: "500-" -> from 500 to EOF
    final start = int.tryParse(startStr);
    if (start == null || start < 0) {
      throw RangeNotSatisfiableException(totalLength);
    }
    if (totalLength == 0 || start >= totalLength) {
      throw RangeNotSatisfiableException(totalLength);
    }

    if (endStr.isEmpty) {
      return ByteRange(start, totalLength - 1);
    }

    // Explicit range: "0-499"
    final end = int.tryParse(endStr);
    if (end == null || end < start) {
      throw RangeNotSatisfiableException(totalLength);
    }

    final clampedEnd = (end >= totalLength) ? (totalLength - 1) : end;
    return ByteRange(start, clampedEnd);
  }
}

/// Thrown when an HTTP `Range` request cannot be satisfied (RFC 7233 / 9110).
class RangeNotSatisfiableException implements Exception {
  const RangeNotSatisfiableException(this.totalLength);
  final int totalLength;

  @override
  String toString() =>
      'RangeNotSatisfiableException(totalLength: $totalLength)';
}

/// Helper that generates a minimal valid ISO Base Media File Format (MP4) byte array
/// with fast-start structure (ftyp followed immediately by moov, before mdat).
Uint8List generateFastStartMp4Bytes({int mdatPayloadSize = 2048}) {
  List<int> box(String type, List<int> payload) {
    final size = 8 + payload.length;
    final header = ByteData(8);
    header.setUint32(0, size);
    final typeUnits = ascii.encode(type);
    for (var i = 0; i < 4; i++) {
      header.setUint8(4 + i, typeUnits[i]);
    }
    final builder = BytesBuilder(copy: false);
    builder.add(header.buffer.asUint8List());
    builder.add(payload);
    return builder.toBytes();
  }

  // 1. ftyp box
  final ftypPayload = <int>[
    ...ascii.encode('isom'), // major_brand
    0x00, 0x00, 0x02, 0x00, // minor_version
    ...ascii.encode('isom'), // compatible_brands
    ...ascii.encode('iso2'),
    ...ascii.encode('mp41'),
    ...ascii.encode('mp42'),
  ];
  final ftypBox = box('ftyp', ftypPayload);

  // 2. moov box contents
  // mvhd
  final mvhdData = ByteData(100);
  // version: 0, flags: 0 (4 bytes 0)
  // creation_time: 0 (4 bytes), mod_time: 0 (4 bytes)
  mvhdData.setUint32(12, 1000); // timescale = 1000
  mvhdData.setUint32(16, 5000); // duration = 5000 ms (5s)
  mvhdData.setUint32(20, 0x00010000); // rate = 1.0
  mvhdData.setUint16(24, 0x0100); // volume = 1.0
  // matrix at offset 36 (36 bytes)
  mvhdData.setUint32(36, 0x00010000);
  mvhdData.setUint32(52, 0x00010000);
  mvhdData.setUint32(68, 0x40000000);
  // next_track_id at offset 96
  mvhdData.setUint32(96, 2);
  final mvhdBox = box('mvhd', mvhdData.buffer.asUint8List());

  // tkhd (92 - 8 = 84 bytes payload)
  final tkhdData = ByteData(84);
  tkhdData.setUint8(3, 3); // flags = track enabled (1) + in movie (2)
  tkhdData.setUint32(12, 1); // track ID = 1
  tkhdData.setUint32(20, 5000); // duration = 5000
  // matrix at offset 36 (36 bytes)
  tkhdData.setUint32(36, 0x00010000);
  tkhdData.setUint32(52, 0x00010000);
  tkhdData.setUint32(68, 0x40000000);
  tkhdData.setUint32(76, 640 << 16); // width 640.0
  tkhdData.setUint32(80, 360 << 16); // height 360.0
  final tkhdBox = box('tkhd', tkhdData.buffer.asUint8List());

  // mdia: mdhd + hdlr + minf
  final mdhdData = ByteData(24);
  mdhdData.setUint32(12, 1000); // timescale
  mdhdData.setUint32(16, 5000); // duration
  mdhdData.setUint16(20, 0x55C4); // language = 'und'
  final mdhdBox = box('mdhd', mdhdData.buffer.asUint8List());

  final hdlrData = ByteData(24);
  final videUnits = ascii.encode('vide');
  for (var i = 0; i < 4; i++) {
    hdlrData.setUint8(8 + i, videUnits[i]);
  }
  final hdlrPayload = <int>[
    ...hdlrData.buffer.asUint8List(),
    ...ascii.encode('VideoHandler\x00'),
  ];
  final hdlrBox = box('hdlr', hdlrPayload);

  // minf: vmhd + dinf + stbl
  final vmhdData = ByteData(12);
  vmhdData.setUint8(3, 1); // flags = 1
  final vmhdBox = box('vmhd', vmhdData.buffer.asUint8List());

  final urlBox = box('url ', [0, 0, 0, 1]); // flags = 1 (data in same file)
  final drefPayload = <int>[
    0, 0, 0, 0, // version + flags
    0, 0, 0, 1, // entry count = 1
    ...urlBox,
  ];
  final drefBox = box('dref', drefPayload);
  final dinfBox = box('dinf', drefBox);

  final stsdBox = box('stsd', [0, 0, 0, 0, 0, 0, 0, 0]);
  final sttsBox = box('stts', [0, 0, 0, 0, 0, 0, 0, 0]);
  final stscBox = box('stsc', [0, 0, 0, 0, 0, 0, 0, 0]);
  final stszBox = box('stsz', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  final stcoBox = box('stco', [0, 0, 0, 0, 0, 0, 0, 0]);
  final stblBox = box('stbl', [
    ...stsdBox,
    ...sttsBox,
    ...stscBox,
    ...stszBox,
    ...stcoBox,
  ]);

  final minfBox = box('minf', [...vmhdBox, ...dinfBox, ...stblBox]);
  final mdiaBox = box('mdia', [...mdhdBox, ...hdlrBox, ...minfBox]);
  final trakBox = box('trak', [...tkhdBox, ...mdiaBox]);

  final moovBox = box('moov', [...mvhdBox, ...trakBox]);

  // 3. mdat box
  final mdatPayload = Uint8List(mdatPayloadSize);
  for (var i = 0; i < mdatPayloadSize; i++) {
    mdatPayload[i] = (i % 256);
  }
  final mdatBox = box('mdat', mdatPayload);

  final builder = BytesBuilder(copy: false);
  builder.add(ftypBox);
  builder.add(moovBox);
  builder.add(mdatBox);
  return builder.toBytes();
}

/// Generates synthetic MPEG-TS packets (188 bytes each starting with sync byte `0x47`).
Uint8List generateMpegTsBytes({int packetCount = 10, int pid = 0x20}) {
  final buffer = Uint8List(packetCount * 188);
  for (var i = 0; i < packetCount; i++) {
    final offset = i * 188;
    buffer[offset] = 0x47; // Sync byte
    buffer[offset + 1] = ((pid >> 8) & 0x1F); // PID high 5 bits
    buffer[offset + 2] = (pid & 0xFF); // PID low 8 bits
    buffer[offset + 3] = 0x10 | (i & 0x0F); // Payload only + continuity counter
    // Fill remainder with deterministic pattern
    for (var j = 4; j < 188; j++) {
      buffer[offset + j] = ((i + j) % 256);
    }
  }
  return buffer;
}

/// A deterministic local HTTP fixture server for testing streaming media,
/// range requests, HLS playlists, DASH manifests, network throttling, and error conditions.
class StreamingFixtureServer {
  StreamingFixtureServer({
    Uint8List? videoMp4Bytes,
    Uint8List? tsSegmentBytes,
    this.throttleBytesPerSecond,
    this.transferDelayPerChunk,
    this.pauseBeforeResponse,
    this.ignoreRangeRequests = false,
    this.expectedSignedToken = 'valid-token',
    this.signedUrlValidator,
    this.stallDuration,
  }) : videoMp4Bytes = videoMp4Bytes ?? generateFastStartMp4Bytes(),
       tsSegmentBytes = tsSegmentBytes ?? generateMpegTsBytes();

  HttpServer? _server;
  final List<RecordedRequest> _ledger = <RecordedRequest>[];
  final Map<String, FutureOr<void> Function(HttpRequest request)>
  _customRoutes = <String, FutureOr<void> Function(HttpRequest request)>{};

  /// Byte payload served for `/video.mp4` and other MP4 routes.
  final Uint8List videoMp4Bytes;

  /// Alias for [videoMp4Bytes].
  Uint8List get fastStartMp4Bytes => videoMp4Bytes;

  /// Byte payload served for MPEG-TS segment routes.
  final Uint8List tsSegmentBytes;

  /// Chunk size in bytes used when streaming throttled or delayed responses.
  int chunkSize = 1024;

  /// Optional transfer speed limit in bytes per second.
  int? throttleBytesPerSecond;

  /// Optional delay injected after each chunk during transfer.
  Duration? transferDelayPerChunk;

  /// Optional delay injected before writing the response headers.
  Duration? pauseBeforeResponse;

  /// When true, ignores client `Range` headers and always responds with full HTTP 200.
  bool ignoreRangeRequests;

  /// Expected signed token for `/signed` route when using default validator.
  String expectedSignedToken;

  /// Custom validation callback for `/signed` URLs.
  bool Function(Uri uri)? signedUrlValidator;

  /// Current sequence number for the rolling HLS live playlist `/hls/live.m3u8`.
  int liveSequence = 1;

  /// Whether `/hls/live.m3u8` automatically increments [liveSequence] on each fetch.
  bool autoAdvanceLiveSequence = false;

  /// Number of segments included in the rolling live playlist window.
  int liveWindowSize = 3;

  /// Duration for `/stalled` requests when no `delayMs` query param is provided.
  Duration? stallDuration;

  /// Optional manual completer to un-stall requests waiting on `/stalled`.
  Completer<void>? _stallCompleter;

  /// All recorded requests received since the server started or [clearLedger] was called.
  List<RecordedRequest> get ledger =>
      List<RecordedRequest>.unmodifiable(_ledger);

  /// Total count of recorded requests.
  int get requestCount => _ledger.length;

  /// The most recent request recorded in the ledger, or `null` if none.
  RecordedRequest? get lastRequest => _ledger.isNotEmpty ? _ledger.last : null;

  /// The first request recorded in the ledger, or `null` if none.
  RecordedRequest? get firstRequest =>
      _ledger.isNotEmpty ? _ledger.first : null;

  /// Whether the server is actively listening for connections.
  bool get isRunning => _server != null;

  /// The local loopback port on which this server is listening.
  int get port {
    final s = _server;
    if (s == null) {
      throw StateError('StreamingFixtureServer has not been started');
    }
    return s.port;
  }

  /// The IP address on which this server is listening.
  InternetAddress get address {
    final s = _server;
    if (s == null) {
      throw StateError('StreamingFixtureServer has not been started');
    }
    return s.address;
  }

  /// Base URL string for this server, e.g. `http://127.0.0.1:54321`.
  String get baseUrl => 'http://127.0.0.1:$port';

  /// Returns a full loopback [Uri] for the given [path] and optional [queryParameters].
  Uri urlFor(String path, [Map<String, dynamic>? queryParameters]) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: normalizedPath,
      queryParameters: queryParameters,
    );
  }

  /// Convenience method returning the [urlFor] result as a string.
  String urlStringFor(String path, [Map<String, dynamic>? queryParameters]) =>
      urlFor(path, queryParameters).toString();

  /// Starts the server on an ephemeral port on the loopback interface.
  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(
      _handleRequest,
      onError: (Object error, StackTrace stack) {
        // Suppress socket errors caused by intentional aborts in tests.
      },
    );
  }

  /// Stops the server and closes all active connections.
  Future<void> stop() async {
    resumeStall();
    final s = _server;
    _server = null;
    if (s != null) {
      await s.close(force: true);
    }
  }

  /// Clears the recorded request journal.
  void clearLedger() {
    _ledger.clear();
  }

  /// Returns all requests that match the given [path].
  List<RecordedRequest> requestsFor(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return _ledger.where((r) => r.path == normalized).toList();
  }

  /// Returns the latest request matching [path], or `null`.
  RecordedRequest? lastRequestFor(String path) {
    final matches = requestsFor(path);
    return matches.isNotEmpty ? matches.last : null;
  }

  /// Manually un-stalls any request waiting on the `/stalled` route.
  void resumeStall() {
    if (_stallCompleter != null && !_stallCompleter!.isCompleted) {
      _stallCompleter!.complete();
    }
    _stallCompleter = null;
  }

  /// Advances the sequence number for rolling live HLS playlists.
  void advanceLiveSequence([int count = 1]) {
    liveSequence += count;
  }

  /// Registers a custom route handler for [path].
  void registerRoute(
    String path,
    FutureOr<void> Function(HttpRequest request) handler,
  ) {
    final normalized = path.startsWith('/') ? path : '/$path';
    _customRoutes[normalized] = handler;
  }

  /// Static helper to instantiate and start a server in one step.
  static Future<StreamingFixtureServer> startServer({
    Uint8List? videoMp4Bytes,
    Uint8List? tsSegmentBytes,
    int? throttleBytesPerSecond,
    Duration? transferDelayPerChunk,
    Duration? pauseBeforeResponse,
    bool ignoreRangeRequests = false,
    String expectedSignedToken = 'valid-token',
    bool Function(Uri uri)? signedUrlValidator,
    Duration? stallDuration,
  }) async {
    final server = StreamingFixtureServer(
      videoMp4Bytes: videoMp4Bytes,
      tsSegmentBytes: tsSegmentBytes,
      throttleBytesPerSecond: throttleBytesPerSecond,
      transferDelayPerChunk: transferDelayPerChunk,
      pauseBeforeResponse: pauseBeforeResponse,
      ignoreRangeRequests: ignoreRangeRequests,
      expectedSignedToken: expectedSignedToken,
      signedUrlValidator: signedUrlValidator,
      stallDuration: stallDuration,
    );
    await server.start();
    return server;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // Record request into ledger
    final headersMap = <String, List<String>>{};
    request.headers.forEach((name, values) {
      headersMap[name.toLowerCase()] = List<String>.unmodifiable(values);
    });

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    ByteRange? requestedRange;
    try {
      requestedRange = ByteRange.parse(rangeHeader, videoMp4Bytes.length);
    } catch (_) {
      // Unsatisfiable or malformed range will be handled during response dispatch
    }

    final recorded = RecordedRequest(
      method: request.method,
      uri: request.uri,
      path: request.uri.path,
      headers: Map<String, List<String>>.unmodifiable(headersMap),
      timestamp: DateTime.now(),
      clientIp: request.connectionInfo?.remoteAddress.address ?? '127.0.0.1',
      rangeHeader: rangeHeader,
      requestedRange: requestedRange,
    );
    _ledger.add(recorded);

    if (pauseBeforeResponse != null) {
      await Future<void>.delayed(pauseBeforeResponse!);
    }

    try {
      final path = request.uri.path;

      // 1. Custom route overrides
      if (_customRoutes.containsKey(path)) {
        await _customRoutes[path]!(request);
        return;
      }

      // 2. Abort route: abruptly destroy TCP socket
      if (path == '/abort') {
        await _handleAbort(request);
        return;
      }

      // 3. Stalled route: send headers, flush, and stall
      if (path == '/stalled') {
        await _handleStalled(request);
        return;
      }

      // 4. Error routes: `/error/403`, `/error/404`, `/error/500`, etc.
      if (path.startsWith('/error/')) {
        await _handleErrorRoute(request);
        return;
      }

      // 5. Redirect route: `/redirect`
      if (path == '/redirect') {
        await _handleRedirect(request);
        return;
      }

      // 6. Signed URL route: `/signed`
      if (path == '/signed') {
        await _handleSigned(request);
        return;
      }

      // 7. MP4 routes: `/video.mp4` and extensionless `/media/stream-1234`
      if (path == '/video.mp4' || path == '/media/stream-1234') {
        await _serveByteResource(
          request,
          videoMp4Bytes,
          contentType: ContentType('video', 'mp4'),
        );
        return;
      }

      // 8. HLS Master Playlist: `/hls/master.m3u8`
      if (path == '/hls/master.m3u8') {
        await _serveHlsMaster(request);
        return;
      }

      // 9. HLS Variant Media Playlists: `/hls/360p.m3u8`, `/hls/720p.m3u8`, `/hls/1080p.m3u8`, `/hls/audio.m3u8`
      if (path == '/hls/360p.m3u8' ||
          path == '/hls/720p.m3u8' ||
          path == '/hls/1080p.m3u8' ||
          path == '/hls/audio.m3u8') {
        await _serveHlsVariant(request);
        return;
      }

      // 10. HLS Rolling Live Playlist: `/hls/live.m3u8`
      if (path == '/hls/live.m3u8') {
        await _serveHlsLive(request);
        return;
      }

      // 11. HLS Subtitles: `/hls/subs_en.vtt`
      if (path == '/hls/subs_en.vtt') {
        await _serveWebVtt(request);
        return;
      }

      // 12. HLS Segment routes: `/hls/seg-*.ts` or any `.ts` segment
      if (path.startsWith('/hls/') && path.endsWith('.ts')) {
        await _serveByteResource(
          request,
          tsSegmentBytes,
          contentType: ContentType('video', 'mp2t'),
        );
        return;
      }

      // 13. DASH MPD Manifest: `/dash/manifest.mpd`
      if (path == '/dash/manifest.mpd') {
        await _serveDashMpd(request);
        return;
      }

      // 14. DASH Media segments / representations: `/dash/*.mp4`
      if (path.startsWith('/dash/') && path.endsWith('.mp4')) {
        await _serveByteResource(
          request,
          videoMp4Bytes,
          contentType: ContentType('video', 'mp4'),
        );
        return;
      }

      // Default: 404 Not Found
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.text;
      request.response.write('Not Found: $path');
      await request.response.close();
    } catch (e) {
      // If the client aborted or closed early, ignore socket errors
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveByteResource(
    HttpRequest request,
    Uint8List data, {
    required ContentType contentType,
  }) async {
    final response = request.response;
    final totalLength = data.length;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);

    // If configured to ignore range requests, treat as full 200 OK
    if (ignoreRangeRequests || rangeHeader == null) {
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = contentType;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentLength = totalLength;

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      await _writeThrottledBytes(response, data);
      return;
    }

    // Process range request
    ByteRange range;
    try {
      final parsed = ByteRange.parse(rangeHeader, totalLength);
      if (parsed == null) {
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = contentType;
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.contentLength = totalLength;
        if (request.method == 'HEAD') {
          await response.close();
          return;
        }
        await _writeThrottledBytes(response, data);
        return;
      }
      range = parsed;
    } on RangeNotSatisfiableException {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$totalLength',
      );
      response.headers.contentLength = 0;
      await response.close();
      return;
    }

    final slice = data.sublist(range.start, range.end + 1);
    response.statusCode = HttpStatus.partialContent;
    response.headers.contentType = contentType;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      range.toContentRangeHeader(totalLength),
    );
    response.headers.contentLength = slice.length;

    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    await _writeThrottledBytes(response, slice);
  }

  Future<void> _writeThrottledBytes(
    HttpResponse response,
    List<int> bytes,
  ) async {
    if (bytes.isEmpty) {
      await response.close();
      return;
    }

    final throttleRate = throttleBytesPerSecond;
    final effectiveChunkSize = chunkSize > 0 ? chunkSize : 1024;

    if (throttleRate == null || throttleRate <= 0) {
      if (transferDelayPerChunk != null) {
        // Chunked with custom delay
        var offset = 0;
        while (offset < bytes.length) {
          final end = (offset + effectiveChunkSize < bytes.length)
              ? offset + effectiveChunkSize
              : bytes.length;
          response.add(bytes.sublist(offset, end));
          await response.flush();
          offset = end;
          if (offset < bytes.length) {
            await Future<void>.delayed(transferDelayPerChunk!);
          }
        }
        await response.close();
        return;
      }

      response.add(bytes);
      await response.close();
      return;
    }

    // Bandwidth shaped streaming
    final cSize = (throttleRate ~/ 10).clamp(64, effectiveChunkSize);
    final chunkDelayMs = ((cSize / throttleRate) * 1000).round();
    final delay = transferDelayPerChunk ?? Duration(milliseconds: chunkDelayMs);

    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + cSize < bytes.length)
          ? offset + cSize
          : bytes.length;
      response.add(bytes.sublist(offset, end));
      await response.flush();
      offset = end;
      if (offset < bytes.length) {
        await Future<void>.delayed(delay);
      }
    }
    await response.close();
  }

  Future<void> _handleRedirect(HttpRequest request) async {
    final target = request.uri.queryParameters['to'] ?? '/video.mp4';
    final statusStr = request.uri.queryParameters['status'];
    final statusCode = int.tryParse(statusStr ?? '') ?? HttpStatus.found;

    request.response.statusCode = statusCode;
    request.response.headers.set(HttpHeaders.locationHeader, target);
    request.response.headers.contentLength = 0;
    await request.response.close();
  }

  Future<void> _handleSigned(HttpRequest request) async {
    final uri = request.uri;
    var isValid = false;

    if (signedUrlValidator != null) {
      isValid = signedUrlValidator!(uri);
    } else {
      final token = uri.queryParameters['token'];
      final expiresStr = uri.queryParameters['expires'];
      if (token == expectedSignedToken && expiresStr != null) {
        final expires = int.tryParse(expiresStr);
        if (expires != null) {
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (expires >= nowSec) {
            isValid = true;
          }
        }
      }
    }

    if (!isValid) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.headers.contentType = ContentType.json;
      final errorJson = jsonEncode(<String, dynamic>{
        'error': 'Forbidden',
        'message': 'Signed URL expired or invalid',
      });
      request.response.write(errorJson);
      await request.response.close();
      return;
    }

    // If media parameter requested or extension specified, serve video bytes
    if (uri.queryParameters['media'] == 'true') {
      await _serveByteResource(
        request,
        videoMp4Bytes,
        contentType: ContentType('video', 'mp4'),
      );
      return;
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(<String, dynamic>{
        'status': 'ok',
        'message': 'Signed URL access granted',
      }),
    );
    await request.response.close();
  }

  Future<void> _handleErrorRoute(HttpRequest request) async {
    final codeStr = request.uri.path.substring('/error/'.length);
    final statusCode = int.tryParse(codeStr) ?? HttpStatus.internalServerError;

    request.response.statusCode = statusCode;
    if (statusCode == HttpStatus.tooManyRequests) {
      request.response.headers.set('Retry-After', '5');
    } else if (statusCode == HttpStatus.serviceUnavailable) {
      request.response.headers.set('Retry-After', '2');
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(<String, dynamic>{
        'error': statusCode,
        'message': 'Simulated error $statusCode',
      }),
    );
    await request.response.close();
  }

  Future<void> _handleAbort(HttpRequest request) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.binary;
    request.response.headers.contentLength = 10000;

    // Detach raw socket, send partial bytes and immediately destroy socket
    final socket = await request.response.detachSocket(writeHeaders: true);
    socket.add(Uint8List(64));
    socket.destroy();
  }

  Future<void> _handleStalled(HttpRequest request) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.binary;
    request.response.headers.chunkedTransferEncoding = true;
    request.response.add(Uint8List(16));
    await request.response.flush();

    final delayMsStr = request.uri.queryParameters['delayMs'];
    final delayMs = int.tryParse(delayMsStr ?? '');

    if (delayMs != null) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    } else if (stallDuration != null) {
      await Future<void>.delayed(stallDuration!);
    } else {
      _stallCompleter = Completer<void>();
      await _stallCompleter!.future;
    }

    try {
      request.response.add(Uint8List(16));
      await request.response.close();
    } catch (_) {}
  }

  Future<void> _serveHlsMaster(HttpRequest request) async {
    const playlist = '''#EXTM3U
#EXT-X-VERSION:4
#EXT-X-INDEPENDENT-SEGMENTS

# Audio rendition group
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="English",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",URI="audio.m3u8"

# Subtitle rendition
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,LANGUAGE="en",URI="subs_en.vtt"

# Video renditions
#EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=750000,RESOLUTION=640x360,FRAME-RATE=29.970,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="audio-aac",SUBTITLES="subs"
360p.m3u8

#EXT-X-STREAM-INF:BANDWIDTH=2500000,AVERAGE-BANDWIDTH=2300000,RESOLUTION=1280x720,FRAME-RATE=29.970,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="audio-aac",SUBTITLES="subs"
720p.m3u8

#EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=4800000,RESOLUTION=1920x1080,FRAME-RATE=29.970,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio-aac",SUBTITLES="subs"
1080p.m3u8
''';

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl',
    );
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final bytes = utf8.encode(playlist);
    request.response.headers.contentLength = bytes.length;
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _serveHlsVariant(HttpRequest request) async {
    final path = request.uri.path;
    final prefix = path.substring('/hls/'.length).replaceAll('.m3u8', '');

    final playlist =
        '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:6.000,
seg-$prefix-0.ts
#EXTINF:6.000,
seg-$prefix-1.ts
#EXTINF:6.000,
seg-$prefix-2.ts
#EXT-X-ENDLIST
''';

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl',
    );
    final bytes = utf8.encode(playlist);
    request.response.headers.contentLength = bytes.length;
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _serveHlsLive(HttpRequest request) async {
    final currentSeq = liveSequence;
    if (autoAdvanceLiveSequence) {
      liveSequence++;
    }

    final buffer = StringBuffer();
    buffer.writeln('#EXTM3U');
    buffer.writeln('#EXT-X-VERSION:3');
    buffer.writeln('#EXT-X-TARGETDURATION:6');
    buffer.writeln('#EXT-X-MEDIA-SEQUENCE:$currentSeq');

    for (var i = 0; i < liveWindowSize; i++) {
      final segIndex = currentSeq + i;
      buffer.writeln('#EXTINF:6.000,');
      buffer.writeln('seg-live-$segIndex.ts');
    }

    final playlist = buffer.toString();
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl',
    );
    final bytes = utf8.encode(playlist);
    request.response.headers.contentLength = bytes.length;
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _serveWebVtt(HttpRequest request) async {
    const vtt = '''WEBVTT

00:00:00.000 --> 00:00:05.000
Streaming fixture test subtitle line 1

00:00:05.000 --> 00:00:10.000
Streaming fixture test subtitle line 2
''';

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set(HttpHeaders.contentTypeHeader, 'text/vtt');
    final bytes = utf8.encode(vtt);
    request.response.headers.contentLength = bytes.length;
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _serveDashMpd(HttpRequest request) async {
    const mpd = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
     profiles="urn:mpeg:dash:profile:isoff-live:2011"
     type="static"
     mediaPresentationDuration="PT30S"
     minBufferTime="PT2S">
  <Period id="0" start="PT0S">
    <AdaptationSet id="0" contentType="video" mimeType="video/mp4" codecs="avc1.4d401f" segmentAlignment="true">
      <Representation id="v-360p" bandwidth="800000" width="640" height="360">
        <BaseURL>video-360p.mp4</BaseURL>
        <SegmentBase indexRange="0-800"/>
      </Representation>
      <Representation id="v-720p" bandwidth="2500000" width="1280" height="720">
        <BaseURL>video-720p.mp4</BaseURL>
        <SegmentBase indexRange="0-800"/>
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="1" contentType="audio" mimeType="audio/mp4" codecs="mp4a.40.2" segmentAlignment="true" lang="en">
      <Representation id="a-en" bandwidth="128000" audioSamplingRate="48000">
        <BaseURL>audio-en.mp4</BaseURL>
        <SegmentBase indexRange="0-800"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/dash+xml',
    );
    final bytes = utf8.encode(mpd);
    request.response.headers.contentLength = bytes.length;
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    request.response.add(bytes);
    await request.response.close();
  }
}
