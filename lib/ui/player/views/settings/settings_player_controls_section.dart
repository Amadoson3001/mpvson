import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../domain/models/control_density.dart';
import '../../../../domain/models/player_controls_preferences.dart';
import '../../player_controller.dart';
import 'settings_player_controls_widgets.dart';
import 'settings_shared_widgets.dart';

class PlayerControlsSettingsSection extends StatelessWidget {
  const PlayerControlsSettingsSection({
    super.key,
    required this.appPreferences,
    required this.controller,
    required this.compactViewport,
  });

  final AppPreferencesRepository appPreferences;
  final PlayerController controller;
  final bool compactViewport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return ListenableBuilder(
      listenable: appPreferences,
      builder: (context, _) {
        final prefs = appPreferences.preferences.playerControls;

        return SettingsContentContainer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsCardGroup(
                title: 'Live preview',
                description:
                    'Real-time visualization of how the player controls look over video content.',
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: LiveControlPreview(
                      prefs: prefs,
                      controller: controller,
                      compact:
                          controller.controlDensity == ControlDensity.compact,
                    ),
                  ),
                ],
              ),
              SettingsCardGroup(
                title: 'Control bar style',
                description:
                    'Choose the visual presentation and framing of the playback strip.',
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final cards = [
                          StylePresetCard(
                            title: 'Floating Pill',
                            description: 'Modern rounded glass island',
                            icon: Icons.picture_in_picture_alt_rounded,
                            selected:
                                prefs.barStyle ==
                                PlayerControlBarStyle.floatingPill,
                            onTap: () => _update(
                              prefs.copyWith(
                                barStyle: PlayerControlBarStyle.floatingPill,
                              ),
                            ),
                          ),
                          StylePresetCard(
                            title: 'Cinematic',
                            description: 'Smooth dark cinema gradient',
                            icon: Icons.gradient_rounded,
                            selected:
                                prefs.barStyle ==
                                PlayerControlBarStyle.cinematicGradient,
                            onTap: () => _update(
                              prefs.copyWith(
                                barStyle:
                                    PlayerControlBarStyle.cinematicGradient,
                              ),
                            ),
                          ),
                          StylePresetCard(
                            title: 'Frosted Dock',
                            description: 'Full-width bottom glass dock',
                            icon: Icons.dock_rounded,
                            selected:
                                prefs.barStyle ==
                                PlayerControlBarStyle.frostedDocked,
                            onTap: () => _update(
                              prefs.copyWith(
                                barStyle: PlayerControlBarStyle.frostedDocked,
                              ),
                            ),
                          ),
                          StylePresetCard(
                            title: 'Minimalist',
                            description: 'Subtle discreet scrim bar',
                            icon: Icons.view_headline_rounded,
                            selected:
                                prefs.barStyle == PlayerControlBarStyle.minimal,
                            onTap: () => _update(
                              prefs.copyWith(
                                barStyle: PlayerControlBarStyle.minimal,
                              ),
                            ),
                          ),
                        ];

                        if (constraints.maxWidth < 540) {
                          return Column(
                            children: [
                              for (var i = 0; i < cards.length; i++) ...[
                                if (i > 0) const SizedBox(height: 8),
                                cards[i],
                              ],
                            ],
                          );
                        }

                        return Column(
                          children: [
                            Row(
                              children: [
                                Expanded(child: cards[0]),
                                const SizedBox(width: 10),
                                Expanded(child: cards[1]),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(child: cards[2]),
                                const SizedBox(width: 10),
                                Expanded(child: cards[3]),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
              SettingsCardGroup(
                title: 'Backdrop & Glass effects',
                description:
                    'Fine-tune the opacity and blur effects applied behind the playback controls.',
                children: [
                  ModernSliderTile(
                    label: 'Backdrop opacity',
                    value: prefs.backgroundOpacity,
                    min: 0.20,
                    max: 1.0,
                    divisions: 16,
                    formatValue: (v) => '${(v * 100).round()}%',
                    onChanged: (v) =>
                        _update(prefs.copyWith(backgroundOpacity: v)),
                    onChangeEnd: (v) =>
                        _update(prefs.copyWith(backgroundOpacity: v)),
                  ),
                  SettingsSwitchTile(
                    icon: Icons.blur_on_rounded,
                    title: 'Frosted glass blur',
                    subtitle:
                        'Applies real-time backdrop blur behind the controls for modern glassmorphism.',
                    value: prefs.enableBlur,
                    onChanged: (val) =>
                        _update(prefs.copyWith(enableBlur: val)),
                  ),
                ],
              ),
              SettingsCardGroup(
                title: 'Timeline & Seekbar',
                description:
                    'Adjust the seekbar thickness and time display presentation.',
                trailing: SegmentedButton<SeekBarThickness>(
                  key: const ValueKey('seekbar-thickness-selector'),
                  segments: const [
                    ButtonSegment(
                      value: SeekBarThickness.slim,
                      label: Text('Slim'),
                    ),
                    ButtonSegment(
                      value: SeekBarThickness.standard,
                      label: Text('Standard'),
                    ),
                    ButtonSegment(
                      value: SeekBarThickness.bold,
                      label: Text('Bold'),
                    ),
                  ],
                  selected: {prefs.seekBarThickness},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected)
                          ? accent
                          : theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.3),
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected)
                          ? (theme.brightness == Brightness.dark
                                ? Colors.black
                                : Colors.white)
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  onSelectionChanged: (s) =>
                      _update(prefs.copyWith(seekBarThickness: s.first)),
                ),
                children: [
                  SettingsSwitchTile(
                    icon: Icons.timer_outlined,
                    title: 'Show remaining time',
                    subtitle:
                        'Display countdown duration (-MM:SS) instead of total video length.',
                    value: prefs.showRemainingTime,
                    onChanged: (val) =>
                        _update(prefs.copyWith(showRemainingTime: val)),
                  ),
                ],
              ),
              SettingsCardGroup(
                title: 'Controls & Buttons layout',
                description:
                    'Toggle individual buttons and controls shown in the bottom bar.',
                children: [
                  SettingsSwitchTile(
                    icon: Icons.stop_circle_outlined,
                    title: 'Stop button',
                    subtitle:
                        'Show dedicated stop playback button next to skip controls.',
                    value: prefs.showStopButton,
                    onChanged: (val) =>
                        _update(prefs.copyWith(showStopButton: val)),
                  ),
                  SettingsSwitchTile(
                    icon: Icons.shuffle_rounded,
                    title: 'Shuffle & repeat buttons',
                    subtitle:
                        'Show playlist shuffle and track repeat toggle buttons.',
                    value: prefs.showShuffleRepeat,
                    onChanged: (val) =>
                        _update(prefs.copyWith(showShuffleRepeat: val)),
                  ),
                  SettingsSwitchTile(
                    icon: Icons.speed_rounded,
                    title: 'Playback speed menu',
                    subtitle:
                        'Show speed multiplier button (1×) for fast or slow motion playback.',
                    value: prefs.showSpeedButton,
                    onChanged: (val) =>
                        _update(prefs.copyWith(showSpeedButton: val)),
                  ),
                  SettingsSwitchTile(
                    icon: Icons.volume_up_rounded,
                    title: 'Inline volume slider',
                    subtitle:
                        'Show full horizontal volume slider instead of a compact icon popup.',
                    value: prefs.showVolumeSlider,
                    onChanged: (val) =>
                        _update(prefs.copyWith(showVolumeSlider: val)),
                  ),
                  SettingsSwitchTile(
                    icon: Icons.playlist_play_rounded,
                    title: 'Queue panel button',
                    subtitle:
                        'Show queue toggle button with active track badge counter.',
                    value: prefs.showQueueButton,
                    onChanged: (val) =>
                        _update(prefs.copyWith(showQueueButton: val)),
                  ),
                ],
              ),
              SettingsCardGroup(
                title: 'Auto-hide behavior',
                description:
                    'How quickly the controls fade away after mouse movement stops.',
                trailing: SegmentedButton<double>(
                  key: const ValueKey('autohide-delay-selector'),
                  segments: const [
                    ButtonSegment(value: 1.5, label: Text('Fast (1.5s)')),
                    ButtonSegment(value: 2.8, label: Text('Normal (2.8s)')),
                    ButtonSegment(value: 4.5, label: Text('Slow (4.5s)')),
                    ButtonSegment(value: 0.0, label: Text('Never')),
                  ],
                  selected: {prefs.autoHideDelaySeconds},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected)
                          ? accent
                          : theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.3),
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected)
                          ? (theme.brightness == Brightness.dark
                                ? Colors.black
                                : Colors.white)
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  onSelectionChanged: (s) =>
                      _update(prefs.copyWith(autoHideDelaySeconds: s.first)),
                ),
                children: const [],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => _update(const PlayerControlsPreferences()),
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: const Text('Reset player controls to defaults'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                      side: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.4,
                        ),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _update(PlayerControlsPreferences prefs) {
    unawaited(appPreferences.updatePlayerControls(prefs));
  }
}
