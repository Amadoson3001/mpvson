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
  final ValueNotifier<({bool hovered, bool pressed})> _interaction =
      ValueNotifier<({bool hovered, bool pressed})>((
        hovered: false,
        pressed: false,
      ));

  @override
  void dispose() {
    _interaction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.lowPower(context);
    final artworkStack = ClipRRect(
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
    );
    final artworkCard = widget.aspectRatio != null
        ? AspectRatio(aspectRatio: widget.aspectRatio!, child: artworkStack)
        : artworkStack;

    return Semantics(
      button: true,
      container: true,
      label: widget.subtitle.isEmpty
          ? widget.title
          : '${widget.title}, ${widget.subtitle}',
      child: InkWell(
        onTap: widget.onTap,
        onHover: (hovering) {
          final current = _interaction.value;
          if (current.hovered != hovering) {
            _interaction.value = (hovered: hovering, pressed: current.pressed);
          }
        },
        onHighlightChanged: (highlighted) {
          final current = _interaction.value;
          if (current.pressed != highlighted) {
            _interaction.value = (
              hovered: current.hovered,
              pressed: highlighted,
            );
          }
        },
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: RepaintBoundary(
                child: reduced
                    ? artworkCard
                    : ValueListenableBuilder<({bool hovered, bool pressed})>(
                        valueListenable: _interaction,
                        child: artworkCard,
                        builder: (context, state, child) {
                          final scale = state.pressed
                              ? 0.98
                              : (state.hovered ? 1.02 : 1.0);
                          final duration = AppMotion.duration(
                            context,
                            state.pressed ? AppMotion.press : AppMotion.hover,
                          );
                          return AnimatedScale(
                            scale: scale,
                            duration: duration,
                            curve: AppMotion.enter,
                            child: child,
                          );
                        },
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
