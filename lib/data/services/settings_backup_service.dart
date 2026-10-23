import 'dart:convert';

import '../../domain/models/control_density.dart';
import '../../domain/models/playback_settings.dart';
import '../../domain/models/player_shortcuts.dart';
import '../repositories/app_preferences_repository.dart';

/// A portable preferences document, deliberately separate from saved sessions.
/// It contains no media, paths, history, URLs, or recording-consent choices.
class SettingsBackup {
  const SettingsBackup({
    required this.desktop,
    required this.playbackSettings,
    required this.controlDensity,
    required this.rate,
    required this.shuffle,
    required this.repeatMode,
  });

  static const maximumBytes = 128 * 1024;
  final DesktopPreferences desktop;
  final PlaybackSettings playbackSettings;
  final ControlDensity controlDensity;
  final double rate;
  final bool shuffle;
  final String repeatMode;

  Map<String, Object?> toJson() => {
    'format': 'mpvson-settings',
    'version': 1,
    'desktop': {
      'openBehavior': desktop.openBehavior?.name,
      'keepAwakeDuringPlayback': desktop.keepAwakeDuringPlayback,
      'shortcutOverrides': desktop.shortcutOverrides,
    },
    'player': {
      'controlDensity': controlDensity.name,
      'rate': rate,
      'shuffle': shuffle,
      'repeatMode': repeatMode,
      'playbackSettings': playbackSettings.toJson(),
    },
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory SettingsBackup.decode(String text) {
    if (utf8.encode(text).length > maximumBytes) {
      throw const FormatException('This settings file is too large.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('Choose a valid Mpvson settings JSON file.');
    }
    final root = _object(decoded, 'settings');
    if (root['format'] != 'mpvson-settings' || root['version'] != 1) {
      throw const FormatException(
        'This settings backup format is not supported.',
      );
    }
    _onlyKeys(root, const {'format', 'version', 'desktop', 'player'});
    final desktop = _object(root['desktop'], 'desktop preferences');
    _onlyKeys(desktop, const {
      'openBehavior',
      'keepAwakeDuringPlayback',
      'shortcutOverrides',
    });
    final behavior = desktop['openBehavior'];
    if (behavior != null &&
        !OpenBehaviorPreference.values.any((v) => v.name == behavior)) {
      throw const FormatException('The opening behavior is invalid.');
    }
    final awake = desktop['keepAwakeDuringPlayback'];
    if (awake is! bool) {
      throw const FormatException('The sleep preference is invalid.');
    }
    final rawOverrides = _object(
      desktop['shortcutOverrides'] ?? <String, Object?>{},
      'shortcuts',
    );
    final overrides = <String, String>{};
    for (final entry in rawOverrides.entries) {
      if (entry.value is! String) {
        throw const FormatException('A shortcut is invalid.');
      }
      overrides[entry.key] = entry.value as String;
    }
    final shortcutError = validateShortcutOverrides(overrides);
    if (shortcutError != null) throw FormatException(shortcutError);

    final player = _object(root['player'], 'player preferences');
    _onlyKeys(player, const {
      'controlDensity',
      'rate',
      'shuffle',
      'repeatMode',
      'playbackSettings',
    });
    final density = player['controlDensity'];
    if (density != 'compact' && density != 'normal') {
      throw const FormatException('The control size is invalid.');
    }
    final rate = player['rate'];
    if (rate is! num || !rate.isFinite || rate < .25 || rate > 4) {
      throw const FormatException('Playback speed must be between 0.25 and 4.');
    }
    if (player['shuffle'] is! bool ||
        !const ['off', 'all', 'one'].contains(player['repeatMode'])) {
      throw const FormatException('The queue preferences are invalid.');
    }
    final rawPlayback = _object(
      player['playbackSettings'],
      'playback preferences',
    );
    final defaults = PlaybackSettings.defaults.toJson();
    _onlyKeys(rawPlayback, defaults.keys.toSet());
    for (final entry in rawPlayback.entries) {
      final baseline = defaults[entry.key];
      final value = entry.value;
      final valid = baseline is bool
          ? value is bool
          : baseline is num
          ? value is num && value.isFinite
          : value is String && value.length <= 512;
      if (!valid) throw FormatException('Invalid value for ${entry.key}.');
    }
    if (rawPlayback['qualityPreset'] case final String preset) {
      if (!PlaybackQualityPreset.values.any((v) => v.name == preset)) {
        throw const FormatException('The video quality preset is invalid.');
      }
    }
    if (rawPlayback['resumeBehavior'] case final String behavior) {
      if (!ResumeBehavior.values.any((v) => v.name == behavior)) {
        throw const FormatException('The resume preference is invalid.');
      }
    }
    if (rawPlayback['subtitleColor'] case final String color) {
      if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
        throw const FormatException('The subtitle color is invalid.');
      }
    }
    if (rawPlayback['subtitleFont'] case final String font) {
      if (font.trim().isEmpty || font.length > 80) {
        throw const FormatException('The subtitle font is invalid.');
      }
    }
    for (final key in const [
      'preferredAudioLanguages',
      'preferredSubtitleLanguages',
    ]) {
      if (rawPlayback[key] case final String languages) {
        for (final tag in languages.split(',').map((tag) => tag.trim())) {
          if (tag.isNotEmpty &&
              PlaybackSettings(
                preferredAudioLanguages: tag,
              ).normalized().preferredAudioLanguages.isEmpty) {
            throw const FormatException(
              'A preferred language code is invalid.',
            );
          }
        }
      }
    }
    final settings = PlaybackSettings.fromJson(rawPlayback);
    final normalized = settings.toJson();
    for (final entry in rawPlayback.entries) {
      if (entry.value is num && entry.value != normalized[entry.key]) {
        throw FormatException('${entry.key} is outside its supported range.');
      }
    }
    return SettingsBackup(
      desktop: DesktopPreferences.fromJson(desktop),
      playbackSettings: settings,
      controlDensity: ControlDensity.fromPersisted(density),
      rate: rate.toDouble(),
      shuffle: player['shuffle'] as bool,
      repeatMode: player['repeatMode'] as String,
    );
  }

  static Map<String, Object?> _object(Object? value, String label) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw FormatException('The $label section is invalid.');
    }
    return Map<String, Object?>.from(value);
  }

  static void _onlyKeys(Map<String, Object?> values, Set<String> allowed) {
    if (values.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('This file contains unsupported settings.');
    }
  }
}
