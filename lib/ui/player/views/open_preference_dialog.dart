import 'package:flutter/material.dart';
import '../../../data/repositories/app_preferences_repository.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_dialog.dart';

/// Shows the first-conflict opening preference dialog.
class OpenPreferenceDialog extends StatelessWidget {
  const OpenPreferenceDialog({super.key});

  static Future<OpenBehaviorPreference?> show(BuildContext context) {
    return AppDialog.show<OpenBehaviorPreference>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const OpenPreferenceDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AppDialog(
      maxWidth: 440,
      title: Text(
        'What should happen when you open new files?',
        style: TextStyle(
          color: context.palette.primaryText,
          fontSize: AppType.title,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Column(
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
          const SizedBox(height: AppSpace.md),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: context.palette.accentForeground,
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
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
          const SizedBox(height: AppSpace.sm),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: context.palette.primaryText,
              side: BorderSide(color: context.palette.border),
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ),
            onPressed: () {
              Navigator.of(context).pop(OpenBehaviorPreference.playNewFilesNow);
            },
            child: const Text(
              'Play new files now',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
