import 'package:flutter/material.dart';

import '../../../../ui/core/app_motion.dart';
import 'seek_preview.dart';

/// Hosts the seek hover bubble in the [Overlay] so the mini-player card
/// cannot clip or squash it.
class SeekPreviewLayer extends StatefulWidget {
  const SeekPreviewLayer({
    super.key,
    required this.left,
    required this.lift,
    required this.visible,
    required this.preview,
    required this.child,
  });

  final double left;
  final double lift;
  final bool visible;
  final Widget preview;
  final Widget child;

  @override
  State<SeekPreviewLayer> createState() => _SeekPreviewLayerState();
}

class _SeekPreviewLayerState extends State<SeekPreviewLayer> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: Offset(widget.left, -widget.lift),
        child: UnconstrainedBox(
          alignment: Alignment.bottomLeft,
          child: IgnorePointer(
            child: AnimatedSwitcher(
              duration: AppMotion.duration(context, AppMotion.quick),
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              layoutBuilder: SeekPreview.switchLayout,
              transitionBuilder: (child, animation) =>
                  SeekPreview.switchTransition(context, child, animation),
              child: widget.visible
                  ? KeyedSubtree(
                      key: const ValueKey('seek-preview'),
                      child: widget.preview,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(link: _link, child: widget.child),
    );
  }
}
