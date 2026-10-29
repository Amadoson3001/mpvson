import 'dart:async';
import 'dart:ui' as ui;

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
          return Stack(
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
                    return Positioned(
                      left: geometry.insets.left,
                      top: geometry.insets.top,
                      right: geometry.insets.right,
                      bottom: geometry.insets.bottom,
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
  );
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  Timer? _countdown;
  late Duration _remaining = widget.entry.request.duration;
  bool _hovered = false;
  bool _leaving = false;

  static const Duration _tick = Duration(milliseconds: 40);

  @override
  void initState() {
    super.initState();
    widget.entry.pulse.addListener(_restart);
    if (!widget.entry.dismissing) {
      _enter.forward();
      _startCountdown();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduce(context)) {
      _enter.duration = Duration.zero;
      if (_enter.value < 1) _enter.value = 1;
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
    final exit = AppMotion.duration(context, AppMotion.toast);
    if (!AppMotion.reduce(context)) _enter.reverse();
    Future<void>.delayed(exit).then((_) {
      if (mounted) widget.controller.completeDismiss(widget.entry.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.entry.request;
    final accent = _accentFor(request.tone);
    final reduced = AppMotion.reduce(context);

    final card = MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Semantics(
        liveRegion: true,
        container: true,
        label: request.message,
        child: Material(
          type: MaterialType.transparency,
          // The shadow sits outside the clip so it is not cut away.
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.artwork + 2),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.stage.withValues(alpha: 0.45),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.artwork + 2),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.card.withValues(alpha: 0.92),
                    border: Border.all(
                      color: AppTheme.borderStrong.withValues(alpha: 0.75),
                    ),
                  ),
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          3,
                          AppSpace.sm,
                          AppSpace.xs,
                          AppSpace.sm,
                        ),
                        child: Row(
                          children: [
                            _ToneRail(color: accent),
                            const SizedBox(width: AppSpace.sm),
                            Icon(
                              _iconFor(request.tone),
                              size: 17,
                              color: accent,
                            ),
                            const SizedBox(width: AppSpace.sm),
                            Flexible(
                              child: Text(
                                request.message,
                                style: AppTheme.rowPrimary.copyWith(
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
                            _ToastClose(visible: _hovered, onPressed: _leave),
                          ],
                        ),
                      ),
                      ValueListenableBuilder<double>(
                        valueListenable: _progress,
                        builder: (context, value, _) => Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: SizedBox(
                            height: 2,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: (1 - value).clamp(0.0, 1.0),
                                child: Container(
                                  color: accent.withValues(alpha: 0.55),
                                ),
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
          ),
        ),
      ),
    );

    if (reduced) return card;
    return AnimatedBuilder(
      animation: _enter,
      builder: (context, child) {
        final progress = Curves.easeOutCubic
            .transform(_enter.value.clamp(0.0, 1.0))
            .clamp(0.0, 1.0);
        final travel = widget.slideUp ? 12 : -12;
        return Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset(0, (1 - progress) * travel),
            child: Transform.scale(scale: 0.98 + 0.02 * progress, child: child),
          ),
        );
      },
      child: card,
    );
  }

  Color _accentFor(AppToastTone tone) => switch (tone) {
    AppToastTone.neutral => AppTheme.secondaryText,
    AppToastTone.success => AppTheme.success,
    AppToastTone.warning => AppTheme.warning,
    AppToastTone.danger => AppTheme.danger,
  };

  IconData _iconFor(AppToastTone tone) => switch (tone) {
    AppToastTone.neutral => Icons.info_outline_rounded,
    AppToastTone.success => Icons.check_circle_outline_rounded,
    AppToastTone.warning => Icons.warning_amber_rounded,
    AppToastTone.danger => Icons.error_outline_rounded,
  };
}

class _ToneRail extends StatelessWidget {
  const _ToneRail({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 3,
    height: 30,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(2),
    ),
  );
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
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Dismiss',
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xs),
        child: Icon(
          Icons.close_rounded,
          size: 15,
          color: visible ? AppTheme.text : AppTheme.faint,
        ),
      ),
    ),
  );
}
