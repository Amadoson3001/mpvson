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
    this.aspectRatio = 1.0,
  });

  final Widget artwork;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final Widget? overlay;
  final double? aspectRatio;

  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.lowPower(context);
    final scale = reduced ? 1.0 : (_pressed ? 0.98 : (_hovered ? 1.02 : 1.0));
    final duration = AppMotion.duration(
      context,
      _pressed ? AppMotion.press : AppMotion.hover,
    );

    return Semantics(
      button: true,
      container: true,
      label: widget.subtitle.isEmpty
          ? widget.title
          : '${widget.title}, ${widget.subtitle}',
      child: InkWell(
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
                  child: widget.aspectRatio != null
                      ? AspectRatio(
                          aspectRatio: widget.aspectRatio!,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              AppRadii.artwork,
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                widget.artwork,
                                if (widget.overlay != null)
                                  Positioned(
                                    right: AppSpace.xs,
                                    bottom: AppSpace.xs,
                                    child: widget.overlay!,
                                  ),
                              ],
                            ),
                          ),
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadii.artwork),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              widget.artwork,
                              if (widget.overlay != null)
                                Positioned(
                                  right: AppSpace.xs,
                                  bottom: AppSpace.xs,
                                  child: widget.overlay!,
                                ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            Row(
              children: [
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      widget.title,
                      style: context.palette.rowPrimary.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                ?widget.trailing,
              ],
            ),
            const SizedBox(height: AppSpace.micro),
            ExcludeSemantics(
              child: Text(
                widget.subtitle,
                style: context.palette.rowSecondary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
