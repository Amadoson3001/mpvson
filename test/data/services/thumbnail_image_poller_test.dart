import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/thumbnail_image_poller.dart';

const List<int> _tinyPng = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x62,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0d,
  0x0a,
  0x2d,
  0xb4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

ThumbnailImagePoller _poller() => const ThumbnailImagePoller(
  maximumBytes: 1024 * 1024,
  pollInterval: Duration(milliseconds: 5),
);

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'mpvson-image-poller-test-',
    );
  });

  tearDown(() async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Temp cleanup is best-effort.
    }
  });

  test('returns the written image once it decodes', () async {
    File(
      '${directory.path}${Platform.pathSeparator}out.jpg',
    ).writeAsBytesSync(_tinyPng, flush: true);

    final result = await _poller().waitForImage(
      directory: directory,
      deadline: DateTime.now().add(const Duration(seconds: 5)),
      timeout: const Duration(seconds: 5),
      hasImageHeader: (bytes) => bytes.isNotEmpty,
      decodes: (_) async => true,
    );

    expect(result.failure, ThumbnailImagePollFailure.none);
    expect(result.bytes, isNotNull);
    expect(result.bytes!.length, _tinyPng.length);
  });

  test('closes the file handle before invoking the decoder', () async {
    final file = File('${directory.path}${Platform.pathSeparator}out.jpg')
      ..writeAsBytesSync(_tinyPng, flush: true);

    var decoderRan = false;
    final result = await _poller().waitForImage(
      directory: directory,
      deadline: DateTime.now().add(const Duration(seconds: 5)),
      timeout: const Duration(seconds: 5),
      hasImageHeader: (bytes) => bytes.isNotEmpty,
      decodes: (bytes) async {
        decoderRan = true;
        // The poller must have released its read handle before decoding; a
        // fresh read of the same file proves no handle deadlock.
        final reopened = await file.open(mode: FileMode.read);
        try {
          expect(await reopened.length(), bytes.length);
        } finally {
          await reopened.close();
        }
        return true;
      },
    );

    expect(decoderRan, isTrue);
    expect(result.failure, ThumbnailImagePollFailure.none);
  });

  test('retries a failed decode after the file changes', () async {
    final file = File('${directory.path}${Platform.pathSeparator}out.jpg')
      ..writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8], flush: true);

    var decodeAttempts = 0;
    final result = await _poller().waitForImage(
      directory: directory,
      deadline: DateTime.now().add(const Duration(seconds: 5)),
      timeout: const Duration(seconds: 5),
      hasImageHeader: (bytes) => bytes.isNotEmpty,
      decodes: (bytes) async {
        decodeAttempts++;
        if (decodeAttempts == 1) {
          // Grow the file while the first decode is being judged so the next
          // poll sees a new size and retries the decode.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          file.writeAsBytesSync(
            List<int>.generate(64, (index) => index),
            flush: true,
          );
          return false;
        }
        return true;
      },
    );

    expect(result.failure, ThumbnailImagePollFailure.none);
    expect(decodeAttempts, 2);
    expect(result.bytes!.length, 64);
  });

  test('reports oversized outputs immediately', () async {
    File(
      '${directory.path}${Platform.pathSeparator}out.jpg',
    ).writeAsBytesSync(List<int>.generate(64, (index) => index), flush: true);

    final result =
        await const ThumbnailImagePoller(
          maximumBytes: 8,
          pollInterval: Duration(milliseconds: 5),
        ).waitForImage(
          directory: directory,
          deadline: DateTime.now().add(const Duration(seconds: 5)),
          timeout: const Duration(seconds: 5),
          hasImageHeader: (bytes) => bytes.isNotEmpty,
          decodes: (_) async => true,
        );

    expect(result.failure, ThumbnailImagePollFailure.oversized);
    expect(result.lastSeenSize, 64);
  });

  test('reports deadline when no image appears', () async {
    final result = await _poller().waitForImage(
      directory: directory,
      deadline: DateTime.now().add(const Duration(milliseconds: 60)),
      timeout: const Duration(milliseconds: 60),
      hasImageHeader: (bytes) => bytes.isNotEmpty,
      decodes: (_) async => true,
    );

    expect(result.failure, ThumbnailImagePollFailure.deadline);
  });
}
