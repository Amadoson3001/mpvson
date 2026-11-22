import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_mark.dart';
import 'library_section.dart';

class _Destination {
  const _Destination(this.section, this.label, this.icon);

  final LibrarySection section;
  final String label;
  final IconData icon;
}

const _mainDestinations = [
  _Destination(LibrarySection.home, 'Home', Icons.home_rounded),
  _Destination(LibrarySection.videos, 'Videos', Icons.movie_rounded),
  _Destination(LibrarySection.music, 'Music', Icons.music_note_rounded),
  _Destination(
    LibrarySection.playlists,
    'Playlists',
    Icons.queue_music_rounded,
  ),
];

const _folders = _Destination(
  LibrarySection.folders,
  'Folders',
  Icons.folder_rounded,
);

const _settings = _Destination(
  LibrarySection.settings,
  'Settings',
  Icons.settings_rounded,
);

const double _collapseHeaderHeight = 48.0;
const double _navItemHeight = 40.0;
const double _navIconSize = 20.0;
const double _toggleButtonSize = 36.0;

const double _collapsedIconLeft =
    (AppLayout.sidebarCollapsed - AppSpace.xs * 2 - _navIconSize) / 2;
const double _expandedIconLeft = AppSpace.sm;
const double _expandedPillWidth = AppLayout.sidebarExpanded - AppSpace.xs * 2;
const double _expandedLabelSlotWidth =
    _expandedPillWidth -
    _expandedIconLeft -
    _navIconSize -
    AppSpace.sm -
    AppSpace.sm;

const double _collapsedButtonRight =
    (AppLayout.sidebarCollapsed - _toggleButtonSize) / 2;
const double _expandedButtonRight = AppSpace.xs;
const double _expandedHeaderTitleWidth =
    AppLayout.sidebarExpanded -
    (AppSpace.xs + AppSpace.sm) -
    (_expandedButtonRight + _toggleButtonSize + AppSpace.xs);

double _labelReveal(double progress) {
  final normalized = ((progress - 0.25) / 0.60).clamp(0.0, 1.0);
  return Curves.easeInOutCubic.transform(normalized);
}

/// Sidebar content: the full 208px list or the 64px icon rail.
///
/// Animates continuously with [expandProgress] (`0.0` collapsed -> `1.0`
/// expanded) so icons stay anchored, labels emerge smoothly inside clipped
/// fixed-width slots without wrapping, and the sliding indicator pill glides
/// between active destinations with spring physics.
class ShellSideNav extends StatefulWidget {
  const ShellSideNav({
    super.key,
    required this.section,
    required this.onSelect,
    required this.collapsed,
    required this.showSettings,
    this.onToggleCollapse,
    this.expandProgress,
  });

  final LibrarySection section;
  final ValueChanged<LibrarySection> onSelect;
  final bool collapsed;
  final bool showSettings;
  final VoidCallback? onToggleCollapse;
  final Animation<double>? expandProgress;

  @override
  State<ShellSideNav> createState() => _ShellSideNavState();
}

class _ShellSideNavState extends State<ShellSideNav>
    with SingleTickerProviderStateMixin {
  final GlobalKey _rootKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  final Map<LibrarySection, GlobalKey> _itemKeys = {
    for (final d in _mainDestinations) d.section: GlobalKey(),
    _folders.section: GlobalKey(),
    _settings.section: GlobalKey(),
  };

  late final AnimationController _pillTopController =
      AnimationController.unbounded(
        vsync: this,
        value: _estimateTop(widget.section, null),
      );

  static const Tolerance _pillTolerance = Tolerance(
    distance: 0.25,
    velocity: 1.0,
  );

  late Animation<double> _effectiveProgress;
  SpringDescription _indicatorSpring = AppMotion.indicatorSpring;
  bool _reducedMotion = false;
  double? _targetPillTop;
  double? _lastMaxHeight;
  int _pillGeneration = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _targetPillTop = _pillTopController.value;
    _effectiveProgress =
        widget.expandProgress ??
        AlwaysStoppedAnimation<double>(widget.collapsed ? 0.0 : 1.0);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncToMeasured(animate: false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = AppMotion.reduce(context);
    _indicatorSpring = AppMotion.scaledSpring(
      context,
      AppMotion.indicatorSpring,
    );
    if (_reducedMotion &&
        _pillTopController.isAnimating &&
        _targetPillTop != null) {
      _pillGeneration++;
      _pillTopController
        ..stop()
        ..value = _targetPillTop!;
    }
  }

  @override
  void didUpdateWidget(covariant ShellSideNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandProgress != widget.expandProgress ||
        (widget.expandProgress == null &&
            oldWidget.collapsed != widget.collapsed)) {
      _effectiveProgress =
          widget.expandProgress ??
          AlwaysStoppedAnimation<double>(widget.collapsed ? 0.0 : 1.0);
    }

    if (oldWidget.section != widget.section) {
      final hadSelection =
          _itemKeys.containsKey(oldWidget.section) &&
          oldWidget.section != LibrarySection.nowPlaying;
      if (!_hasSelection) {
        _pillGeneration++;
        _pillTopController.stop();
      } else if (!hadSelection || _reducedMotion) {
        _syncToMeasured(animate: false);
      } else {
        final measured = _measureItemRect(widget.section);
        if (measured != null) {
          _animatePillTo(measured.top);
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _syncToMeasured(animate: true);
          });
        }
      }
    } else if (oldWidget.showSettings != widget.showSettings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncToMeasured(animate: false);
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pillGeneration++;
    _pillTopController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasSelection) return;
    final measured = _measureItemRect(widget.section);
    if (measured == null) return;
    if (_pillTopController.isAnimating) {
      _animatePillTo(measured.top);
    } else if ((measured.top - _pillTopController.value).abs() > 0.1) {
      _targetPillTop = measured.top;
      _pillTopController.value = measured.top;
    }
  }

  Rect? _measureItemRect(LibrarySection section) {
    final itemKey = _itemKeys[section];
    if (itemKey == null) return null;
    final itemContext = itemKey.currentContext;
    final rootContext = _rootKey.currentContext;
    if (itemContext == null || rootContext == null) return null;

    final itemBox = itemContext.findRenderObject() as RenderBox?;
    final rootBox = rootContext.findRenderObject() as RenderBox?;
    if (itemBox == null ||
        rootBox == null ||
        !itemBox.hasSize ||
        !rootBox.hasSize) {
      return null;
    }

    final offset = itemBox.localToGlobal(Offset.zero, ancestor: rootBox);
    return offset & itemBox.size;
  }

  void _syncToMeasured({required bool animate}) {
    if (!mounted || !_hasSelection) return;
    final measured = _measureItemRect(widget.section);
    if (measured == null) return;

    if (!animate || _reducedMotion) {
      _pillGeneration++;
      _targetPillTop = measured.top;
      _pillTopController
        ..stop()
        ..value = measured.top;
      return;
    }

    if (_targetPillTop != null &&
        (_targetPillTop! - measured.top).abs() < 0.1 &&
        !_pillTopController.isAnimating) {
      return;
    }
    _animatePillTo(measured.top);
  }

  void _animatePillTo(double targetTop) {
    if (_reducedMotion) {
      _pillGeneration++;
      _targetPillTop = targetTop;
      _pillTopController
        ..stop()
        ..value = targetTop;
      return;
    }
    if ((_pillTopController.value - targetTop).abs() < 0.1 &&
        !_pillTopController.isAnimating) {
      _targetPillTop = targetTop;
      _pillTopController.value = targetTop;
      return;
    }
    _targetPillTop = targetTop;
    final generation = ++_pillGeneration;
    final simulation = SpringSimulation(
      _indicatorSpring,
      _pillTopController.value,
      targetTop,
      _pillTopController.velocity,
      tolerance: _pillTolerance,
    );
    _pillTopController.animateWith(simulation).then((_) {
      if (_disposed || generation != _pillGeneration) return;
      if (!_pillTopController.isAnimating &&
          (_pillTopController.value - targetTop).abs() > 0.001) {
        _pillTopController.value = targetTop;
      }
    });
  }

  double _estimateTop(LibrarySection section, double? maxHeight) {
    const itemStep = _navItemHeight + AppSpace.micro * 2;
    final headerOffset = widget.onToggleCollapse != null
        ? _collapseHeaderHeight
        : 0.0;
    final topPadding = widget.onToggleCollapse != null
        ? AppSpace.xs
        : AppSpace.sm;
    final baseTop = headerOffset + topPadding + AppSpace.micro;

    switch (section) {
      case LibrarySection.home:
        return baseTop;
      case LibrarySection.videos:
        return baseTop + itemStep;
      case LibrarySection.music:
        return baseTop + itemStep * 2;
      case LibrarySection.playlists:
        return baseTop + itemStep * 3;
      case LibrarySection.folders:
        return baseTop + itemStep * 4 + AppSpace.xs * 2 + 1.0;
      case LibrarySection.settings:
        if (maxHeight != null && maxHeight > 200) {
          return maxHeight - AppSpace.sm - _navItemHeight - AppSpace.micro;
        }
        return baseTop + itemStep * 5 + 34.0;
      case LibrarySection.nowPlaying:
        return baseTop;
    }
  }

  bool get _hasSelection =>
      _itemKeys.containsKey(widget.section) &&
      widget.section != LibrarySection.nowPlaying;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ColoredBox(
      color: palette.sidebar,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pillWidth = (constraints.maxWidth - AppSpace.xs * 2).clamp(
              0.0,
              double.infinity,
            );
            // Keep Settings pill aligned if the window height changed while idle.
            if (_hasSelection &&
                widget.section == LibrarySection.settings &&
                !_pillTopController.isAnimating &&
                _lastMaxHeight != constraints.maxHeight) {
              _lastMaxHeight = constraints.maxHeight;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _syncToMeasured(animate: false);
              });
            } else {
              _lastMaxHeight = constraints.maxHeight;
            }
            return AnimatedBuilder(
              animation: _effectiveProgress,
              builder: (context, _) {
                final t = _effectiveProgress.value.clamp(0.0, 1.0);
                return Stack(
                  key: _rootKey,
                  fit: StackFit.expand,
                  children: [
                    // 1. Sliding indicator pill behind items (GPU-translated)
                    if (_hasSelection)
                      Positioned(
                        top: 0,
                        left: AppSpace.xs,
                        width: pillWidth,
                        height: _navItemHeight,
                        child: AnimatedBuilder(
                          animation: _pillTopController,
                          child: RepaintBoundary(
                            child: IgnorePointer(
                              child: _SlidingNavIndicator(
                                accent: palette.accent,
                              ),
                            ),
                          ),
                          builder: (context, child) => Transform.translate(
                            offset: Offset(0, _pillTopController.value),
                            child: child,
                          ),
                        ),
                      ),

                    // 2. Navigation items column
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.onToggleCollapse != null)
                          _SidebarCollapseHeader(
                            collapsed: widget.collapsed,
                            progress: t,
                            onToggle: widget.onToggleCollapse!,
                          ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _scrollController,
                            padding: EdgeInsets.fromLTRB(
                              AppSpace.xs,
                              widget.onToggleCollapse != null
                                  ? AppSpace.xs
                                  : AppSpace.sm,
                              AppSpace.xs,
                              AppSpace.xs,
                            ),
                            child: _items(context, t),
                          ),
                        ),
                        if (widget.showSettings) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.xs,
                            ),
                            child: Divider(height: 1, color: palette.border),
                          ),
                          const SizedBox(height: AppSpace.xs),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpace.xs,
                              0,
                              AppSpace.xs,
                              AppSpace.sm,
                            ),
                            child: _item(_settings, t),
                          ),
                        ],
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _items(BuildContext context, double progress) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final d in _mainDestinations) _item(d, progress),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Divider(height: 1, color: context.palette.border),
      ),
      _item(_folders, progress),
    ],
  );

  Widget _item(_Destination d, double progress) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.micro),
    child: _NavItem(
      key: _itemKeys[d.section],
      destination: d,
      selected: widget.section == d.section,
      collapsed: widget.collapsed,
      progress: progress,
      onTap: () => widget.onSelect(d.section),
    ),
  );
}

class _SlidingNavIndicator extends StatelessWidget {
  const _SlidingNavIndicator({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.control);
    final lowPower = AppMotion.lowPower(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: lowPower
            ? null
            : [
                BoxShadow(
                  color: accent.withValues(alpha: 0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 1),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: ColoredBox(
          color: accent.withValues(alpha: 0.14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 3.0,
              height: double.infinity,
              color: accent,
            ),
          ),
        ),
      ),
    );
  }
}

/// Navigation drawer used below the medium breakpoint.
class ShellNavigationDrawer extends StatelessWidget {
  const ShellNavigationDrawer({
    super.key,
    required this.section,
    required this.onSelect,
    required this.showSettings,
  });

  final LibrarySection section;
  final ValueChanged<LibrarySection> onSelect;
  final bool showSettings;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Drawer(
      backgroundColor: palette.sidebar,
      width: 280,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.md,
                AppSpace.md,
                AppSpace.md,
                AppSpace.sm,
              ),
              child: Row(
                children: [
                  const AppMark(size: 32),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      'Mpvson',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: palette.primaryText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.border),
            Expanded(
              child: ShellSideNav(
                section: section,
                onSelect: onSelect,
                collapsed: false,
                showSettings: showSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    super.key,
    required this.destination,
    required this.selected,
    required this.collapsed,
    required this.progress,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final bool collapsed;
  final double progress;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.accent;
    final selected = widget.selected;
    final radius = BorderRadius.circular(AppRadii.control);
    final label = widget.destination.label;
    final t = widget.progress.clamp(0.0, 1.0);
    final reveal = _labelReveal(t);
    final iconLeft = lerpDouble(_collapsedIconLeft, _expandedIconLeft, t)!;
    final labelLeft = iconLeft + _navIconSize + AppSpace.sm;

    final unselectedColor = palette.primaryText.withValues(alpha: 0.75);
    final targetColor = selected ? accent : unselectedColor;

    Widget item = Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: widget.onTap,
          onFocusChange: (value) => setState(() => _focused = value),
          borderRadius: radius,
          hoverColor: palette.hover.withValues(alpha: selected ? 0.35 : 0.7),
          splashColor: accent.withValues(alpha: 0.12),
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: _focused ? Border.all(color: accent, width: 2) : null,
            ),
            child: SizedBox(
              height: _navItemHeight,
              child: TweenAnimationBuilder<Color?>(
                duration: AppMotion.scaled(context, AppMotion.effectsDefault),
                curve: Curves.easeOutCubic,
                tween: ColorTween(begin: targetColor, end: targetColor),
                builder: (context, iconColor, _) {
                  final effectiveIconColor = iconColor ?? targetColor;
                  final icon = Icon(
                    widget.destination.icon,
                    size: _navIconSize,
                    color: effectiveIconColor,
                  );

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        left: iconLeft,
                        top: 0,
                        bottom: 0,
                        child: Center(child: icon),
                      ),
                      if (reveal > 0.001)
                        Positioned(
                          left: labelLeft,
                          right: AppSpace.sm,
                          top: 0,
                          bottom: 0,
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: _expandedLabelSlotWidth,
                              maxWidth: _expandedLabelSlotWidth,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Opacity(
                                  opacity: reveal,
                                  child: Transform.translate(
                                    offset: Offset(-6.0 * (1.0 - reveal), 0.0),
                                    child: AnimatedDefaultTextStyle(
                                      duration: AppMotion.scaled(
                                        context,
                                        AppMotion.effectsDefault,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall!
                                          .copyWith(
                                            fontWeight: selected
                                                ? FontWeight.w600
                                                : FontWeight.w500,
                                            color: selected
                                                ? palette.primaryText
                                                : unselectedColor,
                                          ),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.ellipsis,
                                      child: Text(label),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.collapsed) {
      item = Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: item,
      );
    }
    return item;
  }
}

class _SidebarCollapseHeader extends StatelessWidget {
  const _SidebarCollapseHeader({
    required this.collapsed,
    required this.progress,
    required this.onToggle,
  });

  final bool collapsed;
  final double progress;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final t = progress.clamp(0.0, 1.0);
    final reveal = _labelReveal(t);
    final buttonRight = lerpDouble(
      _collapsedButtonRight,
      _expandedButtonRight,
      t,
    )!;

    final button = Tooltip(
      message: collapsed ? 'Expand navigation' : 'Collapse navigation',
      waitDuration: const Duration(milliseconds: 400),
      child: IconButton(
        onPressed: onToggle,
        icon: Transform.rotate(
          angle: math.pi * (1.0 - t),
          child: Icon(
            Icons.menu_open_rounded,
            size: _navIconSize,
            color: palette.secondaryText,
          ),
        ),
        style: IconButton.styleFrom(
          minimumSize: const Size.square(_toggleButtonSize),
          maximumSize: const Size.square(_toggleButtonSize),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
    );

    return SizedBox(
      height: _collapseHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpace.sm),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (reveal > 0.001)
              Positioned(
                left: AppSpace.xs + AppSpace.sm,
                right: buttonRight + _toggleButtonSize + AppSpace.xs,
                top: 0,
                bottom: 0,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: _expandedHeaderTitleWidth,
                    maxWidth: _expandedHeaderTitleWidth,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Opacity(
                        opacity: reveal,
                        child: Transform.translate(
                          offset: Offset(-6.0 * (1.0 - reveal), 0.0),
                          child: Text(
                            'Library',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            style: palette.metadata.copyWith(
                              fontWeight: FontWeight.w600,
                              color: palette.mutedText,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              right: buttonRight,
              top: 0,
              bottom: 0,
              width: _toggleButtonSize,
              child: Center(child: button),
            ),
          ],
        ),
      ),
    );
  }
}
