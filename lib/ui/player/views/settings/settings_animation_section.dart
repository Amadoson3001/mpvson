import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../core/app_theme.dart';
import 'settings_shared_widgets.dart';

class AnimationSettingsSection extends StatelessWidget {
  const AnimationSettingsSection({super.key, required this.appPreferences});

  final AppPreferencesRepository appPreferences;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return SettingsContentContainer(
      child: ListenableBuilder(
        listenable: appPreferences,
        builder: (context, _) {
          final prefs = appPreferences.preferences;
          final enabled = !prefs.reduceMotion;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsCardGroup(
                title: 'Motion',
                description:
                    'How the player moves when the queue and other panels open or close.',
                children: [
                  SettingsSwitchTile(
                    icon: Icons.auto_awesome_motion_rounded,
                    title: 'Smooth animations',
                    subtitle:
                        'The queue slides in next to the video while the picture smoothly makes room. Turn off on old or slow PCs — panels open instantly instead.',
                    value: enabled,
                    onChanged: (value) => unawaited(
                      appPreferences.updatePreferences(
                        prefs.copyWith(reduceMotion: !value),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.speed_rounded,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Animation speed',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                  fontSize: 13.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'How quickly panels slide and the video resizes.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.85),
                                  height: 1.35,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        SegmentedButton<AnimationSpeed>(
                          key: const ValueKey('animation-speed-selector'),
                          segments: const [
                            ButtonSegment<AnimationSpeed>(
                              value: AnimationSpeed.fast,
                              label: Text('Fast'),
                            ),
                            ButtonSegment<AnimationSpeed>(
                              value: AnimationSpeed.normal,
                              label: Text('Normal'),
                            ),
                            ButtonSegment<AnimationSpeed>(
                              value: AnimationSpeed.slow,
                              label: Text('Slow'),
                            ),
                          ],
                          selected: {prefs.animationSpeed},
                          showSelectedIcon: false,
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            shape: WidgetStatePropertyAll(
                              RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                              ),
                            ),
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
                            side: WidgetStatePropertyAll(
                              BorderSide(
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.35),
                                width: 1,
                              ),
                            ),
                            padding: const WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                            ),
                          ),
                          onSelectionChanged: enabled
                              ? (selection) => unawaited(
                                  appPreferences.updatePreferences(
                                    prefs.copyWith(
                                      animationSpeed: selection.first,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!enabled)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 22),
                  child: Text(
                    'Animations are off. Panels and the video snap instantly, which uses less CPU and suits older computers.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.85,
                      ),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
