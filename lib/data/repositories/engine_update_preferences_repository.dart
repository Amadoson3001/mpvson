import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/updates/engine_update_channel.dart';

// Keep the public constructor parameter names independent of private fields.
// ignore_for_file: prefer_initializing_formals

/// Persists the engine release channel separately from the active engine.
///
/// A missing or unreadable preference safely selects stable releases.
final class EngineUpdatePreferencesRepository {
  EngineUpdatePreferencesRepository({
    Directory? storageDirectory,
    Future<Directory> Function()? storageDirectoryProvider,
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _storageDirectory = storageDirectory,
       _storageDirectoryProvider = storageDirectoryProvider,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const String fileName = 'engine-update-preferences.json';
  static const int _schemaVersion = 1;
  static const int _maxPreferenceBytes = 4 * 1024;

  final Directory? _storageDirectory;
  final Future<Directory> Function()? _storageDirectoryProvider;
  final Future<Directory> Function() _supportDirectoryProvider;

  Future<EngineUpdateChannel> loadChannel() async {
    try {
      final file = await _preferenceFile();
      if (!await file.exists()) return EngineUpdateChannel.stable;
      if (await file.length() > _maxPreferenceBytes) {
        return EngineUpdateChannel.stable;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
        return EngineUpdateChannel.stable;
      }
      return EngineUpdateChannel.fromStorage(decoded['channel']);
    } on FileSystemException {
      return EngineUpdateChannel.stable;
    } on FormatException {
      return EngineUpdateChannel.stable;
    }
  }

  Future<void> saveChannel(EngineUpdateChannel channel) async {
    final file = await _preferenceFile();
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({'schemaVersion': _schemaVersion, 'channel': channel.name}),
        flush: true,
      );
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
      }
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // The saved preference remains authoritative if cleanup fails.
      }
    }
  }

  Future<File> _preferenceFile() async {
    final storageDirectory = _storageDirectory;
    final directory =
        storageDirectory ??
        await _storageDirectoryProvider?.call() ??
        Directory(
          p.join((await _supportDirectoryProvider()).path, 'mpvson', 'updates'),
        );
    return File(p.join(directory.path, fileName));
  }
}
