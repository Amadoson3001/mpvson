import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../core/app_theme.dart';

/// Top banner that displays scanning progress or unavailable drive alerts.
class LibraryStatusBanner extends StatelessWidget {
  const LibraryStatusBanner({
    super.key,
    required this.repository,
    this.onRescan,
  });

  final MediaLibraryRepository repository;
  final VoidCallback? onRescan;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: repository,
      builder: (context, _) {
        final status = repository.scanStatus;
        final unavailableFolders = repository.folders
            .where((f) => !f.isAvailable)
            .toList();

        final banners = <Widget>[];

        if (repository.initializationError != null) {
          banners.add(
            _buildErrorBanner(
              'Could not open the library.',
              'Retry',
              () => repository.initialize(),
            ),
          );
        } else if (!repository.isReady) {
          banners.add(
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpace.md,
                AppSpace.xs,
                AppSpace.md,
                0,
              ),
              child: Text('Opening library...', style: AppTheme.metadata),
            ),
          );
        } else if (status.phase == ScanPhase.error) {
          banners.add(
            _buildErrorBanner(
              'Could not scan the library. Check the folders and try again.',
              'Rescan',
              onRescan,
            ),
          );
        }

        // 1. Scanning progress indicator
        if (status.isScanning) {
          banners.add(_buildScanningBanner(context, status));
        }

        // 2. Unavailable drive indicator (non-destructive status)
        if (unavailableFolders.isNotEmpty) {
          banners.add(
            _buildUnavailableDriveBanner(context, unavailableFolders),
          );
        }

        if (banners.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: banners,
        );
      },
    );
  }

  Widget _buildErrorBanner(
    String message,
    String action,
    VoidCallback? onAction,
  ) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.xs,
        AppSpace.md,
        AppSpace.xxs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppTheme.danger,
            size: 18,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: AppTheme.rowPrimary)),
          if (onAction != null)
            TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }

  Widget _buildScanningBanner(BuildContext context, LibraryScanStatus status) {
    final accent = Theme.of(context).colorScheme.primary;
    final String phaseLabel = switch (status.phase) {
      ScanPhase.discovering => 'Discovering files...',
      ScanPhase.enriching => 'Enriching metadata...',
      ScanPhase.reconciling => 'Reconciling library...',
      _ => 'Scanning...',
    };

    final double? progress = status.totalToEnrich > 0
        ? (status.enrichedCount / status.totalToEnrich).clamp(0.0, 1.0)
        : null;

    final countDetails = status.totalToEnrich > 0
        ? '${status.discoveredCount} discovered • ${status.enrichedCount} of ${status.totalToEnrich} enriched'
        : '${status.discoveredCount} items discovered';

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.sm,
        AppSpace.md,
        AppSpace.xxs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                  backgroundColor: AppTheme.border,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  phaseLabel,
                  style: AppTheme.rowPrimary.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryText,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  countDetails,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: AppTheme.metadata.copyWith(
                    color: AppTheme.secondaryText,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                tooltip: 'Stop scan',
                visualDensity: VisualDensity.compact,
                color: AppTheme.mutedText,
                hoverColor: AppTheme.hover,
                onPressed: () => repository.cancelScan(),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.control),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: AppTheme.border,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUnavailableDriveBanner(
    BuildContext context,
    List<LibraryFolderRecord> unavailableFolders,
  ) {
    final folderCount = unavailableFolders.length;
    final String folderText = folderCount == 1
        ? unavailableFolders.first.path
        : '$folderCount folders';

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.xs,
        AppSpace.md,
        AppSpace.xxs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: AppTheme.raisedSurface,
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: AppTheme.warning,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Drive unavailable ($folderText)',
                        style: AppTheme.rowPrimary.copyWith(
                          color: AppTheme.warning,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.warning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                      child: Text(
                        'Items preserved',
                        style: AppTheme.badge.copyWith(
                          fontSize: AppType.caption,
                          color: AppTheme.warning,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Your library entries are preserved and will automatically become playable when reconnected.',
                  style: AppTheme.metadata,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
