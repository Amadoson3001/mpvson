import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../../domain/updates/engine_release.dart';
import '../../../domain/updates/engine_update_channel.dart';
import '../../../domain/updates/release_info.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';

class UpdateCenterDialog extends StatelessWidget {
  const UpdateCenterDialog({
    super.key,
    required this.updates,
    required this.engineUpdates,
    required this.engineVersion,
  });

  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final String engineVersion;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([updates, engineUpdates]),
    builder: (context, _) {
      final screenHeight = MediaQuery.sizeOf(context).height;
      final dialogHeight = screenHeight - 48 < 660 ? screenHeight - 48 : 660.0;
      final appBusy = updates.busy;
      final engineBusy = engineUpdates.busy;
      final theme = Theme.of(context);

      return Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.artwork),
          side: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        insetPadding: const EdgeInsets.symmetric(
          horizontal: AppSpace.xl,
          vertical: AppSpace.lg,
        ),
        child: SizedBox(
          width: 580,
          height: dialogHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Dialog Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.sync_rounded,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Updates & about',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            'Software & playback engine component manager',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close dialog',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),

              // Scrollable Body
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Playback Engine Track
                      _EngineTrack(
                        updates: engineUpdates,
                        loadedVersion: engineVersion,
                        busy: engineBusy,
                        onAction: _performEngineAction,
                        onRollback: _scheduleEngineRollback,
                      ),
                      const SizedBox(height: 18),

                      // Application Track
                      _ApplicationTrack(
                        updates: updates,
                        busy: appBusy,
                        onAction: _performApplicationAction,
                      ),
                    ],
                  ),
                ),
              ),

              Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),

              // Dialog Footer
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _performApplicationAction() async {
    try {
      switch (updates.status) {
        case 'available':
          return await updates.download();
        case 'ready':
          return await updates.openDownload();
        default:
          return await updates.check();
      }
    } catch (_) {
      // UpdateService publishes user-readable failures through its error field.
    }
  }

  Future<void> _performEngineAction() async {
    try {
      switch (engineUpdates.status) {
        case 'available':
          return await engineUpdates.downloadAndStage();
        case 'readyToRestart':
          return await engineUpdates.discardPending();
        default:
          return await engineUpdates.check();
      }
    } catch (_) {
      // EngineUpdateService publishes user-readable failures through its state.
    }
  }

  Future<void> _scheduleEngineRollback() async {
    try {
      await engineUpdates.scheduleRollback();
    } catch (_) {
      // EngineUpdateService publishes user-readable failures through its state.
    }
  }
}

class _ApplicationTrack extends StatelessWidget {
  const _ApplicationTrack({
    required this.updates,
    required this.busy,
    required this.onAction,
  });

  final UpdateService updates;
  final bool busy;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final release = updates.release;
    final (status, statusColor) = _applicationStatus(
      context,
      updates.status,
      accent,
    );
    final action = switch (updates.status) {
      'available' => 'Download package',
      'ready' => 'Open package',
      'checking' => 'Checking…',
      'downloading' => 'Downloading…',
      _ => 'Check for updates',
    };
    final enabled =
        !busy &&
        switch (updates.status) {
          'available' || 'ready' => true,
          _ => updates.configured,
        };

    return _ComponentCard(
      icon: Icons.desktop_windows_outlined,
      accentColor: accent,
      title: 'Application',
      subtitle: 'Version ${updates.currentVersion}',
      status: status,
      statusColor: statusColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: AppMotion.duration(context, AppMotion.quick),
            curve: AppMotion.standardCurve,
            alignment: Alignment.topLeft,
            child: AnimatedSwitcher(
              duration: AppMotion.duration(context, AppMotion.quick),
              child: KeyedSubtree(
                key: ValueKey<String>('app-update-${updates.status}'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _applicationStatusContent(
                      context,
                      updates,
                      release,
                      accent,
                    ),
                    if (updates.error != null && updates.status != 'error') ...[
                      const SizedBox(height: 8),
                      _TrackNotice(
                        icon: Icons.error_outline_rounded,
                        color: context.palette.danger,
                        text: updates.error!,
                      ),
                    ],
                    if (release != null && updates.status == 'ready') ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(
                            AppRadii.control,
                          ),
                        ),
                        child: SelectableText(
                          'SHA-256: ${release.sha256}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton.icon(
                onPressed: enabled ? onAction : null,
                icon: busy
                    ? _ActionProgress(reducedMotion: AppMotion.reduce(context))
                    : Icon(
                        updates.status == 'ready'
                            ? Icons.folder_open_rounded
                            : updates.status == 'available'
                            ? Icons.download_rounded
                            : Icons.refresh_rounded,
                        size: 16,
                      ),
                label: Text(action),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static (String, Color) _applicationStatus(
    BuildContext context,
    String value,
    Color accent,
  ) => switch (value) {
    'checking' => ('Checking', AppTheme.warning),
    'available' => ('Update available', accent),
    'downloading' => ('Downloading', AppTheme.warning),
    'ready' => ('Downloaded', AppTheme.success),
    'upToDate' => ('Up to date', AppTheme.success),
    'error' => ('Check failed', context.palette.danger),
    'unconfigured' => ('Not configured', context.palette.muted),
    _ => ('Not checked', context.palette.muted),
  };

  static Widget _applicationStatusContent(
    BuildContext context,
    UpdateService updates,
    ReleaseInfo? release,
    Color accent,
  ) => switch (updates.status) {
    'unconfigured' => _TrackNotice(
      icon: Icons.info_outline_rounded,
      color: context.palette.muted,
      text: 'Update checks are not configured for this build.',
    ),
    'checking' => _TrackNotice(
      icon: Icons.sync_rounded,
      color: accent,
      text: 'Checking for newer Mpvson release…',
    ),
    'upToDate' => const _TrackNotice(
      icon: Icons.check_circle_outline_rounded,
      color: AppTheme.success,
      text: 'You are using the latest version of Mpvson.',
    ),
    'available' when release != null => _AppReleaseDetails(release: release),
    'downloading' => _ProgressDetail(
      title: release == null
          ? 'Downloading package…'
          : 'Downloading version ${release.version}…',
      progress: updates.progress,
    ),
    'ready' => const _TrackNotice(
      icon: Icons.verified_outlined,
      color: AppTheme.success,
      text: 'Verified package downloaded. Close Mpvson before installing.',
    ),
    'error' when updates.error != null => _TrackNotice(
      icon: Icons.error_outline_rounded,
      color: context.palette.danger,
      text: updates.error!,
    ),
    _ => _TrackNotice(
      icon: Icons.check_circle_outline_rounded,
      color: context.palette.secondaryText,
      text: 'Mpvson is ready to check for updates.',
    ),
  };
}

class _EngineTrack extends StatelessWidget {
  const _EngineTrack({
    required this.updates,
    required this.loadedVersion,
    required this.busy,
    required this.onAction,
    required this.onRollback,
  });

  final EngineUpdateService updates;
  final String loadedVersion;
  final bool busy;
  final VoidCallback onAction;
  final VoidCallback onRollback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final linux = defaultTargetPlatform == TargetPlatform.linux;
    final systemManaged =
        linux || !updates.selfManaged || updates.status == 'systemManaged';
    final release = updates.release;
    final (status, color) = _statusLabel(
      context,
      updates.status,
      systemManaged,
      accent,
    );
    final hasPendingAction =
        updates.status == 'readyToRestart' ||
        updates.pendingVersion != null ||
        updates.pendingBundled;
    final rollbackPending = updates.pendingRollback;
    final canScheduleRollback =
        updates.canRollback && !busy && !hasPendingAction;
    final rollbackVersion = updates.rollbackVersion
        ?.replaceAll(RegExp(r'-dev[-+.0-9a-zA-Z]*'), '')
        .trim();
    final action = switch (updates.status) {
      'available' => 'Download and stage',
      'readyToRestart' => 'Discard pending',
      'checking' => 'Checking…',
      'downloading' => 'Downloading…',
      'staging' => 'Staging…',
      _ => 'Check engine updates',
    };
    final enabled =
        !busy &&
        switch (updates.status) {
          'available' || 'readyToRestart' => true,
          _ => updates.configured,
        };

    final cleanLoaded = loadedVersion.trim();

    return _ComponentCard(
      icon: Icons.memory_rounded,
      accentColor: color,
      title: 'Playback engine',
      subtitle: cleanLoaded.isEmpty ? 'libmpv' : 'Loaded: libmpv $cleanLoaded',
      status: status,
      statusColor: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: AppMotion.duration(context, AppMotion.quick),
            curve: AppMotion.standardCurve,
            alignment: Alignment.topLeft,
            child: AnimatedSwitcher(
              duration: AppMotion.duration(context, AppMotion.quick),
              child: KeyedSubtree(
                key: ValueKey<String>('engine-update-${updates.status}'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (updates.sourceLabel.trim().isNotEmpty) ...[
                      Text(
                        'Source: ${updates.sourceLabel}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (updates.usesOfficialMpvSource) ...[
                      _EngineChannelChooser(
                        updates: updates,
                        busy: busy,
                        hasPendingEngine:
                            updates.pendingVersion != null ||
                            updates.pendingBundled,
                      ),
                      const SizedBox(height: 12),
                    ],
                    _engineStatusContent(
                      context,
                      updates,
                      release,
                      loadedVersion,
                      systemManaged,
                      linux,
                      accent,
                    ),
                    if (updates.configurationWarning case final warning?) ...[
                      const SizedBox(height: 8),
                      _TrackNotice(
                        icon: Icons.warning_amber_rounded,
                        color: AppTheme.warning,
                        text: warning,
                      ),
                    ],
                    if (updates.pendingVersion case final pending?
                        when pending.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _TrackNotice(
                        icon: Icons.pending_outlined,
                        color: AppTheme.warning,
                        text: updates.pendingBundled
                            ? 'Bundled engine (v$pending) staged for next restart.'
                            : rollbackPending
                            ? 'Rollback to v$pending staged for next restart.'
                            : 'Engine v$pending staged for next restart.',
                      ),
                    ] else if (updates.pendingBundled) ...[
                      const SizedBox(height: 8),
                      const _TrackNotice(
                        icon: Icons.pending_outlined,
                        color: AppTheme.warning,
                        text: 'Bundled engine selected for next restart.',
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (!systemManaged) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (canScheduleRollback) ...[
                  OutlinedButton.icon(
                    onPressed: onRollback,
                    icon: const Icon(Icons.restore_rounded, size: 16),
                    label: Text(
                      rollbackVersion == null || rollbackVersion.isEmpty
                          ? 'Roll back engine'
                          : 'Roll back to v$rollbackVersion',
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                _engineButton(
                  context,
                  action: action,
                  enabled: enabled,
                  busy: busy,
                  status: updates.status,
                  onAction: onAction,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static Widget _engineButton(
    BuildContext context, {
    required String action,
    required bool enabled,
    required bool busy,
    required String status,
    required VoidCallback onAction,
  }) {
    if (status == 'readyToRestart') {
      return OutlinedButton.icon(
        onPressed: enabled ? onAction : null,
        icon: const Icon(Icons.delete_outline_rounded, size: 16),
        label: Text(action),
      );
    }
    return FilledButton.icon(
      onPressed: enabled ? onAction : null,
      icon: busy
          ? _ActionProgress(reducedMotion: AppMotion.reduce(context))
          : Icon(
              status == 'available'
                  ? Icons.download_rounded
                  : Icons.refresh_rounded,
              size: 16,
            ),
      label: Text(action),
    );
  }

  static (String, Color) _statusLabel(
    BuildContext context,
    String value,
    bool systemManaged,
    Color accent,
  ) {
    if (systemManaged) return ('System managed', context.palette.secondaryText);
    return switch (value) {
      'checking' => ('Checking', AppTheme.warning),
      'savingChannel' => ('Saving choice', AppTheme.warning),
      'available' => ('Update ready', accent),
      'downloading' => ('Downloading', AppTheme.warning),
      'staging' => ('Staging', AppTheme.warning),
      'readyToRestart' => ('Ready to restart', AppTheme.success),
      'upToDate' => ('Up to date', AppTheme.success),
      'newerInstalled' => ('Installed is newer', context.palette.secondaryText),
      'stableUnavailable' => ('Channel fallback', context.palette.muted),
      'error' => ('Update failed', context.palette.danger),
      'unconfigured' => ('Not configured', context.palette.muted),
      _ => ('Ready', AppTheme.success),
    };
  }

  static Widget _engineStatusContent(
    BuildContext context,
    EngineUpdateService updates,
    EngineRelease? release,
    String loadedVersion,
    bool systemManaged,
    bool linux,
    Color accent,
  ) {
    if (systemManaged) {
      return _TrackNotice(
        icon: Icons.inventory_2_outlined,
        color: context.palette.secondaryText,
        text: linux
            ? 'On Linux, the distribution package manager maintains libmpv.'
            : 'The operating system manages updates for this playback engine.',
      );
    }

    final rollbackPending = updates.pendingRollback;

    return switch (updates.status) {
      'unconfigured' when updates.configurationError != null => _TrackNotice(
        icon: Icons.error_outline_rounded,
        color: context.palette.danger,
        text: 'Engine updates disabled: ${updates.configurationError}',
      ),
      'unconfigured' => _TrackNotice(
        icon: Icons.info_outline_rounded,
        color: context.palette.muted,
        text: 'Engine update checks are not configured for this build.',
      ),
      'checking' => _TrackNotice(
        icon: Icons.sync_rounded,
        color: accent,
        text: 'Checking for playback engine updates…',
      ),
      'savingChannel' => _TrackNotice(
        icon: Icons.sync_rounded,
        color: accent,
        text: 'Updating engine update channel…',
      ),
      'stableUnavailable' => _TrackNotice(
        icon: Icons.info_outline_rounded,
        color: context.palette.muted,
        text: updates.stableReleaseVersion == null
            ? 'The latest stable release does not publish a compatible Windows package.'
            : 'mpv ${updates.stableReleaseVersion} does not publish a compatible Windows package. Continuing with current engine.',
      ),
      'upToDate' => const _TrackNotice(
        icon: Icons.check_circle_outline_rounded,
        color: AppTheme.success,
        text: 'The loaded playback engine matches the selected source.',
      ),
      'newerInstalled' => _TrackNotice(
        icon: Icons.check_circle_outline_rounded,
        color: context.palette.secondaryText,
        text: 'Current engine ($loadedVersion) is newer than the remote build. Downgrade skipped.',
      ),
      'available' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Builder(
            builder: (context) {
              final rawVersion = release?.engineVersion;
              final cleanVersion = rawVersion
                  ?.replaceAll(RegExp(r'-dev[-+.0-9a-zA-Z]*'), '')
                  .trim();
              final versionLabel = cleanVersion == null || cleanVersion.isEmpty
                  ? 'New engine build'
                  : 'Engine version $cleanVersion';
              return Text(
                '$versionLabel is available for download and staging.',
                style: TextStyle(
                  color: context.palette.secondaryText,
                  fontSize: 13,
                  height: 1.4,
                ),
              );
            },
          ),
          if (release != null && release.notes.trim().isNotEmpty) ...[
            ReleaseNotesPreview(notes: release.notes),
          ],
        ],
      ),
      'downloading' => _ProgressDetail(
        title: updates.pendingVersion == null
            ? 'Downloading playback engine…'
            : 'Downloading engine version ${updates.pendingVersion}…',
        progress: updates.progress,
      ),
      'staging' => _ProgressDetail(
        title: 'Staging engine binaries…',
        progress: updates.progress,
      ),
      'readyToRestart' => _TrackNotice(
        icon: Icons.restart_alt_rounded,
        color: AppTheme.success,
        text: updates.pendingBundled
            ? 'Restart Mpvson to switch to the bundled engine.'
            : rollbackPending
            ? 'Restart Mpvson to roll back to engine ${updates.pendingVersion}.'
            : 'Restart Mpvson to activate the staged engine.',
      ),
      'error' when updates.error != null => _TrackNotice(
        icon: Icons.error_outline_rounded,
        color: context.palette.danger,
        text: updates.error!,
      ),
      'systemManaged' => _TrackNotice(
        icon: Icons.inventory_2_outlined,
        color: context.palette.secondaryText,
        text: 'The operating system manages updates for this playback engine.',
      ),
      _ => _TrackNotice(
        icon: Icons.check_circle_outline_rounded,
        color: context.palette.secondaryText,
        text: 'Playback engine is active and ready.',
      ),
    };
  }
}

class _EngineChannelChooser extends StatelessWidget {
  const _EngineChannelChooser({
    required this.updates,
    required this.busy,
    required this.hasPendingEngine,
  });

  final EngineUpdateService updates;
  final bool busy;
  final bool hasPendingEngine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Update channel',
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        SegmentedButton<EngineUpdateChannel>(
          segments: const [
            ButtonSegment(
              value: EngineUpdateChannel.stable,
              label: Text('Stable'),
              icon: Icon(Icons.verified_outlined, size: 16),
            ),
            ButtonSegment(
              value: EngineUpdateChannel.development,
              label: Text('Development'),
              icon: Icon(Icons.science_outlined, size: 16),
            ),
          ],
          selected: {updates.channel},
          showSelectedIcon: false,
          onSelectionChanged: busy || hasPendingEngine
              ? null
              : (selected) async {
                  if (selected.isEmpty) return;
                  await updates.setChannel(selected.single);
                },
        ),
        const SizedBox(height: 6),
        Text(
          hasPendingEngine
              ? 'Discard the pending engine to change channels.'
              : updates.channel == EngineUpdateChannel.stable
              ? 'Stable releases are recommended for production playback.'
              : 'Development tracks upstream mpv master builds with latest features.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: updates.channel == EngineUpdateChannel.development
                ? AppTheme.warning
                : theme.colorScheme.onSurfaceVariant,
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }
}

class _ComponentCard extends StatelessWidget {
  const _ComponentCard({
    required this.accentColor,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.statusColor,
    required this.child,
  });

  final Color accentColor;
  final IconData icon;
  final String title;
  final String subtitle;
  final String status;
  final Color statusColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.25),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 19, color: accentColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _StatusPill(status: status, color: statusColor),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _AppReleaseDetails extends StatelessWidget {
  const _AppReleaseDetails({required this.release});

  final ReleaseInfo release;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Version ${release.version} is available for download.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: context.palette.secondaryText,
          ),
        ),
        if (release.notes.trim().isNotEmpty) ...[
          ReleaseNotesPreview(notes: release.notes),
        ],
        const SizedBox(height: 8),
        _TrackNotice(
          icon: Icons.shield_outlined,
          color: context.palette.secondaryText,
          text: 'Verified with SHA-256 integrity check.',
        ),
      ],
    );
  }
}

class ReleaseNotesPreview extends StatefulWidget {
  const ReleaseNotesPreview({super.key, required this.notes});

  final String notes;

  @override
  State<ReleaseNotesPreview> createState() => _ReleaseNotesPreviewState();
}

class _ReleaseNotesPreviewState extends State<ReleaseNotesPreview> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final raw = widget.notes.trim();
    if (raw.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where(
          (l) =>
              l.isNotEmpty &&
              !l.startsWith('http') &&
              !l.startsWith('===') &&
              !l.startsWith('---'),
        )
        .toList();

    final bulletRegex = RegExp(r'^[*\-•+]\s*(.+)');
    final headingRegex = RegExp(
      r'^(#{1,6}\s+|===+|---+|[A-Za-z0-9 _\-]+:|\b(?:Features|Changes|Changelog|Fixes|Notes)\b)',
      caseSensitive: false,
    );

    // Prioritize bullet points in changelogs
    final bullets = <String>[];
    for (final line in lines) {
      final match = bulletRegex.firstMatch(line);
      if (match != null) {
        final text = match
            .group(1)!
            .replaceAll(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), r'$1')
            .trim();
        if (text.length > 3 &&
            !text.toLowerCase().contains('commit') &&
            !text.toLowerCase().contains('sha256')) {
          bullets.add(text.length > 80 ? '${text.substring(0, 77)}…' : text);
          if (bullets.length >= 2) break;
        }
      }
    }

    final highlights = <String>[];
    if (bullets.isNotEmpty) {
      highlights.addAll(bullets);
    } else {
      // Fallback: pick clean non-heading lines
      for (final line in lines) {
        if (headingRegex.hasMatch(line)) continue;
        final clean = line
            .replaceAll(RegExp(r'^[#* \-\t]+'), '')
            .replaceAll(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), r'$1')
            .trim();
        if (clean.length > 5 &&
            !clean.toLowerCase().contains('commit') &&
            !clean.toLowerCase().contains('sha256') &&
            !clean.toLowerCase().startsWith('release notes')) {
          highlights.add(
            clean.length > 80 ? '${clean.substring(0, 77)}…' : clean,
          );
          if (highlights.length >= 2) break;
        }
      }
    }

    final hasMore = lines.length > 2 || raw.length > 150;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 14,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Highlights',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              if (hasMore)
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _expanded ? 'Show less' : 'View full notes',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontSize: 11,
                          ),
                        ),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (!_expanded) ...[
            for (final h
                in highlights.isNotEmpty ? highlights : [lines.first]) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• ',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        h,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ] else ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: Text(
                  raw,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.35,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProgressDetail extends StatelessWidget {
  const _ProgressDetail({required this.title, required this.progress});

  final String title;
  final double progress;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: progress > 0
            ? progress.clamp(0, 1).toDouble()
            : AppMotion.reduce(context)
            ? 0
            : null,
        minHeight: 4,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      if (progress > 0) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${(progress.clamp(0, 1).toDouble() * 100).round()}%',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ],
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, required this.color});

  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppRadii.pill),
      border: Border.all(
        color: color.withValues(alpha: 0.25),
        width: 1,
      ),
    ),
    child: AnimatedSwitcher(
      duration: AppMotion.duration(context, AppMotion.quick),
      child: Text(
        status,
        key: ValueKey<String>(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    ),
  );
}

class _TrackNotice extends StatelessWidget {
  const _TrackNotice({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: color, size: 16),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            height: 1.4,
            fontSize: 12,
          ),
        ),
      ),
    ],
  );
}

class _ActionProgress extends StatelessWidget {
  const _ActionProgress({required this.reducedMotion});

  final bool reducedMotion;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 16,
    height: 16,
    child: reducedMotion
        ? const Icon(Icons.more_horiz_rounded, size: 16)
        : CircularProgressIndicator(
            strokeWidth: 2,
            color: context.palette.accentForeground,
          ),
  );
}
