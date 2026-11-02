import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../core/app_theme.dart';
import '../../core/components/app_dialog.dart';

/// Modal dialog to create a new playlist.
class PlaylistCreateDialog extends StatefulWidget {
  const PlaylistCreateDialog({super.key, required this.repository});

  final MediaLibraryRepository repository;

  static Future<PlaylistRecord?> show(
    BuildContext context,
    MediaLibraryRepository repository,
  ) {
    return AppDialog.show<PlaylistRecord>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => PlaylistCreateDialog(repository: repository),
    );
  }

  @override
  State<PlaylistCreateDialog> createState() => _PlaylistCreateDialogState();
}

class _PlaylistCreateDialogState extends State<PlaylistCreateDialog> {
  final _titleController = TextEditingController();
  bool _isCreating = false;
  String? _error;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isCreating) return;
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Please enter a playlist title');
      return;
    }

    setState(() {
      _isCreating = true;
      _error = null;
    });

    try {
      final playlist = await widget.repository.createPlaylist(title);
      if (mounted) {
        Navigator.of(context).pop(playlist);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
          _error = 'Failed to create playlist: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AppDialog(
      maxWidth: 420,
      title: Text('Create playlist', style: context.palette.albumTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Give your new playlist a descriptive name.',
            style: context.palette.rowSecondary,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _titleController,
            enabled: !_isCreating,
            autofocus: true,
            style: context.palette.rowPrimary,
            cursorColor: accent,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'e.g. Synthwave Favorites',
              hintStyle: context.palette.metadata,
              filled: true,
              fillColor: context.palette.raisedSurface,
              errorText: _error,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpace.md,
                vertical: 14,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.artwork),
                borderSide: BorderSide(color: context.palette.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.artwork),
                borderSide: BorderSide(color: accent, width: 1.5),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.artwork),
                borderSide: BorderSide(color: context.palette.danger),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.artwork),
                borderSide: BorderSide(
                  color: context.palette.danger,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isCreating ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: context.palette.secondaryText,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isCreating ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: context.palette.accentForeground,
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: AppSpace.sm,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            textStyle: const TextStyle(
              fontFamily: AppType.family,
              fontSize: AppType.small,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: _isCreating
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      context.palette.background,
                    ),
                  ),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
