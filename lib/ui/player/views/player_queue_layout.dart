import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';

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
  });

  final Widget playerArea;
  final Widget queuePanel;
  final bool showPlayerQueue;
  final bool queueMounted;
  final VoidCallback onToggleQueue;
  final VoidCallback onCloseQueue;
  final VoidCallback onQueueExitEnd;

  @override
  State<PlayerQueueLayout> createState() => _PlayerQueueLayoutState();
}

class _PlayerQueueLayoutState extends State<PlayerQueueLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _open;
  late final CurvedAnimation _progress;

  @override
  void initState() {
    super.initState();
    _open = AnimationController(
      vsync: this,
      value: widget.showPlayerQueue ? 1.0 : 0.0,
    )..addStatusListener(_handleOpenStatus);
    _progress = CurvedAnimation(
      parent: _open,
      curve: AppMotion.panelEnterCurve,
      reverseCurve: AppMotion.exit,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduce(context);
    // An entering side panel needs room to decelerate; a leaving one can snap.
    _open.duration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.panelEnter);
    _open.reverseDuration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.panelExit);
  }

  @override
  void didUpdateWidget(covariant PlayerQueueLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showPlayerQueue == widget.showPlayerQueue) return;
    if (widget.showPlayerQueue) {
      _open.forward();
    } else {
      _open.reverse();
    }
  }

  @override
  void dispose() {
    _open.removeStatusListener(_handleOpenStatus);
    _progress.dispose();
    _open.dispose();
    super.dispose();
  }

  void _handleOpenStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    // The parent unmounts the panel from here. A zero-length reverse finishes
    // inside our own build phase, so hand the callback to the end of the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onQueueExitEnd();
    });
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
                    progress: _progress,
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
          animation: _progress,
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
              color: scrim.withValues(alpha: 0.6 * _progress.value),
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
          animation: _progress,
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
          builder: (context, child) => Transform.translate(
            offset: Offset((1 - _progress.value) * drawerWidth, 0),
            child: RepaintBoundary(child: child),
          ),
        ),
      ),
    ];
  }
}

/// Widens an inline slot while a fixed-width panel slides in from the right
/// edge as a single already-painted surface, so the video area shrinks in sync
/// and the panel never relayouts mid-transition.
class QueueSlideSlot extends StatelessWidget {
  const QueueSlideSlot({
    super.key,
    required this.progress,
    required this.child,
  });

  final Animation<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: progress,
    child: child,
    builder: (context, child) => ClipRect(
      child: Align(
        alignment: Alignment.centerLeft,
        widthFactor: progress.value,
        child: child,
      ),
    ),
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
