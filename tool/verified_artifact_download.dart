import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Downloads a pinned GitHub artifact without replacing a valid cache entry
/// until its size and digest have both been verified.
Future<void> downloadProvenanceArtifact({
  required http.Client client,
  required Uri uri,
  required File destination,
  required int expectedSize,
  required String expectedSha256,
  Duration idleTimeout = const Duration(seconds: 30),
  Duration deadline = const Duration(minutes: 30),
  void Function(int received)? onProgress,
}) async {
  const maximumSize = 512 * 1024 * 1024;
  if (expectedSize <= 0 ||
      expectedSize > maximumSize ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256)) {
    throw ArgumentError('Invalid pinned artifact size or SHA-256.');
  }
  if (idleTimeout <= Duration.zero || deadline <= Duration.zero) {
    throw ArgumentError('Download timeouts must be positive.');
  }
  void validateUri(Uri value) {
    const hosts = <String>{
      'github.com',
      'objects.githubusercontent.com',
      'release-assets.githubusercontent.com',
      'github-releases.githubusercontent.com',
    };
    if (value.scheme != 'https' ||
        value.userInfo.isNotEmpty ||
        value.port != 443 ||
        !hosts.contains(value.host.toLowerCase())) {
      throw const HttpException('Artifact URL is not an approved HTTPS host.');
    }
  }

  validateUri(uri);
  await destination.parent.create(recursive: true);
  final temporary = await destination.parent.createTemp('.artifact-download-');
  final candidate = File(p.join(temporary.path, 'artifact.part'));
  final abort = Completer<void>();
  final watch = Stopwatch()..start();
  final timer = Timer(deadline, () {
    if (!abort.isCompleted) abort.complete();
  });
  RandomAccessFile? output;
  try {
    var current = uri;
    http.StreamedResponse? response;
    for (var redirects = 0; redirects <= 4; redirects++) {
      validateUri(current);
      final remaining = deadline - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Artifact deadline exceeded.');
      }
      final request = http.AbortableRequest(
        'GET',
        current,
        abortTrigger: abort.future,
      )..followRedirects = false;
      response = await client
          .send(request)
          .timeout(remaining < idleTimeout ? remaining : idleTimeout);
      if (!<int>{301, 302, 303, 307, 308}.contains(response.statusCode)) break;
      final location = response.headers['location'];
      // Abort this response instead of reading an untrusted redirect body.
      await response.stream.listen((_) {}).cancel();
      if (location == null || redirects == 4) {
        throw const HttpException('Invalid artifact redirect chain.');
      }
      current = current.resolve(location);
    }
    final body = response!;
    if (body.statusCode != 200) {
      await body.stream.listen((_) {}).cancel();
      throw HttpException('Artifact HTTP ${body.statusCode}.');
    }
    if (body.contentLength != null && body.contentLength != expectedSize) {
      await body.stream.listen((_) {}).cancel();
      throw const HttpException(
        'Artifact Content-Length differs from the pin.',
      );
    }
    output = await candidate.open(mode: FileMode.write);
    Digest? digest;
    final hash = sha256.startChunkedConversion(
      _DigestSink((value) => digest = value),
    );
    var received = 0;
    final remaining = deadline - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Artifact deadline exceeded.');
    }
    await for (final chunk in body.stream.timeout(
      remaining < idleTimeout ? remaining : idleTimeout,
    )) {
      if (watch.elapsed >= deadline) {
        throw TimeoutException('Artifact deadline exceeded.');
      }
      if (chunk.length > expectedSize - received) {
        throw const HttpException('Artifact exceeds the pinned size.');
      }
      // Await disk writes so a fast response cannot create an unbounded buffer.
      await output.writeFrom(chunk);
      hash.add(chunk);
      received += chunk.length;
      onProgress?.call(received);
    }
    hash.close();
    if (received != expectedSize || digest.toString() != expectedSha256) {
      throw const HttpException(
        'Artifact size or SHA-256 does not match the pin.',
      );
    }
    await output.flush();
    await output.close();
    output = null;
    await candidate.rename(destination.path);
  } finally {
    timer.cancel();
    if (!abort.isCompleted) abort.complete();
    await output?.close();
    await temporary.delete(recursive: true);
  }
}

class _DigestSink implements Sink<Digest> {
  _DigestSink(this.receive);
  final void Function(Digest) receive;
  @override
  void add(Digest value) => receive(value);
  @override
  void close() {}
}
