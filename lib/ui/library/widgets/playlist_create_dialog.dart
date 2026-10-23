import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../theme/library_theme.dart';

/// Modal dialog to create a new playlist.
class PlaylistCreateDialog extends StatefulWidget {
  const PlaylistCreateDialog({super.key, required this.repository});

  final MediaLibraryRepository repository;

  static Future<PlaylistRecord?> show(
    BuildContext context,
    MediaLibraryRepository repository,
  ) {
    return showDialog<PlaylistRecord>(
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
    return Dialog(
      backgroundColor: LibraryTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: LibraryTheme.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Create playlist', style: LibraryTheme.albumTitle),
              const SizedBox(height: 8),
              Text(
                'Give your new playlist a descriptive name.',
                style: LibraryTheme.rowSecondary,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _titleController,
                autofocus: true,
                style: LibraryTheme.rowPrimary,
                cursorColor: LibraryTheme.accent,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: 'e.g. Synthwave Favorites',
                  hintStyle: LibraryTheme.metadata,
                  filled: true,
                  fillColor: LibraryTheme.raisedSurface,
                  errorText: _error,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: LibraryTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: LibraryTheme.accent,
                      width: 1.5,
                    ),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: LibraryTheme.danger),
                  ),
                  focusedErrorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: LibraryTheme.danger,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isCreating
                        ? null
                        : () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: LibraryTheme.secondaryText,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _isCreating ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: LibraryTheme.accent,
                      foregroundColor: LibraryTheme.background,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: _isCreating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                LibraryTheme.background,
                              ),
                            ),
                          )
                        : const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
