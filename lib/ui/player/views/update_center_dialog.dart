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
      final dialogHeight = screenHeight - 48 < 640 ? screenHeight - 48 : 640.0;
      final appBusy =
          updates.status == 'checking' || updates.status == 'downloading';
      final engineBusy = _engineBusy;

      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: SizedBox(
          width: 620,
          height: dialogHeight,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Updates & about',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close updates and about',
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _EngineTrack(
                        updates: engineUpdates,
                        loadedVersion: engineVersion,
                        busy: engineBusy,
                        onAction: _performEngineAction,
                        onRollback: _scheduleEngineRollback,
                      ),
                      const Padding(
                        padding: EdgeInsets.only(left: 18),
                        child: Divider(height: 22),
                      ),
                      _ApplicationTrack(
                        updates: updates,
                        busy: appBusy,
                        onAction: _performApplicationAction,
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  bool get _engineBusy =>
      engineUpdates.status == 'checking' ||
      engineUpdates.status == 'savingChannel' ||
      engineUpdates.status == 'downloading' ||
      engineUpdates.status == 'staging';

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
    final release = updates.release;
    final (status, statusColor) = _applicationStatus(updates.status);
    final action = switch (updates.status) {
      'available' => 'Download package',
      'ready' => 'Open package',
      'checking' => 'Checking…',
      'downloading' => 'Downloading…',
      _ => 'Check for updates',
    };
    final enabled = switch (updates.status) {
      'available' || 'ready' => true,
      _ => updates.configured && !busy,
    };
    return _ReleaseTrack(
      railColor: AppTheme.accent,
      icon: Icons.desktop_windows_outlined,
      title: 'Application',
      status: status,
      statusColor: statusColor,
      currentLabel: 'Version ${updates.currentVersion}',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _applicationStatusContent(updates, release),
                    if (updates.error != null && updates.status != 'error') ...[
                      const SizedBox(height: 8),
                      _TrackNotice(
                        icon: Icons.error_outline_rounded,
                        color: AppTheme.danger,
                        text: updates.error!,
                      ),
                    ],
                    if (release != null && updates.status == 'ready') ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        'SHA-256  ${release.sha256}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppTheme.muted,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Tooltip(
              message: action,
              child: FilledButton.icon(
                onPressed: enabled ? onAction : null,
                icon: busy
                    ? _ActionProgress(reducedMotion: AppMotion.reduce(context))
                    : Icon(
                        updates.status == 'ready'
                            ? Icons.folder_open_rounded
                            : updates.status == 'available'
                            ? Icons.download_rounded
                            : Icons.refresh_rounded,
                      ),
                label: Text(action),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static (String, Color) _applicationStatus(String value) => switch (value) {
    'checking' => ('Checking', AppTheme.warning),
    'available' => ('Update available', AppTheme.accent),
    'downloading' => ('Downloading', AppTheme.warning),
    'ready' => ('Downloaded', AppTheme.success),
    'upToDate' => ('Up to date', AppTheme.success),
    'error' => ('Check failed', AppTheme.danger),
    'unconfigured' => ('Not configured', AppTheme.muted),
    _ => ('Not checked', AppTheme.muted),
  };

  static Widget _applicationStatusContent(
    UpdateService updates,
    ReleaseInfo? release,
  ) => switch (updates.status) {
    'unconfigured' => const _TrackNotice(
      icon: Icons.info_outline_rounded,
      color: AppTheme.muted,
      text: 'Update checks are not configured for this build.',
    ),
    'checking' => const _TrackNotice(
      icon: Icons.sync_rounded,
      color: AppTheme.accent,
      text: 'Checking for a newer Mpvson release…',
    ),
    'upToDate' => const _TrackNotice(
      icon: Icons.check_circle_outline_rounded,
      color: AppTheme.success,
      text: 'You are using the latest available version.',
    ),
    'available' when release != null => _AppReleaseDetails(release: release),
    'downloading' => _ProgressDetail(
      title: release == null
          ? 'Downloading the application package…'
          : 'Downloading version ${release.version}…',
      progress: updates.progress,
    ),
    'ready' => const _TrackNotice(
      icon: Icons.verified_outlined,
      color: AppTheme.success,
      text:
          'The verified package is downloaded. Close Mpvson before installing it.',
    ),
    'error' when updates.error != null => _TrackNotice(
      icon: Icons.error_outline_rounded,
      color: AppTheme.danger,
      text: updates.error!,
    ),
    _ => const _TrackNotice(
      icon: Icons.system_update_alt_rounded,
      color: AppTheme.secondaryText,
      text: 'Check for a newer Mpvson release.',
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
    final linux = defaultTargetPlatform == TargetPlatform.linux;
    final systemManaged =
        linux || !updates.selfManaged || updates.status == 'systemManaged';
    final release = updates.release;
    final (status, color) = _statusLabel(updates.status, systemManaged);
    final hasPendingAction =
        updates.status == 'readyToRestart' ||
        updates.pendingVersion != null ||
        updates.pendingBundled;
    final rollbackPending = updates.pendingRollback;
    final canScheduleRollback =
        updates.canRollback && !busy && !hasPendingAction;
    final rollbackVersion = updates.rollbackVersion?.trim();
    final rollbackTarget = updates.rollbackTargetIsBundled
        ? rollbackVersion == null || rollbackVersion.isEmpty
              ? 'the bundled engine'
              : 'the bundled engine (version $rollbackVersion)'
        : rollbackVersion == null || rollbackVersion.isEmpty
        ? 'the previous compatible engine'
        : 'the previous compatible engine (version $rollbackVersion)';
    final action = switch (updates.status) {
      'available' => 'Download and stage',
      'readyToRestart' => 'Discard pending engine',
      'checking' => 'Checking…',
      'downloading' => 'Downloading…',
      'staging' => 'Staging…',
      _ => 'Check for engine updates',
    };
    final enabled = switch (updates.status) {
      'available' || 'readyToRestart' => true,
      _ => updates.configured && !busy,
    };

    return _ReleaseTrack(
      railColor: color,
      icon: Icons.memory_rounded,
      title: 'Playback engine',
      status: status,
      statusColor: color,
      currentLabel: 'Loaded engine version $loadedVersion',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (updates.sourceLabel.trim().isNotEmpty) ...[
                      Text(
                        'Source: ${updates.sourceLabel}',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: AppTheme.muted),
                      ),
                      const SizedBox(height: 8),
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
                      updates,
                      release,
                      loadedVersion,
                      systemManaged,
                      linux,
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
                            ? 'Bundled engine version $pending selected for the next restart.'
                            : rollbackPending
                            ? 'Rollback to engine version $pending selected for the next restart.'
                            : 'Staged version $pending',
                      ),
                    ] else if (updates.pendingBundled) ...[
                      const SizedBox(height: 8),
                      const _TrackNotice(
                        icon: Icons.pending_outlined,
                        color: AppTheme.warning,
                        text: 'Bundled engine selected for the next restart.',
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (!systemManaged) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Tooltip(
                message: action,
                child: _engineButton(
                  context,
                  action: action,
                  enabled: enabled,
                  busy: busy,
                  status: updates.status,
                  onAction: onAction,
                ),
              ),
            ),
            if (canScheduleRollback) ...[
              const SizedBox(height: 8),
              Text(
                'Select $rollbackTarget for the next restart. The currently loaded engine ($loadedVersion) stays active until then.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.secondaryText,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Tooltip(
                  message: 'Roll back to $rollbackTarget on the next restart',
                  child: OutlinedButton.icon(
                    onPressed: onRollback,
                    icon: const Icon(Icons.restore_rounded),
                    label: const Text('Roll back engine'),
                  ),
                ),
              ),
            ],
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
    final button = status == 'readyToRestart'
        ? OutlinedButton.icon(
            onPressed: enabled ? onAction : null,
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(action),
          )
        : FilledButton.icon(
            onPressed: enabled ? onAction : null,
            icon: busy
                ? _ActionProgress(reducedMotion: AppMotion.reduce(context))
                : Icon(
                    status == 'available'
                        ? Icons.download_rounded
                        : Icons.refresh_rounded,
                  ),
            label: Text(action),
          );
    return button;
  }

  static (String, Color) _statusLabel(String value, bool systemManaged) {
    if (systemManaged) return ('System managed', AppTheme.secondaryText);
    return switch (value) {
      'checking' => ('Checking', AppTheme.warning),
      'savingChannel' => ('Saving choice', AppTheme.warning),
      'available' => ('Update available', AppTheme.accent),
      'downloading' => ('Downloading', AppTheme.warning),
      'staging' => ('Staging', AppTheme.warning),
      'readyToRestart' => ('Ready to restart', AppTheme.success),
      'upToDate' => ('Up to date', AppTheme.success),
      'newerInstalled' => ('Installed is newer', AppTheme.secondaryText),
      'stableUnavailable' => ('Stable package unavailable', AppTheme.muted),
      'error' => ('Update failed', AppTheme.danger),
      'unconfigured' => ('Not configured', AppTheme.muted),
      _ => ('Not checked', AppTheme.muted),
    };
  }

  static Widget _engineStatusContent(
    EngineUpdateService updates,
    EngineRelease? release,
    String loadedVersion,
    bool systemManaged,
    bool linux,
  ) {
    if (systemManaged) {
      return _TrackNotice(
        icon: Icons.inventory_2_outlined,
        color: AppTheme.secondaryText,
        text: linux
            ? 'On Linux, the system package manager owns libmpv. Update it through your distribution.'
            : 'The operating system manages updates for this playback engine.',
      );
    }

    final rollbackPending = updates.pendingRollback;

    return switch (updates.status) {
      'unconfigured' when updates.configurationError != null => _TrackNotice(
        icon: Icons.error_outline_rounded,
        color: AppTheme.danger,
        text:
            'Engine update checks are disabled: ${updates.configurationError}',
      ),
      'unconfigured' => const _TrackNotice(
        icon: Icons.info_outline_rounded,
        color: AppTheme.muted,
        text: 'Engine update checks are not configured for this build.',
      ),
      'checking' => const _TrackNotice(
        icon: Icons.sync_rounded,
        color: AppTheme.accent,
        text: 'Checking for a playback engine update…',
      ),
      'savingChannel' => const _TrackNotice(
        icon: Icons.sync_rounded,
        color: AppTheme.accent,
        text: 'Saving the engine update channel…',
      ),
      'stableUnavailable' => _TrackNotice(
        icon: Icons.info_outline_rounded,
        color: AppTheme.muted,
        text: updates.stableReleaseVersion == null
            ? 'The latest mpv stable release does not publish a compatible Windows libmpv package. Mpvson will keep using the currently loaded engine.'
            : 'mpv ${updates.stableReleaseVersion} does not publish a compatible Windows libmpv package. Mpvson will keep using the currently loaded engine.',
      ),
      'upToDate' => const _TrackNotice(
        icon: Icons.check_circle_outline_rounded,
        color: AppTheme.success,
        text: 'The loaded playback engine matches the selected source.',
      ),
      'newerInstalled' => _TrackNotice(
        icon: Icons.arrow_upward_rounded,
        color: AppTheme.secondaryText,
        text:
            'The loaded engine version $loadedVersion is newer than the latest version from this source (${release?.engineVersion ?? 'unknown'}). Mpvson will not downgrade it.',
      ),
      'available' => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            updates.usesOfficialMpvSource
                ? updates.channel == EngineUpdateChannel.stable
                      ? release == null || release.engineVersion.trim().isEmpty
                            ? 'An upstream mpv stable engine release is available.'
                            : 'Upstream mpv stable engine version ${release.engineVersion} is available.'
                      : release == null || release.engineVersion.trim().isEmpty
                      ? 'An upstream mpv development build is available.'
                      : 'Upstream mpv development build ${release.engineVersion} is available.'
                : release == null || release.engineVersion.trim().isEmpty
                ? 'A playback engine update is available.'
                : 'Engine version ${release.engineVersion} is available.',
            style: const TextStyle(color: AppTheme.secondaryText, height: 1.45),
          ),
          if (release != null && release.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              release.notes,
              style: const TextStyle(color: AppTheme.muted, height: 1.45),
            ),
          ],
        ],
      ),
      'downloading' => _ProgressDetail(
        title: updates.pendingVersion == null
            ? 'Downloading the playback engine…'
            : 'Downloading engine version ${updates.pendingVersion}…',
        progress: updates.progress,
      ),
      'staging' => _ProgressDetail(
        title: 'Staging the playback engine…',
        progress: updates.progress,
      ),
      'readyToRestart' => _TrackNotice(
        icon: Icons.restart_alt_rounded,
        color: AppTheme.success,
        text: updates.pendingBundled
            ? 'Restart Mpvson to use the bundled engine. The player currently has $loadedVersion loaded.'
            : rollbackPending
            ? 'Restart Mpvson to roll back to engine version ${updates.pendingVersion}. The player currently has $loadedVersion loaded.'
            : 'Restart Mpvson to activate the staged engine. The player currently has $loadedVersion loaded.',
      ),
      'error' when updates.error != null => _TrackNotice(
        icon: Icons.error_outline_rounded,
        color: AppTheme.danger,
        text: updates.error!,
      ),
      'systemManaged' => const _TrackNotice(
        icon: Icons.inventory_2_outlined,
        color: AppTheme.secondaryText,
        text: 'The operating system manages updates for this playback engine.',
      ),
      _ => const _TrackNotice(
        icon: Icons.memory_rounded,
        color: AppTheme.secondaryText,
        text: 'Check for a playback engine update.',
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Update channel', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      SegmentedButton<EngineUpdateChannel>(
        segments: const [
          ButtonSegment(
            value: EngineUpdateChannel.stable,
            label: Text('Stable'),
            icon: Icon(Icons.verified_outlined),
          ),
          ButtonSegment(
            value: EngineUpdateChannel.development,
            label: Text('Development'),
            icon: Icon(Icons.science_outlined),
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
            ? 'Stable releases are recommended. The updater checks for a compatible Windows libmpv package.'
            : 'Development follows mpv master. mpv marks these builds as untested.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: updates.channel == EngineUpdateChannel.development
              ? AppTheme.warning
              : AppTheme.secondaryText,
          height: 1.4,
        ),
      ),
    ],
  );
}

class _ReleaseTrack extends StatelessWidget {
  const _ReleaseTrack({
    required this.railColor,
    required this.icon,
    required this.title,
    required this.status,
    required this.statusColor,
    required this.currentLabel,
    required this.content,
  });

  final Color railColor;
  final IconData icon;
  final String title;
  final String status;
  final Color statusColor;
  final String currentLabel;
  final Widget content;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 0, 10),
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: railColor, width: 3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 21, color: railColor),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _StatusPill(status: status, color: statusColor),
          ],
        ),
        const SizedBox(height: 5),
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Text(
            currentLabel,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 10),
        Padding(padding: const EdgeInsets.only(left: 30), child: content),
      ],
    ),
  );
}

class _AppReleaseDetails extends StatelessWidget {
  const _AppReleaseDetails({required this.release});

  final ReleaseInfo release;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Version ${release.version} is available',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppTheme.secondaryText),
      ),
      if (release.notes.trim().isNotEmpty) ...[
        const SizedBox(height: 7),
        Text(
          release.notes,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.45),
        ),
      ],
      const SizedBox(height: 7),
      const _TrackNotice(
        icon: Icons.shield_outlined,
        color: AppTheme.secondaryText,
        text: 'Mpvson checks the downloaded package against its SHA-256 hash.',
      ),
    ],
  );
}

class _ProgressDetail extends StatelessWidget {
  const _ProgressDetail({required this.title, required this.progress});

  final String title;
  final double progress;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 9),
      LinearProgressIndicator(
        value: progress > 0
            ? progress.clamp(0, 1).toDouble()
            : AppMotion.reduce(context)
            ? 0
            : null,
        minHeight: 4,
        borderRadius: BorderRadius.circular(5),
      ),
      if (progress > 0) ...[
        const SizedBox(height: 5),
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
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: AnimatedSwitcher(
      duration: AppMotion.duration(context, AppMotion.quick),
      child: Text(
        status,
        key: ValueKey<String>(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
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
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.45),
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
        : const CircularProgressIndicator(
            strokeWidth: 2,
            color: AppTheme.accentForeground,
          ),
  );
}
