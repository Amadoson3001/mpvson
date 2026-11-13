import 'package:flutter/foundation.dart';

import '../../../data/repositories/media_library_repository.dart';
import '../../../domain/models/library_models.dart';
import '../../player/player_controller.dart';

/// Subtabs within the Music library view.
enum MusicSubtab {
  songs,
  albums,
  artists,
  favorites,
  recentlyAdded,
  recentlyPlayed,
}

typedef MusicSubTab = MusicSubtab;

/// ViewModel holding music subtab selection and item playback/favorite actions.
class MusicViewModel extends ChangeNotifier {
  MusicViewModel({required this.repository, this.playerController});

  final MediaLibraryRepository repository;
  final PlayerController? playerController;

  MusicSubtab _currentSubtab = MusicSubtab.songs;
  MusicSubtab get currentSubtab => _currentSubtab;
  MusicSubtab get selectedSubtab => _currentSubtab;
  MusicSubtab get subTab => _currentSubtab;
  MusicSubtab get subtab => _currentSubtab;

  bool _disposed = false;

  void selectSubtab(MusicSubtab subtab) {
    if (_disposed || _currentSubtab == subtab) return;
    _currentSubtab = subtab;
    notifyListeners();
  }

  set currentSubtab(MusicSubtab subtab) => selectSubtab(subtab);
  set selectedSubtab(MusicSubtab subtab) => selectSubtab(subtab);
  set subTab(MusicSubtab subtab) => selectSubtab(subtab);
  set subtab(MusicSubtab subtab) => selectSubtab(subtab);

  Future<MediaItemRecord?> _resolveMediaRecord(String mediaId) async {
    final byId = await repository.getMediaById(mediaId);
    if (byId != null) return byId;
    return repository.getMediaByCanonicalSource(mediaId);
  }

  List<String> _extractPaths(dynamic media) {
    if (media is MediaItemRecord) return [media.path];
    if (media is String) return [media];
    if (media is List<MediaItemRecord>) {
      return media.map((e) => e.path).toList();
    }
    if (media is List<String>) return media;
    if (media is Iterable<MediaItemRecord>) {
      return media.map((e) => e.path).toList();
    }
    if (media is Iterable<String>) return media.toList();
    return const [];
  }

  /// Inserts item(s) to play immediately after the current song.
  Future<void> playNext(dynamic media) async {
    final paths = _extractPaths(media);
    if (paths.isEmpty) return;
    await playerController?.openPaths(paths, append: true, playNext: true);
  }

  /// Appends item(s) to the end of the playback queue.
  Future<void> addToQueue(dynamic media) async {
    final paths = _extractPaths(media);
    if (paths.isEmpty) return;
    await playerController?.openPaths(paths, append: true);
  }

  /// Toggles favorite status for a given media item or id.
  Future<void> toggleFavorite(dynamic media, [bool? targetStatus]) async {
    String mediaId;
    bool newStatus;
    if (media is MediaItemRecord) {
      mediaId = media.id;
      newStatus = targetStatus ?? !media.isFavorite;
    } else if (media is String) {
      mediaId = media;
      final existing = await _resolveMediaRecord(mediaId);
      newStatus =
          targetStatus ?? (existing != null ? !existing.isFavorite : true);
    } else {
      return;
    }

    await repository.toggleFavorite(mediaId, newStatus);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
