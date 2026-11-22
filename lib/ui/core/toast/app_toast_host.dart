import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../tokens/motion.dart';
import 'app_toast.dart';
import 'toast_layout.dart';

/// Mounts the toast layer above the whole application.
///
/// The layer only ever occupies the corner the geometry resolver picks, so
/// pointer events everywhere else reach the interface underneath untouched.
class AppToastHost extends StatefulWidget {
  const AppToastHost({super.key, required this.child});

  final Widget child;

  @override
  State<AppToastHost> createState() => _AppToastHostState();
}

class _AppToastHostState extends State<AppToastHost> {
  final AppToastController _controller = AppToastController();
  final ToastLayoutState _layout = ToastLayoutState();

  @override
  void dispose() {
    _controller.dispose();
    _layout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppToastScope(
      controller: _controller,
      layout: _layout,
      // The stack is always present so the application below keeps its element
      // identity; only the toast layer inside it comes and goes.
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final entries = _controller.entries;
          // The toast layer mounts above the Navigator's Overlay, so widgets
          // rendered inside a toast (tooltips, menus) find no Overlay ancestor.
          // This one backs them. It is window-sized and never fades or
          // unmounts with a card, so portal children cannot be orphaned
          // mid-animation (flutter/flutter#190357).
          return Overlay.wrap(
            child: Stack(
              children: [
                Positioned.fill(child: widget.child),
                if (entries.isNotEmpty)
                  ListenableBuilder(
                    listenable: _layout,
                    builder: (context, _) {
                      final media = MediaQuery.of(context);
                      final geometry = resolveToastGeometry(
                        screen: media.size,
                        safe: media.viewPadding,
                        regions: _layout.rects,
                      );
                      final rawPinnedOffset = _layout.pinnedHeight > 0
                          ? _layout.pinnedHeight + AppSpace.xs
                          : 0.0;
                      final maxExtraOffset = math.max(
                        0.0,
                        media.size.height - geometry.insets.vertical - 80,
                      );
                      final pinnedOffset = math.min(
                        rawPinnedOffset,
                        maxExtraOffset,
                      );
                      final insets = geometry.insets.copyWith(
                        bottom: geometry.alignment.y > 0
                            ? geometry.insets.bottom + pinnedOffset
                            : geometry.insets.bottom,
                        top: geometry.alignment.y <= 0
                            ? geometry.insets.top + pinnedOffset
                            : geometry.insets.top,
                      );
                      return Positioned(
                        left: insets.left,
                        top: insets.top,
                        right: insets.right,
                        bottom: insets.bottom,
                        child: Align(
                          alignment: geometry.alignment,
                          child: _ToastStack(
                            entries: entries,
                            controller: _controller,
                            maxWidth: geometry.maxWidth,
                            slideUp: geometry.alignment.y > 0,
                            alignEnd: geometry.alignment.x > 0,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ToastStack extends StatelessWidget {
  const _ToastStack({
    required this.entries,
    required this.controller,
    required this.maxWidth,
    required this.slideUp,
    required this.alignEnd,
  });

  final List<AppToastEntry> entries;
  final AppToastController controller;
  final double maxWidth;
  final bool slideUp;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    // Newest last, so it sits closest to the corner it grows from.
    final ordered = entries.reversed.toList(growable: false);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: alignEnd
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < ordered.length; index++)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : AppSpace.xs),
              child: _ToastCard(
                key: ValueKey<int>(ordered[index].id),
                entry: ordered[index],
                controller: controller,
                slideUp: slideUp,
              ),
            ),
        ],
      ),
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({
    super.key,
    required this.entry,
    required this.controller,
    required this.slideUp,
  });

  final AppToastEntry entry;
  final AppToastController controller;
  final bool slideUp;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: AppMotion.toast,
    reverseDuration: AppMotion.toastExit,
  );
  late final CurvedAnimation _enterCurve = CurvedAnimation(
    parent: _enter,
    curve: AppMotion.enter,
    reverseCurve: AppMotion.exit,
  );
  late final Animation<double> _scaleAnimation = Tween<double>(
    begin: 0.97,
    end: 1.0,
  ).animate(_enterCurve);
  late final Animation<Offset> _slideUpOffset = Tween<Offset>(
    begin: const Offset(0, 0.22),
    end: Offset.zero,
  ).animate(_enterCurve);
  late final Animation<Offset> _slideDownOffset = Tween<Offset>(
    begin: const Offset(0, -0.22),
    end: Offset.zero,
  ).animate(_enterCurve);
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  Timer? _countdown;
  late Duration _remaining = widget.entry.request.duration;
  bool _hovered = false;
  bool _leaving = false;
  bool _enterLaunched = false;

  static const Duration _tick = Duration(milliseconds: 16);

  @override
  void initState() {
    super.initState();
    widget.entry.pulse.addListener(_restart);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduce(context);
    final lowPower = AppMotion.lowPower(context);
    _enter.duration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.toast);
    _enter.reverseDuration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.toastExit);
    if (!_enterLaunched) {
      _enterLaunched = true;
      if (!widget.entry.dismissing) {
        if (lowPower) {
          _enter.value = 1;
        } else {
          _enter.forward();
        }
        _startCountdown();
      }
    } else if (lowPower && !_leaving && _enter.value < 1) {
      _enter.value = 1;
    }
    if (widget.entry.dismissing) _leave();
  }

  @override
  void didUpdateWidget(covariant _ToastCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != widget.entry) {
      oldWidget.entry.pulse.removeListener(_restart);
      widget.entry.pulse.addListener(_restart);
    }
    if (widget.entry.dismissing) _leave();
  }

  @override
  void dispose() {
    widget.entry.pulse.removeListener(_restart);
    _countdown?.cancel();
    _enterCurve.dispose();
    _enter.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _restart() {
    _progress.value = 0;
    _remaining = widget.entry.request.duration;
    if (!_hovered && !_leaving) _startCountdown();
  }

  void _startCountdown() {
    _countdown?.cancel();
    _countdown = Timer.periodic(_tick, _onTick);
  }

  void _onTick(Timer timer) {
    _remaining -= _tick;
    if (_remaining <= Duration.zero) {
      timer.cancel();
      _progress.value = 1;
      _leave();
      return;
    }
    _progress.value =
        1 -
        _remaining.inMilliseconds /
            widget.entry.request.duration.inMilliseconds;
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    if (value) {
      _countdown?.cancel();
    } else if (!_leaving) {
      _startCountdown();
    }
  }

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    _countdown?.cancel();
    widget.controller.requestDismiss(widget.entry.id);
    if (AppMotion.lowPower(context)) {
      _enter.value = 0;
      if (mounted) widget.controller.completeDismiss(widget.entry.id);
      return;
    }
    _enter.reverse().then((_) {
      if (mounted) widget.controller.completeDismiss(widget.entry.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.entry.request;
    final palette = context.palette;
    final accent = _accentFor(request.tone);
    final reduced = AppMotion.lowPower(context);
    final borderColor = switch (request.tone) {
      AppToastTone.danger || AppToastTone.warning => Color.lerp(
        palette.borderStrong,
        accent,
        palette.isDark ? 0.28 : 0.34,
      )!,
      AppToastTone.neutral ||
      AppToastTone.success => palette.borderStrong.withValues(alpha: 0.72),
    };

    final card = MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Semantics(
        liveRegion: true,
        container: true,
        label: request.message,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              color: palette.card.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              border: Border.all(color: borderColor),
              boxShadow: reduced
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: palette.isDark ? 0.36 : 0.10,
                        ),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.sm,
                    10,
                    AppSpace.xs,
                    10,
                  ),
                  child: Row(
                    children: [
                      Icon(_iconFor(request.tone), size: 16, color: accent),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          request.message,
                          style: palette.rowPrimary.copyWith(
                            fontSize: AppType.small,
                            height: 1.35,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (request.actionLabel != null &&
                          request.onAction != null) ...[
                        const SizedBox(width: AppSpace.xxs),
                        _ToastAction(
                          label: request.actionLabel!,
                          accent: accent,
                          onPressed: () {
                            final action = request.onAction!;
                            _leave();
                            action();
                          },
                        ),
                      ],
                      const SizedBox(width: AppSpace.xxs),
                      _ToastClose(visible: _hovered, onPressed: _leave),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SizedBox(
                    height: 1.5,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _ToastProgressPainter(
                          progress: _progress,
                          color: accent.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (reduced) return RepaintBoundary(child: card);
    return FadeTransition(
      opacity: _enterCurve,
      alwaysIncludeSemantics: true,
      child: SlideTransition(
        position: widget.slideUp ? _slideUpOffset : _slideDownOffset,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: RepaintBoundary(child: card),
        ),
      ),
    );
  }

  Color _accentFor(AppToastTone tone) => switch (tone) {
    AppToastTone.neutral => context.palette.secondaryText,
    AppToastTone.success => context.palette.success,
    AppToastTone.warning => context.palette.warning,
    AppToastTone.danger => context.palette.danger,
  };

  IconData _iconFor(AppToastTone tone) => switch (tone) {
    AppToastTone.neutral => Icons.info_outline_rounded,
    AppToastTone.success => Icons.check_circle_outline_rounded,
    AppToastTone.warning => Icons.warning_amber_rounded,
    AppToastTone.danger => Icons.error_outline_rounded,
  };
}

class _ToastAction extends StatelessWidget {
  const _ToastAction({
    required this.label,
    required this.accent,
    required this.onPressed,
  });

  final String label;
  final Color accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: accent,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xxs,
      ),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      textStyle: const TextStyle(
        fontFamily: AppType.family,
        fontSize: AppType.caption,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    ),
    child: Text(label),
  );
}

class _ToastClose extends StatelessWidget {
  const _ToastClose({required this.visible, required this.onPressed});

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return IconButton(
      onPressed: onPressed,
      tooltip: 'Dismiss',
      style: IconButton.styleFrom(
        minimumSize: const Size.square(28),
        maximumSize: const Size.square(28),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: visible
            ? palette.text
            : palette.secondaryText.withValues(alpha: 0.72),
        hoverColor: palette.hover,
        focusColor: palette.hover,
        highlightColor: palette.hover,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
      ),
      icon: const Icon(Icons.close_rounded, size: 15),
    );
  }
}

class _ToastProgressPainter extends CustomPainter {
  const _ToastProgressPainter({required this.progress, required this.color})
    : super(repaint: progress);

  final ValueListenable<double> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final remaining = (1.0 - progress.value).clamp(0.0, 1.0);
    if (remaining <= 0.0 || size.width <= 0 || size.height <= 0) return;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * remaining, size.height),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _ToastProgressPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
