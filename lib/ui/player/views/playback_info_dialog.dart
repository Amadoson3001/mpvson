import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/services/playback_statistics.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_dialog.dart';

/// Refreshes once per second so GPU and frame-drop counters stay current
/// without polling while the dialog is closed.
class PlaybackInfoDialog extends StatefulWidget {
  const PlaybackInfoDialog({super.key, required this.readStatistics});

  final Future<PlaybackStatistics> Function() readStatistics;

  @override
  State<PlaybackInfoDialog> createState() => _PlaybackInfoDialogState();
}

class _PlaybackInfoDialogState extends State<PlaybackInfoDialog> {
  PlaybackStatistics? _statistics;
  bool _busy = false;
  bool _inFlight = false;
  String? _error;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refresh(silent: true),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_inFlight) return;
    _inFlight = true;
    if (!silent) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final statistics = await widget.readStatistics();
      if (mounted) {
        setState(() {
          _statistics = statistics;
          _error = null;
        });
      }
    } on Object {
      if (mounted && !silent) {
        setState(
          () => _error =
              'Playback information could not be read. Try refreshing after opening a video.',
        );
      }
    } finally {
      _inFlight = false;
      if (mounted && !silent) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AppDialog(
      maxWidth: 528,
      scrollable: true,
      title: const Text('Playback information'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Check the active decoder, GPU memory, and dropped frames when playback stutters. Samples refresh once per second while this window is open.',
          ),
          const SizedBox(height: AppSpace.md),
          if (_busy)
            LinearProgressIndicator(
              color: accent,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_statistics case final statistics?)
            for (final entry in statistics.values.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(entry.key)),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: SelectableText(
                        entry.value,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: accent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: _busy ? null : () => _refresh(),
          child: const Text('Refresh'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: accent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
