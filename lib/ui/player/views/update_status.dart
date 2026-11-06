import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../../data/services/engine_update_service.dart';
import '../../../data/services/update_service.dart';
import '../../core/app_theme.dart';

/// True when libmpv is managed outside the app's own updater.
bool engineSystemManaged(EngineUpdateService updates) =>
    defaultTargetPlatform == TargetPlatform.linux ||
    !updates.selfManaged ||
    updates.status == 'systemManaged';

(String label, Color color) appUpdateStatusPresentation(
  BuildContext context,
  UpdateService updates,
) => switch (updates.status) {
  'checking' => ('Checking', context.palette.warning),
  'available' => ('Update available', Theme.of(context).colorScheme.primary),
  'downloading' => ('Downloading', context.palette.warning),
  'ready' => ('Downloaded', context.palette.success),
  'upToDate' => ('Up to date', context.palette.success),
  // A failed check means the current version could not be verified; only a
  // failed download is an actual update failure.
  'error' => updates.failedDuringDownload
      ? ('Update failed', context.palette.danger)
      : ('Check failed', context.palette.danger),
  'unconfigured' => ('Not configured', context.palette.muted),
  _ => ('Not checked', context.palette.muted),
};

(String label, Color color) engineUpdateStatusPresentation(
  BuildContext context,
  EngineUpdateService updates,
) {
  if (engineSystemManaged(updates)) {
    return ('System managed', context.palette.secondaryText);
  }
  return switch (updates.status) {
    'checking' => ('Checking', context.palette.warning),
    'savingChannel' => ('Saving choice', context.palette.warning),
    'available' => ('Update ready', Theme.of(context).colorScheme.primary),
    'downloading' => ('Downloading', context.palette.warning),
    'staging' => ('Staging', context.palette.warning),
    'readyToRestart' => ('Ready to restart', context.palette.success),
    'upToDate' => ('Up to date', context.palette.success),
    'newerInstalled' => ('Installed is newer', context.palette.secondaryText),
    'stableUnavailable' => ('Channel fallback', context.palette.muted),
    // A failed check leaves the loaded engine untouched; only a download or
    // staging failure is an actual update failure.
    'error' => updates.failedDuringDownload
        ? ('Update failed', context.palette.danger)
        : ('Check failed', context.palette.danger),
    'unconfigured' => ('Not configured', context.palette.muted),
    _ => ('Ready', context.palette.success),
  };
}

class UpdateStatusPill extends StatelessWidget {
  const UpdateStatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(AppRadii.pill),
      border: Border.all(color: color.withValues(alpha: 0.38), width: 1),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 11.5,
        letterSpacing: 0.1,
      ),
    ),
  );
}
