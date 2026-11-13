import 'package:flutter/material.dart';

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

/// Sidebar content: the full 208px list or the 64px icon rail.
///
/// Features a physically continuous sliding indicator pill that glides between
/// active navigation destinations without any fade or visual flicker.
class ShellSideNav extends StatefulWidget {
  const ShellSideNav({
    super.key,
    required this.section,
    required this.onSelect,
    required this.collapsed,
    required this.showSettings,
  });

  final LibrarySection section;
  final ValueChanged<LibrarySection> onSelect;
  final bool collapsed;
  final bool showSettings;

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

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: const Cubic(0.12, 1.0, 0.24, 1.0),
  );

  Rect? _startRect;
  Rect? _targetRect;
  Rect? _currentRect;

  @override
  void initState() {
    super.initState();
    _currentRect = _estimateRect(widget.section, widget.collapsed, null);
    _startRect = _currentRect;
    _targetRect = _currentRect;
    _controller.value = 1.0;
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncToMeasured(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant ShellSideNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      if (AppMotion.reduce(context)) {
        _syncToMeasured(animate: false);
      } else {
        final measured = _measureItemRect(widget.section);
        if (measured != null) {
          _startRect = _interpolatedRect;
          _targetRect = measured;
          _controller.forward(from: 0.0);
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _syncToMeasured(animate: true);
          });
        }
      }
    } else if (oldWidget.collapsed != widget.collapsed ||
        oldWidget.showSettings != widget.showSettings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncToMeasured(animate: false);
      });
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.isAnimating) {
      final measured = _measureItemRect(widget.section);
      if (measured != null &&
          (measured != _currentRect ||
              measured != _targetRect ||
              measured != _startRect)) {
        setState(() {
          _startRect = measured;
          _targetRect = measured;
          _currentRect = measured;
        });
      }
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
    if (!mounted) return;
    final measured = _measureItemRect(widget.section);
    if (measured == null) return;

    if (!animate || AppMotion.reduce(context) || _currentRect == null) {
      _controller.stop();
      _controller.value = 1.0;
      setState(() {
        _startRect = measured;
        _targetRect = measured;
        _currentRect = measured;
      });
      return;
    }

    if (_targetRect == measured && _controller.value == 1.0) {
      return;
    }

    _startRect = _interpolatedRect;
    _targetRect = measured;
    _controller.forward(from: 0.0);
  }

  Rect? get _interpolatedRect {
    if (_startRect == null || _targetRect == null) {
      return _currentRect ?? _targetRect ?? _startRect;
    }
    final t = _curve.value;
    return Rect.lerp(_startRect, _targetRect, t);
  }

  Rect _estimateRect(
    LibrarySection section,
    bool collapsed,
    double? maxHeight,
  ) {
    final width = collapsed
        ? 48.0
        : (AppLayout.sidebarExpanded - AppSpace.xs * 2);
    final height = collapsed ? 44.0 : 40.0;
    final itemStep = collapsed ? 48.0 : 44.0;
    const left = AppSpace.xs;

    double top;
    switch (section) {
      case LibrarySection.home:
        top = AppSpace.sm + AppSpace.micro;
      case LibrarySection.videos:
        top = AppSpace.sm + AppSpace.micro + itemStep;
      case LibrarySection.music:
        top = AppSpace.sm + AppSpace.micro + itemStep * 2;
      case LibrarySection.playlists:
        top = AppSpace.sm + AppSpace.micro + itemStep * 3;
      case LibrarySection.folders:
        top = AppSpace.sm + AppSpace.micro + itemStep * 4 + 17.0;
      case LibrarySection.settings:
        if (maxHeight != null && maxHeight > 200) {
          top = maxHeight - AppSpace.sm - height - AppSpace.micro;
        } else {
          top = AppSpace.sm + AppSpace.micro + itemStep * 5 + 34.0;
        }
      case LibrarySection.nowPlaying:
        top = AppSpace.sm + AppSpace.micro;
    }
    return Rect.fromLTWH(left, top, width, height);
  }

  bool get _hasSelection =>
      _itemKeys.containsKey(widget.section) &&
      widget.section != LibrarySection.nowPlaying;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ColoredBox(
      color: palette.sidebar,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            key: _rootKey,
            fit: StackFit.expand,
            children: [
              // 1. Sliding indicator pill behind items
              if (_hasSelection)
                AnimatedBuilder(
                  animation: _curve,
                  builder: (context, _) {
                    final rect =
                        _interpolatedRect ??
                        _estimateRect(
                          widget.section,
                          widget.collapsed,
                          constraints.hasBoundedHeight
                              ? constraints.maxHeight
                              : null,
                        );
                    return Positioned(
                      top: rect.top,
                      left: rect.left,
                      width: rect.width,
                      height: rect.height,
                      child: IgnorePointer(
                        child: _SlidingNavIndicator(
                          accent: palette.accent,
                          collapsed: widget.collapsed,
                        ),
                      ),
                    );
                  },
                ),

              // 2. Navigation items column
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.xs,
                        AppSpace.sm,
                        AppSpace.xs,
                        AppSpace.xs,
                      ),
                      child: _items(context),
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
                      child: _item(_settings),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _items(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final d in _mainDestinations) _item(d),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Divider(height: 1, color: context.palette.border),
      ),
      _item(_folders),
    ],
  );

  Widget _item(_Destination d) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.micro),
    child: _NavItem(
      key: _itemKeys[d.section],
      destination: d,
      selected: widget.section == d.section,
      collapsed: widget.collapsed,
      onTap: () => widget.onSelect(d.section),
    ),
  );
}

class _SlidingNavIndicator extends StatelessWidget {
  const _SlidingNavIndicator({required this.accent, required this.collapsed});

  final Color accent;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.control);
    final lowPower = AppMotion.lowPower(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: radius,
        border: Border(left: BorderSide(color: accent, width: 3.0)),
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
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final bool collapsed;
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
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: widget.collapsed ? 44 : 40,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.collapsed ? 0 : AppSpace.sm,
                  vertical: AppSpace.xs,
                ),
                child: TweenAnimationBuilder<Color?>(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  tween: ColorTween(begin: targetColor, end: targetColor),
                  builder: (context, iconColor, _) {
                    final effectiveIconColor = iconColor ?? targetColor;
                    final icon = Icon(
                      widget.destination.icon,
                      size: 20,
                      color: effectiveIconColor,
                    );

                    if (widget.collapsed) {
                      return Center(child: icon);
                    }

                    return Row(
                      children: [
                        icon,
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            style: Theme.of(context).textTheme.titleSmall!
                                .copyWith(
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: selected
                                      ? palette.primaryText
                                      : unselectedColor,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            child: Text(label),
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
