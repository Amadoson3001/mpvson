import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// User preference for how to handle opening files when playback is active or paused.
enum OpenBehaviorPreference {
  keepPlayingAndEnqueue,
  playNewFilesNow,
  askEveryTime,
}

/// Persistent user settings for desktop integration and opening behavior.
@immutable
class DesktopPreferences {
  const DesktopPreferences({
    this.openBehavior,
    this.keepAwakeDuringPlayback = true,
  });

  /// Null means first-time user has not chosen yet and will be prompted on first conflict.
  final OpenBehaviorPreference? openBehavior;
  final bool keepAwakeDuringPlayback;

  DesktopPreferences copyWith({
    OpenBehaviorPreference? openBehavior,
    bool clearOpenBehavior = false,
    bool? keepAwakeDuringPlayback,
  }) {
    return DesktopPreferences(
      openBehavior: clearOpenBehavior
          ? null
          : (openBehavior ?? this.openBehavior),
      keepAwakeDuringPlayback:
          keepAwakeDuringPlayback ?? this.keepAwakeDuringPlayback,
    );
  }

  factory DesktopPreferences.fromJson(Map<String, Object?> json) {
    OpenBehaviorPreference? behavior;
    final rawBehavior = json['openBehavior'] as String?;
    if (rawBehavior != null) {
      for (final value in OpenBehaviorPreference.values) {
        if (value.name == rawBehavior) {
          behavior = value;
          break;
        }
      }
    }
    return DesktopPreferences(
      openBehavior: behavior,
      keepAwakeDuringPlayback: json['keepAwakeDuringPlayback'] as bool? ?? true,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (openBehavior != null) 'openBehavior': openBehavior!.name,
    'keepAwakeDuringPlayback': keepAwakeDuringPlayback,
  };
}

/// Repository that manages app-level desktop & opening preferences independently of playback session.
class AppPreferencesRepository extends ChangeNotifier {
  AppPreferencesRepository({File? preferenceFile})
    : _customFile = preferenceFile;

  final File? _customFile;
  DesktopPreferences _preferences = const DesktopPreferences();
  bool _loaded = false;
  bool _primaryInvalid = false;
  int _revision = 0;
  int _savedRevision = 0;
  Future<void>? _writeInFlight;
  Object? _saveError;
  Object? get saveError => _saveError;
  bool get isSaving => _writeInFlight != null;

  DesktopPreferences get preferences => _preferences;
  bool get isLoaded => _loaded;

  Future<File> _resolveFile() async {
    if (_customFile != null) return _customFile;
    final supportDir = await getApplicationSupportDirectory();
    return File(p.join(supportDir.path, 'app_preferences.json'));
  }

  Future<void> load() async {
    try {
      final file = await _resolveFile();
      final backup = File('${file.path}.bak');
      Future<DesktopPreferences> read(File source) async {
        final json =
            jsonDecode(await source.readAsString()) as Map<String, Object?>;
        return DesktopPreferences.fromJson(json);
      }

      if (await file.exists()) {
        try {
          _preferences = await read(file);
        } on Object {
          _primaryInvalid = true;
          if (await backup.exists()) _preferences = await read(backup);
        }
      } else if (await backup.exists()) {
        _primaryInvalid = true;
        _preferences = await read(backup);
      }
    } on Object {
      // Keep defaults if neither copy can be read. Do not overwrite the backup.
      _primaryInvalid = true;
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> updatePreferences(DesktopPreferences preferences) async {
    _preferences = preferences;
    _revision++;
    notifyListeners();
    await _drain();
  }

  Future<void> _drain() {
    final active = _writeInFlight;
    if (active != null) return active;
    late final Future<void> write;
    write =
        Future<void>.microtask(() async {
          while (_savedRevision != _revision) {
            final revision = _revision;
            final contents = jsonEncode(_preferences.toJson());
            try {
              final file = await _resolveFile();
              await file.parent.create(recursive: true);
              final temporary = File(
                '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$revision.tmp',
              );
              final backup = File('${file.path}.bak');
              await temporary.writeAsString(contents, flush: true);
              try {
                if (_primaryInvalid) {
                  // Keep the known-good backup while replacing a damaged primary.
                  if (await file.exists()) await file.delete();
                } else {
                  if (await backup.exists()) await backup.delete();
                  if (await file.exists()) await file.rename(backup.path);
                }
                try {
                  await temporary.rename(file.path);
                } on Object {
                  if (!await file.exists() && await backup.exists()) {
                    await backup.copy(file.path);
                  }
                  rethrow;
                }
              } finally {
                if (await temporary.exists()) await temporary.delete();
              }
              _primaryInvalid = false;
              _savedRevision = revision;
              _saveError = null;
            } on Object catch (error) {
              _saveError = error;
              break;
            }
          }
        }).whenComplete(() {
          _writeInFlight = null;
          notifyListeners();
        });
    _writeInFlight = write;
    return write;
  }

  /// Retry unsaved changes and report a failure to the caller.
  Future<void> flush() async {
    await _drain();
    if (_saveError != null) throw _saveError!;
  }

  Future<void> setOpenBehavior(OpenBehaviorPreference preference) async {
    await updatePreferences(_preferences.copyWith(openBehavior: preference));
  }

  Future<void> setKeepAwake(bool keepAwake) async {
    await updatePreferences(
      _preferences.copyWith(keepAwakeDuringPlayback: keepAwake),
    );
  }
}
