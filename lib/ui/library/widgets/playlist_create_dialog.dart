import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../core/app_theme.dart';

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
    return Dialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.artwork),
        side: const BorderSide(color: AppTheme.border),
      ),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.xl,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Create playlist', style: AppTheme.albumTitle),
              const SizedBox(height: 8),
              Text(
                'Give your new playlist a descriptive name.',
                style: AppTheme.rowSecondary,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _titleController,
                enabled: !_isCreating,
                autofocus: true,
                style: AppTheme.rowPrimary,
                cursorColor: accent,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: 'e.g. Synthwave Favorites',
                  hintStyle: AppTheme.metadata,
                  filled: true,
                  fillColor: AppTheme.raisedSurface,
                  errorText: _error,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: 14,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    borderSide: const BorderSide(color: AppTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    borderSide: BorderSide(color: accent, width: 1.5),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    borderSide: const BorderSide(color: AppTheme.danger),
                  ),
                  focusedErrorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    borderSide: const BorderSide(
                      color: AppTheme.danger,
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
                      foregroundColor: AppTheme.secondaryText,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.md,
                        vertical: AppSpace.sm,
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _isCreating ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: AppTheme.background,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: AppSpace.sm,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                      textStyle: const TextStyle(
                        fontSize: AppType.small,
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
                                AppTheme.background,
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
