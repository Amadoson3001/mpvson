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
      backgroundColor: context.palette.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        side: BorderSide(color: context.palette.border),
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
      title: Text(
        'What should happen when you open new files?',
        style: TextStyle(
          color: context.palette.primaryText,
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
            Text(
              'You can change this anytime in Settings > Desktop integration > Opening files.',
              style: TextStyle(
                color: context.palette.secondaryText,
                fontSize: AppType.small,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: context.palette.deepBackground,
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
                foregroundColor: context.palette.primaryText,
                side: BorderSide(color: context.palette.border),
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
