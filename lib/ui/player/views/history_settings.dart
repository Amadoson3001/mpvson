import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../player_controller.dart';

/// History controls shared by the desktop settings layouts.
class HistorySettings extends StatefulWidget {
  const HistorySettings({
    super.key,
    required this.controller,
    this.embedded = false,
    this.anchorBuilder,
  });

  final PlayerController controller;
  final bool embedded;
  final Widget Function(String id, Widget child)? anchorBuilder;

  Widget _anchor(String id, Widget child) =>
      anchorBuilder?.call(id, child) ?? _HistoryAnchor(id: id, child: child);

  @override
  State<HistorySettings> createState() => _HistorySettingsState();
}

class _HistorySettingsState extends State<HistorySettings> {
  String? _message;
  bool _failed = false;

  Future<void> _update(
    Future<void> Function() operation, {
    String? success,
  }) async {
    setState(() => _message = null);
    try {
      await operation();
      if (mounted) {
        setState(() {
          _failed = false;
          _message = success;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = 'Could not update saved history. Please try again.';
        });
      }
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear playback history?'),
        content: const SizedBox(
          width: 360,
          child: Text(
            'Remove recent files, saved playback positions, and library play '
            'counts from this computer. Your queue, favorites, playlists, and '
            'media files stay in place.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-clear-history'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: AppTheme.background,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _update(
        widget.controller.clearHistory,
        success: 'Playback history cleared.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final busy = controller.historyBusy;
      final count = controller.recent.length;
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          widget._anchor(
            'history-enabled',
            SwitchListTile.adaptive(
              key: const ValueKey('history-enabled-toggle'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Save playback history'),
              subtitle: const Text(
                'Remember recent files, resume positions, and recently played '
                'music. Turning this off stops new recording; existing history '
                'stays until you clear it.',
              ),
              value: controller.historyEnabled,
              onChanged: busy
                  ? null
                  : (value) =>
                        _update(() => controller.setHistoryEnabled(value)),
            ),
          ),
          const Divider(height: 24),
          Text('Saved history', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            count == 1 ? '1 recent item' : '$count recent items',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'Clear recent files, saved playback positions, and library play '
            'counts. Current playback continues and your queue stays saved.',
          ),
          const SizedBox(height: 16),
          widget._anchor(
            'clear-history',
            OutlinedButton.icon(
              key: const ValueKey('clear-history-button'),
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
              onPressed: busy ? null : _confirmClear,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(busy ? 'Saving changes…' : 'Clear history'),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                _message!,
                style: TextStyle(
                  color: _failed ? AppTheme.danger : AppTheme.success,
                ),
              ),
            ),
          ],
        ],
      );
      return widget.embedded
          ? content
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: content,
            );
    },
  );
}

class _HistoryAnchor extends StatelessWidget {
  const _HistoryAnchor({required this.id, required this.child});
  final String id;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: ValueKey(id), child: child);
}
