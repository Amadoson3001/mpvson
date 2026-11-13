import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/components/app_toggle_switch.dart';
import '../../../core/slider_overlay.dart';

class SettingsContentContainer extends StatelessWidget {
  const SettingsContentContainer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(28, 8, 28, 40),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: child,
      ),
    ),
  );
}

class SettingsCardGroup extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(
                  title!,
                  style: palette.sectionTitle.copyWith(
                    fontSize: AppType.small,
                    color: palette.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                ?trailing,
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: 4),
              Text(description!, style: palette.rowSecondary),
            ],
            const SizedBox(height: 10),
          ],
          Material(
            color: palette.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.artwork),
              side: BorderSide(color: palette.border.withValues(alpha: 0.7)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: palette.border.withValues(alpha: 0.55),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: palette.muted),
              const SizedBox(width: 12),
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

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.trailing,
    this.onTap,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: palette.muted),
            const SizedBox(width: 12),
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
          trailing,
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        hoverColor: palette.hover.withValues(alpha: 0.45),
        child: content,
      );
    }
    return content;
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: palette.muted),
              const SizedBox(width: 12),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.muted),
          const SizedBox(width: 12),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.muted),
          const SizedBox(width: 12),
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
  return '$title · $language';
}

double nearestPlaybackRate(double rate) => const [
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  2.0,
].reduce((a, b) => (a - rate).abs() <= (b - rate).abs() ? a : b);
