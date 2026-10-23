import '../../data/repositories/app_preferences_repository.dart';
import '../../domain/models/control_density.dart';
import '../../domain/models/playback_settings.dart';
import '../../domain/models/player_shortcuts.dart';
import 'player_controller.dart';

/// Shared values and defaults used by the changed-preferences view.
class SettingsPreference {
  const SettingsPreference({
    required this.id,
    required this.title,
    required this.category,
    required this.scope,
    required this.value,
    required this.defaultValue,
  });
  final String id, title, category, scope;
  final Object? value, defaultValue;
  bool get isModified => value != defaultValue;
  String get currentLabel => _format(id, value);
  String get defaultLabel => _format(id, defaultValue);

  static String _format(String id, Object? value) {
    if (value == null) return 'Ask on first opening conflict';
    if (value is bool) return value ? 'On' : 'Off';
    if (id.contains('Languages') && value == '') return 'Automatic';
    if (id.endsWith('DelaySeconds') && value is num) {
      return '${value.toStringAsFixed(1)} s';
    }
    if (id == 'rate' && value is num) return '$value×';
    if (id == 'playback.subtitleBackgroundOpacity' && value is num) {
      return '${(value * 100).round()}%';
    }
    if (id == 'playback.subtitlePosition' && value is num) {
      return '${value.round()}% from top';
    }
    return switch (value) {
      'compact' => 'Compact',
      'normal' => 'Normal',
      'balanced' => 'Balanced',
      'performance' => 'Performance',
      'quality' => 'Quality',
      'automatic' => 'Resume automatically',
      'ask' => 'Ask before resuming',
      'startOver' => 'Start from beginning',
      'sans-serif' => 'Sans serif',
      'keepPlayingAndEnqueue' => 'Keep playing and add to queue',
      'playNewFilesNow' => 'Play new files now',
      'askEveryTime' => 'Ask every time',
      'off' => 'Off',
      'all' => 'Repeat queue',
      'one' => 'Repeat current item',
      _ =>
        value is num && value == value.roundToDouble()
            ? value.toInt().toString()
            : value.toString(),
    };
  }
}

const _playbackTitles = <String, (String, String, String)>{
  'qualityPreset': ('Quality preset', 'Video', 'Current and future videos'),
  'preferHardwareDecoding': (
    'Hardware decoding',
    'Video',
    'Current and future videos',
  ),
  'brightness': ('Brightness', 'Video', 'Current and future videos'),
  'contrast': ('Contrast', 'Video', 'Current and future videos'),
  'saturation': ('Saturation', 'Video', 'Current and future videos'),
  'gamma': ('Gamma', 'Video', 'Current and future videos'),
  'audioDelaySeconds': (
    'Audio delay',
    'Audio & subtitles',
    'Current and future playback',
  ),
  'subtitleDelaySeconds': (
    'Subtitle delay',
    'Audio & subtitles',
    'Current and future playback',
  ),
  'subtitleFont': (
    'Subtitle font',
    'Audio & subtitles',
    'Player subtitle style',
  ),
  'subtitleFontSize': (
    'Subtitle text size',
    'Audio & subtitles',
    'Player subtitle style',
  ),
  'subtitleColor': (
    'Subtitle color',
    'Audio & subtitles',
    'Player subtitle style',
  ),
  'subtitleOutlineSize': (
    'Subtitle outline',
    'Audio & subtitles',
    'Player subtitle style',
  ),
  'subtitleBackgroundOpacity': (
    'Subtitle background',
    'Audio & subtitles',
    'Player subtitle style',
  ),
  'subtitlePosition': (
    'Subtitle position',
    'Audio & subtitles',
    'Player subtitle style',
  ),
  'preferredAudioLanguages': (
    'Preferred audio languages',
    'Audio & subtitles',
    'Future media',
  ),
  'preferredSubtitleLanguages': (
    'Preferred subtitle languages',
    'Audio & subtitles',
    'Future media',
  ),
  'resumeBehavior': (
    'Resume playback',
    'Playback',
    'Future media with a saved position',
  ),
};

List<SettingsPreference> settingsPreferences(
  PlayerController controller,
  DesktopPreferences desktop,
) {
  final playback = controller.playbackSettings.toJson();
  final defaults = PlaybackSettings.defaults.toJson();
  final shortcuts = resolvePlayerShortcuts(desktop.shortcutOverrides);
  return [
    SettingsPreference(
      id: 'controlDensity',
      title: 'Control size',
      category: 'Appearance',
      scope: 'Player controls',
      value: controller.controlDensity.name,
      defaultValue: 'compact',
    ),
    SettingsPreference(
      id: 'desktop.openBehavior',
      title: 'Opening files',
      category: 'General',
      scope: 'Future file opening',
      value: desktop.openBehavior?.name,
      defaultValue: null,
    ),
    SettingsPreference(
      id: 'desktop.keepAwakeDuringPlayback',
      title: 'Keep computer awake',
      category: 'General',
      scope: 'While playback is active',
      value: desktop.keepAwakeDuringPlayback,
      defaultValue: true,
    ),
    SettingsPreference(
      id: 'rate',
      title: 'Playback speed',
      category: 'Playback',
      scope: 'Current and future playback',
      value: controller.rate,
      defaultValue: 1.0,
    ),
    SettingsPreference(
      id: 'shuffle',
      title: 'Shuffle',
      category: 'Playback',
      scope: 'Current queue; remembered between sessions',
      value: controller.shuffle,
      defaultValue: false,
    ),
    SettingsPreference(
      id: 'repeatMode',
      title: 'Repeat',
      category: 'Playback',
      scope: 'Current queue; remembered between sessions',
      value: controller.repeatMode,
      defaultValue: 'off',
    ),
    for (final entry in _playbackTitles.entries)
      SettingsPreference(
        id: 'playback.${entry.key}',
        title: entry.value.$1,
        category: entry.value.$2,
        scope: entry.value.$3,
        value: playback[entry.key],
        defaultValue: defaults[entry.key],
      ),
    SettingsPreference(
      id: 'historyEnabled',
      title: 'Save playback history',
      category: 'History & privacy',
      scope: 'New playback activity',
      value: controller.historyEnabled,
      defaultValue: true,
    ),
    SettingsPreference(
      id: 'saveNetworkUrls',
      title: 'Save network URLs',
      category: 'History & privacy',
      scope: 'Session files on this computer',
      value: controller.saveNetworkUrls,
      defaultValue: false,
    ),
    for (final entry in defaultShortcutBindings.entries)
      SettingsPreference(
        id: 'shortcut.${entry.key.name}',
        title: shortcutActionLabel(entry.key),
        category: 'Shortcuts',
        scope: 'Keyboard controls',
        value: shortcuts[entry.key],
        defaultValue: entry.value,
      ),
  ];
}

/// Resets only the chosen preferences, preserving navigation and other values.
Future<void> resetSettingsPreferences(
  Set<String> ids,
  PlayerController controller,
  AppPreferencesRepository repository,
) async {
  // A single default can collide with another custom binding. Validate the
  // complete proposed map before resetting any selected preference.
  final shortcuts = Map<String, String>.of(
    repository.preferences.shortcutOverrides,
  );
  for (final id in ids.where((id) => id.startsWith('shortcut.'))) {
    shortcuts.remove(id.substring('shortcut.'.length));
  }
  final shortcutError = validateShortcutOverrides(shortcuts);
  if (shortcutError != null && ids.any((id) => id.startsWith('shortcut.'))) {
    throw FormatException(
      '$shortcutError Select the conflicting shortcuts together or restore all shortcut defaults.',
    );
  }
  final defaults = PlaybackSettings.defaults.toJson();
  final playback = controller.playbackSettings.toJson();
  var playbackChanged = false;
  for (final id in ids.where((id) => id.startsWith('playback.'))) {
    final key = id.substring('playback.'.length);
    if (defaults.containsKey(key)) {
      playback[key] = defaults[key];
      playbackChanged = true;
    }
  }
  if (playbackChanged) {
    await controller.setPlaybackSettings(PlaybackSettings.fromJson(playback));
  }
  if (ids.contains('controlDensity')) {
    controller.setControlDensity(ControlDensity.compact);
  }
  if (ids.contains('rate')) await controller.setRate(1);
  if (ids.contains('repeatMode')) await controller.setRepeatMode('off');
  if (ids.contains('shuffle') && controller.shuffle) {
    await controller.toggleShuffle();
  }
  if (ids.contains('historyEnabled')) await controller.setHistoryEnabled(true);
  if (ids.contains('saveNetworkUrls') &&
      !await controller.setSaveNetworkUrls(false)) {
    throw StateError('Could not remove stored network URLs. Retry the change.');
  }
  if (ids.any(
    (id) => id.startsWith('desktop.') || id.startsWith('shortcut.'),
  )) {
    final current = repository.preferences;
    await repository.updatePreferences(
      current.copyWith(
        clearOpenBehavior: ids.contains('desktop.openBehavior'),
        keepAwakeDuringPlayback: ids.contains('desktop.keepAwakeDuringPlayback')
            ? true
            : null,
        shortcutOverrides: shortcuts,
      ),
    );
    if (repository.saveError != null) throw StateError(repository.saveError!);
  }
}
