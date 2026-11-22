import 'package:flutter/material.dart';

import '../../../core/app_motion.dart';
import '../../../core/app_theme.dart';
import '../../../core/components/app_toggle_switch.dart';
import '../../../core/slider_overlay.dart';

class SettingsContentContainer extends StatelessWidget {
  const SettingsContentContainer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: child,
      ),
    ),
  );
}

/// Small tinted rounded square that leads a settings row.
class SettingsIconChip extends StatelessWidget {
  const SettingsIconChip({super.key, required this.icon, this.size = 34});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.control + 2),
      ),
      child: Icon(icon, size: 18, color: palette.accent),
    );
  }
}

class SettingsCardGroup extends StatefulWidget {
  const SettingsCardGroup({
    super.key,
    this.title,
    this.description,
    this.trailing,
    required this.children,
  });

  final String? title;
  final String? description;
  final Widget? trailing;
  final List<Widget> children;

  @override
  State<SettingsCardGroup> createState() => _SettingsCardGroupState();
}

class _SettingsCardGroupState extends State<SettingsCardGroup>
    with SingleTickerProviderStateMixin {
  // Groups that mount together (one section opening) cascade in order.
  static DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
  static int _count = 0;

  late final AnimationController _controller;
  late final Animation<double> _curve;
  bool _hovered = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    if (now.difference(_epoch) > const Duration(milliseconds: 400)) {
      _epoch = now;
      _count = 0;
    }
    final delayMs = (_count++).clamp(0, 5) * 55;
    const bodyMs = 360;
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: delayMs + bodyMs),
    );
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Interval(delayMs / (delayMs + bodyMs), 1, curve: AppMotion.enter),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (AppMotion.lowPower(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final title = widget.title;
    final description = widget.description;
    final children = widget.children;
    final radius = BorderRadius.circular(AppRadii.card);

    final content = Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Text(
                    title,
                    style: palette.sectionTitle.copyWith(
                      fontSize: AppType.body,
                      color: palette.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  ?widget.trailing,
                ],
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(description, style: palette.rowSecondary),
              ),
            ],
            const SizedBox(height: 12),
          ],
          MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: AnimatedContainer(
              duration: AppMotion.duration(context, AppMotion.standard),
              curve: AppMotion.standardCurve,
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: radius,
                border: Border.all(
                  color: _hovered
                      ? palette.accent.withValues(alpha: 0.35)
                      : palette.border.withValues(alpha: 0.5),
                ),
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < children.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: palette.border.withValues(alpha: 0.45),
                          ),
                        children[i],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return AnimatedBuilder(
      animation: _curve,
      child: content,
      builder: (context, child) => Opacity(
        opacity: _curve.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - _curve.value)),
          child: child,
        ),
      ),
    );
  }
}

class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: () => onChanged(!value),
      hoverColor: palette.hover.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            if (icon != null) ...[
              SettingsIconChip(icon: icon!),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: palette.rowPrimary.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: palette.rowSecondary),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            AppToggleSwitch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class SettingsActionTile extends StatelessWidget {
  const SettingsActionTile({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: onTap,
      hoverColor: palette.hover.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            if (icon != null) ...[
              SettingsIconChip(icon: icon!),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: palette.rowPrimary.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: palette.rowSecondary),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing ??
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: palette.muted,
                ),
          ],
        ),
      ),
    );
  }
}

class ModernSliderTile extends StatelessWidget {
  const ModernSliderTile({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.formatValue,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) formatValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final display = formatValue(value);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: palette.rowPrimary.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                display,
                style: palette.metadata.copyWith(
                  color: value != 0 ? palette.accent : palette.muted,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          SliderOverlay(
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              divisions: divisions,
              label: display,
              semanticFormatterCallback: (val) => '$label ${formatValue(val)}',
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }
}

class DropdownSettingTile<T> extends StatelessWidget {
  const DropdownSettingTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          SettingsIconChip(icon: icon),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: palette.rowPrimary.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              items: items,
              onChanged: onChanged,
              isDense: true,
              borderRadius: BorderRadius.circular(AppRadii.control),
              icon: Icon(
                Icons.expand_more_rounded,
                size: 18,
                color: palette.muted,
              ),
              style: palette.rowPrimary.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class TrackSettingTile<T> extends StatelessWidget {
  const TrackSettingTile({
    super.key,
    required this.icon,
    required this.label,
    required this.tracks,
    required this.selected,
    required this.trackLabel,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final List<T> tracks;
  final T? selected;
  final String Function(T) trackLabel;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    T? selectedValue;
    for (final track in tracks) {
      if (track == selected) {
        selectedValue = track;
        break;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          SettingsIconChip(icon: icon),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: palette.rowPrimary.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: selectedValue,
              hint: const Text('Unavailable'),
              isDense: true,
              borderRadius: BorderRadius.circular(AppRadii.control),
              icon: Icon(
                Icons.expand_more_rounded,
                size: 18,
                color: palette.muted,
              ),
              style: palette.rowPrimary.copyWith(fontWeight: FontWeight.w500),
              items: tracks.map<DropdownMenuItem<T>>((track) {
                final itemText = trackLabel(track);
                final isSelected = track == selectedValue;
                return DropdownMenuItem<T>(
                  value: track,
                  child: Semantics(
                    selected: isSelected,
                    label: isSelected ? '$itemText, selected' : itemText,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 190),
                      child: Text(itemText, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                );
              }).toList(),
              onChanged: tracks.isEmpty
                  ? null
                  : (track) {
                      if (track != null) onSelected(track);
                    },
            ),
          ),
        ],
      ),
    );
  }
}

String formatColorValue(double value) =>
    value == 0 ? '0' : '${value > 0 ? '+' : ''}${value.toStringAsFixed(0)}';

String formatSecondsValue(double value) =>
    '${value > 0 ? '+' : ''}${value.toStringAsFixed(1)} s';

String formatTrackLabel(String id, String? rawTitle, String? rawLanguage) {
  if (id == 'auto') return 'Automatic';
  if (id == 'no') return 'Off';
  final title = (rawTitle ?? '').trim();
  final language = (rawLanguage ?? '').trim();
  if (title.isEmpty && language.isEmpty) return 'Track $id';
  if (title.isEmpty) return language;
  if (language.isEmpty) return title;
  return '$title Â· $language';
}

double nearestPlaybackRate(double rate) => const [
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
].reduce((a, b) => (a - rate).abs() <= (b - rate).abs() ? a : b);
