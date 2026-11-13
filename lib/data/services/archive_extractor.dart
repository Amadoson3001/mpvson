import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

/// Represents a validated extracted dependency file.
final class ArchiveExtractionDependency {
  final String path;
  final int size;
  final String sha256;

  const ArchiveExtractionDependency({
    required this.path,
    required this.size,
    required this.sha256,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'size': size,
    'sha256': sha256,
  };
}

/// The result of an archive extraction operation.
final class ArchiveExtractionResult {
  final String librarySha256;
  final List<ArchiveExtractionDependency> dependencies;

  const ArchiveExtractionResult({
    required this.librarySha256,
    required this.dependencies,
  });
}

/// Parameters configuring extraction in a dedicated worker isolate.
final class ArchiveExtractionParams {
  final String packageFilePath;
  final String stagingDirectoryPath;
  final String cancellationSignalPath;
  final int maxArchiveEntries;
  final int maxUncompressedBytes;
  final String engineLibraryFileName;
  final Set<String> reservedControlPaths;

  const ArchiveExtractionParams({
    required this.packageFilePath,
    required this.stagingDirectoryPath,
    required this.cancellationSignalPath,
    required this.maxArchiveEntries,
    required this.maxUncompressedBytes,
    required this.engineLibraryFileName,
    this.reservedControlPaths = const <String>{},
  });
}

/// Thrown when archive extraction is cancelled by request or signal.
class ArchiveExtractionCancelledException implements Exception {
  const ArchiveExtractionCancelledException();

  @override
  String toString() => 'Archive extraction was cancelled.';
}

/// Safely validates and extracts ZIP archives in a background isolate.
class ArchiveExtractor {
  const ArchiveExtractor();

  /// Validates an archive path for path-traversal safety and returns its normalized form.
  static String validateArchivePath(String source) => _validatedArchivePath(source);

  /// Returns true if [relativePath] points to an executable or dynamic library dependency (.dll or .exe).
  static bool isExecutableDependency(String relativePath) => _isExecutableDependency(relativePath);

  /// Extracts the archive specified by [params] into its staging directory.
  ///
  /// Throws [ArchiveExtractionCancelledException] when [shouldCancel] returns true.
  /// Throws [FormatException] if archive structure, path safety, or content limits fail.
  /// Throws [StateError] on unrecoverable worker failures.
  Future<ArchiveExtractionResult> extract(
    ArchiveExtractionParams params, {
    bool Function()? shouldCancel,
  }) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final started = Completer<void>();
    final response = Completer<Object?>();
    final failure = Completer<Object?>();
    final exited = Completer<void>();
    SendPort? workerCancellationPort;

    try {
      await Isolate.spawn<List<Object?>>(
        _archiveExtractionWorkerEntryPoint,
        <Object?>[messages.sendPort, params],
        onError: errors.sendPort,
        onExit: messages.sendPort,
        errorsAreFatal: true,
      );
    } on Object {
      messages.close();
      errors.close();
      rethrow;
    }

    final messageSubscription = messages.listen((message) {
      if (message is List &&
          message.length == 2 &&
          message[0] == 'started' &&
          message[1] is SendPort) {
        workerCancellationPort = message[1] as SendPort;
        if (!started.isCompleted) started.complete();
      } else if (message == null) {
        if (!exited.isCompleted) exited.complete();
      } else if (!response.isCompleted) {
        response.complete(message);
      }
    });
    final errorSubscription = errors.listen((message) {
      if (!failure.isCompleted) failure.complete(message);
    });

    Future<void> signalCancellationAndWait() async {
      workerCancellationPort?.send(null);
      final cancellationDirectory = Directory(params.cancellationSignalPath);
      try {
        final type = await FileSystemEntity.type(
          cancellationDirectory.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) {
          await cancellationDirectory.create();
        } else if (type != FileSystemEntityType.directory) {
          throw StateError('The engine cancellation signal path is not safe.');
        }
      } on Object {
        // The SendPort still cancels the worker when its event loop is available.
      }
      workerCancellationPort?.send(null);
      await exited.future;
    }

    try {
      while (!started.isCompleted &&
          !response.isCompleted &&
          !failure.isCompleted &&
          !exited.isCompleted) {
        if (shouldCancel?.call() == true) {
          await signalCancellationAndWait();
          throw const ArchiveExtractionCancelledException();
        }
        await Future.any<void>([
          started.future,
          response.future.then<void>((_) {}),
          failure.future.then<void>((_) {}),
          exited.future,
          Future<void>.delayed(const Duration(milliseconds: 20)),
        ]);
      }

      while (!response.isCompleted &&
          !failure.isCompleted &&
          !exited.isCompleted) {
        if (shouldCancel?.call() == true) {
          await signalCancellationAndWait();
          throw const ArchiveExtractionCancelledException();
        }
        await Future.any<void>([
          response.future.then<void>((_) {}),
          failure.future.then<void>((_) {}),
          exited.future,
          Future<void>.delayed(const Duration(milliseconds: 20)),
        ]);
      }

      if (shouldCancel?.call() == true) {
        await signalCancellationAndWait();
        throw const ArchiveExtractionCancelledException();
      }
      if (failure.isCompleted) {
        await exited.future;
        throw StateError('Engine package extraction worker failed.');
      }
      if (!response.isCompleted) {
        throw StateError('Engine package extraction worker exited unexpectedly.');
      }
      await exited.future;
      final message = await response.future;
      if (message is! List || message.isEmpty) {
        throw StateError(
          'Engine package extraction worker returned invalid data.',
        );
      }
      if (message[0] == 'cancelled') {
        if (message.length != 1) {
          throw StateError(
            'Engine package extraction worker returned invalid cancellation data.',
          );
        }
        throw const ArchiveExtractionCancelledException();
      }
      if (message.length != 3) {
        throw StateError(
          'Engine package extraction worker returned invalid data.',
        );
      }
      if (message[0] == 'error') {
        final kind = message[1];
        final description = message[2];
        if (kind == 'FormatException' && description is String) {
          throw FormatException(description);
        }
        throw StateError('Engine package extraction failed: $description');
      }
      if (message[0] != 'ok' || message[1] is! String || message[2] is! List) {
        throw StateError(
          'Engine package extraction worker returned invalid data.',
        );
      }
      final dependencies = <ArchiveExtractionDependency>[];
      for (final item in message[2] as List) {
        if (item is! List ||
            item.length != 3 ||
            item[0] is! String ||
            item[1] is! int ||
            item[2] is! String) {
          throw StateError(
            'Engine package extraction worker returned an invalid inventory.',
          );
        }
        dependencies.add(
          ArchiveExtractionDependency(
            path: item[0] as String,
            size: item[1] as int,
            sha256: item[2] as String,
          ),
        );
      }
      return ArchiveExtractionResult(
        librarySha256: message[1] as String,
        dependencies: dependencies,
      );
    } finally {
      if (!exited.isCompleted) {
        await signalCancellationAndWait();
      }
      await messageSubscription.cancel();
      await errorSubscription.cancel();
      messages.close();
      errors.close();
    }
  }
}

void _archiveExtractionWorkerEntryPoint(List<Object?> request) async {
  final sendPort = request[0] as SendPort;
  final params = request[1] as ArchiveExtractionParams;
  final cancellationMessages = ReceivePort();
  var cancellationReceived = false;
  cancellationMessages.listen((_) => cancellationReceived = true);
  bool shouldCancel() =>
      cancellationReceived ||
      FileSystemEntity.typeSync(
            params.cancellationSignalPath,
            followLinks: false,
          ) ==
          FileSystemEntityType.directory;
  sendPort.send(<Object?>['started', cancellationMessages.sendPort]);
  try {
    final result = await _extractArchiveInWorker(
      params,
      shouldCancel: shouldCancel,
    );
    sendPort.send(<Object?>[
      'ok',
      result.librarySha256,
      result.dependencies
          .map(
            (dependency) => <Object?>[
              dependency.path,
              dependency.size,
              dependency.sha256,
            ],
          )
          .toList(),
    ]);
  } on Object catch (error) {
    if (error is ArchiveExtractionCancelledException) {
      sendPort.send(<Object?>['cancelled']);
    } else {
      sendPort.send(<Object?>[
        'error',
        error is FormatException
            ? 'FormatException'
            : error.runtimeType.toString(),
        error is FormatException ? error.message.toString() : error.toString(),
      ]);
    }
  } finally {
    cancellationMessages.close();
  }
}

Future<ArchiveExtractionResult> _extractArchiveInWorker(
  ArchiveExtractionParams params, {
  bool Function()? shouldCancel,
}) async {
  final fileStream = InputFileStream(params.packageFilePath);
  try {
    _throwIfExtractionCancelled(shouldCancel);
    _preflightZipStream(
      fileStream,
      maxArchiveEntries: params.maxArchiveEntries,
      maxUncompressedBytes: params.maxUncompressedBytes,
      engineLibraryFileName: params.engineLibraryFileName,
      reservedControlPaths: params.reservedControlPaths,
      shouldCancel: shouldCancel,
    );

    fileStream.position = 0;
    final archive = ZipDecoder().decodeStream(fileStream);
    _throwIfExtractionCancelled(shouldCancel);

    String? librarySha256;
    final dependencies = <ArchiveExtractionDependency>[];

    for (final file in archive.files) {
      _throwIfExtractionCancelled(shouldCancel);
      final relativePath = _validatedArchivePath(file.name);
      final destinationPath = p.normalize(
        p.join(params.stagingDirectoryPath, relativePath),
      );

      if (!p.isWithin(params.stagingDirectoryPath, destinationPath) &&
          destinationPath != p.normalize(params.stagingDirectoryPath)) {
        throw const FormatException('Engine ZIP contains an unsafe path.');
      }

      if (file.isSymbolicLink || file.symbolicLink != null) {
        throw const FormatException('Engine ZIP contains a link entry.');
      }

      if (file.isDirectory) {
        await Directory(destinationPath).create(recursive: true);
        continue;
      }

      final parentDir = Directory(p.dirname(destinationPath));
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      final outFileStream = OutputFileStream(destinationPath);
      try {
        file.writeContent(
          _CancellationAwareOutputStream(
            outFileStream,
            shouldCancel: shouldCancel,
          ),
          freeMemory: true,
        );
      } finally {
        try {
          outFileStream.closeSync();
        } finally {
          file.closeSync();
        }
      }

      _throwIfExtractionCancelled(shouldCancel);
      final stat = await FileStat.stat(destinationPath);
      final actualFile = File(destinationPath);
      final hash = await crypto.sha256
          .bind(
            actualFile.openRead().map((chunk) {
              _throwIfExtractionCancelled(shouldCancel);
              return chunk;
            }),
          )
          .single;
      final shaString = hash.toString().toLowerCase();

      if (_isExecutableDependency(relativePath)) {
        dependencies.add(
          ArchiveExtractionDependency(
            path: relativePath.replaceAll(p.separator, '/'),
            size: stat.size,
            sha256: shaString,
          ),
        );
      }

      if (relativePath == params.engineLibraryFileName) {
        librarySha256 = shaString;
      }
    }

    _throwIfExtractionCancelled(shouldCancel);
    if (librarySha256 == null) {
      throw FormatException(
        'Engine ZIP must contain a non-empty root ${params.engineLibraryFileName}.',
      );
    }

    return ArchiveExtractionResult(
      librarySha256: librarySha256,
      dependencies: dependencies,
    );
  } finally {
    fileStream.closeSync();
  }
}

bool _isExecutableDependency(String relativePath) {
  final lower = relativePath.toLowerCase();
  return lower.endsWith('.dll') || lower.endsWith('.exe');
}

void _throwIfExtractionCancelled(bool Function()? shouldCancel) {
  if (shouldCancel?.call() == true) {
    throw const ArchiveExtractionCancelledException();
  }
}

final class _CancellationAwareOutputStream extends OutputStream {
  _CancellationAwareOutputStream(this._delegate, {required this.shouldCancel})
    : super(byteOrder: _delegate.byteOrder);

  static const int _checkInterval = 128 * 1024;

  final OutputFileStream _delegate;
  final bool Function()? shouldCancel;
  int _nextCheckAt = 0;

  @override
  int get length => _delegate.length;

  @override
  bool get isOpen => _delegate.isOpen;

  void _checkCancellation() {
    if (_delegate.length < _nextCheckAt) return;
    _nextCheckAt = _delegate.length + _checkInterval;
    _throwIfExtractionCancelled(shouldCancel);
  }

  @override
  void clear() => _delegate.closeSync();

  @override
  Future<void> close() => _delegate.close();

  @override
  void closeSync() => _delegate.closeSync();

  @override
  void flush() {
    _checkCancellation();
    _delegate.flush();
  }

  @override
  void writeByte(int value) {
    _checkCancellation();
    _delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _checkCancellation();
    _delegate.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      _checkCancellation();
      final bytes = stream.readBytes(_checkInterval).toUint8List();
      if (bytes.isEmpty) break;
      _delegate.writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _delegate.subset(start, end);
}

void _preflightZipStream(
  InputStream stream, {
  required int maxArchiveEntries,
  required int maxUncompressedBytes,
  required String engineLibraryFileName,
  required Set<String> reservedControlPaths,
  bool Function()? shouldCancel,
}) {
  final directory = ZipDirectory()..read(stream);
  final headers = directory.fileHeaders;
  final declaredCount = directory.totalCentralDirectoryEntries;
  if (headers.isEmpty ||
      declaredCount <= 0 ||
      declaredCount > maxArchiveEntries ||
      headers.length != declaredCount ||
      directory.totalCentralDirectoryEntriesOnThisDisk != declaredCount) {
    throw const FormatException('Engine ZIP has an invalid number of entries.');
  }

  final normalizedPaths = <String>{};
  final files = <String>{};
  final directories = <String>{};
  var totalUncompressed = 0;
  var hasRootLibrary = false;
  final foldedReservedPaths = reservedControlPaths.map((p) => p.toLowerCase()).toSet();

  for (final header in headers) {
    _throwIfExtractionCancelled(shouldCancel);
    final entry = header.file;
    if (entry == null || entry.filename != header.filename) {
      throw const FormatException('Engine ZIP has a malformed entry.');
    }
    final mode = (header.externalFileAttributes >> 16) & 0xffff;
    final type = mode & 0xf000;
    final unixMade = (header.versionMadeBy >> 8) == 3;
    if ((unixMade && type == 0xa000) ||
        (header.externalFileAttributes & 0x400) != 0) {
      throw const FormatException('Engine ZIP contains a link entry.');
    }

    final source = header.filename;
    final relativePath = _validatedArchivePath(source);
    final foldedPath = relativePath.toLowerCase();
    final archiveStylePath = relativePath
        .replaceAll(p.separator, '/')
        .toLowerCase();
    if (foldedReservedPaths.any(
      (reservedPath) =>
          archiveStylePath == reservedPath ||
          archiveStylePath.startsWith('$reservedPath/'),
    )) {
      throw const FormatException(
        'Engine ZIP contains a reserved updater control path.',
      );
    }
    if (!normalizedPaths.add(foldedPath)) {
      throw const FormatException('Engine ZIP contains duplicate paths.');
    }
    final isDirectory = source.endsWith('/') || source.endsWith('\\');
    if (unixMade && type != 0 && type != 0x8000 && type != 0x4000) {
      throw const FormatException('Engine ZIP contains an unsupported entry.');
    }
    if ((type == 0x4000) != isDirectory && unixMade && type != 0) {
      throw const FormatException('Engine ZIP has inconsistent entry type.');
    }

    final size = entry.uncompressedSize;
    final compressedSize = entry.compressedSize;
    if (size < 0 || compressedSize < 0 || compressedSize > stream.length) {
      throw const FormatException('Engine ZIP contains an invalid file size.');
    }
    if (size > maxUncompressedBytes - totalUncompressed) {
      throw const FormatException(
        'Engine ZIP exceeds the extraction size limit.',
      );
    }
    totalUncompressed += size;

    if (isDirectory) {
      directories.add(foldedPath);
    } else {
      files.add(foldedPath);
      if (relativePath == engineLibraryFileName) {
        hasRootLibrary = size > 0;
      }
    }
  }
  if (!hasRootLibrary) {
    throw FormatException(
      'Engine ZIP must contain a non-empty root $engineLibraryFileName.',
    );
  }
  for (final filePath in files) {
    if (directories.contains(filePath)) {
      throw const FormatException(
        'Engine ZIP has a file and directory path collision.',
      );
    }
    var parent = p.dirname(filePath);
    while (parent != '.' && parent.isNotEmpty) {
      if (files.contains(parent)) {
        throw const FormatException('Engine ZIP has a file path collision.');
      }
      parent = p.dirname(parent);
    }
  }
}

String _validatedArchivePath(String source) {
  if (source.isEmpty || source.contains('\u0000') || source.contains('\\')) {
    throw const FormatException('Engine ZIP contains an unsafe path.');
  }
  final normalized = source.replaceAll('/', p.separator);
  if (p.isAbsolute(normalized) ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
      normalized.startsWith('\\')) {
    throw const FormatException('Engine ZIP contains an absolute path.');
  }
  final hasTrailingSlash = source.endsWith('/');
  final components = source.split('/');
  if (hasTrailingSlash) components.removeLast();
  if (components.isEmpty ||
      components.any(
        (component) =>
            component.isEmpty ||
            component == '.' ||
            component == '..' ||
            component.contains(':') ||
            component.endsWith('.') ||
            component.endsWith(' ') ||
            RegExp(r'[<>"|?*\x00-\x1f]').hasMatch(component) ||
            _isReservedWindowsName(component),
      )) {
    throw const FormatException('Engine ZIP contains an unsafe path.');
  }
  final result = components.join(p.separator);
  final normalizedResult = p.normalize(result);
  if (normalizedResult == '.' || p.isAbsolute(normalizedResult)) {
    throw const FormatException('Engine ZIP contains an unsafe path.');
  }
  return normalizedResult;
}

bool _isReservedWindowsName(String component) {
  final baseName = component.split('.').first.toUpperCase();
  return const {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  }.contains(baseName);
}
