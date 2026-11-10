import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../core/components/page_header.dart';
import 'library_section.dart';

/// Top bar of the library shell.
///
/// One consistent strip for every section: navigation trigger on compact
/// widths, optional return-to-video, search on library pages, secondary
/// actions and the queue toggle. Page titles live in each page's own
/// `PageHeader`, not here.
class LibraryTopBar extends StatelessWidget {
  const LibraryTopBar({
    super.key,
    required this.section,
    required this.compact,
    required this.canDockQueue,
    required this.queueOpen,
    required this.searchController,
    required this.searchFocus,
    required this.onOpenNavigation,
    required this.onToggleQueue,
    this.onBackToPlayer,
    this.onOpenFiles,
    this.onOpenUrl,
  });

  final LibrarySection section;
  final bool compact;
  final bool canDockQueue;
  final bool queueOpen;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final VoidCallback onOpenNavigation;
  final VoidCallback onToggleQueue;
  final VoidCallback? onBackToPlayer;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onOpenUrl;

  bool get _showActions =>
      section != LibrarySection.home && section != LibrarySection.settings;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      height: AppLayout.headerHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final gutter = PageHeader.gutterFor(constraints.maxWidth);
          // IconButtons carry their own padding, so they sit closer to the edge.
          final startInset = compact ? AppSpace.xs : gutter;
          final showBackLabel = constraints.maxWidth >= 640;
          return Padding(
            padding: EdgeInsets.only(
              left: startInset,
              right: canDockQueue ? AppSpace.xs : gutter,
            ),
            child: Row(
              children: [
                if (compact)
                  IconButton(
                    icon: const Icon(Icons.menu_rounded),
                    tooltip: 'Open navigation',
                    color: palette.primaryText,
                    onPressed: onOpenNavigation,
                  ),
                if (onBackToPlayer != null) ...[
                  if (showBackLabel)
                    TextButton.icon(
                      onPressed: onBackToPlayer,
                      icon: const Icon(Icons.arrow_back_rounded, size: 18),
                      label: const Text('Return to video'),
                      style: TextButton.styleFrom(
                        foregroundColor: palette.primaryText,
                      ),
                    )
                  else
                    IconButton(
                      onPressed: onBackToPlayer,
                      tooltip: 'Return to video',
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: palette.primaryText,
                    ),
                  const SizedBox(width: AppSpace.xs),
                ],
                if (compact && onBackToPlayer == null)
                  const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: section.hasSearch
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 440),
                            child: _SearchField(
                              controller: searchController,
                              focusNode: searchFocus,
                              hint: 'Search ${section.hintName}',
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (_showActions && onOpenFiles != null)
                  IconButton(
                    onPressed: onOpenFiles,
                    tooltip: 'Open file',
                    color: palette.secondaryText,
                    icon: const Icon(Icons.file_open_rounded),
                  ),
                if (_showActions && onOpenUrl != null)
                  IconButton(
                    onPressed: onOpenUrl,
                    tooltip: 'Open URL',
                    color: palette.secondaryText,
                    icon: const Icon(Icons.link_rounded),
                  ),
                if (canDockQueue && section != LibrarySection.home)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: TextButton.icon(
                      onPressed: onToggleQueue,
                      icon: Icon(
                        Icons.queue_music_rounded,
                        size: 18,
                        color: queueOpen
                            ? palette.accent
                            : palette.secondaryText,
                      ),
                      label: Text(
                        'Queue',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: queueOpen
                                  ? palette.accent
                                  : palette.secondaryText,
                            ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        backgroundColor: queueOpen
                            ? palette.accent.withValues(alpha: 0.14)
                            : Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.control),
                          side: BorderSide(
                            color: queueOpen
                                ? palette.accent.withValues(alpha: 0.3)
                                : Colors.transparent,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.hint,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (controller.text.isNotEmpty) {
      controller.clear();
    } else {
      focusNode.unfocus();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.accent;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          borderSide: BorderSide(color: color, width: width),
        );
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onKey,
      child: SizedBox(
        height: 40,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => TextField(
            controller: controller,
            focusNode: focusNode,
            style: palette.rowPrimary,
            cursorColor: accent,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: palette.metadata.copyWith(fontSize: AppType.small),
              isDense: true,
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: palette.mutedText,
              ),
              suffixIcon: controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      color: palette.mutedText,
                      tooltip: 'Clear search',
                      onPressed: controller.clear,
                    )
                  : Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Center(
                        widthFactor: 1,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: palette.background.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: palette.border),
                          ),
                          child: Text(
                            'Ctrl+F',
                            style: palette.metadata.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: palette.mutedText,
                            ),
                          ),
                        ),
                      ),
                    ),
              filled: true,
              fillColor: palette.raisedSurface,
              contentPadding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              enabledBorder: border(palette.border),
              focusedBorder: border(accent, 1.5),
              border: border(palette.border),
            ),
          ),
        ),
      ),
    );
  }
}
