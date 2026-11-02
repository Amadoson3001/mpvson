import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../../data/services/engine_update_service.dart';
import '../../../../data/services/update_service.dart';
import '../../../../domain/updates/engine_update_channel.dart';
import '../update_center_dialog.dart';
import 'settings_shared_widgets.dart';

class AboutSettingsSection extends StatelessWidget {
  const AboutSettingsSection({
    super.key,
    required this.updates,
    required this.engineUpdates,
    required this.engineVersion,
  });

  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final String engineVersion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return SettingsContentContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  accent.withValues(alpha: 0.15),
                  theme.colorScheme.surfaceContainer,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              border: Border.all(
                color: accent.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 32,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Mpvson',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Modern desktop media player powered by mpv',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => UpdateCenterDialog(
                        updates: updates,
                        engineUpdates: engineUpdates,
                        engineVersion: engineVersion,
                      ),
                    );
                  },
                  icon: const Icon(Icons.system_update_alt_rounded, size: 16),
                  label: const Text('Update center'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SettingsCardGroup(
            title: 'System & Engine status',
            children: [
              AnimatedBuilder(
                animation: Listenable.merge([updates, engineUpdates]),
                builder: (context, _) => ListTile(
                  leading: const Icon(Icons.update_rounded),
                  title: const Text('App & engine updates'),
                  subtitle: Text(
                    _updateSummary(),
                    key: ValueKey<String>(
                      'update-summary-${updates.status}-${engineUpdates.status}',
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => UpdateCenterDialog(
                        updates: updates,
                        engineUpdates: engineUpdates,
                        engineVersion: engineVersion,
                      ),
                    );
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.video_settings_rounded),
                title: const Text('Playback engine'),
                subtitle: Text(engineVersion),
              ),
              ListTile(
                leading: const Icon(Icons.source_rounded),
                title: const Text('Engine distribution'),
                subtitle: Text(engineUpdates.sourceLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _updateSummary() {
    final appStatus = switch (updates.status) {
      'checking' => 'Checking…',
      'available' => 'Update available',
      'downloading' => 'Downloading…',
      'ready' => 'Update downloaded',
      'upToDate' => 'Up to date',
      'error' => 'Check failed',
      'unconfigured' => 'Checks not configured',
      _ => null,
    };
    final engineStatus = switch (engineUpdates.status) {
      'available' =>
        engineUpdates.usesOfficialMpvSource
            ? engineUpdates.channel == EngineUpdateChannel.stable
                  ? 'Stable engine update available'
                  : 'mpv development build available'
            : 'Engine update available',
      'stableUnavailable' => 'Stable engine build unavailable',
      'newerInstalled' => 'Installed engine is newer',
      'savingChannel' => 'Saving engine channel',
      'downloading' || 'staging' => 'Engine update in progress',
      'readyToRestart' => 'Engine staged',
      'error' => 'Engine update failed',
      'upToDate' => 'Engine up to date',
      _ => null,
    };
    final summary = appStatus == null
        ? 'Mpvson ${updates.currentVersion}'
        : 'Mpvson ${updates.currentVersion} · $appStatus';
    return engineStatus == null ? summary : '$summary · $engineStatus';
  }
}
