import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../../data/repositories/app_preferences_repository.dart';
import '../../../../data/services/desktop_integration_service.dart';
import 'settings_shared_widgets.dart';

class DesktopIntegrationSettingsSection extends StatelessWidget {
  const DesktopIntegrationSettingsSection({
    super.key,
    required this.preferences,
    required this.desktopIntegration,
  });

  final AppPreferencesRepository preferences;
  final DesktopIntegrationService desktopIntegration;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      final currentOpenBehavior = preferences.preferences.openBehavior;
      final theme = Theme.of(context);

      return SettingsContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (preferences.saveError != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      color: theme.colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Could not save settings. Please verify app directory write permissions.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(preferences.flush()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ],
            SettingsCardGroup(
              title: 'Opening media files',
              description:
                  'Choose behavior when files are opened while video is playing.',
              children: [
                RadioGroup<OpenBehaviorPreference>(
                  groupValue: currentOpenBehavior,
                  onChanged: (val) {
                    if (val != null) {
                      unawaited(preferences.setOpenBehavior(val));
                    }
                  },
                  child: Column(
                    children: [
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-keep-playing'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        title: const Text('Keep playing and add to queue'),
                        subtitle: const Text(
                          'Appends opened media without interrupting the active stream.',
                        ),
                        value: OpenBehaviorPreference.keepPlayingAndEnqueue,
                      ),
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-play-now'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        title: const Text('Play new files immediately'),
                        subtitle: const Text(
                          'Switches playback to the new file right away.',
                        ),
                        value: OpenBehaviorPreference.playNewFilesNow,
                      ),
                      RadioListTile<OpenBehaviorPreference>(
                        key: const ValueKey('open-behavior-ask-every-time'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        title: const Text('Ask every time'),
                        subtitle: const Text(
                          'Displays a prompt asking whether to play or enqueue.',
                        ),
                        value: OpenBehaviorPreference.askEveryTime,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SettingsCardGroup(
              title: 'Power & Sleep',
              children: [
                SettingsSwitchTile(
                  key: const ValueKey('keep-awake-switch'),
                  icon: Icons.coffee_rounded,
                  title: 'Prevent computer sleep during playback',
                  subtitle:
                      'Inhibits screen savers and system standby while video is active.',
                  value: preferences.preferences.keepAwakeDuringPlayback,
                  onChanged: (val) => unawaited(preferences.setKeepAwake(val)),
                ),
              ],
            ),
            SettingsCardGroup(
              title: 'System integration',
              children: [
                ListTile(
                  leading: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.settings_applications_rounded,
                      size: 17,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  title: const Text('Default app associations'),
                  subtitle: const Text(
                    'Configure default video/audio player file extensions in OS settings.',
                  ),
                  trailing: OutlinedButton.icon(
                    key: const ValueKey('default-apps-button'),
                    onPressed: () =>
                        unawaited(desktopIntegration.openDefaultAppsSettings()),
                    icon: const Icon(Icons.open_in_new_rounded, size: 15),
                    label: const Text('Open settings'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
