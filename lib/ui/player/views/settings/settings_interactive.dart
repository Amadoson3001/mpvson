import 'package:flutter/material.dart';

import '../../../core/app_motion.dart';
import '../../../core/app_theme.dart';

/// Semantic colors for status text and pills that stay readable on both the
/// dark and the light card surface.
enum SettingsTone { neutral, accent, success, warning, danger }

Color settingsToneColor(BuildContext context, SettingsTone tone) {
  final scheme = Theme.of(context).colorScheme;
  final dark = scheme.brightness == Brightness.dark;
  return switch (tone) {
    SettingsTone.neutral => scheme.onSurfaceVariant,
    SettingsTone.accent => scheme.primary,
    SettingsTone.success => dark ? AppColors.jade : const Color(0xFF1F7A56),
    SettingsTone.warning => dark ? AppColors.gold : const Color(0xFF8A5A00),
    SettingsTone.danger => dark ? AppColors.rose : const Color(0xFFB4372B),
  };
}

/// Outer focus ring that does not change layout.
List<BoxShadow> settingsFocusRing(Color color) => [
  BoxShadow(color: color.withValues(alpha: 0.4), spreadRadius: 2),
];

/// A tappable surface that exposes hover, focus, pressed and selected states
/// to [builder] and activates with Enter or Space.
class SettingsPressable extends StatefulWidget {
  const SettingsPressable({
    super.key,
    required this.onTap,
    required this.builder,
    this.selected,
    this.focusable = true,
    this.autofocus = false,
    this.button = true,
    this.semanticLabel,
    this.focusNode,
  });

  final VoidCallback? onTap;
  final Widget Function(BuildContext context, Set<WidgetState> states) builder;
  final bool? selected;

  /// Rows that contain their own focusable control (a switch) pass false so
  /// keyboard users do not tab through the same control twice.
  final bool focusable;
  final bool autofocus;
  final bool button;
  final String? semanticLabel;
  final FocusNode? focusNode;

  @override
  State<SettingsPressable> createState() => _SettingsPressableState();
}

class _SettingsPressableState extends State<SettingsPressable> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _update(VoidCallback change) {
    if (!mounted) return;
    setState(change);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final states = <WidgetState>{
      if (!enabled) WidgetState.disabled,
      if (enabled && _hovered) WidgetState.hovered,
      if (enabled && _focused) WidgetState.focused,
      if (enabled && _pressed) WidgetState.pressed,
      if (widget.selected ?? false) WidgetState.selected,
    };
    final cursor = enabled ? SystemMouseCursors.click : MouseCursor.defer;
    final body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: enabled ? (_) => _update(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => _update(() => _pressed = false) : null,
      onTapCancel: enabled ? () => _update(() => _pressed = false) : null,
      child: widget.builder(context, states),
    );
    final Widget interactive = widget.focusable
        ? FocusableActionDetector(
            enabled: enabled,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            mouseCursor: cursor,
            onShowHoverHighlight: (v) => _update(() => _hovered = v),
            onShowFocusHighlight: (v) => _update(() => _focused = v),
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap?.call();
                  return null;
                },
              ),
            },
            child: body,
          )
        : MouseRegion(
            cursor: cursor,
            onEnter: (_) => _update(() => _hovered = true),
            onExit: (_) => _update(() => _hovered = false),
            child: body,
          );
    return Semantics(
      button: widget.button,
      enabled: enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: interactive,
    );
  }
}

/// Small rounded status label such as "Available" or "Up to date".
class SettingsPill extends StatelessWidget {
  const SettingsPill({
    super.key,
    required this.label,
    this.tone = SettingsTone.neutral,
    this.icon,
    this.busy = false,
  });

  final String label;
  final SettingsTone tone;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = settingsToneColor(context, tone);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.xs,
        vertical: AppSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 10,
              height: 10,
              child: AppMotion.reduce(context)
                  ? Icon(Icons.more_horiz_rounded, size: 10, color: color)
                  : CircularProgressIndicator(strokeWidth: 1.6, color: color),
            )
          else if (icon != null)
            Icon(icon, size: 12, color: color)
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A dropdown drawn as a bordered field with a visible focus ring.
class SettingsSelect<T> extends StatefulWidget {
  const SettingsSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.selectedItemBuilder,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;
  final DropdownButtonBuilder? selectedItemBuilder;

  @override
  State<SettingsSelect<T>> createState() => _SettingsSelectState<T>();
}

class _SettingsSelectState<T> extends State<SettingsSelect<T>> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Settings select');
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = widget.onChanged != null && widget.items.isNotEmpty;
    final borderColor = !enabled
        ? scheme.outlineVariant
        : _focused
        ? scheme.primary
        : _hovered
        ? scheme.outline
        : scheme.outlineVariant;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppMotion.quick),
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.only(left: AppSpace.sm, right: AppSpace.xxs),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: borderColor),
          boxShadow: _focused && enabled
              ? settingsFocusRing(scheme.primary)
              : null,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            focusNode: _focusNode,
            value: widget.value,
            items: widget.items,
            hint: widget.hint,
            selectedItemBuilder: widget.selectedItemBuilder,
            onChanged: enabled ? widget.onChanged : null,
            isDense: true,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.artwork),
            dropdownColor: scheme.surfaceContainer,
            icon: const Icon(Icons.expand_more_rounded, size: 20),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsSegment<T> {
  const SettingsSegment({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// Compact single-choice control with a clear selected state.
class SettingsSegmentedControl<T> extends StatelessWidget {
  const SettingsSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<SettingsSegment<T>> segments;
  final T selected;

  /// Null disables every segment.
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.xxs),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppRadii.control + 2),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final segment in segments)
              Flexible(
                child: _SegmentButton<T>(
                  segment: segment,
                  selected: segment.value == selected,
                  onTap: onChanged == null
                      ? null
                      : () => onChanged!(segment.value),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SegmentButton<T> extends StatelessWidget {
  const _SegmentButton({
    required this.segment,
    required this.selected,
    required this.onTap,
  });

  final SettingsSegment<T> segment;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SettingsPressable(
      onTap: onTap,
      selected: selected,
      builder: (context, states) {
        final hovered = states.contains(WidgetState.hovered);
        final focused = states.contains(WidgetState.focused);
        final disabled = states.contains(WidgetState.disabled);
        final foreground = selected ? scheme.onPrimary : scheme.onSurface;
        return Opacity(
          opacity: disabled ? 0.5 : 1,
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.quick),
            constraints: const BoxConstraints(minHeight: 34),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm,
              vertical: AppSpace.xxs,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary
                  : hovered
                  ? scheme.surfaceContainerHighest
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.control),
              boxShadow: focused ? settingsFocusRing(scheme.primary) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (segment.icon != null) ...[
                  Icon(segment.icon, size: 16, color: foreground),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    segment.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
