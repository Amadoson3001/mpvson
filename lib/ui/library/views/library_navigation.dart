import 'package:flutter/material.dart';

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
class ShellSideNav extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ColoredBox(
      color: palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xs,
                AppSpace.sm,
                AppSpace.xs,
                AppSpace.xs,
              ),
              child: _items(context),
            ),
          ),
          if (showSettings)
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
      destination: d,
      selected: section == d.section,
      collapsed: collapsed,
      onTap: () => onSelect(d.section),
    ),
  );
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

    final icon = Icon(
      widget.destination.icon,
      size: 20,
      color: selected ? accent : palette.secondaryText,
    );
    final content = widget.collapsed
        ? Center(child: icon)
        : Row(
            children: [
              icon,
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? palette.primaryText
                        : palette.secondaryText,
                  ),
                ),
              ),
            ],
          );

    Widget item = Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: selected
            ? Color.alphaBlend(accent.withValues(alpha: 0.14), palette.sidebar)
            : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: widget.onTap,
          onFocusChange: (value) => setState(() => _focused = value),
          borderRadius: radius,
          hoverColor: palette.hover.withValues(alpha: selected ? 0.5 : 1),
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
                child: content,
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
