import 'package:flutter/material.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../player/player_controller.dart';
import '../theme/library_theme.dart';
import '../widgets/docked_queue_widget.dart';
import '../widgets/library_status_banner.dart';
import 'music_view.dart';
import 'now_playing_view.dart';
import 'playlists_view.dart';
import 'videos_view.dart';

enum LibrarySection {
  videos,
  music,
  playlists,
  nowPlaying,
}

/// Top-level shell integrating navigation, search, content stage, and responsive layout.
class LibraryShell extends StatefulWidget {
  const LibraryShell({
    super.key,
    required this.repository,
    required this.controller,
    this.initialSection = LibrarySection.music,
    this.onAddFolders,
    this.onShowInFolder,
    this.onSwitchToVideo,
  });

  final MediaLibraryRepository repository;
  final PlayerController controller;
  final LibrarySection initialSection;
  final VoidCallback? onAddFolders;
  final ValueChanged<String>? onShowInFolder;
  final VoidCallback? onSwitchToVideo;

  @override
  State<LibraryShell> createState() => _LibraryShellState();
}

class _LibraryShellState extends State<LibraryShell> {
  late LibrarySection _currentSection;
  final _searchController = TextEditingController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String _searchQuery = '';
  bool _isOnDemandQueueOpen = false;

  @override
  void initState() {
    super.initState();
    _currentSection = widget.initialSection;
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text;
    });
  }

  void _selectSection(LibrarySection section) {
    setState(() {
      _currentSection = section;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isDesktopWide = width >= 1180;
        final isDesktopMedium = width >= 960 && width < 1180;
        final isCompact = width < 960;

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: LibraryTheme.background,
          drawer: isCompact ? _buildNavigationDrawer() : null,
          body: Row(
            children: [
              // 1. Navigation: 208px sidebar on >=1180, collapsed 64px rail on 960-1179, drawer on <960
              if (isDesktopWide) ...[
                SizedBox(
                  width: 208,
                  child: _buildSideNav(isCollapsed: false),
                ),
                const VerticalDivider(width: 1, color: LibraryTheme.border),
              ] else if (isDesktopMedium) ...[
                SizedBox(
                  width: 64,
                  child: _buildSideNav(isCollapsed: true),
                ),
                const VerticalDivider(width: 1, color: LibraryTheme.border),
              ],

              // 2. Main Content Area: Top bar + Status Banner + Active Stage + Stacked Audio Bar
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header Bar (Search & Mobile Drawer Trigger)
                    _buildHeaderBar(isCompact, isDesktopMedium),
                    // Status Banners (Scanning indicator, Unavailable drive warning)
                    LibraryStatusBanner(
                      repository: widget.repository,
                      onRescan: () => widget.repository.rescanAll(),
                    ),
                    // Main Stage View
                    Expanded(
                      child: _buildContentStage(),
                    ),
                    // Stacked Audio Layout (Mini Player at bottom when not in NowPlaying view)
                    if (_currentSection != LibrarySection.nowPlaying)
                      _buildBottomMiniPlayer(isCompact),
                  ],
                ),
              ),

              // 3. Docked Queue Panel
              if (isDesktopWide && _currentSection != LibrarySection.nowPlaying) ...[
                const VerticalDivider(width: 1, color: LibraryTheme.border),
                SizedBox(
                  width: 280,
                  child: DockedQueueWidget(controller: widget.controller),
                ),
              ] else if (isDesktopMedium && _isOnDemandQueueOpen && _currentSection != LibrarySection.nowPlaying) ...[
                const VerticalDivider(width: 1, color: LibraryTheme.border),
                SizedBox(
                  width: 280,
                  child: DockedQueueWidget(
                    controller: widget.controller,
                    onClose: () => setState(() => _isOnDemandQueueOpen = false),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // --- Header Bar ---

  Widget _buildHeaderBar(bool isCompact, bool isDesktopMedium) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: LibraryTheme.surface,
      child: Row(
        children: [
          if (isCompact) ...[
            IconButton(
              icon: const Icon(Icons.menu_rounded),
              tooltip: 'Open navigation',
              color: LibraryTheme.primaryText,
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            const SizedBox(width: 8),
          ],
          // Search input field
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: SizedBox(
                height: 38,
                child: TextField(
                  controller: _searchController,
                  style: LibraryTheme.rowPrimary.copyWith(fontSize: 13),
                  cursorColor: LibraryTheme.accent,
                  decoration: InputDecoration(
                    hintText: 'Search in ${_sectionName(_currentSection)}...',
                    hintStyle: LibraryTheme.metadata,
                    prefixIcon: const Icon(Icons.search_rounded, size: 18, color: LibraryTheme.mutedText),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close_rounded, size: 16),
                            color: LibraryTheme.mutedText,
                            onPressed: () => _searchController.clear(),
                          )
                        : null,
                    filled: true,
                    fillColor: LibraryTheme.raisedSurface,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: LibraryTheme.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: LibraryTheme.accent, width: 1.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Rescan / Refresh library button
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: 'Rescan library',
            color: LibraryTheme.secondaryText,
            onPressed: () => widget.repository.rescanAll(),
          ),
          if (widget.onSwitchToVideo != null && (widget.controller.isVideo || widget.controller.hasMedia)) ...[
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.videocam_rounded, size: 20),
              tooltip: 'Switch to video player',
              color: LibraryTheme.accent,
              onPressed: widget.onSwitchToVideo,
            ),
          ],
          // Medium screen On-Demand Queue Toggle
          if (isDesktopMedium && _currentSection != LibrarySection.nowPlaying) ...[
            const SizedBox(width: 6),
            IconButton(
              icon: Icon(
                Icons.queue_music_rounded,
                size: 20,
                color: _isOnDemandQueueOpen ? LibraryTheme.accent : LibraryTheme.secondaryText,
              ),
              tooltip: _isOnDemandQueueOpen ? 'Close queue' : 'Open queue',
              onPressed: () => setState(() => _isOnDemandQueueOpen = !_isOnDemandQueueOpen),
            ),
          ],
        ],
      ),
    );
  }

  String _sectionName(LibrarySection s) {
    return switch (s) {
      LibrarySection.videos => 'videos',
      LibrarySection.music => 'music',
      LibrarySection.playlists => 'playlists',
      LibrarySection.nowPlaying => 'now playing',
    };
  }

  // --- Content Stage ---

  Widget _buildContentStage() {
    switch (_currentSection) {
      case LibrarySection.videos:
        return VideosView(
          repository: widget.repository,
          controller: widget.controller,
          searchQuery: _searchQuery,
          onAddFolders: widget.onAddFolders,
          onShowInFolder: widget.onShowInFolder,
        );
      case LibrarySection.music:
        return MusicView(
          repository: widget.repository,
          controller: widget.controller,
          searchQuery: _searchQuery,
          onAddFolders: widget.onAddFolders,
          onShowInFolder: widget.onShowInFolder,
        );
      case LibrarySection.playlists:
        return PlaylistsView(
          repository: widget.repository,
          controller: widget.controller,
          searchQuery: _searchQuery,
        );
      case LibrarySection.nowPlaying:
        return NowPlayingView(
          controller: widget.controller,
          repository: widget.repository,
          onBack: () => _selectSection(LibrarySection.music),
        );
    }
  }

  // --- Side Navigation & Collapsed Rail ---

  Widget _buildSideNav({required bool isCollapsed}) {
    return Container(
      color: LibraryTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // App Logo / Title
          Container(
            height: 56,
            padding: EdgeInsets.symmetric(horizontal: isCollapsed ? 12 : 20),
            alignment: isCollapsed ? Alignment.center : Alignment.centerLeft,
            child: Row(
              mainAxisAlignment: isCollapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: LibraryTheme.accent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Center(
                    child: Icon(Icons.play_arrow_rounded, color: LibraryTheme.background, size: 20),
                  ),
                ),
                if (!isCollapsed) ...[
                  const SizedBox(width: 12),
                  const Text(
                    'Mpvson',
                    style: TextStyle(
                      color: LibraryTheme.primaryText,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: LibraryTheme.border),
          const SizedBox(height: 12),
          // Nav Items
          _navItem(LibrarySection.videos, 'Videos', Icons.movie_outlined, Icons.movie_rounded, isCollapsed),
          _navItem(LibrarySection.music, 'Music', Icons.music_note_outlined, Icons.music_note_rounded, isCollapsed),
          _navItem(LibrarySection.playlists, 'Playlists', Icons.queue_music_outlined, Icons.queue_music_rounded, isCollapsed),
          _navItem(LibrarySection.nowPlaying, 'Now playing', Icons.album_outlined, Icons.album_rounded, isCollapsed),
          const Spacer(),
          // Add Folder Action button
          if (!isCollapsed && widget.onAddFolders != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: LibraryTheme.primaryText,
                  side: const BorderSide(color: LibraryTheme.border),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: widget.onAddFolders,
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('Add folders', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _navItem(
    LibrarySection section,
    String label,
    IconData unselectedIcon,
    IconData selectedIcon,
    bool isCollapsed,
  ) {
    final isSelected = _currentSection == section;
    final icon = isSelected ? selectedIcon : unselectedIcon;

    if (isCollapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: IconButton(
          icon: Icon(icon, size: 22),
          tooltip: label,
          color: isSelected ? LibraryTheme.accent : LibraryTheme.secondaryText,
          style: IconButton.styleFrom(
            backgroundColor: isSelected ? LibraryTheme.raisedSurface : Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: () => _selectSection(section),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: InkWell(
        onTap: () => _selectSection(section),
        borderRadius: BorderRadius.circular(8),
        hoverColor: LibraryTheme.hover,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? LibraryTheme.raisedSurface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? LibraryTheme.accent.withValues(alpha: 0.3) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? LibraryTheme.accent : LibraryTheme.secondaryText,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected ? LibraryTheme.primaryText : LibraryTheme.secondaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Drawer for < 960px Screens ---

  Widget _buildNavigationDrawer() {
    return Drawer(
      backgroundColor: LibraryTheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: LibraryTheme.accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Center(
                      child: Icon(Icons.play_arrow_rounded, color: LibraryTheme.background, size: 24),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Mpvson Library',
                      style: TextStyle(
                        color: LibraryTheme.primaryText,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: LibraryTheme.border),
            const SizedBox(height: 8),
            _drawerItem(LibrarySection.videos, 'Videos', Icons.movie_rounded),
            _drawerItem(LibrarySection.music, 'Music', Icons.music_note_rounded),
            _drawerItem(LibrarySection.playlists, 'Playlists', Icons.queue_music_rounded),
            _drawerItem(LibrarySection.nowPlaying, 'Now playing', Icons.album_rounded),
            const Spacer(),
            if (widget.onAddFolders != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: LibraryTheme.accent,
                    foregroundColor: LibraryTheme.background,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onAddFolders?.call();
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add folders'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(LibrarySection section, String label, IconData icon) {
    final isSelected = _currentSection == section;
    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? LibraryTheme.accent : LibraryTheme.secondaryText,
      ),
      title: Text(
        label,
        style: TextStyle(
          color: isSelected ? LibraryTheme.primaryText : LibraryTheme.secondaryText,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      selected: isSelected,
      selectedTileColor: LibraryTheme.raisedSurface,
      onTap: () {
        _selectSection(section);
        Navigator.of(context).pop();
      },
    );
  }

  // --- Stacked Audio Layout (Bottom Mini Player) ---

  Widget _buildBottomMiniPlayer(bool isCompact) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final current = widget.controller.current;
        if (current == null && widget.controller.queue.isEmpty) {
          return const SizedBox.shrink();
        }

        final title = current?.title ?? 'No Track Playing';
        final isPlaying = widget.controller.isPlaying;

        return InkWell(
          onTap: () => _selectSection(LibrarySection.nowPlaying),
          hoverColor: LibraryTheme.hover,
          child: Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: LibraryTheme.surface,
              border: Border(top: BorderSide(color: LibraryTheme.border)),
            ),
            child: Row(
              children: [
                // Mini Artwork
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: LibraryTheme.raisedSurface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: LibraryTheme.border),
                  ),
                  child: const Center(
                    child: Icon(Icons.music_note_rounded, size: 20, color: LibraryTheme.accent),
                  ),
                ),
                const SizedBox(width: 12),
                // Title
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: LibraryTheme.rowPrimary.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Now Playing',
                        style: LibraryTheme.metadata,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Play / Pause
                IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 26,
                    color: LibraryTheme.primaryText,
                  ),
                  tooltip: isPlaying ? 'Pause' : 'Play',
                  onPressed: () => widget.controller.togglePlayPause(),
                ),
                // Next
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded, size: 24, color: LibraryTheme.secondaryText),
                  tooltip: 'Next',
                  onPressed: () => widget.controller.next(),
                ),
                if (isCompact) ...[
                  IconButton(
                    icon: const Icon(Icons.queue_music_rounded, size: 20, color: LibraryTheme.secondaryText),
                    tooltip: 'Queue',
                    onPressed: () => _selectSection(LibrarySection.nowPlaying),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
