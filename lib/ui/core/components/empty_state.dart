import 'package:flutter/material.dart';
import '../app_theme.dart';

/// Empty state widget for the library or specific empty views.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.title = 'Your library is empty',
    this.message =
        'Add your media folders to browse and play your local music, albums, and video collection.',
    this.actionLabel,
    this.onAction,
    this.icon = Icons.folder_open_rounded,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.xl,
          vertical: 48,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppTheme.raisedSurface,
                  borderRadius: BorderRadius.circular(AppRadii.artwork),
                ),
                child: Icon(icon, size: 30, color: accent),
              ),
              const SizedBox(height: 24),
              Text(title, style: AppTheme.albumTitle),
              const SizedBox(height: 12),
              Text(
                message,
                style: AppTheme.rowSecondary.copyWith(
                  color: AppTheme.secondaryText,
                  height: 1.5,
                ),
              ),
              if (onAction != null && actionLabel != null) ...[
                const SizedBox(height: 28),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: AppTheme.background,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    textStyle: const TextStyle(
                      fontSize: AppType.small,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: onAction,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
