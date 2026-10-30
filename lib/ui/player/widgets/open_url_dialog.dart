import 'package:flutter/material.dart';

import '../../core/app_motion.dart';
import '../../core/app_theme.dart';

class OpenUrlDialog extends StatefulWidget {
  const OpenUrlDialog({super.key});

  @override
  State<OpenUrlDialog> createState() => _OpenUrlDialogState();
}

class _OpenUrlDialogState extends State<OpenUrlDialog> {
  final _textController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _open() {
    final value = _textController.text.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) {
      setState(() => _error = 'Enter a valid http or https address.');
      return;
    }
    Navigator.of(context).pop(uri.toString());
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        side: BorderSide(color: context.palette.border),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 20, 16),
      title: const Text('Open URL'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Enter an HTTP or HTTPS address to play a stream.',
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
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _open(),
                decoration: InputDecoration(
                  labelText: 'Video URL',
                  hintText: 'https://example.com/video.mp4',
                  errorText: _error,
                  prefixIcon: const Icon(Icons.link_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    borderSide: BorderSide(color: context.palette.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    borderSide: BorderSide(color: context.palette.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    borderSide: BorderSide(color: accent, width: 1.3),
                  ),
                ),
              ),
            ),
          ],
        ),
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
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: context.palette.accentForeground,
            minimumSize: const Size(92, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
          onPressed: _open,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Open'),
        ),
      ],
    );
  }
}
