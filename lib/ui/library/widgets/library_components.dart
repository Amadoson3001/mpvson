import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/components/page_header.dart';

/// Label style for custom controls, built from the theme so the Onest family
/// is kept. A bare `TextStyle(fontSize: ..)` handed to a button, dropdown or
/// tab replaces the theme style and falls back to the platform font.
TextStyle libraryLabelStyle(
  BuildContext context, {
  Color? color,
  FontWeight? weight,
  double? size,
}) => (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
  color: color,
  fontWeight: weight,
  fontSize: size,
);

/// Height of [lines] lines of text at [fontSize] under the user's text scale.
double libraryTextHeight(
  BuildContext context,
  double fontSize, {
  double lineHeight = 1.3,
  int lines = 1,
}) => MediaQuery.textScalerOf(context).scale(fontSize) * lineHeight * lines;

/// Compact square icon button style used inside rows and toolbars.
ButtonStyle libraryIconButtonStyle() => IconButton.styleFrom(
  minimumSize: const Size.square(36),
  maximumSize: const Size.square(40),
  padding: EdgeInsets.zero,
  iconSize: 18,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// Column metrics for a grid of cards inside [contentWidth].
class LibraryGridMetrics {
  const LibraryGridMetrics({required this.columns, required this.tileWidth});

  factory LibraryGridMetrics.compute(
    double contentWidth, {
    required double minTileWidth,
    double spacing = AppSpace.md,
    int maxColumns = 12,
  }) {
    final usable = math.max(contentWidth, 1.0);
    final columns = ((usable + spacing) / (minTileWidth + spacing))
        .floor()
        .clamp(1, maxColumns);
    final tileWidth = (usable - (columns - 1) * spacing) / columns;
    return LibraryGridMetrics(columns: columns, tileWidth: tileWidth);
  }

  final int columns;
  final double tileWidth;
}

/// Centered message for loading, error, empty and no-result states.
class LibraryNotice extends StatelessWidget {
  const LibraryNotice({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.primaryLabel,
    this.primaryIcon,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? primaryLabel;
  final IconData? primaryIcon;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tone = isError ? palette.danger : palette.accent;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.xl,
          ),
          child: Semantics(
            container: true,
            liveRegion: isError,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadii.artwork),
                    border: Border.all(color: tone.withValues(alpha: 0.24)),
                  ),
                  child: Icon(icon, size: 26, color: tone),
                ),
                const SizedBox(height: AppSpace.md),
                Text(
                  title,
                  style: palette.albumTitle,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                if (message != null) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    message!,
                    style: palette.rowSecondary.copyWith(
                      fontSize: AppType.small,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (primaryLabel != null || secondaryLabel != null) ...[
                  const SizedBox(height: AppSpace.lg),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: AppSpace.xs,
                    runSpacing: AppSpace.xs,
                    children: [
                      if (primaryLabel != null)
                        primaryIcon == null
                            ? FilledButton(
                                onPressed: onPrimary,
                                child: Text(primaryLabel!),
                              )
                            : FilledButton.icon(
                                onPressed: onPrimary,
                                icon: Icon(primaryIcon, size: 18),
                                label: Text(primaryLabel!),
                              ),
                      if (secondaryLabel != null)
                        OutlinedButton(
                          onPressed: onSecondary,
                          child: Text(secondaryLabel!),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Spinner with a label for the first load of a view.
class LibraryLoading extends StatelessWidget {
  const LibraryLoading({super.key, this.label = 'Loading'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: label,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                label,
                style: palette.rowSecondary.copyWith(fontSize: AppType.small),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small status chip such as "Missing".
class LibraryBadge extends StatelessWidget {
  const LibraryBadge({super.key, required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tone = color ?? palette.danger;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: tone.withValues(alpha: 0.32)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          label,
          style: palette.badge.copyWith(color: tone, fontSize: AppType.caption),
          maxLines: 1,
        ),
      ),
    );
  }
}

/// Button face with hover, focus, pressed, selected and disabled states.
///
/// Used for sub-tabs, toolbar toggles and sort chips so every control in the
/// three library views behaves the same.
class LibraryPill extends StatefulWidget {
  const LibraryPill({
    super.key,
    required this.child,
    required this.onPressed,
    this.selected = false,
    this.outlined = false,
    this.tooltip,
    this.semanticLabel,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpace.sm),
    this.minWidth = 0,
    this.minHeight = 36,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool selected;
  final bool outlined;
  final String? tooltip;
  final String? semanticLabel;
  final EdgeInsetsGeometry padding;
  final double minWidth;
  final double minHeight;

  @override
  State<LibraryPill> createState() => _LibraryPillState();
}

class _LibraryPillState extends State<LibraryPill> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.accent;
    final enabled = widget.onPressed != null;
    final showRing =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final foreground = !enabled
        ? palette.faint
        : widget.selected
        ? accent
        : palette.secondaryText;
    final borderColor = showRing
        ? accent
        : widget.selected
        ? accent.withValues(alpha: 0.4)
        : widget.outlined
        ? palette.border
        : Colors.transparent;
    final radius = BorderRadius.circular(AppRadii.control);
    Widget pill = Material(
      color: widget.selected
          ? accent.withValues(alpha: 0.14)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: borderColor, width: showRing ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onPressed,
        onFocusChange: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        hoverColor: palette.hover.withValues(alpha: 0.7),
        focusColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: widget.minWidth,
            minHeight: widget.minHeight,
          ),
          child: Padding(
            padding: widget.padding,
            child: Center(
              widthFactor: 1,
              child: DefaultTextStyle.merge(
                style: libraryLabelStyle(context, color: foreground),
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground, size: 18),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    pill = Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      child: pill,
    );
    if (widget.tooltip != null) {
      pill = Tooltip(message: widget.tooltip!, child: pill);
    }
    return pill;
  }
}

/// A bordered group of exclusive icon choices, such as grid and list.
class LibraryToggleGroup<T> extends StatelessWidget {
  const LibraryToggleGroup({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<LibraryToggleOption<T>> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              LibraryPill(
                selected: option.value == value,
                tooltip: option.tooltip,
                semanticLabel: option.tooltip,
                minWidth: 36,
                minHeight: 32,
                padding: EdgeInsets.zero,
                onPressed: () => onChanged(option.value),
                child: Icon(option.icon),
              ),
          ],
        ),
      ),
    );
  }
}

class LibraryToggleOption<T> {
  const LibraryToggleOption({
    required this.value,
    required this.icon,
    required this.tooltip,
  });

  final T value;
  final IconData icon;
  final String tooltip;
}

/// Outlined chip that opens a popup menu, e.g. "Sort: Title".
class LibraryMenuButton<T> extends StatelessWidget {
  const LibraryMenuButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
    this.icon,
    this.active = false,
  });

  final String label;
  final String tooltip;
  final IconData? icon;
  final bool active;
  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = active ? palette.accent : palette.secondaryText;
    final radius = BorderRadius.circular(AppRadii.control);
    return Semantics(
      button: true,
      label: '$tooltip: $label',
      excludeSemantics: true,
      child: PopupMenuButton<T>(
        tooltip: tooltip,
        borderRadius: radius,
        offset: const Offset(0, 40),
        onSelected: onSelected,
        itemBuilder: itemBuilder,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: active
                  ? palette.accent.withValues(alpha: 0.1)
                  : Colors.transparent,
              borderRadius: radius,
              border: Border.all(
                color: active
                    ? palette.accent.withValues(alpha: 0.4)
                    : palette.border,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.only(
                left: AppSpace.sm,
                right: AppSpace.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: foreground),
                    const SizedBox(width: AppSpace.xs),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: libraryLabelStyle(context, color: foreground),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 20,
                    color: foreground,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fixed-height sliver header that stays pinned, used for table columns.
class LibraryPinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const LibraryPinnedHeaderDelegate({
    required this.height,
    required this.builder,
  });

  final double height;
  final Widget Function(BuildContext context) builder;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => builder(context);

  @override
  bool shouldRebuild(covariant LibraryPinnedHeaderDelegate oldDelegate) => true;
}

/// Column title cell for a table header.
class LibraryHeaderLabel extends StatelessWidget {
  const LibraryHeaderLabel(
    this.text, {
    super.key,
    this.align = TextAlign.start,
  });

  final String text;
  final TextAlign align;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: context.palette.metadata.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: AppLetterSpacing.wide,
    ),
    textAlign: align,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

/// Pinned header strip that sits above table rows.
class LibraryTableHeader extends StatelessWidget {
  const LibraryTableHeader({
    super.key,
    required this.outerPadding,
    required this.inset,
    required this.trailingWidth,
    required this.children,
  });

  final double outerPadding;

  /// Left inset that matches the row's content padding.
  final double inset;

  /// Width reserved for the row's trailing buttons.
  final double trailingWidth;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: outerPadding),
        child: Row(
          children: [
            SizedBox(width: inset),
            ...children,
            SizedBox(width: trailingWidth),
          ],
        ),
      ),
    );
  }
}

/// Header of a drill-in page: back link, artwork and the title block.
class LibraryDetailHeader extends StatelessWidget {
  const LibraryDetailHeader({
    super.key,
    required this.backLabel,
    required this.onBack,
    required this.artwork,
    required this.kind,
    required this.title,
    this.subtitle,
    this.meta,
    this.actions = const <Widget>[],
    this.circularArtwork = false,
  });

  final String backLabel;
  final VoidCallback onBack;
  final Widget artwork;

  /// Small label above the title, e.g. "Album".
  final String kind;
  final String title;
  final String? subtitle;
  final String? meta;
  final List<Widget> actions;
  final bool circularArtwork;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gutter = PageHeader.gutterFor(width);
        final stacked = width < 520;
        final side = stacked ? 120.0 : (width < 800 ? 136.0 : 168.0);
        final art = SizedBox(
          width: side,
          height: side,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              shape: circularArtwork ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: circularArtwork
                  ? null
                  : BorderRadius.circular(AppRadii.artwork),
              border: Border.all(color: palette.border),
            ),
            child: circularArtwork
                ? ClipOval(child: artwork)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.artwork),
                    child: artwork,
                  ),
          ),
        );
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              kind.toUpperCase(),
              style: palette.metadata.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: AppSpace.xxs),
            Semantics(
              header: true,
              child: Text(
                title,
                style: palette.pageTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpace.xxs),
              Text(
                subtitle!,
                style: palette.sectionTitle.copyWith(
                  color: palette.secondaryText,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (meta != null) ...[
              const SizedBox(height: AppSpace.xxs),
              Text(
                meta!,
                style: palette.rowSecondary.copyWith(fontSize: AppType.small),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: AppSpace.xs,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ],
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                math.max(gutter - AppSpace.sm, AppSpace.xs),
                AppSpace.sm,
                gutter,
                0,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: Text(backLabel),
                  style: TextButton.styleFrom(
                    foregroundColor: palette.secondaryText,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                AppSpace.xs,
                gutter,
                AppSpace.md,
              ),
              child: stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        art,
                        const SizedBox(height: AppSpace.md),
                        details,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        art,
                        const SizedBox(width: AppSpace.lg),
                        Expanded(child: details),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
