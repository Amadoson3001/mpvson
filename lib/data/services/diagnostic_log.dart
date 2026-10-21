import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/media_source.dart';

/// Local-only diagnostic records.
///
/// Records are bounded in size, carry a source identifier and the failure stage,
/// and never leave the machine. Credentials, query strings and fragments are
/// redacted before anything is written.
abstract interface class DiagnosticSink {
  void record(String stage, {String? sourceId, String? message, Object? error});

  /// Waits until queued records have been written.
  Future<void> flush();
}

/// Keeps records in memory. Used by tests and by the failure UI.
class MemoryDiagnosticLog implements DiagnosticSink {
  MemoryDiagnosticLog({this.capacity = 64});

  final int capacity;
  final List<String> records = <String>[];

  @override
  void record(
    String stage, {
    String? sourceId,
    String? message,
    Object? error,
  }) {
    if (capacity <= 0) return;
    if (records.length >= capacity) records.removeAt(0);
    records.add(
      _format(stage, sourceId: sourceId, message: message, error: error),
    );
  }

  @override
  Future<void> flush() async {}
}

/// Appends bounded records to `<application support>/mpvson/diagnostics.log`.
class FileDiagnosticLog implements DiagnosticSink {
  FileDiagnosticLog({
    Directory? directory,
    this.maxBytes = 256 * 1024,
    this.retainRotations = 1,
  }) : _providedDirectory = directory;

  final Directory? _providedDirectory;
  final int maxBytes;
  final int retainRotations;

  Directory? _resolved;
  Future<void> _tail = Future<void>.value();
  bool _disabled = false;

  @override
  void record(
    String stage, {
    String? sourceId,
    String? message,
    Object? error,
  }) {
    if (_disabled) return;
    final line = _format(
      stage,
      sourceId: sourceId,
      message: message,
      error: error,
    );
    _tail = _tail.then((_) => _append(line)).catchError((Object _) {
      _disabled = true;
    });
  }

  @override
  Future<void> flush() => _tail;

  Future<void> _append(String line) async {
    final file = File(p.join((await _directory()).path, 'diagnostics.log'));
    if (await file.exists() && await file.length() >= maxBytes) {
      await _rotate(file);
    }
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  Future<void> _rotate(File file) async {
    for (var index = retainRotations - 1; index >= 1; index--) {
      final previous = File('${file.path}.$index');
      if (await previous.exists()) {
        final target = File('${file.path}.${index + 1}');
        if (await target.exists()) await target.delete();
        await previous.rename(target.path);
      }
    }
    if (retainRotations > 0) {
      final first = File('${file.path}.1');
      if (await first.exists()) await first.delete();
      await file.rename(first.path);
    } else {
      await file.delete();
    }
  }

  Future<Directory> _directory() async {
    final existing = _resolved;
    if (existing != null) return existing;
    final base = _providedDirectory ?? await getApplicationSupportDirectory();
    final directory = Directory(p.join(base.path, 'mpvson'));
    await directory.create(recursive: true);
    _resolved = directory;
    return directory;
  }
}

String _format(
  String stage, {
  String? sourceId,
  String? message,
  Object? error,
}) {
  final record = <String, Object?>{
    'at': DateTime.now().toUtc().toIso8601String(),
    'stage': _collapse(MediaSource.redactText(stage)),
    if (sourceId != null && sourceId.isNotEmpty)
      'source': _collapse(MediaSource.redact(sourceId)),
    if (message != null && message.isNotEmpty)
      'message': _collapse(MediaSource.redactText(message)),
    if (error != null) 'error': _collapse(MediaSource.redactText('$error')),
  };
  return jsonEncode(record);
}

String _collapse(String value) {
  final collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.length <= 500
      ? collapsed
      : '${collapsed.substring(0, 500)}…';
}
