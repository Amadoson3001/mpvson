import 'package:flutter/material.dart';
import '../../../data/repositories/app_preferences_repository.dart';
import '../../core/app_theme.dart';

/// Shows the first-conflict opening preference dialog.
class OpenPreferenceDialog extends StatelessWidget {
  const OpenPreferenceDialog({super.key});

  static Future<OpenBehaviorPreference?> show(BuildContext context) {
    return showDialog<OpenBehaviorPreference>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const OpenPreferenceDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.border),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: const Text(
        'What should happen when you open new files?',
        style: TextStyle(
          color: AppTheme.primaryText,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'You can change this anytime in Settings, under General.',
              style: TextStyle(
                color: AppTheme.secondaryText,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: AppTheme.deepBackground,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.of(
                  context,
                ).pop(OpenBehaviorPreference.keepPlayingAndEnqueue);
              },
              icon: const Icon(Icons.playlist_add_rounded, size: 20),
              label: const Text(
                'Keep playing and add to queue',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryText,
                side: const BorderSide(color: AppTheme.border),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.of(
                  context,
                ).pop(OpenBehaviorPreference.playNewFilesNow);
              },
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text(
                'Play new files now',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
