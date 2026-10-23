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
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, Object?>;
        _preferences = DesktopPreferences.fromJson(json);
      }
    } on Object {
      // Fallback to default preferences on read failure.
      _preferences = const DesktopPreferences();
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> updatePreferences(DesktopPreferences preferences) async {
    _preferences = preferences;
    notifyListeners();
    try {
      final file = await _resolveFile();
      await file.parent.create(recursive: true);
      final jsonString = jsonEncode(_preferences.toJson());
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(jsonString, flush: true);
      await tempFile.rename(file.path);
    } on Object {
      // Best-effort atomic write.
    }
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
