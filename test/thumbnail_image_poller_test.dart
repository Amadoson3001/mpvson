import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpvson/data/services/thumbnail_image_poller.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThumbnailImagePoller', () {
    late Directory sandbox;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('mpvson-image-poll-');
    });

    tearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    test('waits for a partial image write to finish and decode', () async {
      final image = await _createPng(96, 54);
      final file = File(p.join(sandbox.path, 'frame.png'));
      await file.writeAsBytes(image.sublist(0, 4));
      final writer = Future<void>.delayed(
        const Duration(milliseconds: 35),
        () async {
          await file.writeAsBytes(image, flush: true);
        },
      );
      const poller = ThumbnailImagePoller(
        maximumBytes: 1024 * 1024,
        pollInterval: Duration(milliseconds: 3),
      );

      final result = await poller.waitForImage(
        directory: sandbox,
        deadline: DateTime.now().add(const Duration(seconds: 1)),
        timeout: const Duration(seconds: 1),
        hasImageHeader: _hasPngHeader,
        decodes: _decodeImage,
      );
      await writer;

      expect(result.failure, ThumbnailImagePollFailure.none);
      expect(result.bytes, orderedEquals(image));
    });

    test('returns a deadline result when no output image appears', () async {
      const poller = ThumbnailImagePoller(
        maximumBytes: 1024,
        pollInterval: Duration(milliseconds: 2),
      );

      final result = await poller.waitForImage(
        directory: sandbox,
        deadline: DateTime.now().add(const Duration(milliseconds: 35)),
        timeout: const Duration(milliseconds: 35),
        hasImageHeader: _hasPngHeader,
        decodes: _decodeImage,
      );

      expect(result.failure, ThumbnailImagePollFailure.deadline);
      expect(result.lastSeenSize, 0);
    });

    test('stops polling promptly after cancellation', () async {
      final image = await _createPng(12, 12);
      await File(p.join(sandbox.path, 'cancel.png')).writeAsBytes(image);
      var cancelled = false;
      final stalledDecoder = Completer<bool>();
      final decoderStarted = Completer<void>();
      const poller = ThumbnailImagePoller(
        maximumBytes: 1024,
        pollInterval: Duration(milliseconds: 2),
      );

      final polling = poller.waitForImage(
        directory: sandbox,
        deadline: DateTime.now().add(const Duration(seconds: 1)),
        timeout: const Duration(seconds: 1),
        hasImageHeader: _hasPngHeader,
        decodes: (_) {
          if (!decoderStarted.isCompleted) decoderStarted.complete();
          return stalledDecoder.future;
        },
        isCancelled: () => cancelled,
      );
      await decoderStarted.future.timeout(const Duration(seconds: 1));
      cancelled = true;
      final result = await polling;
      stalledDecoder.complete(false);

      expect(result.failure, ThumbnailImagePollFailure.cancelled);
    });

    test('bounds a stalled decoder by the remaining deadline', () async {
      final image = await _createPng(12, 12);
      await File(p.join(sandbox.path, 'stalled.png')).writeAsBytes(image);
      final stalledDecoder = Completer<bool>();
      final decoderStarted = Completer<void>();
      const poller = ThumbnailImagePoller(
        maximumBytes: 1024 * 1024,
        pollInterval: Duration(milliseconds: 2),
      );

      final polling = poller.waitForImage(
        directory: sandbox,
        deadline: DateTime.now().add(const Duration(milliseconds: 100)),
        timeout: const Duration(milliseconds: 100),
        hasImageHeader: _hasPngHeader,
        decodes: (_) {
          if (!decoderStarted.isCompleted) decoderStarted.complete();
          return stalledDecoder.future;
        },
      );
      await decoderStarted.future.timeout(const Duration(seconds: 1));
      final result = await polling;
      stalledDecoder.complete(false);

      expect(result.failure, ThumbnailImagePollFailure.deadline);
    });

    test(
      'rejects output larger than its byte bound before reading it',
      () async {
        final file = File(p.join(sandbox.path, 'too-large.png'));
        final raf = await file.open(mode: FileMode.write);
        await raf.truncate(33);
        await raf.close();
        const poller = ThumbnailImagePoller(
          maximumBytes: 32,
          pollInterval: Duration(milliseconds: 2),
        );

        final result = await poller.waitForImage(
          directory: sandbox,
          deadline: DateTime.now().add(const Duration(seconds: 1)),
          timeout: const Duration(seconds: 1),
          hasImageHeader: _hasPngHeader,
          decodes: _decodeImage,
        );

        expect(result.failure, ThumbnailImagePollFailure.oversized);
        expect(result.lastSeenSize, 33);
      },
    );

    test(
      'retries partial output only when contents change and avoids redundant decodes',
      () async {
        final file = File(p.join(sandbox.path, 'invalid.png'));
        await file.writeAsBytes(<int>[137, 80, 78, 71, 13, 10, 26, 10]);
        var decodeAttempts = 0;
        const poller = ThumbnailImagePoller(
          maximumBytes: 1024,
          pollInterval: Duration(milliseconds: 2),
        );

        final result = await poller.waitForImage(
          directory: sandbox,
          deadline: DateTime.now().add(const Duration(milliseconds: 35)),
          timeout: const Duration(milliseconds: 35),
          hasImageHeader: _hasPngHeader,
          decodes: (_) async {
            decodeAttempts++;
            return false;
          },
        );

        expect(result.failure, ThumbnailImagePollFailure.deadline);
        expect(result.lastSeenSize, 8);
        expect(
          decodeAttempts,
          1,
          reason: 'Unchanging file must be decoded once',
        );
      },
    );

    test('retries a transient output stat failure', () async {
      final image = await _createPng(96, 54);
      final file = File(p.join(sandbox.path, 'busy.png'));
      await file.writeAsBytes(image, flush: true);
      final flakyFile = _FlakyFile(file);
      final directory = _FakeDirectory(
        sandbox,
        files: <FileSystemEntity>[flakyFile],
      );
      const poller = ThumbnailImagePoller(
        maximumBytes: 1024 * 1024,
        pollInterval: Duration(milliseconds: 2),
      );

      final result = await poller.waitForImage(
        directory: directory,
        deadline: DateTime.now().add(const Duration(seconds: 1)),
        timeout: const Duration(seconds: 1),
        hasImageHeader: _hasPngHeader,
        decodes: _decodeImage,
      );

      expect(result.failure, ThumbnailImagePollFailure.none);
      expect(result.bytes, orderedEquals(image));
      expect(
        flakyFile.statCalls,
        greaterThanOrEqualTo(3),
        reason: 'The failed stat must be retried on later polls',
      );
    });

    test('retries a transient directory listing failure', () async {
      final image = await _createPng(96, 54);
      final file = File(p.join(sandbox.path, 'listed.png'));
      await file.writeAsBytes(image, flush: true);
      final directory = _FakeDirectory(
        sandbox,
        files: <FileSystemEntity>[file],
        failFirstList: true,
      );
      const poller = ThumbnailImagePoller(
        maximumBytes: 1024 * 1024,
        pollInterval: Duration(milliseconds: 2),
      );

      final result = await poller.waitForImage(
        directory: directory,
        deadline: DateTime.now().add(const Duration(seconds: 1)),
        timeout: const Duration(seconds: 1),
        hasImageHeader: _hasPngHeader,
        decodes: _decodeImage,
      );

      expect(result.failure, ThumbnailImagePollFailure.none);
      expect(result.bytes, orderedEquals(image));
      expect(
        directory.listCalls,
        greaterThanOrEqualTo(2),
        reason: 'A transient list error must be retried',
      );
    });
  });
}

class _FakeDirectory implements Directory {
  _FakeDirectory(
    this._delegate, {
    required this.files,
    this.failFirstList = false,
  });

  final Directory _delegate;
  final List<FileSystemEntity> files;
  final bool failFirstList;
  int listCalls = 0;

  @override
  String get path => _delegate.path;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) {
    listCalls++;
    if (failFirstList && listCalls == 1) {
      return Stream<FileSystemEntity>.error(
        const FileSystemException('The directory is temporarily busy'),
      );
    }
    return Stream<FileSystemEntity>.fromIterable(files);
  }

  @override
  Future<bool> exists() => _delegate.exists();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FlakyFile implements File {
  _FlakyFile(this._delegate);

  final File _delegate;
  int statCalls = 0;

  @override
  String get path => _delegate.path;

  @override
  Future<FileStat> stat() {
    statCalls++;
    if (statCalls == 1) {
      return Future<FileStat>.error(
        const FileSystemException('The file is temporarily unavailable'),
      );
    }
    return _delegate.stat();
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _delegate.open(mode: mode);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

bool _hasPngHeader(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4e &&
    bytes[3] == 0x47 &&
    bytes[4] == 0x0d &&
    bytes[5] == 0x0a &&
    bytes[6] == 0x1a &&
    bytes[7] == 0x0a;

Future<bool> _decodeImage(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec(targetWidth: 1, targetHeight: 1);
    final frame = await codec.getNextFrame();
    frame.image.dispose();
    return true;
  } on Object {
    return false;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<Uint8List> _createPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff3b82f6),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
