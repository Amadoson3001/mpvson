import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../domain/models/control_density.dart';
import '../../../core/app_theme.dart';
import '../../player_controller.dart';
import 'settings_shared_widgets.dart';

class FloatingDisplayTab extends StatelessWidget {
  const FloatingDisplayTab({
    super.key,
    required this.controller,
    required this.appPreferences,
  });

  final PlayerController controller;
  final AppPreferencesRepository? appPreferences;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = appPreferences?.preferences;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (appPreferences != null && prefs != null) ...[
          SettingsCardGroup(
            title: 'Theme appearance',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _ThemeChip(
                        label: 'Dark',
                        icon: Icons.dark_mode_rounded,
                        selected: prefs.themeMode == ThemeMode.dark,
                        onTap: () => unawaited(
                          appPreferences!.setThemeMode(ThemeMode.dark),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ThemeChip(
                        label: 'Light',
                        icon: Icons.light_mode_rounded,
                        selected: prefs.themeMode == ThemeMode.light,
                        onTap: () => unawaited(
                          appPreferences!.setThemeMode(ThemeMode.light),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ThemeChip(
                        label: 'System',
                        icon: Icons.brightness_auto_rounded,
                        selected: prefs.themeMode == ThemeMode.system,
                        onTap: () => unawaited(
                          appPreferences!.setThemeMode(ThemeMode.system),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SettingsSwitchTile(
                icon: Icons.contrast_rounded,
                title: 'OLED pure black',
                subtitle: 'True pitch-black surfaces for OLED panels.',
                value: prefs.oledBlack,
                onChanged: (val) =>
                    unawaited(appPreferences!.setOledBlack(val)),
              ),
              SettingsSwitchTile(
                icon: Icons.auto_awesome_rounded,
                title: 'Artwork dynamic color',
                subtitle: 'Extracts colors from thumbnails to tint the player.',
                value: prefs.dynamicArtworkColor,
                onChanged: (val) =>
                    unawaited(appPreferences!.setDynamicArtworkColor(val)),
              ),
              SettingsSwitchTile(
                icon: Icons.motion_photos_off_rounded,
                title: 'Reduced motion',
                subtitle: 'Disables transitions and animations.',
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
        SettingsCardGroup(
          title: 'Control bar size',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Size density',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SegmentedButton<ControlDensity>(
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
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                      ),
                    ),
                    onSelectionChanged: (s) =>
                        controller.setControlDensity(s.first),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ThemeChip extends StatelessWidget {
  const _ThemeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Material(
      color: selected
          ? accent.withValues(alpha: 0.12)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(
              color: selected
                  ? accent
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? accent : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? accent : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
