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
    final accent = Theme.of(context).colorScheme.primary;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        side: const BorderSide(color: AppTheme.border),
      ),
      titlePadding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.sm,
      ),
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        20,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        20,
      ),
      title: const Text(
        'What should happen when you open new files?',
        style: TextStyle(
          color: AppTheme.primaryText,
          fontSize: AppType.title,
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
              'You can change this anytime in Settings > Desktop integration > Opening files.',
              style: TextStyle(
                color: AppTheme.secondaryText,
                fontSize: AppType.small,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: AppTheme.deepBackground,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
              ),
              onPressed: () {
                Navigator.of(
                  context,
                ).pop(OpenBehaviorPreference.keepPlayingAndEnqueue);
              },
              child: const Text(
                'Keep playing and add to queue',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryText,
                side: const BorderSide(color: AppTheme.border),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
              ),
              onPressed: () {
                Navigator.of(
                  context,
                ).pop(OpenBehaviorPreference.playNewFilesNow);
              },
              child: const Text(
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
