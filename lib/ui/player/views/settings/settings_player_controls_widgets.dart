import 'package:flutter/material.dart';

import '../../../../domain/models/player_controls_preferences.dart';
import '../../player_controller.dart';

class StylePresetCard extends StatelessWidget {
  const StylePresetCard({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Semantics(
      selected: selected,
      button: true,
      label: 'Control style $title',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.08)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.20,
                    ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? accent
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
                width: selected ? 1.8 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.14),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected
                        ? accent.withValues(alpha: 0.18)
                        : theme.colorScheme.surfaceContainerHighest.withValues(
                            alpha: 0.45,
                          ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: selected
                        ? accent
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: selected
                                  ? (theme.brightness == Brightness.dark
                                        ? Colors.white
                                        : accent)
                                  : theme.colorScheme.onSurface,
                              fontSize: 13,
                            ),
                          ),
                          if (selected) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.check_rounded, size: 14, color: accent),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.8,
                          ),
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LiveControlPreview extends StatelessWidget {
  const LiveControlPreview({
    super.key,
    required this.prefs,
    required this.controller,
    required this.compact,
  });

  final PlayerControlsPreferences prefs;
  final PlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Container(
      key: const ValueKey('player-controls-live-preview'),
      height: 140,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
          width: 1,
        ),
        gradient: const RadialGradient(
          center: Alignment(0.2, -0.4),
          radius: 1.2,
          colors: [Color(0xFF2D1620), Color(0xFF141722), Color(0xFF090B10)],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Opacity(
              opacity: 0.25,
              child: Icon(
                Icons.play_circle_fill_rounded,
                size: 48,
                color: accent,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildPreviewStrip(context, accent),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewStrip(BuildContext context, Color accent) {
    final isFloating = prefs.barStyle == PlayerControlBarStyle.floatingPill;
    final radius = BorderRadius.circular(12);

    Widget bar = Container(
      padding: EdgeInsets.symmetric(
        horizontal: isFloating ? 12 : 14,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: switch (prefs.barStyle) {
          PlayerControlBarStyle.floatingPill => const Color(
            0xFF0F1117,
          ).withValues(alpha: prefs.backgroundOpacity),
          PlayerControlBarStyle.cinematicGradient => null,
          PlayerControlBarStyle.frostedDocked => const Color(
            0xFF0F1117,
          ).withValues(alpha: prefs.backgroundOpacity),
          PlayerControlBarStyle.minimal => null,
        },
        gradient: switch (prefs.barStyle) {
          PlayerControlBarStyle.cinematicGradient => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: prefs.backgroundOpacity * 0.45),
              Colors.black.withValues(alpha: prefs.backgroundOpacity),
            ],
          ),
          PlayerControlBarStyle.minimal => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: prefs.backgroundOpacity * 0.75),
            ],
          ),
          _ => null,
        },
        borderRadius: isFloating ? radius : null,
        border: switch (prefs.barStyle) {
          PlayerControlBarStyle.floatingPill => Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            width: 1,
          ),
          PlayerControlBarStyle.frostedDocked => Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.15),
              width: 1,
            ),
          ),
          _ => null,
        },
        boxShadow: isFloating
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: 0.38,
              minHeight: prefs.seekBarThickness.restingHeight,
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.skip_previous_rounded,
                size: 16,
                color: Colors.white.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 6),
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.4),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.skip_next_rounded,
                size: 16,
                color: Colors.white.withValues(alpha: 0.9),
              ),
              if (prefs.showStopButton) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.stop_rounded,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ],
              if (prefs.showShuffleRepeat) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.shuffle_rounded,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.repeat_rounded,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ],
              const SizedBox(width: 8),
              Text(
                prefs.showRemainingTime ? '01:24 / -02:18' : '01:24 / 03:42',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: Colors.white70,
                ),
              ),
              const Spacer(),
              if (prefs.showVolumeSlider) ...[
                Icon(
                  Icons.volume_up_rounded,
                  size: 15,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 40,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: 0.75,
                      minHeight: 2.5,
                      backgroundColor: Colors.white24,
                      valueColor: AlwaysStoppedAnimation<Color>(accent),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (prefs.showSpeedButton) ...[
                const Text(
                  '1×',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (prefs.showQueueButton) ...[
                Icon(
                  Icons.playlist_play_rounded,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
                const SizedBox(width: 6),
              ],
              Icon(
                Icons.fullscreen_rounded,
                size: 16,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ],
          ),
        ],
      ),
    );

    if (isFloating) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: bar,
      );
    }

    return bar;
  }
}
