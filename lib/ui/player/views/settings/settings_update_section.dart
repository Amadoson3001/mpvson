import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/components/app_mark.dart';
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

  void _openUpdateCenter(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => UpdateCenterDialog(
        updates: updates,
        engineUpdates: engineUpdates,
        engineVersion: engineVersion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return SettingsContentContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero Branded Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.25),
                      width: 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const AppMark(size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Mpvson',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                            ),
                            child: Text(
                              'v${updates.currentVersion}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Modern desktop media player powered by mpv',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: () => _openUpdateCenter(context),
                  icon: const Icon(Icons.sync_rounded, size: 16),
                  label: const Text('Update center'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Software & Engine Status Group
          SettingsCardGroup(
            title: 'Software & Engine',
            children: [
              AnimatedBuilder(
                animation: Listenable.merge([updates, engineUpdates]),
                builder: (context, _) {
                  final (statusText, statusColor) = _appStatusInfo(
                    context,
                    updates.status,
                    accent,
                  );
                  return _AboutTile(
                    icon: Icons.desktop_windows_outlined,
                    title: 'Application updates',
                    subtitle: _updateSummary(),
                    subtitleKey: ValueKey<String>(
                      'update-summary-${updates.status}-${engineUpdates.status}',
                    ),
                    trailing: _StatusBadge(
                      label: statusText,
                      color: statusColor,
                    ),
                    onTap: () => _openUpdateCenter(context),
                  );
                },
              ),
              AnimatedBuilder(
                animation: engineUpdates,
                builder: (context, _) {
                  final (statusText, statusColor) = _engineStatusInfo(
                    context,
                    engineUpdates.status,
                    accent,
                  );
                  final cleanEngine = _formatEngineVersion(engineVersion);
                  return _AboutTile(
                    icon: Icons.memory_rounded,
                    title: 'Playback engine',
                    subtitle: cleanEngine,
                    trailing: _StatusBadge(
                      label: statusText,
                      color: statusColor,
                    ),
                    onTap: () => _openUpdateCenter(context),
                  );
                },
              ),
              _AboutTile(
                icon: Icons.alt_route_rounded,
                title: 'Engine channel & distribution',
                subtitle:
                    '${engineUpdates.channel.name.toUpperCase()} · ${engineUpdates.sourceLabel}',
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => _openUpdateCenter(context),
              ),
            ],
          ),

          // System & Architecture Group
          SettingsCardGroup(
            title: 'System & Architecture',
            children: const [
              _AboutTile(
                icon: Icons.speed_rounded,
                title: 'Rendering pipeline',
                subtitle: 'Flutter Impeller · Direct3D 11 · GPU Accelerated',
              ),
              _AboutTile(
                icon: Icons.verified_user_outlined,
                title: 'Open source & license',
                subtitle: 'GPLv3 / LGPL · Built with Flutter and libmpv',
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatEngineVersion(String raw) {
    final clean = raw.trim();
    if (clean.isEmpty) return 'libmpv';
    return 'libmpv $clean';
  }

  static (String, Color) _appStatusInfo(
    BuildContext context,
    String status,
    Color accent,
  ) => switch (status) {
    'checking' => ('Checking…', AppTheme.warning),
    'available' => ('Update ready', accent),
    'downloading' => ('Downloading…', AppTheme.warning),
    'ready' => ('Downloaded', AppTheme.success),
    'upToDate' => ('Up to date', AppTheme.success),
    'error' => ('Check failed', context.palette.danger),
    'unconfigured' => ('Not configured', context.palette.muted),
    _ => ('Idle', context.palette.muted),
  };

  static (String, Color) _engineStatusInfo(
    BuildContext context,
    String status,
    Color accent,
  ) => switch (status) {
    'available' => ('Update ready', accent),
    'staging' || 'downloading' => ('In progress', AppTheme.warning),
    'readyToRestart' => ('Restart ready', AppTheme.success),
    'newerInstalled' => ('Upstream older', context.palette.secondaryText),
    'stableUnavailable' => ('Channel fallback', context.palette.muted),
    'error' => ('Check failed', context.palette.danger),
    'upToDate' => ('Up to date', AppTheme.success),
    _ => ('Ready', AppTheme.success),
  };

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
                  : 'Engine update available'
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

class _AboutTile extends StatelessWidget {
  const _AboutTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.subtitleKey,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Key? subtitleKey;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 17,
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
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  key: subtitleKey,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );

    if (onTap == null) return content;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: content,
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(
          color: color.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}
