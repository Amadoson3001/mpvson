import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/media_catalog.dart';
import '../../player/player_controller.dart';
import '../../core/app_theme.dart';
import '../../core/components/seek_bar.dart';
import '../../core/components/app_mark.dart';
import '../../player/widgets/queue_panel.dart';
import '../../player/widgets/player_controls.dart';
import '../widgets/audio_volume_control.dart';
import '../widgets/library_status_banner.dart';
import '../widgets/library_artwork.dart';
import 'music_view.dart';
import 'now_playing_view.dart';
import 'playlists_view.dart';
import 'videos_view.dart';

enum LibrarySection {
  home,
  videos,
  music,
  playlists,
  folders,
  nowPlaying,
  settings,
}

/// Top-level shell integrating navigation, search, content stage, and responsive layout.
class LibraryShell extends StatefulWidget {
  const LibraryShell({
    super.key,
    required this.repository,
    required this.controller,
    this.initialSection = LibrarySection.home,
    this.home,
    this.onOpenFiles,
    this.onOpenUrl,
    this.onAddQueueFiles,
    this.onAddFolders,
    this.onShowInFolder,
    this.onBackToPlayer,
    this.settings,
    this.folders,
    this.showSettings = false,
    this.onSettings,
    this.onCloseSettings,
    this.homeNavigationRequest = 0,
    this.queueOpen,
    this.onQueueOpenChanged,
  });

  final MediaLibraryRepository repository;
  final PlayerController controller;
  final LibrarySection initialSection;
  final Widget? home;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onOpenUrl;
  final VoidCallback? onAddQueueFiles;
  final VoidCallback? onAddFolders;
  final ValueChanged<String>? onShowInFolder;
  final VoidCallback? onBackToPlayer;
  final Widget? settings;
  final Widget? folders;
  final bool showSettings;
  final VoidCallback? onSettings;
  final VoidCallback? onCloseSettings;
  final int homeNavigationRequest;
  final bool? queueOpen;
  final ValueChanged<bool>? onQueueOpenChanged;

  @override
  State<LibraryShell> createState() => _LibraryShellState();
}

class _LibraryShellState extends State<LibraryShell> {
  late LibrarySection _currentSection;
  LibrarySection _previousSection = LibrarySection.home;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String _searchQuery = '';
  bool _isOnDemandQueueOpen = false;

  bool get _isQueueOpen => widget.queueOpen ?? _isOnDemandQueueOpen;

  void _setQueueOpen(bool next) {
    setState(() => _isOnDemandQueueOpen = next);
    widget.onQueueOpenChanged?.call(next);
  }

  @override
  void initState() {
    super.initState();
    _currentSection = widget.showSettings
        ? LibrarySection.settings
        : widget.initialSection;
    _isOnDemandQueueOpen = widget.queueOpen ?? false;
    _searchController.addListener(_onSearchChanged);
    widget.controller.addListener(_onPlaybackChanged);
  }

  @override
  void didUpdateWidget(LibraryShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPlaybackChanged);
      widget.controller.addListener(_onPlaybackChanged);
    }
    if (widget.queueOpen != oldWidget.queueOpen && widget.queueOpen != null) {
      _isOnDemandQueueOpen = widget.queueOpen!;
    }
    if (widget.showSettings != oldWidget.showSettings) {
      if (widget.showSettings) {
        _previousSection = _currentSection;
        _currentSection = LibrarySection.settings;
      } else if (_currentSection == LibrarySection.settings) {
        _currentSection = _previousSection;
      }
    }
    if (widget.homeNavigationRequest != oldWidget.homeNavigationRequest) {
      _searchController.removeListener(_onSearchChanged);
      _searchController.clear();
      _searchController.addListener(_onSearchChanged);
      _searchQuery = '';
      _currentSection = LibrarySection.home;
      _previousSection = LibrarySection.home;
      _isOnDemandQueueOpen = false;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPlaybackChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onPlaybackChanged() {
    if (mounted &&
        widget.controller.current == null &&
        _currentSection == LibrarySection.nowPlaying) {
      setState(() => _currentSection = _previousSection);
    }
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text;
    });
  }

  void _selectSection(LibrarySection section) {
    if (section == LibrarySection.settings && widget.onSettings != null) {
      widget.onSettings!();
      return;
    }
    if (_currentSection == section) return;
    if (_currentSection == LibrarySection.settings) {
      widget.onCloseSettings?.call();
    }
    _searchController.clear();
    setState(() {
      if (section == LibrarySection.nowPlaying &&
          _currentSection != LibrarySection.nowPlaying) {
        _previousSection = _currentSection;
      }
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

        return Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            final focused = FocusManager.instance.primaryFocus?.context;
            final editing =
                focused?.widget is EditableText ||
                focused?.findAncestorWidgetOfExactType<EditableText>() != null;
            if (!editing &&
                event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.slash) {
              _searchFocus.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.keyK,
                control: true,
              ): () =>
                  _searchFocus.requestFocus(),
            },
            child: Scaffold(
              key: _scaffoldKey,
              backgroundColor: AppTheme.background,
              drawer: isCompact ? _buildNavigationDrawer() : null,
              body: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        // 1. Navigation: 208px sidebar on >=1180, collapsed 64px rail on 960-1179, drawer on <960
                        if (isDesktopWide) ...[
                          SizedBox(
                            width: 208,
                            child: _buildSideNav(isCollapsed: false),
                          ),
                          const VerticalDivider(
                            width: 1,
                            color: AppTheme.border,
                          ),
                        ] else if (isDesktopMedium) ...[
                          SizedBox(
                            width: 64,
                            child: _buildSideNav(isCollapsed: true),
                          ),
                          const VerticalDivider(
                            width: 1,
                            color: AppTheme.border,
                          ),
                        ],

                        // 2. Main Content Area: Top bar + Status Banner + Active Stage + Stacked Audio Bar
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Header Bar (Search & Mobile Drawer Trigger)
                              AnimatedBuilder(
                                animation: widget.controller,
                                builder: (context, _) => _buildHeaderBar(
                                  isCompact,
                                  !isCompact,
                                  showBackLabel: width >= 600,
                                ),
                              ),
                              // Status Banners (Scanning indicator, Unavailable drive warning)
                              LibraryStatusBanner(
                                repository: widget.repository,
                                onRescan: () => widget.repository.rescanAll(),
                              ),
                              // Main Stage View
                              Expanded(child: _buildContentStage()),
                            ],
                          ),
                        ),

                        // 3. Docked Queue Panel
                        if (!isCompact && _isQueueOpen) ...[
                          const VerticalDivider(
                            width: 1,
                            color: AppTheme.border,
                          ),
                          SizedBox(
                            width: 280,
                            child: QueuePanel(
                              controller: widget.controller,
                              onQueueFocus: (_) {},
                              onAddFiles: widget.onAddQueueFiles ?? () {},
                              onClose: () => _setQueueOpen(false),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _buildBottomMiniPlayer(isCompact),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Header Bar ---

  Widget _buildHeaderBar(
    bool isCompact,
    bool canDockQueue, {
    required bool showBackLabel,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    final queueOpen = _isQueueOpen;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      color: AppTheme.surface,
      child: Row(
        children: [
          if (widget.onBackToPlayer != null) ...[
            if (showBackLabel)
              TextButton.icon(
                onPressed: widget.onBackToPlayer,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                label: const Text('Return to video'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.primaryText,
                ),
              )
            else
              IconButton(
                onPressed: widget.onBackToPlayer,
                tooltip: 'Return to video',
                icon: const Icon(Icons.arrow_back_rounded),
                color: AppTheme.primaryText,
              ),
            const SizedBox(width: 8),
          ],
          if (isCompact) ...[
            IconButton(
              icon: const Icon(Icons.menu_rounded),
              tooltip: 'Open navigation',
              color: AppTheme.primaryText,
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            const SizedBox(width: 8),
          ],
          // Search input field
          Expanded(
            child: _currentSection == LibrarySection.home
                ? const SizedBox.shrink()
                : _currentSection == LibrarySection.nowPlaying ||
                      _currentSection == LibrarySection.settings ||
                      _currentSection == LibrarySection.folders
                ? Text(
                    _currentSection == LibrarySection.nowPlaying
                        ? 'Now playing'
                        : _currentSection == LibrarySection.settings
                        ? 'Settings'
                        : 'Folders',
                    style: AppTheme.sectionTitle,
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: SizedBox(
                        height: 38,
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          style: AppTheme.rowPrimary.copyWith(
                            fontSize: AppType.small,
                          ),
                          cursorColor: accent,
                          decoration: InputDecoration(
                            hintText: 'Search ${_sectionName(_currentSection)}',
                            hintStyle: AppTheme.metadata,
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: AppTheme.mutedText,
                            ),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                    ),
                                    color: AppTheme.mutedText,
                                    tooltip: 'Clear search',
                                    onPressed: () => _searchController.clear(),
                                  )
                                : null,
                            filled: true,
                            fillColor: AppTheme.raisedSurface,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: AppSpace.xs,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              borderSide: const BorderSide(
                                color: AppTheme.border,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadii.control,
                              ),
                              borderSide: BorderSide(color: accent, width: 1.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          if (_currentSection != LibrarySection.home &&
              widget.onOpenFiles != null)
            IconButton(
              onPressed: widget.onOpenFiles,
              tooltip: 'Open file',
              icon: const Icon(Icons.file_open_rounded),
            ),
          if (_currentSection != LibrarySection.home &&
              widget.onOpenUrl != null)
            IconButton(
              onPressed: widget.onOpenUrl,
              tooltip: 'Open URL',
              icon: const Icon(Icons.link_rounded),
            ),
          const SizedBox(width: 12),
          // Medium screen On-Demand Queue Toggle
          if (canDockQueue) ...[
            const SizedBox(width: 6),
            IconButton(
              icon: Icon(
                Icons.queue_music_rounded,
                size: 20,
                color: queueOpen ? accent : AppTheme.secondaryText,
              ),
              tooltip: queueOpen ? 'Close queue' : 'Open queue',
              onPressed: () => _setQueueOpen(!queueOpen),
            ),
          ],
        ],
      ),
    );
  }

  String _sectionName(LibrarySection s) {
    return switch (s) {
      LibrarySection.home => 'home',
      LibrarySection.videos => 'videos',
      LibrarySection.music => 'music',
      LibrarySection.playlists => 'playlists',
      LibrarySection.folders => 'folders',
      LibrarySection.nowPlaying => 'now playing',
      LibrarySection.settings => 'settings',
    };
  }

  // --- Content Stage ---

  Widget _buildContentStage() {
    switch (_currentSection) {
      case LibrarySection.home:
        return widget.home ?? const SizedBox.shrink();
      case LibrarySection.settings:
        return widget.settings ?? const SizedBox.shrink();
      case LibrarySection.folders:
        return widget.folders ?? const SizedBox.shrink();
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
          onBack: () => _selectSection(_previousSection),
        );
    }
  }

  // --- Side Navigation & Collapsed Rail ---

  Widget _buildSideNav({required bool isCollapsed}) {
    return Container(
      color: AppTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // App Logo / Title
          Container(
            height: 56,
            padding: EdgeInsets.symmetric(
              horizontal: isCollapsed ? AppSpace.sm : 20,
            ),
            alignment: isCollapsed ? Alignment.center : Alignment.centerLeft,
            child: Row(
              mainAxisAlignment: isCollapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                const AppMark(size: 28),
                if (!isCollapsed) ...[
                  const SizedBox(width: 12),
                  const Text(
                    'Mpvson',
                    style: TextStyle(
                      color: AppTheme.primaryText,
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.border),
          const SizedBox(height: 12),
          // Nav Items
          _navItem(
            LibrarySection.home,
            'Home',
            Icons.home_rounded,
            Icons.home_rounded,
            isCollapsed,
          ),
          _navItem(
            LibrarySection.videos,
            'Videos',
            Icons.movie_rounded,
            Icons.movie_rounded,
            isCollapsed,
          ),
          _navItem(
            LibrarySection.music,
            'Music',
            Icons.music_note_rounded,
            Icons.music_note_rounded,
            isCollapsed,
          ),
          _navItem(
            LibrarySection.playlists,
            'Playlists',
            Icons.queue_music_rounded,
            Icons.queue_music_rounded,
            isCollapsed,
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: AppTheme.border),
          const SizedBox(height: 8),
          _navItem(
            LibrarySection.folders,
            'Folders',
            Icons.folder_rounded,
            Icons.folder_rounded,
            isCollapsed,
          ),
          const Spacer(),
          if (widget.onSettings != null)
            _navItem(
              LibrarySection.settings,
              'Settings',
              Icons.settings_rounded,
              Icons.settings_rounded,
              isCollapsed,
            ),
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
    final accent = Theme.of(context).colorScheme.primary;
    final icon = selectedIcon;

    if (isCollapsed) {
      return Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isSelected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(
          vertical: AppSpace.xxs,
          horizontal: AppSpace.xs,
        ),
        child: IconButton(
          icon: Icon(icon, size: 22),
          tooltip: label,
          color: isSelected ? accent : AppTheme.secondaryText,
          style: IconButton.styleFrom(
            backgroundColor: isSelected
                ? accent.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          onPressed: () => _selectSection(section),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
      child: InkWell(
        onTap: () => _selectSection(section),
        borderRadius: BorderRadius.circular(AppRadii.control),
        hoverColor: AppTheme.hover,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.sm,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? accent.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border(
              left: BorderSide(
                color: isSelected ? accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? accent : AppTheme.secondaryText,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: AppType.small,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected ? accent : AppTheme.secondaryText,
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
      backgroundColor: AppTheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, AppSpace.md),
              child: Row(
                children: [
                  const AppMark(size: 32),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Mpvson',
                      style: TextStyle(
                        color: AppTheme.primaryText,
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppTheme.border),
            const SizedBox(height: 8),
            _drawerItem(LibrarySection.home, 'Home', Icons.home_rounded),
            _drawerItem(LibrarySection.videos, 'Videos', Icons.movie_rounded),
            _drawerItem(
              LibrarySection.music,
              'Music',
              Icons.music_note_rounded,
            ),
            _drawerItem(
              LibrarySection.playlists,
              'Playlists',
              Icons.queue_music_rounded,
            ),
            _drawerItem(
              LibrarySection.folders,
              'Folders',
              Icons.folder_rounded,
            ),
            const Spacer(),
            if (widget.onSettings != null)
              _drawerItem(
                LibrarySection.settings,
                'Settings',
                Icons.settings_rounded,
              ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(LibrarySection section, String label, IconData icon) {
    final isSelected = _currentSection == section;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isSelected ? accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: ListTile(
        selected: isSelected,
        selectedColor: accent,
        tileColor: isSelected
            ? accent.withValues(alpha: 0.10)
            : Colors.transparent,
        leading: Icon(
          icon,
          color: isSelected ? accent : AppTheme.secondaryText,
        ),
        title: Text(
          label,
          style: TextStyle(
            color: isSelected ? accent : AppTheme.secondaryText,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        onTap: () {
          _selectSection(section);
          Navigator.of(context).pop();
        },
      ),
    );
  }

  void _showCompactQueue() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.8,
        child: QueuePanel(
          controller: widget.controller,
          onClose: () => Navigator.of(sheetContext).pop(),
          onQueueFocus: (_) {},
          onAddFiles: widget.onAddQueueFiles ?? () {},
        ),
      ),
    );
  }

  // --- Stacked Audio Layout (Bottom Mini Player) ---

  Widget _buildBottomMiniPlayer(bool isCompact) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final current = widget.controller.current;
        if (current == null) return const SizedBox.shrink();
        final title = current.title;
        final isVideo =
            widget.controller.isVideo ||
            MediaCatalog.kindFromExtension(current.path).isVideo;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AudioVolumeWheel(
              controller: widget.controller,
              child: Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  border: Border(top: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap:
                            widget.controller.isVideo &&
                                widget.onBackToPlayer != null
                            ? widget.onBackToPlayer
                            : () => _selectSection(LibrarySection.nowPlaying),
                        borderRadius: BorderRadius.circular(AppRadii.control),
                        hoverColor: AppTheme.hover,
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AppRadii.artwork,
                              ),
                              child: SizedBox(
                                width: 40,
                                height: 40,
                                child: LibraryArtwork(
                                  mediaPath: current.path,
                                  repository: widget.repository,
                                  iconSize: 20,
                                ),
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
                                    style: AppTheme.rowPrimary.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  FutureBuilder(
                                    key: ValueKey(current.path),
                                    future: widget.repository
                                        .getMediaByCanonicalSource(
                                          current.path,
                                        ),
                                    builder: (context, snapshot) => Text(
                                      isVideo
                                          ? 'Video'
                                          : snapshot.data?.artist ??
                                                'Unknown artist',
                                      style: AppTheme.metadata,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TransportButtons(
                      controller: widget.controller,
                      compact: false,
                    ),
                    AudioVolumeControl(
                      controller: widget.controller,
                      compact: true,
                    ),
                    if (isCompact) ...[
                      IconButton(
                        icon: const Icon(
                          Icons.queue_music_rounded,
                          size: 20,
                          color: AppTheme.secondaryText,
                        ),
                        tooltip: 'Queue',
                        onPressed: _showCompactQueue,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            SizedBox(height: 24, child: SeekBar(controller: widget.controller)),
          ],
        );
      },
    );
  }
}
