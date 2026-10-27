import 'package:flutter/material.dart';
import '../app_theme.dart';

/// Artwork with a title and a supporting line, used by collection grids.
class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.artwork,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.overlay,
  });
  final Widget artwork;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final Widget? overlay;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(AppRadii.artwork),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.artwork),
            child: Stack(
              fit: StackFit.expand,
              children: [
                artwork,
                if (overlay != null)
                  Positioned(right: 8, bottom: 8, child: overlay!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: AppTheme.rowPrimary.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: AppTheme.rowSecondary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}
