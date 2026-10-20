import 'package:flutter/material.dart';

import '../../../data/services/playback_statistics.dart';

/// Refresh is explicit so inspecting playback never starts a polling workload.
class PlaybackInfoDialog extends StatefulWidget {
  const PlaybackInfoDialog({super.key, required this.readStatistics});

  final Future<PlaybackStatistics> Function() readStatistics;

  @override
  State<PlaybackInfoDialog> createState() => _PlaybackInfoDialogState();
}

class _PlaybackInfoDialogState extends State<PlaybackInfoDialog> {
  PlaybackStatistics? _statistics;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final statistics = await widget.readStatistics();
      if (mounted) setState(() => _statistics = statistics);
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Playback information could not be read. Try refreshing after opening a video.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Playback information'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Check the active decoder and dropped frames when playback stutters. Refresh to take another sample.',
          ),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_statistics case final statistics?)
            for (final entry in statistics.values.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(entry.key)),
                    const SizedBox(width: 16),
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
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : _refresh,
        child: const Text('Refresh'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}
