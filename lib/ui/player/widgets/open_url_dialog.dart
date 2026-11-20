import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/models/media_entry.dart';
import '../../../domain/models/media_source.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_dialog.dart';

/// Outcome returned by [OpenUrlDialog.show] indicating whether the submitted
/// stream should open immediately or append to the queue.
@immutable
class OpenUrlResult {
  const OpenUrlResult({required this.url, this.enqueue = false});

  final String url;
  final bool enqueue;
}

class OpenUrlDialog extends StatefulWidget {
  const OpenUrlDialog({
    super.key,
    this.allowEnqueue = false,
    this.recentUrls = const <MediaEntry>[],
    this.readClipboard,
  });

  final bool allowEnqueue;
  final List<MediaEntry> recentUrls;
  final Future<String?> Function()? readClipboard;

  static Future<OpenUrlResult?> show(
    BuildContext context, {
    bool allowEnqueue = true,
    List<MediaEntry> recentUrls = const <MediaEntry>[],
    Future<String?> Function()? readClipboard,
  }) async {
    final result = await AppDialog.show<Object>(
      context: context,
      builder: (_) => OpenUrlDialog(
        allowEnqueue: allowEnqueue,
        recentUrls: recentUrls,
        readClipboard: readClipboard,
      ),
    );
    if (result is OpenUrlResult) return result;
    if (result is String && result.isNotEmpty) {
      return OpenUrlResult(url: result, enqueue: false);
    }
    return null;
  }

  @override
  State<OpenUrlDialog> createState() => _OpenUrlDialogState();
}

class _OpenUrlDialogState extends State<OpenUrlDialog> {
  final _textController = TextEditingController();
  String? _error;
  String? _clipboardSuggestion;

  @override
  void initState() {
    super.initState();
    unawaited(_loadClipboardSuggestion());
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<String?> _readClipboardText() async {
    if (widget.readClipboard != null) {
      return widget.readClipboard!();
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  Future<void> _loadClipboardSuggestion() async {
    try {
      final raw = await _readClipboardText();
      final trimmed = raw?.trim();
      if (!mounted || trimmed == null || trimmed.isEmpty) return;
      final validation = MediaSource.validate(trimmed);
      if (validation.isValid &&
          MediaSource.isNetworkUrl(validation.source ?? '')) {
        setState(() => _clipboardSuggestion = validation.source);
      }
    } catch (_) {
      // Clipboard may be unavailable on some platforms/tests.
    }
  }

  void _applyUrlText(String text) {
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {
      if (_error != null) _error = null;
    });
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final raw = await _readClipboardText();
      final text = raw?.trim();
      if (!mounted || text == null || text.isEmpty) return;
      _applyUrlText(text);
    } catch (_) {
      // Clipboard may be unavailable on some platforms/tests.
    }
  }

  void _submit({required bool enqueue}) {
    final value = _textController.text.trim();
    final validation = MediaSource.validate(value);
    if (!validation.isValid || !MediaSource.isNetworkUrl(validation.source!)) {
      setState(
        () =>
            _error = validation.error ?? 'Enter a valid http or https address.',
      );
      return;
    }
    final source = validation.source!;
    if (widget.allowEnqueue) {
      Navigator.of(
        context,
      ).pop<Object>(OpenUrlResult(url: source, enqueue: enqueue));
    } else {
      Navigator.of(context).pop<Object>(source);
    }
  }

  static String _displayHost(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final palette = context.palette;
    final showSuggestion =
        _clipboardSuggestion != null &&
        _clipboardSuggestion != _textController.text.trim();

    return AppDialog(
      maxWidth: 460,
      title: const Text('Open URL'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Text(
              'Paste a video link, HLS/DASH stream, or direct media URL.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          AnimatedSize(
            duration: AppMotion.duration(context, AppMotion.quick),
            curve: AppMotion.standardCurve,
            alignment: Alignment.topCenter,
            child: TextField(
              key: const ValueKey('open-url-input'),
              controller: _textController,
              autofocus: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              cursorColor: accent,
              onChanged: (_) => setState(() {
                if (_error != null) _error = null;
              }),
              onSubmitted: (_) => _submit(enqueue: false),
              decoration: InputDecoration(
                labelText: 'Video URL',
                hintText: 'https://example.com/video.mp4',
                errorText: _error,
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: IconButton(
                  onPressed: () => unawaited(_pasteFromClipboard()),
                  tooltip: 'Paste URL',
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.artwork),
                  borderSide: BorderSide(color: palette.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.artwork),
                  borderSide: BorderSide(color: palette.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.artwork),
                  borderSide: BorderSide(color: accent, width: 1.3),
                ),
              ),
            ),
          ),
          if (showSuggestion) ...[
            const SizedBox(height: AppSpace.sm),
            ActionChip(
              key: const ValueKey('open-url-clipboard-chip'),
              avatar: Icon(
                Icons.content_paste_go_rounded,
                size: 16,
                color: accent,
              ),
              label: Text(
                'Use clipboard link (${_displayHost(_clipboardSuggestion!)})',
                overflow: TextOverflow.ellipsis,
              ),
              side: BorderSide(color: accent.withValues(alpha: 0.35)),
              backgroundColor: accent.withValues(alpha: 0.1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              onPressed: () => _applyUrlText(_clipboardSuggestion!),
            ),
          ],
          if (widget.recentUrls.isNotEmpty) ...[
            const SizedBox(height: AppSpace.md),
            Text(
              'Recent streams',
              style: palette.metadata.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpace.xs),
            for (final entry in widget.recentUrls.take(4))
              InkWell(
                borderRadius: BorderRadius.circular(AppRadii.control),
                onTap: () => _applyUrlText(entry.path),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.xs,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 16,
                        color: palette.mutedText,
                      ),
                      const SizedBox(width: AppSpace.xs),
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: AppSpace.xs),
                      Text(_displayHost(entry.path), style: palette.metadata),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: accent,
            minimumSize: const Size(72, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (widget.allowEnqueue)
          OutlinedButton.icon(
            key: const ValueKey('open-url-enqueue'),
            style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              minimumSize: const Size(124, 44),
              side: BorderSide(color: accent.withValues(alpha: 0.45)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
            ),
            onPressed: () => _submit(enqueue: true),
            icon: const Icon(Icons.playlist_add_rounded, size: 18),
            label: const Text('Add to queue'),
          ),
        FilledButton.icon(
          key: const ValueKey('open-url-submit'),
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: palette.accentForeground,
            minimumSize: const Size(92, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: () => _submit(enqueue: false),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Open'),
        ),
      ],
    );
  }
}
