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
    this.shortcutOverrides = const {},
    this.lastSettingsSection,
  });

  /// Null means first-time user has not chosen yet and will be prompted on first conflict.
  final OpenBehaviorPreference? openBehavior;
  final bool keepAwakeDuringPlayback;
  final Map<String, String> shortcutOverrides;
  final String? lastSettingsSection;

  DesktopPreferences copyWith({
    OpenBehaviorPreference? openBehavior,
    bool clearOpenBehavior = false,
    bool? keepAwakeDuringPlayback,
    Map<String, String>? shortcutOverrides,
    String? lastSettingsSection,
    bool clearLastSettingsSection = false,
  }) {
    return DesktopPreferences(
      openBehavior: clearOpenBehavior
          ? null
          : (openBehavior ?? this.openBehavior),
      keepAwakeDuringPlayback:
          keepAwakeDuringPlayback ?? this.keepAwakeDuringPlayback,
      shortcutOverrides: shortcutOverrides == null
          ? this.shortcutOverrides
          : Map<String, String>.unmodifiable(shortcutOverrides),
      lastSettingsSection: clearLastSettingsSection
          ? null
          : lastSettingsSection ?? this.lastSettingsSection,
    );
  }

  factory DesktopPreferences.fromJson(Map<String, Object?> json) {
    OpenBehaviorPreference? behavior;
    final rawBehavior = json['openBehavior'];
    if (rawBehavior is String) {
      for (final value in OpenBehaviorPreference.values) {
        if (value.name == rawBehavior) {
          behavior = value;
          break;
        }
      }
    }
    return DesktopPreferences(
      openBehavior: behavior,
      keepAwakeDuringPlayback: json['keepAwakeDuringPlayback'] is bool
          ? json['keepAwakeDuringPlayback'] as bool
          : true,
      shortcutOverrides: Map<String, String>.unmodifiable({
        if (json['shortcutOverrides']
            case final Map<Object?, Object?> overrides)
          for (final entry in overrides.entries)
            if (entry.key is String &&
                entry.value is String &&
                (entry.key as String).length <= 64 &&
                (entry.value as String).length <= 80)
              entry.key as String: entry.value as String,
      }),
      lastSettingsSection: json['lastSettingsSection'] is String
          ? json['lastSettingsSection'] as String
          : null,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (openBehavior != null) 'openBehavior': openBehavior!.name,
    'keepAwakeDuringPlayback': keepAwakeDuringPlayback,
    if (shortcutOverrides.isNotEmpty) 'shortcutOverrides': shortcutOverrides,
    if (lastSettingsSection != null) 'lastSettingsSection': lastSettingsSection,
  };
}

/// Repository that manages app-level desktop & opening preferences independently of playback session.
class AppPreferencesRepository extends ChangeNotifier {
  AppPreferencesRepository({File? preferenceFile})
    : _customFile = preferenceFile;

  final File? _customFile;
  DesktopPreferences _preferences = const DesktopPreferences();
  bool _loaded = false;
  bool _disposed = false;
  int _revision = 0;
  int _pendingWrites = 0;
  String? _saveError;
  Future<void>? _loadFuture;
  Future<void> _writeTail = Future<void>.value();

  DesktopPreferences get preferences => _preferences;
  bool get isLoaded => _loaded;
  bool get isSaving => _pendingWrites > 0;
  String? get saveError => _saveError;

  Future<File> _resolveFile() async {
    if (_customFile != null) return _customFile;
    final supportDir = await getApplicationSupportDirectory();
    return File(p.join(supportDir.path, 'app_preferences.json'));
  }

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    final revision = _revision;
    try {
      final file = await _resolveFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, Object?>;
        if (revision == _revision) {
          _preferences = DesktopPreferences.fromJson(json);
        }
      }
    } on Object {
      // Fallback to default preferences on read failure.
      if (revision == _revision) {
        _preferences = const DesktopPreferences();
      }
    } finally {
      _loaded = true;
      _notifyIfOpen();
    }
  }

  Future<void> updatePreferences(DesktopPreferences preferences) {
    if (_disposed) return Future<void>.value();
    _preferences = preferences;
    _revision++;
    return _queueSave(preferences);
  }

  /// Retries the latest choice without reverting its immediate application.
  Future<void> retrySave() =>
      _disposed ? Future<void>.value() : _queueSave(_preferences);

  Future<void> _queueSave(DesktopPreferences preferences) {
    _pendingWrites++;
    _saveError = null;
    // One writer owns the temporary file at a time. Each request captures its
    // value, so an older write can never replace the most recent choice.
    final write = _writeTail.then((_) async {
      try {
        final file = await _resolveFile();
        await file.parent.create(recursive: true);
        final tempFile = File('${file.path}.tmp');
        await tempFile.writeAsString(
          jsonEncode(preferences.toJson()),
          flush: true,
        );
        await tempFile.rename(file.path);
        _saveError = null;
      } on Object {
        _saveError =
            'Could not save preferences. Your changes apply for this '
            'session. Retry to remember them after restarting.';
      } finally {
        _pendingWrites--;
        _notifyIfOpen();
      }
    });
    _writeTail = write;
    _notifyIfOpen();
    return write;
  }

  void _notifyIfOpen() {
    if (!_disposed) notifyListeners();
  }

  Future<void> setOpenBehavior(OpenBehaviorPreference preference) async {
    await updatePreferences(_preferences.copyWith(openBehavior: preference));
  }

  Future<void> setKeepAwake(bool keepAwake) async {
    await updatePreferences(
      _preferences.copyWith(keepAwakeDuringPlayback: keepAwake),
    );
  }

  Future<void> setShortcutOverrides(Map<String, String> overrides) =>
      updatePreferences(_preferences.copyWith(shortcutOverrides: overrides));

  Future<void> setLastSettingsSection(String section) {
    if (_preferences.lastSettingsSection == section && _saveError == null) {
      return Future<void>.value();
    }
    return updatePreferences(
      _preferences.copyWith(lastSettingsSection: section),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
