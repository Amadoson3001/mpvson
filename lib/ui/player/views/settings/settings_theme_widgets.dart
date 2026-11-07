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

  static Widget _dot(Color color) => Container(
    width: 5,
    height: 5,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

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
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.quick),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.08)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.3,
                    ),
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(
                color: selected
                    ? accent
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                width: selected ? 1.8 : 1,
              ),
            ),
            child: Column(
              children: [
                Container(
                  height: 52,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: isSystem
                        ? null
                        : (previewDark
                              ? AppColors.layer
                              : AppColors.lightGround),
                    gradient: isSystem
                        ? const LinearGradient(
                            colors: [AppColors.layer, AppColors.lightGround],
                            stops: [0.5, 0.5],
                          )
                        : null,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: selected
                          ? accent.withValues(alpha: 0.4)
                          : theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.4,
                            ),
                      width: 1,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 5,
                        left: 7,
                        child: Row(
                          children: [
                            _dot(const Color(0xFFEF4444)),
                            const SizedBox(width: 3),
                            _dot(const Color(0xFFF59E0B)),
                            const SizedBox(width: 3),
                            _dot(const Color(0xFF10B981)),
                          ],
                        ),
                      ),
                      Positioned(
                        bottom: 7,
                        left: 8,
                        right: 8,
                        child: Row(
                          children: [
                            Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                color: selected
                                    ? accent
                                    : const Color(0xFF888888),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Container(
                                height: 2.5,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? accent.withValues(alpha: 0.8)
                                      : const Color(
                                          0xFF888888,
                                        ).withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Center(
                        child: Icon(
                          icon,
                          size: 16,
                          color: selected
                              ? accent
                              : (previewDark || isSystem
                                    ? Colors.white70
                                    : Colors.black54),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected ? accent : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: 4),
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
        ? displayColor.withValues(alpha: 0.7)
        : displayColor;

    return Tooltip(
      message: isOverridden
          ? '${preset.label} (Overridden by active artwork)'
          : '${preset.label} — ${preset.description}',
      waitDuration: const Duration(milliseconds: 300),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            hoverColor: displayColor.withValues(alpha: 0.1),
            child: AnimatedContainer(
              duration: AppMotion.duration(context, AppMotion.quick),
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: selected
                    ? (isOverridden
                          ? displayColor.withValues(alpha: 0.08)
                          : displayColor.withValues(alpha: 0.16))
                    : theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.35,
                      ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: selected
                      ? (isOverridden
                            ? displayColor.withValues(alpha: 0.4)
                            : displayColor)
                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                  width: selected ? (isOverridden ? 1.2 : 1.6) : 1,
                ),
                boxShadow: selected && !isOverridden
                    ? [
                        BoxShadow(
                          color: displayColor.withValues(alpha: 0.22),
                          blurRadius: 6,
                          offset: const Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: effectiveColor,
                      shape: BoxShape.circle,
                      boxShadow: !isOverridden
                          ? [
                              BoxShadow(
                                color: displayColor.withValues(alpha: 0.35),
                                blurRadius: 3,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            size: 13,
                            color: isColorDark ? Colors.white : Colors.black87,
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    preset.label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected && !isOverridden
                          ? displayColor
                          : theme.colorScheme.onSurface,
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
