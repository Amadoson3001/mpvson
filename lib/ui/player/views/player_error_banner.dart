import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/toast/toast_layout.dart';

const double _maxErrorWidth = 440;
const Duration _copiedResetDelay = Duration(milliseconds: 1800);

/// Splits a raw playback error into a scannable headline and optional secondary
/// guidance/detail while keeping short or path-like messages intact.
({String headline, String? detail}) parsePlayerErrorMessage(String raw) {
  final normalized = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) {
    return (headline: '', detail: null);
  }

  final sentenceBreak = normalized.indexOf('. ');
  if (sentenceBreak >= 12 && sentenceBreak <= 96) {
    final detail = normalized.substring(sentenceBreak + 2).trim();
    if (detail.isNotEmpty) {
      return (
        headline: normalized.substring(0, sentenceBreak + 1),
        detail: detail,
      );
    }
  }

  final colonBreak = normalized.indexOf(': ');
  if (colonBreak >= 8 && colonBreak <= 72) {
    final prefix = normalized.substring(0, colonBreak).trim();
    final detail = normalized.substring(colonBreak + 2).trim();
    final isScheme =
        prefix.endsWith('http') ||
        prefix.endsWith('https') ||
        prefix.endsWith('file');
    if (!isScheme && prefix.isNotEmpty && detail.isNotEmpty) {
      return (headline: prefix, detail: detail);
    }
  }

  return (headline: normalized, detail: null);
}

/// Minimalist, theme-aware playback error card with optional Retry, Copy, and
/// explicit Dismiss actions.
class PlayerErrorBanner extends StatefulWidget {
  const PlayerErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.onDismiss,
  });

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  @override
  State<PlayerErrorBanner> createState() => _PlayerErrorBannerState();
}

class _PlayerErrorBannerState extends State<PlayerErrorBanner> {
  Timer? _copiedTimer;
  bool _copied = false;

  @override
  void didUpdateWidget(covariant PlayerErrorBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message &&
        (_copied || _copiedTimer != null)) {
      _copiedTimer?.cancel();
      _copiedTimer = null;
      _copied = false;
    }
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copyMessage() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.message));
    } catch (_) {
      // Clipboard access can be unavailable in headless test environments.
    }
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(_copiedResetDelay, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final lowPower = AppMotion.lowPower(context);
    final parsed = parsePlayerErrorMessage(widget.message);
    final headline = parsed.headline;
    final detail = parsed.detail;
    final isCompact = detail == null && headline.length <= 56;
    final borderColor = Color.lerp(
      palette.borderStrong,
      palette.danger,
      palette.isDark ? 0.30 : 0.36,
    )!;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxErrorWidth),
      child: Semantics(
        liveRegion: true,
        container: true,
        label: widget.message,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              color: palette.card.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              border: Border.all(color: borderColor),
              boxShadow: lowPower
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: palette.isDark ? 0.38 : 0.11,
                        ),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
            ),
            child: isCompact
                ? _buildCompactContent(palette, headline)
                : _buildStructuredContent(palette, headline, detail),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactContent(AppPalette palette, String headline) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.xs,
        AppSpace.xs,
        AppSpace.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, color: palette.danger, size: 16),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              headline,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: palette.rowPrimary.copyWith(
                fontSize: AppType.small,
                height: 1.35,
              ),
            ),
          ),
          if (widget.onRetry != null) ...[
            const SizedBox(width: 10),
            _ErrorRetryButton(palette: palette, onPressed: widget.onRetry!),
          ],
          if (widget.onDismiss != null) ...[
            const SizedBox(width: AppSpace.xxs),
            _ErrorDismissButton(palette: palette, onPressed: widget.onDismiss!),
          ],
        ],
      ),
    );
  }

  Widget _buildStructuredContent(
    AppPalette palette,
    String headline,
    String? detail,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, AppSpace.sm, 10, AppSpace.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.error_outline_rounded,
              color: palette.danger,
              size: 16,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: palette.rowPrimary.copyWith(
                    fontSize: AppType.small,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: palette.rowPrimary.copyWith(
                      fontSize: 12,
                      color: palette.secondaryText,
                      height: 1.4,
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Wrap(
                    spacing: AppSpace.xs,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (widget.onRetry != null)
                        _ErrorRetryButton(
                          palette: palette,
                          onPressed: widget.onRetry!,
                        ),
                      _ErrorCopyButton(
                        palette: palette,
                        copied: _copied,
                        onPressed: _copyMessage,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (widget.onDismiss != null) ...[
            const SizedBox(width: 6),
            _ErrorDismissButton(palette: palette, onPressed: widget.onDismiss!),
          ],
        ],
      ),
    );
  }
}

class _ErrorRetryButton extends StatelessWidget {
  const _ErrorRetryButton({required this.palette, required this.onPressed});

  final AppPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: palette.hover,
        foregroundColor: palette.text,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 28),
        maximumSize: const Size(double.infinity, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        textStyle: const TextStyle(
          fontFamily: AppType.family,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: const Text('Retry'),
    );
  }
}

class _ErrorCopyButton extends StatelessWidget {
  const _ErrorCopyButton({
    required this.palette,
    required this.copied,
    required this.onPressed,
  });

  final AppPalette palette;
  final bool copied;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final foreground = copied ? palette.success : palette.secondaryText;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
        minimumSize: const Size(0, 28),
        maximumSize: const Size(double.infinity, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        textStyle: const TextStyle(
          fontFamily: AppType.family,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            copied ? Icons.check_rounded : Icons.content_copy_rounded,
            size: 13,
            color: foreground,
          ),
          const SizedBox(width: 5),
          Text(copied ? 'Copied' : 'Copy'),
        ],
      ),
    );
  }
}

class _ErrorDismissButton extends StatelessWidget {
  const _ErrorDismissButton({required this.palette, required this.onPressed});

  final AppPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: 'Dismiss',
      style: IconButton.styleFrom(
        minimumSize: const Size.square(28),
        maximumSize: const Size.square(28),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: palette.secondaryText,
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

/// Floats [PlayerErrorBanner] inside free screen space (avoiding `ToastRegion`
/// chrome) without shifting the underlying layout, and reserves its height so
/// transient `AppToast` notifications stack cleanly above it.
class PlayerErrorOverlay extends StatefulWidget {
  const PlayerErrorOverlay({
    super.key,
    required this.message,
    this.onRetry,
    this.onDismiss,
  });

  final String? message;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  @override
  State<PlayerErrorOverlay> createState() => _PlayerErrorOverlayState();
}

class _PlayerErrorOverlayState extends State<PlayerErrorOverlay>
    with SingleTickerProviderStateMixin {
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
  late final Animation<Offset> _slideUp = Tween<Offset>(
    begin: const Offset(0, 0.16),
    end: Offset.zero,
  ).animate(_enterCurve);
  late final Animation<Offset> _slideDown = Tween<Offset>(
    begin: const Offset(0, -0.16),
    end: Offset.zero,
  ).animate(_enterCurve);
  final GlobalKey _cardKey = GlobalKey();
  final Object _pinnedKey = Object();

  ToastLayoutState? _layout;
  String? _renderedMessage;
  VoidCallback? _renderedOnRetry;
  bool _measureScheduled = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _enter.addStatusListener(_handleAnimationStatus);
    if (widget.message != null) {
      _renderedMessage = widget.message;
      _renderedOnRetry = widget.onRetry;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextLayout = AppToastScope.maybeOf(context)?.layout;
    if (!identical(_layout, nextLayout)) {
      _layout?.releasePinnedHeight(_pinnedKey);
      _layout = nextLayout;
    }
    final skipMotion = AppMotion.lowPower(context);
    final reduced = AppMotion.reduce(context);
    _enter.duration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.toast);
    _enter.reverseDuration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.toastExit);
    if (widget.message != null) {
      if (skipMotion) {
        _enter.value = 1;
      } else if (_enter.status != AnimationStatus.forward &&
          _enter.status != AnimationStatus.completed) {
        _enter.forward();
      }
    }
  }

  @override
  void didUpdateWidget(covariant PlayerErrorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final skipMotion = AppMotion.lowPower(context);
    if (widget.message != null) {
      _renderedMessage = widget.message;
      _renderedOnRetry = widget.onRetry;
      if (skipMotion) {
        _enter.value = 1;
      } else if (_enter.status != AnimationStatus.forward &&
          _enter.status != AnimationStatus.completed) {
        _enter.forward();
      }
    } else if (oldWidget.message != null) {
      _layout?.releasePinnedHeight(_pinnedKey);
      if (skipMotion) {
        _enter.value = 0;
        _renderedMessage = null;
        _renderedOnRetry = null;
      } else {
        _enter.reverse();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _enter.removeStatusListener(_handleAnimationStatus);
    _enterCurve.dispose();
    _enter.dispose();
    _layout?.releasePinnedHeight(_pinnedKey);
    super.dispose();
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && widget.message == null) {
      _layout?.releasePinnedHeight(_pinnedKey);
      if (mounted) {
        setState(() {
          _renderedMessage = null;
          _renderedOnRetry = null;
        });
      }
    }
  }

  void _scheduleMeasure() {
    if (_measureScheduled || _disposed) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted || _disposed) return;
      if (widget.message == null) {
        _layout?.releasePinnedHeight(_pinnedKey);
        return;
      }
      final box = _cardKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      _layout?.reportPinnedHeight(_pinnedKey, box.size.height);
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeMessage = _renderedMessage;
    if (activeMessage == null) {
      return const Positioned(
        left: 0,
        top: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }

    if (widget.message != null) {
      _scheduleMeasure();
    }

    final layout = _layout;
    if (layout != null) {
      return ListenableBuilder(
        listenable: layout,
        builder: (context, _) =>
            _buildPositioned(context, activeMessage, layout.rects),
      );
    }
    return _buildPositioned(context, activeMessage, const <Rect>[]);
  }

  Widget _buildPositioned(
    BuildContext context,
    String activeMessage,
    List<Rect> regions,
  ) {
    final media = MediaQuery.of(context);
    final geometry = layoutOrFallbackGeometry(media, regions);
    final slideUp = geometry.alignment.y > 0;
    final skipMotion = AppMotion.lowPower(context);

    final banner = KeyedSubtree(
      key: _cardKey,
      child: PlayerErrorBanner(
        message: activeMessage,
        onRetry: _renderedOnRetry,
        onDismiss: widget.onDismiss,
      ),
    );

    final animatedBanner = skipMotion
        ? RepaintBoundary(child: banner)
        : FadeTransition(
            opacity: _enterCurve,
            alwaysIncludeSemantics: true,
            child: SlideTransition(
              position: slideUp ? _slideUp : _slideDown,
              child: RepaintBoundary(child: banner),
            ),
          );

    return Positioned(
      left: geometry.insets.left,
      top: geometry.insets.top,
      right: geometry.insets.right,
      bottom: geometry.insets.bottom,
      child: IgnorePointer(
        ignoring: widget.message == null,
        child: Align(
          alignment: geometry.alignment,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: geometry.maxWidth),
            child: animatedBanner,
          ),
        ),
      ),
    );
  }

  ToastGeometry layoutOrFallbackGeometry(
    MediaQueryData media,
    List<Rect> regions,
  ) {
    if (_layout != null) {
      return resolveToastGeometry(
        screen: media.size,
        safe: media.viewPadding,
        regions: regions,
        maxWidth: _maxErrorWidth,
      );
    }
    final safe = media.viewPadding;
    final available =
        media.size.width - safe.left - safe.right - AppSpace.md * 2;
    final maxWidth = math.min(_maxErrorWidth, math.max(160.0, available));
    return ToastGeometry(
      insets: EdgeInsets.only(
        right: safe.right + AppSpace.md,
        bottom: safe.bottom + AppSpace.md,
      ),
      alignment: Alignment.bottomRight,
      maxWidth: maxWidth,
    );
  }
}
