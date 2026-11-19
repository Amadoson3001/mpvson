import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../domain/models/stream_rendition.dart';
import '../../player_controller.dart';
import '../player_control_style.dart';

/// Quality selector shown beside transport controls for streaming sources.
class StreamQualityMenu extends StatelessWidget {
  const StreamQualityMenu({
    super.key,
    required this.controller,
    required this.onMenuVisibilityChanged,
  });

  final PlayerController controller;
  final ValueChanged<bool>? onMenuVisibilityChanged;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.transportListenable,
      builder: (context, _) {
        final transport = controller.transportState;
        final renditions = transport.availableRenditions;
        final selected = transport.selectedRendition;
        final active = transport.activeRendition;
        final isAuto = selected == null || selected.isAuto;

        final currentLabel = isAuto
            ? (active != null ? 'Auto (${active.qualityLabel})' : 'Auto')
            : (selected.qualityLabel);

        return Semantics(
          label: 'Stream quality, selected $currentLabel',
          button: true,
          child: PopupMenuButton<StreamRendition>(
            tooltip: 'Stream quality',
            initialValue: selected ?? StreamRendition.auto,
            onOpened: () => onMenuVisibilityChanged?.call(true),
            onCanceled: () => onMenuVisibilityChanged?.call(false),
            onSelected: (rendition) {
              onMenuVisibilityChanged?.call(false);
              unawaited(controller.selectStreamQuality(rendition));
            },
            itemBuilder: (context) {
              final items = <PopupMenuEntry<StreamRendition>>[];

              // Auto option
              items.add(
                PopupMenuItem<StreamRendition>(
                  value: StreamRendition.auto,
                  child: Semantics(
                    selected: isAuto,
                    label: isAuto ? 'Auto, selected' : 'Auto',
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            active != null
                                ? 'Auto (${active.qualityLabel})'
                                : 'Auto',
                            style: TextStyle(
                              fontWeight: isAuto
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (isAuto)
                          Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
                ),
              );

              if (renditions.isNotEmpty) {
                items.add(const PopupMenuDivider());
                for (final rendition in renditions) {
                  if (rendition.isAuto) continue;
                  final isThisSelected =
                      !isAuto && (selected.id == rendition.id);
                  final label = rendition.bitrate != null
                      ? '${rendition.qualityLabel} (${(rendition.bitrate! / 1000000).toStringAsFixed(1)} Mbps)'
                      : rendition.qualityLabel;

                  items.add(
                    PopupMenuItem<StreamRendition>(
                      value: rendition,
                      child: Semantics(
                        selected: isThisSelected,
                        label: isThisSelected ? '$label, selected' : label,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontWeight: isThisSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (isThisSelected)
                              Icon(
                                Icons.check_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                }
              }

              return items;
            },
            child: SizedBox(
              height: PlayerControlStyle.of(context).buttonExtent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.high_quality_rounded,
                      size: 18,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isAuto
                          ? (active != null ? active.qualityLabel : 'Auto')
                          : selected.qualityLabel,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.88),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
