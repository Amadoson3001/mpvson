import 'package:flutter/material.dart';

import '../../../core/app_motion.dart';
import '../../../core/app_theme.dart';

class ThemeModeCard extends StatelessWidget {
  const ThemeModeCard({
    super.key,
    required this.title,
    required this.icon,
    required this.selected,
    this.previewDark = true,
    this.isSystem = false,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final bool previewDark;
  final bool isSystem;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Semantics(
      selected: selected,
      button: true,
      label: 'Theme mode $title',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.quick),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.08)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.22,
                    ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? accent
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
                width: selected ? 1.8 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.16),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              children: [
                _buildPreview(context, accent),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 14,
                      color: selected
                          ? accent
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: selected
                              ? (theme.brightness == Brightness.dark
                                    ? Colors.white
                                    : accent)
                              : theme.colorScheme.onSurface,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: 5),
                      Icon(Icons.check_rounded, size: 14, color: accent),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context, Color accent) {
    return Container(
      height: 62,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: selected
              ? accent.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.07),
          width: 1,
        ),
      ),
      child: isSystem
          ? _buildSystemPreview(accent)
          : (previewDark
                ? _buildDarkPreview(accent)
                : _buildLightPreview(accent)),
    );
  }

  Widget _buildDarkPreview(Color accent) {
    return Container(
      color: const Color(0xFF13151D),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF353849),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF353849),
                  shape: BoxShape.circle,
                ),
              ),
              const Spacer(),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          const Spacer(),
          Container(
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1E212D),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(Icons.play_arrow_rounded, size: 10, color: accent),
                const SizedBox(width: 5),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: 0.55,
                      minHeight: 2.5,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      valueColor: AlwaysStoppedAnimation<Color>(accent),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLightPreview(Color accent) {
    return Container(
      color: const Color(0xFFF8FAFC),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFFCBD5E1),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFFCBD5E1),
                  shape: BoxShape.circle,
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.light_mode_rounded,
                size: 12,
                color: Color(0xFFF59E0B),
              ),
            ],
          ),
          const Spacer(),
          Container(
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(Icons.play_arrow_rounded, size: 10, color: accent),
                const SizedBox(width: 5),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: 0.55,
                      minHeight: 2.5,
                      backgroundColor: Colors.black.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation<Color>(accent),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemPreview(Color accent) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            color: const Color(0xFF13151D),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFF353849),
                    shape: BoxShape.circle,
                  ),
                ),
                const Spacer(),
                Container(
                  height: 18,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1E212D),
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(4),
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.dark_mode_rounded,
                      size: 10,
                      color: accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(width: 1, color: Colors.white.withValues(alpha: 0.12)),
        Expanded(
          child: Container(
            color: const Color(0xFFF8FAFC),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Icon(
                  Icons.brightness_auto_rounded,
                  size: 11,
                  color: Color(0xFF64748B),
                ),
                const Spacer(),
                Container(
                  height: 18,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFFFFF),
                    borderRadius: BorderRadius.horizontal(
                      right: Radius.circular(4),
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.light_mode_rounded,
                      size: 10,
                      color: Color(0xFFF59E0B),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class AccentColorChip extends StatelessWidget {
  const AccentColorChip({
    super.key,
    required this.preset,
    required this.selected,
    this.isOverridden = false,
    required this.onTap,
  });

  final AppAccentPreset preset;
  final bool selected;
  final bool isOverridden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final displayColor = isDark ? preset.color : preset.lightColor;
    final isColorDark =
        ThemeData.estimateBrightnessForColor(displayColor) == Brightness.dark;
    final effectiveColor = isOverridden && selected
        ? displayColor.withValues(alpha: 0.65)
        : displayColor;

    return Tooltip(
      message: isOverridden
          ? '${preset.label} (Overridden by active artwork)'
          : '${preset.label} — ${preset.description}',
      waitDuration: const Duration(milliseconds: 300),
      child: Semantics(
        button: true,
        selected: selected,
        label: preset.label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            hoverColor: displayColor.withValues(alpha: 0.1),
            child: AnimatedContainer(
              duration: AppMotion.duration(context, AppMotion.quick),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: selected && !isOverridden
                    ? displayColor.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected && !isOverridden
                      ? displayColor.withValues(alpha: 0.4)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: effectiveColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? (isDark ? Colors.white : Colors.black87)
                            : (isDark
                                  ? Colors.white.withValues(alpha: 0.18)
                                  : Colors.black.withValues(alpha: 0.12)),
                        width: selected ? 2.5 : 1,
                      ),
                      boxShadow: selected && !isOverridden
                          ? [
                              BoxShadow(
                                color: displayColor.withValues(alpha: 0.45),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 3,
                                offset: const Offset(0, 1),
                              ),
                            ],
                    ),
                    alignment: Alignment.center,
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            size: 20,
                            color: isColorDark ? Colors.white : Colors.black87,
                          )
                        : null,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    preset.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected && !isOverridden
                          ? displayColor
                          : theme.colorScheme.onSurfaceVariant,
                      fontSize: 11.5,
                    ),
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
