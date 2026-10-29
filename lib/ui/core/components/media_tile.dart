import 'package:flutter/material.dart';
import '../app_motion.dart';
import '../app_theme.dart';

/// Artwork with a title and a supporting line, used by collection grids.
///
/// Features low-cost, hardware-composited hover lift and tap spring feedback.
class MediaTile extends StatefulWidget {
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
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduce(context);
    final scale = reduced ? 1.0 : (_pressed ? 0.97 : (_hovered ? 1.03 : 1.0));
    final duration = AppMotion.duration(
      context,
      _pressed ? AppMotion.press : AppMotion.hover,
    );

    return InkWell(
      onTap: widget.onTap,
      onHover: (hovering) {
        if (_hovered != hovering) setState(() => _hovered = hovering);
      },
      onHighlightChanged: (highlighted) {
        if (_pressed != highlighted) setState(() => _pressed = highlighted);
      },
      borderRadius: BorderRadius.circular(AppRadii.artwork),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: RepaintBoundary(
              child: AnimatedScale(
                scale: scale,
                duration: duration,
                curve: AppMotion.enter,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.artwork),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.artwork,
                      if (widget.overlay != null)
                        Positioned(right: 8, bottom: 8, child: widget.overlay!),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: AppTheme.rowPrimary.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ?widget.trailing,
            ],
          ),
          const SizedBox(height: 2),
          Text(
            widget.subtitle,
            style: AppTheme.rowSecondary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
