import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';
import '../../../core/components/empty_state.dart';
import '../../../core/toast/app_toast.dart';
import '../../../../data/repositories/media_library_repository.dart';
import '../../../../domain/models/media_entry.dart';

class LibraryFoldersView extends StatelessWidget {
  const LibraryFoldersView({super.key, required this.repository});

  final MediaLibraryRepository repository;

  @override
  Widget build(BuildContext context) =>
      MediaLibrarySettingsSection(libraryRepository: repository);
}

class MediaLibrarySettingsSection extends StatefulWidget {
  const MediaLibrarySettingsSection({
    super.key,
    required this.libraryRepository,
    this.pickDirectory,
  });

  final MediaLibraryRepository libraryRepository;
  final Future<String?> Function()? pickDirectory;

  @override
  State<MediaLibrarySettingsSection> createState() =>
      _MediaLibrarySettingsSectionState();
}

class _MediaLibrarySettingsSectionState
    extends State<MediaLibrarySettingsSection> {
  /// Folder operations currently in flight. The mutating controls stay
  /// disabled while this is non-zero so the repository never runs two folder
  /// mutations concurrently.
  int _pendingOperations = 0;

  bool get _busy => _pendingOperations > 0;

  /// Runs [operation] with the readiness gate engaged; errors propagate to
  /// the caller for its own messaging.
  Future<void> _runOperation(Future<void> Function() operation) async {
    setState(() => _pendingOperations++);
    try {
      await operation();
    } finally {
      if (mounted) setState(() => _pendingOperations--);
    }
  }

  Future<void> _addFolder() async {
    try {
      final path = await (widget.pickDirectory != null
          ? widget.pickDirectory!()
          : getDirectoryPath());
      if (path == null || path.isEmpty) return;
      final formattedPath = MediaEntry.formatDisplayPath(path);
      await _runOperation(
        () => widget.libraryRepository.addFolder(formattedPath),
      );
    } catch (_) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not add folder. Please check directory permissions.',
        tone: AppToastTone.danger,
      );
    }
  }

  Future<void> _removeFolder(String path) async {
    try {
      await _runOperation(() => widget.libraryRepository.removeFolder(path));
    } catch (_) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not remove that folder. Please check directory permissions.',
        tone: AppToastTone.danger,
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.libraryRepository,
    builder: (context, _) {
      final repository = widget.libraryRepository;
      final folders = repository.folders;
      final theme = Theme.of(context);
      final accent = theme.colorScheme.primary;
      // Readiness gate: the repository must be initialized AND no folder
      // operation may be in flight before the mutating controls re-arm.
      final isReady = repository.isReady && !_busy;

      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 24, 40, 16),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('add-folder-button'),
                      icon: const Icon(
                        Icons.create_new_folder_outlined,
                        size: 17,
                      ),
                      label: const Text('Add media folder'),
                      onPressed: isReady ? _addFolder : null,
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('rescan-all-button'),
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('Rescan library'),
                      onPressed: isReady && folders.isNotEmpty
                          ? () => unawaited(_runOperation(repository.rescanAll))
                          : null,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: folders.isEmpty
                    ? const EmptyState(
                        title: 'No media folders added',
                        message:
                            'Add folders containing videos or music to build your local catalog.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 8,
                        ),
                        itemCount: folders.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final folder = folders[index];
                          return Material(
                            color: theme.colorScheme.surfaceContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              side: BorderSide(
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.6),
                              ),
                            ),
                            child: ListTile(
                              leading: Icon(
                                folder.isAvailable
                                    ? Icons.folder_rounded
                                    : Icons.folder_off_rounded,
                                color: folder.isAvailable
                                    ? accent
                                    : theme.colorScheme.error,
                                size: 24,
                              ),
                              title: Tooltip(
                                message: folder.displayPath,
                                waitDuration: const Duration(milliseconds: 500),
                                child: Text(
                                  folder.displayPath,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              subtitle: Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: folder.isAvailable
                                          ? context.palette.success
                                          : context.palette.danger,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    folder.isAvailable
                                        ? 'Available'
                                        : 'Drive unavailable',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: folder.isAvailable
                                          ? theme.colorScheme.onSurfaceVariant
                                          : context.palette.danger,
                                    ),
                                  ),
                                  const Text(' · '),
                                  Expanded(
                                    child: Text(
                                      '${folder.fileCount} indexed ${folder.fileCount == 1 ? 'file' : 'files'}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              trailing: IconButton(
                                key: ValueKey('remove-folder-${folder.path}'),
                                tooltip: 'Remove folder',
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 19,
                                ),
                                onPressed: isReady
                                    ? () =>
                                          unawaited(_removeFolder(folder.path))
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
