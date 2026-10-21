import 'package:http/http.dart' as http;

/// The length of the bytes yielded by an HTTP response, when known.
/// IOClient decompresses gzip bodies while retaining the wire Content-Length.
int? responseBodyLength(http.StreamedResponse response) {
  final encoding = response.headers['content-encoding']?.trim().toLowerCase();
  if (encoding != null && encoding.isNotEmpty && encoding != 'identity') {
    return null;
  }
  return response.contentLength;
}
