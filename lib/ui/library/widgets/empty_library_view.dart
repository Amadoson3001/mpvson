import 'package:flutter/material.dart';
import '../theme/library_theme.dart';

/// Empty state widget for the library or specific empty views.
class EmptyLibraryView extends StatelessWidget {
  const EmptyLibraryView({
    super.key,
    this.title = 'Your library is empty',
    this.message =
        'Add your media folders to browse and play your local music, albums, and video collection.',
    this.actionLabel = 'Add folders',
    this.onAction,
    this.icon = Icons.folder_open_rounded,
  });

  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Container(
            padding: const EdgeInsets.all(36),
            decoration: BoxDecoration(
              color: LibraryTheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: LibraryTheme.border, width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: LibraryTheme.raisedSurface,
                    shape: BoxShape.circle,
                    border: Border.all(color: LibraryTheme.border),
                  ),
                  child: Icon(icon, size: 30, color: LibraryTheme.accent),
                ),
                const SizedBox(height: 24),
                Text(
                  title,
                  style: LibraryTheme.albumTitle,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: LibraryTheme.rowSecondary.copyWith(
                    color: LibraryTheme.secondaryText,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (onAction != null) ...[
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: LibraryTheme.accent,
                      foregroundColor: LibraryTheme.background,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: onAction,
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: Text(actionLabel),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
