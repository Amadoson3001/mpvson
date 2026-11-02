import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_motion.dart';
import '../../../core/app_theme.dart';
import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../domain/models/control_density.dart';
import '../../player_controller.dart';
import 'settings_control_preview.dart';
import 'settings_shared_widgets.dart';
import 'settings_theme_widgets.dart';

export 'settings_control_preview.dart';
export 'settings_theme_widgets.dart';

class AppearanceSettingsSection extends StatelessWidget {
  const AppearanceSettingsSection({
    super.key,
    required this.controller,
    required this.compactViewport,
    this.appPreferences,
  });

  final PlayerController controller;
  final bool compactViewport;
  final AppPreferencesRepository? appPreferences;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return SettingsContentContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (appPreferences != null)
            ListenableBuilder(
              listenable: appPreferences!,
              builder: (context, _) {
                final prefs = appPreferences!.preferences;
                final currentMode = prefs.themeMode;
                final activeId = prefs.accentPreset;
                final isArtworkSyncActive = prefs.dynamicArtworkColor;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SettingsCardGroup(
                      title: 'Theme mode',
                      description: 'Select your preferred visual appearance.',
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(
                                child: ThemeModeCard(
                                  title: 'Dark',
                                  icon: Icons.dark_mode_rounded,
                                  selected: currentMode == ThemeMode.dark,
                                  previewDark: true,
                                  onTap: () => unawaited(
                                    appPreferences!.setThemeMode(
                                      ThemeMode.dark,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ThemeModeCard(
                                  title: 'Light',
                                  icon: Icons.light_mode_rounded,
                                  selected: currentMode == ThemeMode.light,
                                  previewDark: false,
                                  onTap: () => unawaited(
                                    appPreferences!.setThemeMode(
                                      ThemeMode.light,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ThemeModeCard(
                                  title: 'System',
                                  icon: Icons.brightness_auto_rounded,
                                  selected: currentMode == ThemeMode.system,
                                  isSystem: true,
                                  onTap: () => unawaited(
                                    appPreferences!.setThemeMode(
                                      ThemeMode.system,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SettingsCardGroup(
                      title: 'Accent color',
                      description:
                          'Curated palettes for highlights, timeline bars, and buttons.',
                      trailing: isArtworkSyncActive
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.3),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.auto_awesome_rounded,
                                    size: 13,
                                    color: accent,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    'Overridden by active artwork',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: accent,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : null,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: AnimatedOpacity(
                            duration: AppMotion.duration(
                              context,
                              AppMotion.quick,
                            ),
                            opacity: isArtworkSyncActive ? 0.5 : 1.0,
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final preset in AppAccentPreset.all)
                                  AccentColorChip(
                                    preset: preset,
                                    selected: preset.id == activeId,
                                    isOverridden: isArtworkSyncActive,
                                    onTap: () => unawaited(
                                      appPreferences!.setAccentPreset(
                                        preset.id,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    SettingsCardGroup(
                      title: 'Personalization & Display',
                      children: [
                        SettingsSwitchTile(
                          icon: Icons.auto_awesome_rounded,
                          title: 'Sync with media artwork',
                          subtitle:
                              'Extracts colors from active video thumbnails or music album covers to dynamically tint the player.',
                          value: prefs.dynamicArtworkColor,
                          onChanged: (val) => unawaited(
                            appPreferences!.setDynamicArtworkColor(val),
                          ),
                        ),
                        SettingsSwitchTile(
                          icon: Icons.contrast_rounded,
                          title: 'OLED pure black',
                          subtitle:
                              'Renders true pitch-black surfaces in dark mode for OLED displays and battery efficiency.',
                          value: prefs.oledBlack,
                          onChanged: (val) =>
                              unawaited(appPreferences!.setOledBlack(val)),
                        ),
                        SettingsSwitchTile(
                          icon: Icons.motion_photos_off_rounded,
                          title: 'Calm mode (Reduced motion)',
                          subtitle:
                              'Disables animations and transitions app-wide for minimal visual stimulation and low CPU usage.',
                          value: prefs.reduceMotion,
                          onChanged: (val) => unawaited(
                            appPreferences!.updatePreferences(
                              prefs.copyWith(reduceMotion: val),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final isCompact =
                  controller.controlDensity == ControlDensity.compact;
              return SettingsCardGroup(
                title: 'Player control size',
                description:
                    'Compact saves vertical space; Normal gives larger touch targets.',
                trailing: SegmentedButton<ControlDensity>(
                  key: const ValueKey('control-density-selector'),
                  segments: const [
                    ButtonSegment<ControlDensity>(
                      value: ControlDensity.compact,
                      label: Text('Compact'),
                    ),
                    ButtonSegment<ControlDensity>(
                      value: ControlDensity.normal,
                      label: Text('Normal'),
                    ),
                  ],
                  selected: {controller.controlDensity},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected)
                          ? accent
                          : theme.colorScheme.surfaceContainer,
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected)
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurface,
                    ),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    ),
                  ),
                  onSelectionChanged: (selection) =>
                      controller.setControlDensity(selection.first),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: ExcludeSemantics(
                      child: RepaintBoundary(
                        child: ControlBarPreview(
                          compact: isCompact,
                          compactViewport: compactViewport,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
