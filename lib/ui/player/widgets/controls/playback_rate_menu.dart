import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../ui/core/app_theme.dart';
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
    final speedText =
        '${controller.rate.toStringAsFixed(controller.rate == controller.rate.roundToDouble() ? 0 : 2)}×';
    return Semantics(
      label: 'Playback speed, selected $speedText',
      button: true,
      child: PopupMenuButton<double>(
        tooltip: 'Playback speed',
        initialValue: _nearestRate(controller.rate),
        onOpened: () => onMenuVisibilityChanged?.call(true),
        onCanceled: () => onMenuVisibilityChanged?.call(false),
        onSelected: (rate) {
          onMenuVisibilityChanged?.call(false);
          unawaited(controller.setRate(rate));
        },
        itemBuilder: (context) =>
            const <double>[0.5, 0.75, 1, 1.25, 1.5, 2].map((rate) {
              final isSelected = (controller.rate - rate).abs() < 0.01;
              final label = rate == 1 ? 'Normal speed' : '$rate×';
              return PopupMenuItem<double>(
                value: rate,
                child: Semantics(
                  selected: isSelected,
                  label: isSelected ? '$label, selected' : label,
                  child: Text(label),
                ),
              );
            }).toList(),
        child: SizedBox(
          width: PlayerControlStyle.of(context).compact ? 40 : 52,
          height: PlayerControlStyle.of(context).buttonExtent,
          child: Center(
            child: Text(
              speedText,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: context.palette.secondaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
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
