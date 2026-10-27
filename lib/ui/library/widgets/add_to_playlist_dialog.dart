import 'package:flutter/material.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../core/app_theme.dart';
import 'playlist_create_dialog.dart';

/// Lets a library item be added to an existing or newly created playlist.
class AddToPlaylistDialog extends StatefulWidget {
  const AddToPlaylistDialog({
    super.key,
    required this.repository,
    required this.mediaId,
  });

  final MediaLibraryRepository repository;
  final String mediaId;

  static Future<bool> show(
    BuildContext context,
    MediaLibraryRepository repository,
    String mediaId,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) =>
            AddToPlaylistDialog(repository: repository, mediaId: mediaId),
      ) ??
      false;

  @override
  State<AddToPlaylistDialog> createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<AddToPlaylistDialog> {
  late Future<List<PlaylistRecord>> _playlists;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _playlists = widget.repository.getPlaylists();
  }

  Future<void> _add(PlaylistRecord playlist) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repository.addToPlaylist(playlist.id, [widget.mediaId]);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not add this item. Try again.';
        });
      }
    }
  }

  Future<void> _createAndAdd() async {
    final playlist = await PlaylistCreateDialog.show(
      context,
      widget.repository,
    );
    if (playlist != null && mounted) await _add(playlist);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: const Text('Add to playlist', style: AppTheme.sectionTitle),
      content: SizedBox(
        width: 360,
        child: FutureBuilder<List<PlaylistRecord>>(
          future: _playlists,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Text(
                'Could not load playlists.',
                style: AppTheme.rowSecondary,
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final playlists = snapshot.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (playlists.isEmpty)
                  const Text(
                    'Create a playlist to add this item.',
                    style: AppTheme.rowSecondary,
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        return ListTile(
                          title: Text(
                            playlist.title,
                            style: AppTheme.rowPrimary,
                          ),
                          subtitle: Text(
                            '${playlist.entryCount} items',
                            style: AppTheme.metadata,
                          ),
                          onTap: _saving ? null : () => _add(playlist),
                        );
                      },
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppTheme.danger)),
                ],
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _createAndAdd,
          icon: const Icon(Icons.add_rounded),
          label: const Text('New playlist'),
        ),
      ],
    );
  }
}
