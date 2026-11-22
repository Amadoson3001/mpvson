import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../player_controller.dart';
import '../player_control_style.dart';

/// Speed selector shown beside the transport controls.
class PlaybackRateMenu extends StatelessWidget {
  const PlaybackRateMenu({
    super.key,
    required this.controller,
    required this.onMenuVisibilityChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onMenuVisibilityChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: controller.rateListenable,
      builder: (context, currentRate, _) {
        final speedText = _formatRate(currentRate);
        final isModified = (currentRate - 1.0).abs() >= 0.01;
        final accent = Theme.of(context).colorScheme.primary;
        final sizing = PlayerControlStyle.of(context);
        return Semantics(
          label: 'Playback speed, selected $speedText',
          button: true,
          child: PopupMenuButton<double>(
            key: const ValueKey('playback-rate-menu-button'),
            tooltip: 'Playback speed',
            position: PopupMenuPosition.over,
            borderRadius: BorderRadius.circular(AppRadii.control),
            initialValue: _nearestRate(currentRate),
            onOpened: () => onMenuVisibilityChanged?.call(true),
            onCanceled: () => onMenuVisibilityChanged?.call(false),
            onSelected: (rate) {
              onMenuVisibilityChanged?.call(false);
              unawaited(controller.setRate(rate));
            },
            itemBuilder: (context) =>
                const <double>[0.5, 0.75, 1, 1.25, 1.5, 2].map((rate) {
                  final isSelected = (currentRate - rate).abs() < 0.01;
                  final label = rate == 1 ? 'Normal speed' : _formatRate(rate);
                  return PopupMenuItem<double>(
                    value: rate,
                    child: Semantics(
                      selected: isSelected,
                      label: isSelected ? '$label, selected' : label,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (isSelected)
                            Icon(Icons.check_rounded, size: 17, color: accent),
                        ],
                      ),
                    ),
                  );
                }).toList(),
            child: SizedBox(
              width: sizing.compact ? 44 : 54,
              height: sizing.buttonExtent,
              child: Center(
                child: Text(
                  speedText,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: isModified
                        ? accent
                        : Colors.white.withValues(alpha: 0.88),
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _formatRate(double rate) {
    if (rate == rate.roundToDouble()) return '${rate.toInt()}×';
    final formatted = rate
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return '$formatted×';
  }

  static double _nearestRate(double rate) => const [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ].reduce((a, b) => (a - rate).abs() <= (b - rate).abs() ? a : b);
}
