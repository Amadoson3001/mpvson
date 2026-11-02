import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

class PlayerErrorBanner extends StatelessWidget {
  const PlayerErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.md,
      vertical: AppSpace.xs,
    ),
    color: context.palette.danger.withValues(alpha: 0.12),
    child: Row(
      children: [
        Icon(
          Icons.error_outline_rounded,
          color: context.palette.danger,
          size: AppSpace.md,
        ),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.palette.secondaryText,
            ),
          ),
        ),
      ],
    ),
  );
}
