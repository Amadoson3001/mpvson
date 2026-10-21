import 'package:flutter/material.dart';

import '../../core/app_motion.dart';

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
  Widget build(BuildContext context) => AlertDialog(
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
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _open(),
              decoration: InputDecoration(
                labelText: 'Video URL',
                hintText: 'https://example.com/video.mp4',
                errorText: _error,
                prefixIcon: const Icon(Icons.link_rounded),
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(72, 44)),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(92, 44)),
        onPressed: _open,
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('Open'),
      ),
    ],
  );
}
