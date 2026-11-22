import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import 'queue_slide_transition.dart';

/// Places the queue beside the player on wide windows and over it on narrow
/// ones.
///
/// One animation value drives both presentations, so the panel always moves as
/// a single already-painted surface. The inline slot widens while the panel
/// keeps its fixed width and slides in from the right edge, which means the
/// queue never relayouts mid-transition and the video area is never resized in
/// a single jump.
class PlayerQueueLayout extends StatefulWidget {
  const PlayerQueueLayout({
    super.key,
    required this.playerArea,
    required this.queuePanel,
    required this.showPlayerQueue,
    required this.queueMounted,
    required this.onToggleQueue,
    required this.onCloseQueue,
    required this.onQueueExitEnd,
    this.onMotionActiveChanged,
  });

  final Widget playerArea;
  final Widget queuePanel;
  final bool showPlayerQueue;
  final bool queueMounted;
  final VoidCallback onToggleQueue;
  final VoidCallback onCloseQueue;
  final VoidCallback onQueueExitEnd;
  final ValueChanged<bool>? onMotionActiveChanged;

  @override
  State<PlayerQueueLayout> createState() => _PlayerQueueLayoutState();
}

class _PlayerQueueLayoutState extends State<PlayerQueueLayout>
    with SingleTickerProviderStateMixin {
  late final QueueSlideTransition _slide;

  @override
  void initState() {
    super.initState();
    _slide = QueueSlideTransition(
      vsync: this,
      initialOpen: widget.showPlayerQueue,
      onDismissed: () {
        if (mounted) widget.onQueueExitEnd();
      },
      onAnimatingChanged: (active) =>
          widget.onMotionActiveChanged?.call(active),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _slide.applyMotion(context);
  }

  @override
  void didUpdateWidget(covariant PlayerQueueLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showPlayerQueue == widget.showPlayerQueue) return;
    _slide.drive(widget.showPlayerQueue);
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= AppLayout.wideBreakpoint;
        final open = widget.showPlayerQueue;
        final present = open || widget.queueMounted;

        return Stack(
          children: [
            Row(
              children: [
                Expanded(child: widget.playerArea),
                if (wide && present)
                  QueueSlideSlot(
                    progress: _slide.progress,
                    child: _InlinePanel(open: open, panel: widget.queuePanel),
                  ),
              ],
            ),
            if (!wide && present)
              ..._buildDrawer(context, constraints.maxWidth, open),
          ],
        );
      },
    );
  }

  List<Widget> _buildDrawer(BuildContext context, double available, bool open) {
    final drawerWidth = available > 360.0 ? 360.0 : available;
    final scrim = context.palette.background;

    return [
      Positioned.fill(
        child: AnimatedBuilder(
          animation: _slide.progress,
          child: IgnorePointer(
            ignoring: !open,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onToggleQueue,
              child: const SizedBox.expand(),
            ),
          ),
          builder: (context, child) => DecoratedBox(
            decoration: BoxDecoration(
              color: scrim.withValues(alpha: 0.6 * _slide.progress.value),
            ),
            child: child,
          ),
        ),
      ),
      Positioned(
        top: 0,
        bottom: 0,
        right: 0,
        width: drawerWidth,
        child: AnimatedBuilder(
          animation: _slide.progress,
          child: RepaintBoundary(
            child: IgnorePointer(
              ignoring: !open,
              child: ExcludeSemantics(
                excluding: !open,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    boxShadow: AppMotion.lowPower(context)
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 18,
                              offset: const Offset(-6, 0),
                            ),
                          ],
                  ),
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape):
                          widget.onCloseQueue,
                    },
                    child: widget.queuePanel,
                  ),
                ),
              ),
            ),
          ),
          builder: (context, child) => Transform.translate(
            offset: Offset((1 - _slide.progress.value) * drawerWidth, 0),
            child: child,
          ),
        ),
      ),
    ];
  }
}

/// Widens an inline slot while a fixed-width panel slides in from the right
/// edge as a single already-painted surface, so the video area shrinks in sync
/// and the panel never relayouts mid-transition.
///
/// The animated [SizedBox] width reveals the slot; the child stays at
/// [AppLayout.queuePanelWidth] and is clipped horizontally. We avoid
/// [Align.widthFactor] on the panel itself so its layout constraints do not
/// change every frame during the transition.
class QueueSlideSlot extends StatelessWidget {
  const QueueSlideSlot({
    super.key,
    required this.progress,
    required this.child,
    this.panelWidth = AppLayout.queuePanelWidth,
  });

  final Animation<double> progress;
  final Widget child;
  final double panelWidth;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: progress,
    child: child,
    builder: (context, child) {
      final value = progress.value.clamp(0.0, 1.0);
      final visibleWidth = panelWidth * value;
      return SizedBox(
        width: visibleWidth,
        child: ClipRect(
          clipBehavior: value < 0.999 ? Clip.hardEdge : Clip.none,
          child: OverflowBox(
            maxWidth: panelWidth,
            alignment: Alignment.centerLeft,
            child: SizedBox(width: panelWidth, child: child),
          ),
        ),
      );
    },
  );
}

/// Holds the inline panel at its final width so widening the slot never
/// relayouts the queue while it slides.
class _InlinePanel extends StatelessWidget {
  const _InlinePanel({required this.open, required this.panel});

  final bool open;
  final Widget panel;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !open,
    child: ExcludeSemantics(
      excluding: !open,
      child: RepaintBoundary(
        child: SizedBox(width: AppLayout.queuePanelWidth, child: panel),
      ),
    ),
  );
}
