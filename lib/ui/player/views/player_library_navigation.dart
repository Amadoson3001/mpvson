import 'package:flutter/foundation.dart';

import '../../../domain/models/media_catalog.dart';
import '../player_controller.dart';

/// Library overlay state for `PlayerScreen`.
///
/// Decides when the library shell replaces the player stage and tracks which
/// settings pane is open, leaving playback and chrome to their own controllers.
class PlayerLibraryNavigation extends ChangeNotifier {
  PlayerLibraryNavigation({
    required this.controller,
    required this.hasLibraryRepository,
    required this.onExitMiniPlayer,
    required this.onVisibilityChanged,
  });

  PlayerController controller;
  bool hasLibraryRepository;

  final void Function() onExitMiniPlayer;
  final void Function() onVisibilityChanged;

  bool _showLibrary = false;
  bool _showPlayerView = false;
  String? _playerViewEntryId;
  int _homeNavigationRequest = 0;
  bool _settingsOpen = false;

  bool get settingsOpen => _settingsOpen;
  int get homeNavigationRequest => _homeNavigationRequest;

  bool get isShowingLibrary {
    final current = controller.current;
    final isAudioMedia =
        (controller.isAudio && controller.hasMedia) ||
        (current != null &&
            MediaCatalog.kindFromExtension(current.path).isAudio);
    final showPlayerForCurrent =
        _showPlayerView && _playerViewEntryId == current?.id;
    return (_showLibrary ||
            ((isAudioMedia || current == null) && !showPlayerForCurrent)) &&
        hasLibraryRepository;
  }

  void openLibrary() {
    onExitMiniPlayer();
    _showLibrary = true;
    _showPlayerView = false;
    notifyListeners();
    onVisibilityChanged();
  }

  void returnToPlayer(String? entryId) {
    _showLibrary = false;
    _showPlayerView = true;
    _playerViewEntryId = entryId;
    notifyListeners();
    onVisibilityChanged();
  }

  void backToHome() {
    _showLibrary = true;
    _showPlayerView = false;
    _settingsOpen = false;
    _homeNavigationRequest++;
    notifyListeners();
    onVisibilityChanged();
  }

  /// A newly opened video brings the stage back even if the library was forced
  /// open from the settings pane.
  void hideLibrary() {
    if (!_showLibrary) return;
    _showLibrary = false;
    notifyListeners();
  }

  /// Settings live inside the library shell, so opening them also brings the
  /// shell forward when a video is on the stage.
  void openSettings() {
    _showLibrary = true;
    _showPlayerView = false;
    _settingsOpen = true;
    notifyListeners();
    onVisibilityChanged();
  }

  void setSettingsOpen(bool open) {
    if (_settingsOpen == open) return;
    _settingsOpen = open;
    notifyListeners();
  }
}
