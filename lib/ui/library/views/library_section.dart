/// Destinations of the library shell.
enum LibrarySection {
  home,
  videos,
  music,
  playlists,
  folders,
  nowPlaying,
  settings;

  /// Human-readable name, lower case, used in hints such as "Search videos".
  String get hintName => switch (this) {
    LibrarySection.home => 'home',
    LibrarySection.videos => 'videos',
    LibrarySection.music => 'music',
    LibrarySection.playlists => 'playlists',
    LibrarySection.folders => 'folders',
    LibrarySection.nowPlaying => 'now playing',
    LibrarySection.settings => 'settings',
  };

  /// Whether the top bar shows a search field on this section.
  bool get hasSearch =>
      this == LibrarySection.videos ||
      this == LibrarySection.music ||
      this == LibrarySection.playlists;
}
