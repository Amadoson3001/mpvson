import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/models/media_catalog.dart';
import '../../../domain/models/media_entry.dart';
import '../../../domain/models/stream_playback_state.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/toast/app_toast.dart';
import '../../core/toast/toast_layout.dart';
import '../player_controller.dart';

const double _maxLoadingCardWidth = 384;
const Duration _localLoadRevealDelay = Duration(milliseconds: 180);
const Duration _bufferingRevealDelay = Duration(milliseconds: 250);

/// Maps current transport and stream lifecycle states into concise sentence-case
/// loading labels for UI indicators.
String? resolveLoadingStageLabel({
  required TransportState transport,
  required MediaEntry? entry,
}) {
  final stream = transport.streamPlaybackState;
  final stageMessage = stream.stageMessage?.trim();
  final hasStageMessage = stageMessage != null && stageMessage.isNotEmpty;

  switch (stream.stage) {
    case StreamStage.resolving:
      return hasStageMessage ? stageMessage : 'Resolving link';
    case StreamStage.connecting:
      return hasStageMessage ? stageMessage : 'Connecting';
    case StreamStage.buffering:
      return hasStageMessage ? stageMessage : 'Buffering';
    case StreamStage.reconnecting:
      return hasStageMessage ? stageMessage : 'Reconnecting';
    case StreamStage.switchingQuality:
      return hasStageMessage ? stageMessage : 'Switching quality';
    case StreamStage.idle:
    case StreamStage.ready:
    case StreamStage.failed:
      break;
  }

  if (transport.isLoading) {
    final isNetwork =
        entry != null && MediaEntry.isBufferedNetworkSource(entry.path);
    return isNetwork ? 'Opening stream' : 'Opening file';
  }
  if (transport.isBuffering) {
    return 'Buffering';
  }
  return null;
}

/// Formats a compact, readable subtitle describing the source being loaded.
String? formatLoadingSourceLabel(
  MediaEntry? entry,
  StreamPlaybackState streamState,
) {
  final resolvedTitle = streamState.resolvedTitle?.trim();
  if (resolvedTitle != null && resolvedTitle.isNotEmpty) {
    return resolvedTitle;
  }

  final entryPath = entry?.path ?? '';
  final networkUrl = MediaEntry.isNetworkUrl(entryPath)
      ? entryPath
      : (streamState.originalUrl.isNotEmpty ? streamState.originalUrl : null);

  if (networkUrl != null) {
    final uri = Uri.tryParse(networkUrl);
    if (uri != null) {
      final nonEmptySegments = uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList(growable: false);
      if (nonEmptySegments.isNotEmpty) {
        String lastSegment;
        try {
          lastSegment = Uri.decodeComponent(nonEmptySegments.last);
        } catch (_) {
          lastSegment = nonEmptySegments.last;
        }
        final lower = lastSegment.toLowerCase();
        if (MediaCatalog.isSupportedFile(lastSegment) ||
            lower.endsWith('.m3u8') ||
            lower.endsWith('.mpd')) {
          return lastSegment;
        }
      }
      final host = uri.host.trim();
      if (host.isNotEmpty) {
        return host.startsWith('www.') ? host.substring(4) : host;
      }
    }
  }

  final title = entry?.title.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  return null;
}

/// Minimalist floating slate shown while opening a stream or file from the
/// library view, without shifting underlying grid/list geometry.
class PlayerLoadingBanner extends StatelessWidget {
  const PlayerLoadingBanner({
    super.key,
    required this.stageLabel,
    this.sourceLabel,
    this.onCancel,
  });

  final String stageLabel;
  final String? sourceLabel;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final reduce = AppMotion.reduce(context);
    final lowPower = AppMotion.lowPower(context);
    final semanticLabel = sourceLabel != null && sourceLabel!.isNotEmpty
        ? '$stageLabel: $sourceLabel'
        : stageLabel;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxLoadingCardWidth),
      child: Semantics(
        liveRegion: true,
        container: true,
        label: semanticLabel,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              color: palette.card.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              border: Border.all(
                color: palette.borderStrong.withValues(alpha: 0.78),
              ),
              boxShadow: lowPower
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
                    11,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 16,
                        child: RepaintBoundary(
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            value: reduce ? 0.72 : null,
                            color: palette.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              stageLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: palette.rowPrimary.copyWith(
                                fontSize: AppType.small,
                                fontWeight: FontWeight.w500,
                                height: 1.3,
                              ),
                            ),
                            if (sourceLabel != null &&
                                sourceLabel!.isNotEmpty) ...[
                              const SizedBox(height: 1),
                              Text(
                                sourceLabel!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: palette.rowPrimary.copyWith(
                                  fontSize: 12,
                                  color: palette.secondaryText,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (onCancel != null) ...[
                        const SizedBox(width: AppSpace.xs),
                        TextButton(
                          onPressed: onCancel,
                          style: TextButton.styleFrom(
                            foregroundColor: palette.secondaryText,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 28),
                            maximumSize: const Size(double.infinity, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                            ),
                            textStyle: const TextStyle(
                              fontFamily: AppType.family,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ],
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
                      child: LinearProgressIndicator(
                        value: reduce ? 0.45 : null,
                        backgroundColor: Colors.transparent,
                        color: palette.accent.withValues(alpha: 0.7),
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
  }
}

/// Coordinates a floating [PlayerLoadingBanner] above the library shell when a
/// stream or file is opening in the background.
class PlayerLoadingOverlay extends StatefulWidget {
  const PlayerLoadingOverlay({
    super.key,
    required this.controller,
    required this.visible,
  });

  final PlayerController controller;
  final bool visible;

  @override
  State<PlayerLoadingOverlay> createState() => _PlayerLoadingOverlayState();
}

class _PlayerLoadingOverlayState extends State<PlayerLoadingOverlay>
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
  Listenable? _controllerEvents;
  Timer? _delayTimer;
  bool _showing = false;
  bool _measureScheduled = false;
  bool _disposed = false;
  String? _renderedStageLabel;
  String? _renderedSourceLabel;

  @override
  void initState() {
    super.initState();
    _enter.addStatusListener(_handleAnimationStatus);
    _bindController(widget.controller);
    _syncState(notify: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextLayout = AppToastScope.maybeOf(context)?.layout;
    if (!identical(_layout, nextLayout)) {
      _layout?.releasePinnedHeight(_pinnedKey);
      _layout = nextLayout;
    }
    final reduced = AppMotion.reduce(context);
    _enter.duration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.toast);
    _enter.reverseDuration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.toastExit);
    if (_showing) {
      if (AppMotion.lowPower(context)) {
        _enter.value = 1;
      } else if (_enter.status != AnimationStatus.forward &&
          _enter.status != AnimationStatus.completed) {
        _enter.forward();
      }
    }
  }

  @override
  void didUpdateWidget(covariant PlayerLoadingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _bindController(widget.controller);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.visible != widget.visible) {
      _syncState(notify: false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _delayTimer?.cancel();
    _delayTimer = null;
    _controllerEvents?.removeListener(_onControllerChanged);
    _controllerEvents = null;
    _enter.removeStatusListener(_handleAnimationStatus);
    _enterCurve.dispose();
    _enter.dispose();
    _layout?.releasePinnedHeight(_pinnedKey);
    super.dispose();
  }

  void _bindController(PlayerController controller) {
    _controllerEvents?.removeListener(_onControllerChanged);
    _controllerEvents = Listenable.merge(<Listenable>[
      controller.transportListenable,
      controller.structureListenable,
    ]);
    _controllerEvents!.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (!mounted || _disposed) return;
    _syncState(notify: true);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !_showing) {
      _layout?.releasePinnedHeight(_pinnedKey);
      if (mounted) {
        setState(() {
          _renderedStageLabel = null;
          _renderedSourceLabel = null;
        });
      }
    }
  }

  void _syncState({required bool notify}) {
    final transport = widget.controller.transportState;
    final entry = widget.controller.current;
    final wantsVisible = widget.visible && transport.isLoading;

    if (!wantsVisible) {
      final timerWasPending = _delayTimer != null;
      _delayTimer?.cancel();
      _delayTimer = null;
      if (!_showing) {
        if (timerWasPending && notify && mounted) setState(() {});
        return;
      }
      _showing = false;
      _layout?.releasePinnedHeight(_pinnedKey);
      final lowPower = mounted && _tryLowPower();
      if (lowPower) {
        _enter.value = 0;
        _renderedStageLabel = null;
        _renderedSourceLabel = null;
      } else {
        _enter.reverse();
      }
      if (notify && mounted) setState(() {});
      return;
    }

    final stageLabel =
        resolveLoadingStageLabel(transport: transport, entry: entry) ??
        'Opening stream';
    final sourceLabel = formatLoadingSourceLabel(
      entry,
      transport.streamPlaybackState,
    );
    final labelsChanged =
        stageLabel != _renderedStageLabel ||
        sourceLabel != _renderedSourceLabel;

    final isNetwork =
        transport.isStreaming ||
        (entry != null && MediaEntry.isBufferedNetworkSource(entry.path));

    if (_showing) {
      _renderedStageLabel = stageLabel;
      _renderedSourceLabel = sourceLabel;
      if (labelsChanged && notify && mounted) setState(() {});
      return;
    }

    if (isNetwork) {
      _delayTimer?.cancel();
      _delayTimer = null;
      _renderedStageLabel = stageLabel;
      _renderedSourceLabel = sourceLabel;
      _revealNow(notify: notify);
      return;
    }

    _delayTimer ??= Timer(_localLoadRevealDelay, () {
      _delayTimer = null;
      if (!mounted || _disposed) return;
      final latest = widget.controller.transportState;
      final latestEntry = widget.controller.current;
      if (!widget.visible || !latest.isLoading) return;
      _renderedStageLabel =
          resolveLoadingStageLabel(transport: latest, entry: latestEntry) ??
          'Opening file';
      _renderedSourceLabel = formatLoadingSourceLabel(
        latestEntry,
        latest.streamPlaybackState,
      );
      _revealNow(notify: true);
    });
  }

  void _revealNow({required bool notify}) {
    _showing = true;
    final lowPower = mounted && _tryLowPower();
    if (lowPower) {
      _enter.value = 1;
    } else if (_enter.status != AnimationStatus.forward &&
        _enter.status != AnimationStatus.completed) {
      _enter.forward();
    }
    if (notify && mounted) setState(() {});
  }

  bool _tryLowPower() {
    try {
      return AppMotion.lowPower(context);
    } catch (_) {
      return false;
    }
  }

  void _scheduleMeasure() {
    if (_measureScheduled || _disposed) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted || _disposed) return;
      if (!_showing) {
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
    final stageLabel = _renderedStageLabel;
    if (stageLabel == null) {
      return const Positioned(
        left: 0,
        top: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }

    if (_showing) {
      _scheduleMeasure();
    }

    final layout = _layout;
    if (layout != null) {
      return ListenableBuilder(
        listenable: layout,
        builder: (context, _) => _buildPositioned(
          context,
          stageLabel,
          _renderedSourceLabel,
          layout.rects,
        ),
      );
    }
    return _buildPositioned(
      context,
      stageLabel,
      _renderedSourceLabel,
      const <Rect>[],
    );
  }

  Widget _buildPositioned(
    BuildContext context,
    String stageLabel,
    String? sourceLabel,
    List<Rect> regions,
  ) {
    final media = MediaQuery.of(context);
    final geometry = _resolveGeometry(media, regions);
    final slideUp = geometry.alignment.y > 0;
    final skipMotion = AppMotion.lowPower(context);

    final banner = KeyedSubtree(
      key: _cardKey,
      child: PlayerLoadingBanner(
        stageLabel: stageLabel,
        sourceLabel: sourceLabel,
        onCancel: () => unawaited(widget.controller.cancelLoading()),
      ),
    );

    final animated = skipMotion
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
        ignoring: !_showing,
        child: Align(
          alignment: geometry.alignment,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: geometry.maxWidth),
            child: animated,
          ),
        ),
      ),
    );
  }

  ToastGeometry _resolveGeometry(MediaQueryData media, List<Rect> regions) {
    if (_layout != null) {
      return resolveToastGeometry(
        screen: media.size,
        safe: media.viewPadding,
        regions: regions,
        maxWidth: _maxLoadingCardWidth,
      );
    }
    final safe = media.viewPadding;
    final available =
        media.size.width - safe.left - safe.right - AppSpace.md * 2;
    final maxWidth = math.min(_maxLoadingCardWidth, math.max(160.0, available));
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

enum _StageOverlayMode { none, initialLoad, statusPill }

/// Displays clean, cinema-native loading and buffering feedback directly over
/// the player stage:
/// - Centered spinner + stage copy + Cancel during initial unattached loads.
/// - Compact top-center quality-switch pill or center buffering/reconnecting
///   pill during active playback, staying clear of bottom subtitles.
class PlayerStageLoadingOverlay extends StatefulWidget {
  const PlayerStageLoadingOverlay({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<PlayerStageLoadingOverlay> createState() =>
      _PlayerStageLoadingOverlayState();
}

class _PlayerStageLoadingOverlayState extends State<PlayerStageLoadingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AppMotion.toast,
    reverseDuration: AppMotion.toastExit,
  );
  late final CurvedAnimation _fadeCurve = CurvedAnimation(
    parent: _fade,
    curve: AppMotion.enter,
    reverseCurve: AppMotion.exit,
  );
  Listenable? _controllerEvents;
  Timer? _delayTimer;
  bool _disposed = false;

  _StageOverlayMode _activeMode = _StageOverlayMode.none;
  _StageOverlayMode _pendingMode = _StageOverlayMode.none;
  _StageOverlayMode _renderedMode = _StageOverlayMode.none;
  String? _renderedStageLabel;
  String? _renderedSourceLabel;
  bool _renderedTopAligned = false;

  @override
  void initState() {
    super.initState();
    _fade.addStatusListener(_handleFadeStatus);
    _bindController(widget.controller);
    _syncState(notify: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduce(context);
    _fade.duration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.toast);
    _fade.reverseDuration = reduced
        ? Duration.zero
        : AppMotion.scaled(context, AppMotion.toastExit);
    if (_activeMode != _StageOverlayMode.none) {
      if (AppMotion.lowPower(context)) {
        _fade.value = 1;
      } else if (_fade.status != AnimationStatus.forward &&
          _fade.status != AnimationStatus.completed) {
        _fade.forward();
      }
    }
  }

  @override
  void didUpdateWidget(covariant PlayerStageLoadingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _bindController(widget.controller);
      _syncState(notify: false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _delayTimer?.cancel();
    _delayTimer = null;
    _controllerEvents?.removeListener(_onControllerChanged);
    _controllerEvents = null;
    _fade.removeStatusListener(_handleFadeStatus);
    _fadeCurve.dispose();
    _fade.dispose();
    super.dispose();
  }

  void _bindController(PlayerController controller) {
    _controllerEvents?.removeListener(_onControllerChanged);
    _controllerEvents = Listenable.merge(<Listenable>[
      controller.transportListenable,
      controller.structureListenable,
    ]);
    _controllerEvents!.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (!mounted || _disposed) return;
    _syncState(notify: true);
  }

  void _handleFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        _activeMode == _StageOverlayMode.none &&
        mounted) {
      setState(() {
        _renderedMode = _StageOverlayMode.none;
        _renderedStageLabel = null;
        _renderedSourceLabel = null;
      });
    }
  }

  ({
    _StageOverlayMode mode,
    Duration delay,
    String? stageLabel,
    String? sourceLabel,
    bool topAligned,
  })
  _evaluateSnapshot() {
    final controller = widget.controller;
    final transport = controller.transportState;
    final stage = transport.streamStage;
    final entry = controller.current;

    if (!controller.hasMedia && transport.isLoading) {
      final immediate =
          transport.isStreaming ||
          (entry != null && MediaEntry.isBufferedNetworkSource(entry.path));
      return (
        mode: _StageOverlayMode.initialLoad,
        delay: immediate ? Duration.zero : _localLoadRevealDelay,
        stageLabel:
            resolveLoadingStageLabel(transport: transport, entry: entry) ??
            'Opening media',
        sourceLabel: formatLoadingSourceLabel(
          entry,
          transport.streamPlaybackState,
        ),
        topAligned: false,
      );
    }

    if (controller.hasMedia &&
        (transport.isBuffering ||
            stage == StreamStage.reconnecting ||
            stage == StreamStage.switchingQuality)) {
      final immediate =
          stage == StreamStage.reconnecting ||
          stage == StreamStage.switchingQuality;
      return (
        mode: _StageOverlayMode.statusPill,
        delay: immediate ? Duration.zero : _bufferingRevealDelay,
        stageLabel:
            resolveLoadingStageLabel(transport: transport, entry: entry) ??
            'Buffering',
        sourceLabel: null,
        topAligned: stage == StreamStage.switchingQuality,
      );
    }

    return (
      mode: _StageOverlayMode.none,
      delay: Duration.zero,
      stageLabel: null,
      sourceLabel: null,
      topAligned: false,
    );
  }

  void _syncState({required bool notify}) {
    final evaluated = _evaluateSnapshot();
    if (evaluated.mode == _StageOverlayMode.none) {
      final hadPending = _delayTimer != null;
      _delayTimer?.cancel();
      _delayTimer = null;
      _pendingMode = _StageOverlayMode.none;
      if (_activeMode == _StageOverlayMode.none) {
        if (hadPending && notify && mounted) setState(() {});
        return;
      }
      _activeMode = _StageOverlayMode.none;
      if (mounted && _tryLowPower()) {
        _fade.value = 0;
        _renderedMode = _StageOverlayMode.none;
        _renderedStageLabel = null;
        _renderedSourceLabel = null;
      } else {
        _fade.reverse();
      }
      if (notify && mounted) setState(() {});
      return;
    }

    if (evaluated.delay == Duration.zero || _activeMode == evaluated.mode) {
      _delayTimer?.cancel();
      _delayTimer = null;
      _pendingMode = evaluated.mode;
      final changed =
          _activeMode != evaluated.mode ||
          _renderedMode != evaluated.mode ||
          _renderedStageLabel != evaluated.stageLabel ||
          _renderedSourceLabel != evaluated.sourceLabel ||
          _renderedTopAligned != evaluated.topAligned;
      _activeMode = evaluated.mode;
      _renderedMode = evaluated.mode;
      _renderedStageLabel = evaluated.stageLabel;
      _renderedSourceLabel = evaluated.sourceLabel;
      _renderedTopAligned = evaluated.topAligned;
      _revealNow();
      if (changed && notify && mounted) setState(() {});
      return;
    }

    if (_pendingMode != evaluated.mode) {
      _delayTimer?.cancel();
      _pendingMode = evaluated.mode;
      _delayTimer = Timer(evaluated.delay, () {
        _delayTimer = null;
        if (!mounted || _disposed) return;
        final latest = _evaluateSnapshot();
        if (latest.mode != evaluated.mode) {
          _syncState(notify: true);
          return;
        }
        _pendingMode = latest.mode;
        _activeMode = latest.mode;
        _renderedMode = latest.mode;
        _renderedStageLabel = latest.stageLabel;
        _renderedSourceLabel = latest.sourceLabel;
        _renderedTopAligned = latest.topAligned;
        _revealNow();
        setState(() {});
      });
    }
  }

  void _revealNow() {
    if (mounted && _tryLowPower()) {
      _fade.value = 1;
    } else if (_fade.status != AnimationStatus.forward &&
        _fade.status != AnimationStatus.completed) {
      _fade.forward();
    }
  }

  bool _tryLowPower() {
    try {
      return AppMotion.lowPower(context);
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_renderedMode == _StageOverlayMode.none ||
        _renderedStageLabel == null) {
      return const SizedBox.shrink();
    }

    final reduce = AppMotion.reduce(context);
    final skipMotion = AppMotion.lowPower(context);
    final accent = Theme.of(context).colorScheme.primary;
    final active = _activeMode != _StageOverlayMode.none;

    final Widget content = switch (_renderedMode) {
      _StageOverlayMode.none => const SizedBox.shrink(),
      _StageOverlayMode.initialLoad => _buildInitialLoadOverlay(
        context,
        accent: accent,
        reduce: reduce,
        stageLabel: _renderedStageLabel!,
        sourceLabel: _renderedSourceLabel,
      ),
      _StageOverlayMode.statusPill => _buildStatusPill(
        context,
        accent: accent,
        reduce: reduce,
        stageLabel: _renderedStageLabel!,
        topAligned: _renderedTopAligned,
      ),
    };

    final animated = skipMotion
        ? RepaintBoundary(child: content)
        : FadeTransition(
            opacity: _fadeCurve,
            child: RepaintBoundary(child: content),
          );

    if (!active) {
      return IgnorePointer(child: animated);
    }
    return animated;
  }

  Widget _buildInitialLoadOverlay(
    BuildContext context, {
    required Color accent,
    required bool reduce,
    required String stageLabel,
    required String? sourceLabel,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        child: Semantics(
          liveRegion: true,
          container: true,
          label: sourceLabel != null && sourceLabel.isNotEmpty
              ? '$stageLabel: $sourceLabel'
              : stageLabel,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 28,
                      child: RepaintBoundary(
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          value: reduce ? 0.72 : null,
                          color: accent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      stageLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: AppTheme.onStage,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (sourceLabel != null && sourceLabel.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: Text(
                          sourceLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall?.copyWith(
                            color: AppTheme.onStage.withValues(alpha: 0.68),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => unawaited(widget.controller.cancelLoading()),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.onStage.withValues(alpha: 0.88),
                  side: BorderSide(
                    color: AppTheme.onStage.withValues(alpha: 0.18),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 32),
                  maximumSize: const Size(double.infinity, 32),
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
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPill(
    BuildContext context, {
    required Color accent,
    required bool reduce,
    required String stageLabel,
    required bool topAligned,
  }) {
    final pill = Semantics(
      liveRegion: true,
      container: true,
      label: stageLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.layer.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: AppTheme.onStage.withValues(alpha: 0.14)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 14,
                child: RepaintBoundary(
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    value: reduce ? 0.72 : null,
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  stageLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.onStage,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return IgnorePointer(
      child: topAligned
          ? Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 64),
                child: pill,
              ),
            )
          : Center(child: pill),
    );
  }
}
