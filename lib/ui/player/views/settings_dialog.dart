import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../../data/repositories/app_preferences_repository.dart';
import '../../../data/repositories/media_library_repository.dart';
import '../../../data/services/desktop_integration_service.dart';
import '../../../data/services/engine_update_service.dart';
import '../../../data/services/settings_backup_service.dart';
import '../../../data/services/update_service.dart';
import '../../../domain/models/control_density.dart';
import '../../../domain/models/library_models.dart';
import '../../../domain/models/player_shortcuts.dart';
import '../../../domain/models/playback_settings.dart';
import '../../core/app_motion.dart';
import '../../core/app_theme.dart';
import '../../core/slider_overlay.dart';
import '../player_controller.dart';
import '../settings_preferences_catalog.dart';
import 'update_center_dialog.dart';
import 'history_settings.dart';

part 'settings_sections.dart';
part 'settings_subtitles.dart';
part 'settings_shortcuts.dart';
part 'settings_management.dart';

ThemeData _settingsTheme(ThemeData base) {
  final textTheme = base.textTheme;
  return base.copyWith(
    textTheme: textTheme.copyWith(
      titleLarge: textTheme.titleLarge?.copyWith(fontSize: 24),
      titleMedium: textTheme.titleMedium?.copyWith(fontSize: 18),
      bodyMedium: textTheme.bodyMedium?.copyWith(fontSize: 14),
      bodySmall: textTheme.bodySmall?.copyWith(fontSize: 12),
      labelLarge: textTheme.labelLarge?.copyWith(fontSize: 14),
    ),
  );
}

enum SettingsSection {
  appearance,
  general,
  playback,
  video,
  audioSubtitles,
  historyPrivacy,
  mediaLibrary,
  shortcuts,
  updatesAbout,
  changed,
}

extension SettingsSectionDetails on SettingsSection {
  String get label => switch (this) {
    SettingsSection.general => 'General',
    SettingsSection.appearance => 'Appearance',
    SettingsSection.playback => 'Playback',
    SettingsSection.video => 'Video',
    SettingsSection.audioSubtitles => 'Audio & subtitles',
    SettingsSection.historyPrivacy => 'History & privacy',
    SettingsSection.mediaLibrary => 'Media library',
    SettingsSection.shortcuts => 'Shortcuts',
    SettingsSection.updatesAbout => 'Updates & about',
    SettingsSection.changed => 'Changed settings',
  };

  String get description => switch (this) {
    SettingsSection.general =>
      'Choose how Mpvson opens and behaves on your desktop.',
    SettingsSection.appearance =>
      'Adjust the player controls to fit your screen.',
    SettingsSection.playback => 'Set how playback starts and repeats.',
    SettingsSection.video => 'Tune picture quality and decoding.',
    SettingsSection.audioSubtitles => 'Choose tracks and subtitle behavior.',
    SettingsSection.historyPrivacy =>
      'Control saved activity and network history.',
    SettingsSection.mediaLibrary => 'Manage indexed folders and scans.',
    SettingsSection.shortcuts => 'Review keyboard and mouse controls.',
    SettingsSection.updatesAbout => 'Check app and playback engine versions.',
    SettingsSection.changed => 'Review changed settings and restore defaults.',
  };

  IconData get icon => switch (this) {
    SettingsSection.general => Icons.settings_outlined,
    SettingsSection.appearance => Icons.tune_rounded,
    SettingsSection.playback => Icons.play_circle_outline_rounded,
    SettingsSection.video => Icons.high_quality_rounded,
    SettingsSection.audioSubtitles => Icons.closed_caption_outlined,
    SettingsSection.historyPrivacy => Icons.history_rounded,
    SettingsSection.mediaLibrary => Icons.folder_copy_outlined,
    SettingsSection.shortcuts => Icons.keyboard_alt_outlined,
    SettingsSection.updatesAbout => Icons.system_update_alt_rounded,
    SettingsSection.changed => Icons.tune_rounded,
  };
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.controller,
    required this.updates,
    required this.engineUpdates,
    required this.pickSubtitle,
    this.appPreferences,
    this.desktopIntegration,
    this.libraryRepository,
    this.pickDirectory,
    this.initialSection,
    this.pickSettingsExportPath,
    this.pickSettingsImportPath,
  });

  final PlayerController controller;
  final UpdateService updates;
  final EngineUpdateService engineUpdates;
  final Future<String?> Function() pickSubtitle;
  final AppPreferencesRepository? appPreferences;
  final DesktopIntegrationService? desktopIntegration;
  final MediaLibraryRepository? libraryRepository;
  final Future<String?> Function()? pickDirectory;
  final SettingsSection? initialSection;
  final Future<String?> Function()? pickSettingsExportPath;
  final Future<String?> Function()? pickSettingsImportPath;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsSection _section =
      widget.initialSection ?? SettingsSection.appearance;
  late bool _compactShowingDetail = widget.initialSection != null;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'Settings search');
  final Map<String, GlobalKey> _searchResultKeys = {};
  final _dialogFocus = FocusNode(debugLabel: 'Settings dialog');
  final Map<String, _SettingAnchorState> _anchors = {};
  final _scrollStorage = PageStorageBucket();
  String _query = '';
  int _activeResult = 0;
  AppPreferencesRepository? _fallbackPreferences;
  bool _restoredFocus = false;
  bool _userSelectedSection = false;
  String? _highlightedAnchor;
  Timer? _highlightTimer;

  AppPreferencesRepository get _preferences =>
      widget.appPreferences ??
      (_fallbackPreferences ??= AppPreferencesRepository());

  List<SettingsSearchResult> get _results => settingsSearch(_query);

  @override
  void initState() {
    super.initState();
    if (widget.appPreferences == null) unawaited(_preferences.load());
    if (widget.initialSection == null) unawaited(_restoreLastSection());
  }

  Future<void> _restoreLastSection() async {
    final preferences = _preferences;
    if (!preferences.isLoaded) await preferences.load();
    if (!mounted || widget.initialSection != null || _userSelectedSection) {
      return;
    }
    final stored = preferences.preferences.lastSettingsSection;
    SettingsSection? section;
    for (final candidate in SettingsSection.values) {
      if (candidate.name == stored) {
        section = candidate;
        break;
      }
    }
    if (section == null) return;
    setState(() {
      _section = section!;
      _compactShowingDetail = true;
    });
  }

  void _persistSection(SettingsSection section) {
    unawaited(_preferences.setLastSettingsSection(section.name));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restoredFocus) {
      _restoredFocus = true;
      // Give the dialog route a predictable initial keyboard focus; the route
      // restores focus to its opener when it closes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dialogFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _fallbackPreferences?.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _dialogFocus.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _registerAnchor(String id, _SettingAnchorState anchor) =>
      _anchors[id] = anchor;
  void _unregisterAnchor(String id, _SettingAnchorState anchor) {
    if (identical(_anchors[id], anchor)) _anchors.remove(id);
  }

  void _selectSection(SettingsSection section, {bool revealDetail = true}) {
    _userSelectedSection = true;
    if (_section != section || (revealDetail && !_compactShowingDetail)) {
      setState(() {
        _section = section;
        if (revealDetail) _compactShowingDetail = true;
      });
      _persistSection(section);
    }
  }

  void _updateQuery(String value) => setState(() {
    _query = value;
    _activeResult = 0;
  });

  void _moveActiveResult(int delta) {
    if (_results.isEmpty) return;
    setState(() => _activeResult = (_activeResult + delta) % _results.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final result = _results.isEmpty ? null : _results[_activeResult];
      final target = result == null ? null : _searchResultKeys[result.anchorId];
      if (target?.currentContext case final context?) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.2,
          duration: AppMotion.duration(this.context, AppMotion.quick),
          curve: AppMotion.standardCurve,
        );
      }
    });
  }

  void _activateResult(int index) {
    final results = _results;
    if (results.isEmpty) return;
    final result = results[index.clamp(0, results.length - 1).toInt()];
    _userSelectedSection = true;
    _searchController.clear();
    setState(() {
      _query = '';
      _activeResult = 0;
      _section = result.section;
      _compactShowingDetail = true;
      _highlightedAnchor = result.anchorId;
    });
    _persistSection(result.section);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _highlightedAnchor = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _anchors[result.anchorId];
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(
          target.context,
          alignment: 0.18,
          duration: AppMotion.duration(context, AppMotion.standard),
          curve: AppMotion.enter,
        );
        target.focus();
      }
    });
  }

  void _handleEscape() {
    if (_query.isNotEmpty) {
      _searchController.clear();
      _updateQuery('');
      _searchFocus.requestFocus();
    } else if (!_isWide() && _compactShowingDetail) {
      setState(() => _compactShowingDetail = false);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  bool _isWide() {
    final media = MediaQuery.of(context);
    final margin = media.size.width < 620 || media.size.height < 540
        ? 12.0
        : 24.0;
    final availableWidth = (media.size.width - margin * 2).clamp(0.0, 1040.0);
    final scale = media.textScaler.scale(1);
    return availableWidth >= 880 && availableWidth - 224 >= 560 * scale;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final margin = size.width < 620 || size.height < 540 ? 12.0 : 24.0;
    final width = (size.width - margin * 2).clamp(0.0, 1040.0).toDouble();
    final height = (size.height - margin * 2 - media.viewInsets.vertical)
        .clamp(0.0, 760.0)
        .toDouble();
    final textScale = media.textScaler.scale(1);
    final wide = width >= 880 && width - 224 >= 560 * textScale;
    final compactViewport = height < 600;

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusSettingsSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _FocusSettingsSearchIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _SettingsEscapeIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown): _SearchNextIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): _SearchPreviousIntent(),
        SingleActivator(LogicalKeyboardKey.enter): _ActivateSearchIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _FocusSettingsSearchIntent:
              CallbackAction<_FocusSettingsSearchIntent>(
                onInvoke: (_) {
                  _searchFocus.requestFocus();
                  return null;
                },
              ),
          _SettingsEscapeIntent: CallbackAction<_SettingsEscapeIntent>(
            onInvoke: (_) {
              _handleEscape();
              return null;
            },
          ),
          _SearchNextIntent: _SearchCallbackAction<_SearchNextIntent>(
            enabled: () => _searchFocus.hasFocus && _query.isNotEmpty,
            onInvoke: (_) {
              if (_results.isNotEmpty) {
                _moveActiveResult(1);
              }
              return null;
            },
          ),
          _SearchPreviousIntent: _SearchCallbackAction<_SearchPreviousIntent>(
            enabled: () => _searchFocus.hasFocus && _query.isNotEmpty,
            onInvoke: (_) {
              if (_results.isNotEmpty) {
                _moveActiveResult(-1);
              }
              return null;
            },
          ),
          _ActivateSearchIntent: _SearchCallbackAction<_ActivateSearchIntent>(
            enabled: () => _searchFocus.hasFocus && _query.isNotEmpty,
            onInvoke: (_) {
              if (_results.isNotEmpty) _activateResult(_activeResult);
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _dialogFocus,
          autofocus: true,
          child: Dialog(
            insetPadding: EdgeInsets.all(margin),
            child: Theme(
              data: _settingsTheme(Theme.of(context)),
              child: Builder(
                builder: (context) => SizedBox(
                  width: width,
                  height: height,
                  child: _SettingsAnchorScope(
                    register: _registerAnchor,
                    unregister: _unregisterAnchor,
                    highlightedId: _highlightedAnchor,
                    child: PageStorage(
                      bucket: _scrollStorage,
                      child: Column(
                        children: [
                          _buildHeader(context, textScale),
                          const Divider(height: 1),
                          _PreferenceSaveStatus(preferences: _preferences),
                          Expanded(
                            child: _query.trim().isNotEmpty
                                ? _buildSearchResults(context)
                                : wide
                                ? Row(
                                    children: [
                                      SizedBox(
                                        width: 224,
                                        child: ColoredBox(
                                          color: AppTheme.background,
                                          child: _buildCategories(
                                            context,
                                            wide: true,
                                          ),
                                        ),
                                      ),
                                      const VerticalDivider(
                                        width: 1,
                                        thickness: 1,
                                      ),
                                      Expanded(
                                        child: _buildContent(
                                          context,
                                          compactViewport,
                                        ),
                                      ),
                                    ],
                                  )
                                : _compactShowingDetail
                                ? _buildContent(context, compactViewport)
                                : _buildCategories(context, wide: false),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, double textScale) => Padding(
    padding: EdgeInsets.fromLTRB(textScale > 1.3 ? 14 : 20, 8, 8, 10),
    child: Column(
      children: [
        Row(
          children: [
            if (!_isWide() && _compactShowingDetail)
              IconButton(
                tooltip: 'Settings categories',
                onPressed: () => setState(() => _compactShowingDetail = false),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Changes apply immediately',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close settings',
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: TextField(
            key: const ValueKey('settings-search-input'),
            controller: _searchController,
            focusNode: _searchFocus,
            onChanged: _updateQuery,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: 'Search settings',
              suffixIcon: _query.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Center(
                        widthFactor: 1,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.card,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: const Text(
                            'Ctrl F',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.muted,
                            ),
                          ),
                        ),
                      ),
                    )
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        _updateQuery('');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildSearchResults(BuildContext context) {
    final results = _results;
    if (results.isEmpty) {
      return Center(
        child: Text(
          'No matching settings',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: Column(
        children: [
          for (var index = 0; index < results.length; index++)
            ListTile(
              key: _searchResultKeys.putIfAbsent(
                results[index].anchorId,
                () => GlobalKey(
                  debugLabel: 'settings-search-${results[index].anchorId}',
                ),
              ),
              dense: true,
              selected: index == _activeResult,
              title: Text(
                results[index].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${results[index].section.label}: ${results[index].description}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _activateResult(index),
            ),
        ],
      ),
    );
  }

  Widget _buildCategories(BuildContext context, {required bool wide}) {
    final sections = SettingsSection.values;
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(wide ? 12 : 18, 14, wide ? 12 : 18, 20),
      itemCount: sections.length,
      itemBuilder: (context, index) {
        final section = sections[index];
        final selected = section == _section;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Semantics(
            selected: selected,
            button: true,
            child: Material(
              color: selected ? AppTheme.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _selectSection(section),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 10 : 14,
                    vertical: 11,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                          section.icon,
                          size: 19,
                          color: selected
                              ? AppTheme.accent
                              : AppTheme.secondaryText,
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              section.label,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: selected
                                        ? AppTheme.accent
                                        : AppTheme.primaryText,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                            ),
                            if (!wide)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  section.description,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: AppTheme.secondaryText),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (selected && wide)
                        Container(width: 2, height: 22, color: AppTheme.accent),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context, bool compactViewport) {
    final section = _section;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: AppMotion.duration(context, AppMotion.standard),
            reverseDuration: AppMotion.duration(context, AppMotion.quick),
            switchInCurve: AppMotion.enter,
            switchOutCurve: AppMotion.exit,
            layoutBuilder: (currentChild, previousChildren) => Stack(
              fit: StackFit.expand,
              alignment: Alignment.topLeft,
              children: [...previousChildren, ?currentChild],
            ),
            transitionBuilder: (child, animation) => AppMotion.reduce(context)
                ? child
                : FadeTransition(opacity: animation, child: child),
            child: KeyedSubtree(
              key: ValueKey<SettingsSection>(section),
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) =>
                    _sectionBody(context, section, compactViewport),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionBody(
    BuildContext context,
    SettingsSection section,
    bool compactViewport,
  ) {
    final heading = _sectionHeading(context, section, compactViewport);
    return switch (section) {
      SettingsSection.general => _GeneralSettings(
        preferences: _preferences,
        controller: widget.controller,
        desktopIntegration: widget.desktopIntegration,
        pickExportPath: widget.pickSettingsExportPath,
        pickImportPath: widget.pickSettingsImportPath,
        heading: heading,
      ),
      SettingsSection.appearance => _AppearanceSettings(
        controller: widget.controller,
        compactViewport: compactViewport,
        heading: heading,
      ),
      SettingsSection.playback => _PlaybackSettings(
        controller: widget.controller,
        heading: heading,
      ),
      SettingsSection.video => _VideoSettings(
        controller: widget.controller,
        heading: heading,
      ),
      SettingsSection.audioSubtitles => _AudioSubtitleSettings(
        controller: widget.controller,
        pickSubtitle: widget.pickSubtitle,
        heading: heading,
      ),
      SettingsSection.historyPrivacy => _HistoryPrivacySettings(
        controller: widget.controller,
        heading: heading,
      ),
      SettingsSection.mediaLibrary => _MediaLibrarySettings(
        libraryRepository: widget.libraryRepository,
        pickDirectory: widget.pickDirectory,
        heading: heading,
      ),
      SettingsSection.shortcuts => _ShortcutsSettings(
        preferences: _preferences,
        heading: heading,
      ),
      SettingsSection.updatesAbout => SingleChildScrollView(
        key: const PageStorageKey<String>('settings-updates-about'),
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heading,
            UpdateCenterContent(
              updates: widget.updates,
              engineUpdates: widget.engineUpdates,
              engineVersion: widget.controller.engineVersion,
              anchorBuilder: (id, child) =>
                  _SettingAnchor(id: id, child: child),
            ),
          ],
        ),
      ),
      SettingsSection.changed => _ChangedSettings(
        controller: widget.controller,
        preferences: _preferences,
        heading: heading,
      ),
    };
  }

  Widget _sectionHeading(
    BuildContext context,
    SettingsSection section,
    bool compactViewport,
  ) => Padding(
    padding: EdgeInsets.fromLTRB(
      0,
      compactViewport ? 8 : 18,
      0,
      compactViewport ? 12 : 20,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(section.label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 3),
        Text(
          section.description,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppTheme.secondaryText),
        ),
      ],
    ),
  );
}

class SettingsSearchResult {
  const SettingsSearchResult(this.section, this.anchorId, this.title);
  final SettingsSection section;
  final String anchorId;
  final String title;
  String get description => _searchDescriptions[anchorId] ?? section.label;
}

const _settingsSearchIndex = <SettingsSearchResult>[
  SettingsSearchResult(
    SettingsSection.appearance,
    'control-size',
    'Control size',
  ),
  SettingsSearchResult(
    SettingsSection.general,
    'open-behavior',
    'Open behavior',
  ),
  SettingsSearchResult(
    SettingsSection.general,
    'keep-awake',
    'Keep screen awake',
  ),
  SettingsSearchResult(SettingsSection.general, 'default-apps', 'Default apps'),
  SettingsSearchResult(SettingsSection.playback, 'shuffle', 'Shuffle'),
  SettingsSearchResult(
    SettingsSection.playback,
    'resume-behavior',
    'Resume behavior',
  ),
  SettingsSearchResult(SettingsSection.playback, 'repeat', 'Repeat'),
  SettingsSearchResult(SettingsSection.playback, 'speed', 'Playback speed'),
  SettingsSearchResult(SettingsSection.video, 'quality', 'Video quality'),
  SettingsSearchResult(
    SettingsSection.video,
    'hardware-decoding',
    'Hardware decoding',
  ),
  SettingsSearchResult(SettingsSection.video, 'brightness', 'Brightness'),
  SettingsSearchResult(SettingsSection.video, 'contrast', 'Contrast'),
  SettingsSearchResult(SettingsSection.video, 'saturation', 'Saturation'),
  SettingsSearchResult(SettingsSection.video, 'gamma', 'Gamma'),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'audio-track',
    'Audio track',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'subtitle-track',
    'Subtitle track',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'load-subtitle',
    'Load subtitle file',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'audio-delay',
    'Audio delay',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'subtitle-delay',
    'Subtitle delay',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'subtitle-font',
    'Subtitle font family',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'subtitle-font-size',
    'Subtitle font size',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'subtitle-color',
    'Subtitle text color',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'subtitle-outline',
    'Subtitle outline width',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'subtitle-background-opacity',
    'Subtitle background opacity',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'subtitle-position',
    'Subtitle vertical position',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'preferred-audio-languages',
    'Audio language priority',
  ),
  SettingsSearchResult(
    SettingsSection.audioSubtitles,
    'preferred-subtitle-languages',
    'Subtitle language priority',
  ),
  SettingsSearchResult(
    SettingsSection.historyPrivacy,
    'history-enabled',
    'Playback history',
  ),
  SettingsSearchResult(
    SettingsSection.historyPrivacy,
    'clear-history',
    'Clear history',
  ),
  SettingsSearchResult(
    SettingsSection.historyPrivacy,
    'save-network-urls',
    'Save network URLs',
  ),
  SettingsSearchResult(
    SettingsSection.mediaLibrary,
    'library-folders',
    'Library folders',
  ),
  SettingsSearchResult(
    SettingsSection.mediaLibrary,
    'library-scan',
    'Scan library',
  ),
  SettingsSearchResult(
    SettingsSection.shortcuts,
    'keyboard-shortcuts',
    'Keyboard shortcuts',
  ),
  SettingsSearchResult(
    SettingsSection.shortcuts,
    'mouse-controls',
    'Mouse controls',
  ),
  SettingsSearchResult(
    SettingsSection.updatesAbout,
    'engine-updates',
    'Playback engine updates',
  ),
  SettingsSearchResult(
    SettingsSection.updatesAbout,
    'app-updates',
    'App updates',
  ),
  SettingsSearchResult(
    SettingsSection.changed,
    'changed-settings',
    'Changed settings',
  ),
];

List<SettingsSearchResult> settingsSearch(String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return const [];
  final terms = normalized.split(RegExp(r'\s+'));
  return _settingsSearchIndex
      .where((entry) {
        final words =
            '${entry.title} ${entry.section.label} ${entry.section.description} ${_searchSynonyms[entry.anchorId] ?? ''}'
                .toLowerCase();
        return terms.every(words.contains);
      })
      .toList(growable: false);
}

const _searchSynonyms = <String, String>{
  'control-size': 'compact normal controls density',
  'open-behavior': 'file launch open double click queue',
  'keep-awake': 'sleep display prevent screen awake',
  'default-apps': 'file associations operating system',
  'shuffle': 'random order',
  'resume-behavior':
      'resume position progress start over restart prompt ask playback',
  'repeat': 'loop playlist one track',
  'speed': 'rate faster slower tempo',
  'quality': 'resolution codec',
  'hardware-decoding': 'gpu acceleration decode',
  'brightness': 'picture light',
  'contrast': 'picture levels',
  'saturation': 'color intensity',
  'gamma': 'picture tone',
  'audio-track': 'sound language',
  'subtitle-track': 'captions language',
  'load-subtitle': 'captions external file',
  'audio-delay': 'sound sync offset',
  'subtitle-delay': 'captions sync offset',
  'subtitle-font': 'typeface style font family',
  'subtitle-font-size': 'text scale size size relative picture',
  'subtitle-color': 'text foreground hex color',
  'subtitle-outline': 'stroke border outline text',
  'subtitle-background-opacity': 'background box transparency alpha',
  'subtitle-position': 'vertical placement top bottom screen',
  'preferred-audio-languages': 'future media language priority preference',
  'preferred-subtitle-languages': 'future media captions language priority',
  'history-enabled':
      'recent watched remember resume continue playback position',
  'clear-history': 'erase delete remove',
  'save-network-urls': 'privacy internet streaming tokens consent credentials',
  'library-folders': 'media directory source add folder remove unavailable',
  'library-scan': 'rescan refresh index',
  'keyboard-shortcuts': 'keys hotkeys',
  'mouse-controls': 'click wheel gestures',
  'engine-updates':
      'mpv playback engine channel stable development rollback restart download discard',
  'app-updates': 'version application',
};

const _searchDescriptions = <String, String>{
  'control-size': 'Make controls compact or normal',
  'open-behavior': 'Choose what happens when files open',
  'keep-awake': 'Prevent sleep during playback',
  'default-apps': 'Open system file association settings',
  'shuffle': 'Randomize queue order',
  'resume-behavior': 'Choose whether to resume saved progress',
  'repeat': 'Repeat the queue or current video',
  'speed': 'Set playback rate',
  'quality': 'Choose the video quality preset',
  'hardware-decoding': 'Use GPU video decoding',
  'brightness': 'Adjust picture brightness',
  'contrast': 'Adjust picture contrast',
  'saturation': 'Adjust color intensity',
  'gamma': 'Adjust picture gamma',
  'audio-track': 'Select the sound track',
  'subtitle-track': 'Select or disable subtitles',
  'load-subtitle': 'Load an external subtitle file',
  'audio-delay': 'Synchronize sound with video',
  'subtitle-delay': 'Synchronize captions with video',
  'subtitle-font': 'Choose the subtitle font family',
  'subtitle-font-size': 'Set subtitle size relative to picture height',
  'subtitle-color': 'Set subtitle text color',
  'subtitle-outline': 'Set subtitle outline width',
  'subtitle-background-opacity': 'Adjust the subtitle background',
  'subtitle-position': 'Move subtitles vertically',
  'preferred-audio-languages': 'Set future audio language priorities',
  'preferred-subtitle-languages': 'Set future subtitle language priorities',
  'history-enabled': 'Remember recent files and resume position',
  'clear-history': 'Remove saved playback activity',
  'save-network-urls': 'Keep streaming URLs in the queue',
  'library-folders': 'Add or remove indexed folders',
  'library-scan': 'Refresh indexed media',
  'keyboard-shortcuts': 'Review keys for player actions',
  'mouse-controls': 'Review mouse actions on video',
  'engine-updates': 'Manage stable and development builds',
  'app-updates': 'Check the installed app version',
  'changed-settings': 'Review changes and restore defaults',
};

class _PreferenceSaveStatus extends StatelessWidget {
  const _PreferenceSaveStatus({required this.preferences});

  final AppPreferencesRepository preferences;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) {
      if (!preferences.isLoaded || preferences.isSaving) {
        return LinearProgressIndicator(
          minHeight: 2,
          semanticsLabel: preferences.isLoaded
              ? 'Saving preferences'
              : 'Loading preferences',
        );
      }
      final error = preferences.saveError;
      if (error == null) return const SizedBox.shrink();
      return Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  error,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppTheme.danger),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => unawaited(preferences.retrySave()),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SettingAnchor extends StatefulWidget {
  const _SettingAnchor({required this.id, required this.child});
  final String id;
  final Widget child;
  @override
  State<_SettingAnchor> createState() => _SettingAnchorState();
}

class _SettingAnchorState extends State<_SettingAnchor> {
  final _focusNode = FocusNode(skipTraversal: true);
  _SettingsAnchorScope? _scope;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = _SettingsAnchorScope.maybeOf(context);
    if (!identical(next, _scope)) {
      _scope?.unregister(widget.id, this);
      _scope = next;
      _scope?.register(widget.id, this);
    }
  }

  @override
  void didUpdateWidget(covariant _SettingAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _scope?.unregister(oldWidget.id, this);
      _scope?.register(widget.id, this);
    }
  }

  @override
  void dispose() {
    _scope?.unregister(widget.id, this);
    _focusNode.dispose();
    super.dispose();
  }

  void focus() => _focusNode.requestFocus();

  @override
  Widget build(BuildContext context) {
    _scope?.register(widget.id, this);
    final highlighted = _scope?.highlightedId == widget.id;
    return Focus(
      focusNode: _focusNode,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppMotion.quick),
        decoration: BoxDecoration(
          color: highlighted ? AppTheme.accent.withValues(alpha: 0.1) : null,
          border: highlighted
              ? Border.all(color: AppTheme.accent, width: 1.5)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: widget.child,
      ),
    );
  }
}

class _SettingsAnchorScope extends InheritedWidget {
  const _SettingsAnchorScope({
    required this.register,
    required this.unregister,
    required this.highlightedId,
    required super.child,
  });
  final void Function(String, _SettingAnchorState) register;
  final void Function(String, _SettingAnchorState) unregister;
  final String? highlightedId;
  static _SettingsAnchorScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SettingsAnchorScope>();
  @override
  bool updateShouldNotify(_SettingsAnchorScope oldWidget) =>
      highlightedId != oldWidget.highlightedId;
}

class _FocusSettingsSearchIntent extends Intent {
  const _FocusSettingsSearchIntent();
}

class _SettingsEscapeIntent extends Intent {
  const _SettingsEscapeIntent();
}

class _SearchNextIntent extends Intent {
  const _SearchNextIntent();
}

class _SearchPreviousIntent extends Intent {
  const _SearchPreviousIntent();
}

class _ActivateSearchIntent extends Intent {
  const _ActivateSearchIntent();
}

class _SearchCallbackAction<T extends Intent> extends CallbackAction<T> {
  _SearchCallbackAction({required this.enabled, required super.onInvoke});

  final bool Function() enabled;

  @override
  bool isEnabled(T intent) => enabled();
}
