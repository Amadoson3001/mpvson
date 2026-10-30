import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/player_hotkeys.dart';

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
    this.reduceMotion = false,
    this.seekStepSeconds = 5,
    this.syncStepMs = 50,
    this.hotkeyOverrides,
    this.themeMode = ThemeMode.dark,
    this.accentPreset = 'lamp',
    this.dynamicArtworkColor = true,
    this.oledBlack = false,
  });

  static const List<int> seekStepOptions = <int>[1, 2, 5, 10, 15, 30];
  static const List<int> syncStepOptions = <int>[25, 50, 100, 250];

  /// Null means first-time user has not chosen yet and will be prompted on first conflict.
  final OpenBehaviorPreference? openBehavior;
  final bool keepAwakeDuringPlayback;
  final bool reduceMotion;

  /// How far the seek shortcut jumps in one press.
  final int seekStepSeconds;

  /// Adjustment applied to audio/subtitle delay per shortcut press.
  final int syncStepMs;

  /// Saved key combinations; null means every action uses its default.
  final PlayerHotkeys? hotkeyOverrides;
  PlayerHotkeys get hotkeys => hotkeyOverrides ?? PlayerHotkeys.defaults;

  /// Active theme mode (dark, light, or system).
  final ThemeMode themeMode;

  /// Accent color preset identifier (e.g. 'lamp', 'jade', 'sky', 'rose', 'amethyst', 'gold').
  final String accentPreset;

  /// Whether to dynamically tint the player based on media artwork during playback.
  final bool dynamicArtworkColor;

  /// Whether to use pitch black surfaces in dark mode for OLED displays.
  final bool oledBlack;

  DesktopPreferences copyWith({
    OpenBehaviorPreference? openBehavior,
    bool clearOpenBehavior = false,
    bool? keepAwakeDuringPlayback,
    bool? reduceMotion,
    int? seekStepSeconds,
    int? syncStepMs,
    PlayerHotkeys? hotkeyOverrides,
    ThemeMode? themeMode,
    String? accentPreset,
    bool? dynamicArtworkColor,
    bool? oledBlack,
  }) {
    return DesktopPreferences(
      openBehavior: clearOpenBehavior
          ? null
          : (openBehavior ?? this.openBehavior),
      keepAwakeDuringPlayback:
          keepAwakeDuringPlayback ?? this.keepAwakeDuringPlayback,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      seekStepSeconds: seekStepSeconds ?? this.seekStepSeconds,
      syncStepMs: syncStepMs ?? this.syncStepMs,
      hotkeyOverrides: hotkeyOverrides ?? this.hotkeyOverrides,
      themeMode: themeMode ?? this.themeMode,
      accentPreset: accentPreset ?? this.accentPreset,
      dynamicArtworkColor: dynamicArtworkColor ?? this.dynamicArtworkColor,
      oledBlack: oledBlack ?? this.oledBlack,
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
    ThemeMode themeMode = ThemeMode.dark;
    final rawThemeMode = json['themeMode'] as String?;
    if (rawThemeMode != null) {
      for (final value in ThemeMode.values) {
        if (value.name == rawThemeMode) {
          themeMode = value;
          break;
        }
      }
    }
    return DesktopPreferences(
      openBehavior: behavior,
      keepAwakeDuringPlayback: json['keepAwakeDuringPlayback'] as bool? ?? true,
      reduceMotion: json['reduceMotion'] as bool? ?? false,
      seekStepSeconds: _readChoice(json['seekStepSeconds'], seekStepOptions, 5),
      syncStepMs: _readChoice(json['syncStepMs'], syncStepOptions, 50),
      hotkeyOverrides: json.containsKey('hotkeys')
          ? PlayerHotkeys.fromJson(json['hotkeys'])
          : null,
      themeMode: themeMode,
      accentPreset: json['accentPreset'] as String? ?? 'lamp',
      dynamicArtworkColor: json['dynamicArtworkColor'] as bool? ?? true,
      oledBlack: json['oledBlack'] as bool? ?? false,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (openBehavior != null) 'openBehavior': openBehavior!.name,
    'keepAwakeDuringPlayback': keepAwakeDuringPlayback,
    'reduceMotion': reduceMotion,
    'seekStepSeconds': seekStepSeconds,
    'syncStepMs': syncStepMs,
    'hotkeys': hotkeys.toJson(),
    'themeMode': themeMode.name,
    'accentPreset': accentPreset,
    'dynamicArtworkColor': dynamicArtworkColor,
    'oledBlack': oledBlack,
  };

  static int _readChoice(Object? value, List<int> options, int fallback) {
    final number = value is num ? value.toInt() : null;
    return number != null && options.contains(number) ? number : fallback;
  }
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

  Future<void> setSeekStep(int seconds) async {
    if (!DesktopPreferences.seekStepOptions.contains(seconds)) return;
    await updatePreferences(_preferences.copyWith(seekStepSeconds: seconds));
  }

  Future<void> setSyncStep(int milliseconds) async {
    if (!DesktopPreferences.syncStepOptions.contains(milliseconds)) return;
    await updatePreferences(_preferences.copyWith(syncStepMs: milliseconds));
  }

  Future<void> setHotkey(PlayerAction action, HotkeyBinding binding) async {
    await updatePreferences(
      _preferences.copyWith(
        hotkeyOverrides: _preferences.hotkeys.withBinding(action, binding),
      ),
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await updatePreferences(_preferences.copyWith(themeMode: mode));
  }

  Future<void> setAccentPreset(String preset) async {
    await updatePreferences(_preferences.copyWith(accentPreset: preset));
  }

  Future<void> setDynamicArtworkColor(bool enabled) async {
    await updatePreferences(
      _preferences.copyWith(dynamicArtworkColor: enabled),
    );
  }

  Future<void> setOledBlack(bool enabled) async {
    await updatePreferences(_preferences.copyWith(oledBlack: enabled));
  }

  Future<void> resetHotkeys() async {
    await updatePreferences(
      _preferences.copyWith(hotkeyOverrides: PlayerHotkeys.defaults),
    );
  }
}
