import 'package:flutter/material.dart';
import '../../player/player_controller.dart';
import '../../player/widgets/player_controls.dart';
import '../../player/widgets/player_control_style.dart';

/// The player's preview-enabled seek control with timecodes for the shell.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.controller});

  /// Inset that keeps the timecodes and the track off the stage's edges.
  ///
  /// Controls that share the timeline's band — the volume readout on the Now
  /// Playing screen — align to the same line so the playback group reads as one
  /// block instead of two slightly offset ones.
  static const double sideInset = 12;

  final PlayerController controller;
  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  Duration? _preview;
  String _time(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    // The strip is the only part of the library that changes per playback
    // tick; isolating it keeps those frames from repainting the whole window.
    child: ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller.displayPositionListenable,
        widget.controller.durationListenable,
      ]),
      builder: (context, _) => Row(
        children: [
          SizedBox(width: SeekBar.sideInset),
          Text(
            _time(_preview ?? widget.controller.displayPosition),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: PlayerControlStyle(
              compact: true,
              child: SharedSeekBar(
                controller: widget.controller,
                onPreviewChanged: (value) {
                  if (mounted) setState(() => _preview = value);
                },
                onInteractionChanged: null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _time(widget.controller.duration),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          SizedBox(width: SeekBar.sideInset),
        ],
      ),
    ),
  );
}
