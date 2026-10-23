import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../theme/library_theme.dart';

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

  Widget _buildScanningBanner(BuildContext context, LibraryScanStatus status) {
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
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: LibraryTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: LibraryTheme.accent.withValues(alpha: 0.4)),
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
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    LibraryTheme.accent,
                  ),
                  backgroundColor: LibraryTheme.border,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  phaseLabel,
                  style: LibraryTheme.rowPrimary.copyWith(
                    fontWeight: FontWeight.w600,
                    color: LibraryTheme.primaryText,
                  ),
                ),
              ),
              Text(
                countDetails,
                style: LibraryTheme.metadata.copyWith(
                  color: LibraryTheme.secondaryText,
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16),
                tooltip: 'Stop scan',
                visualDensity: VisualDensity.compact,
                color: LibraryTheme.mutedText,
                hoverColor: LibraryTheme.hover,
                onPressed: () => repository.cancelScan(),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: LibraryTheme.border,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  LibraryTheme.accent,
                ),
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
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: LibraryTheme.raisedSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: LibraryTheme.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: LibraryTheme.warning,
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
                        style: LibraryTheme.rowPrimary.copyWith(
                          color: LibraryTheme.warning,
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
                        color: LibraryTheme.warning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Items preserved',
                        style: LibraryTheme.badge.copyWith(
                          fontSize: 10,
                          color: LibraryTheme.warning,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Your library entries are preserved and will automatically become playable when reconnected.',
                  style: LibraryTheme.metadata,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
