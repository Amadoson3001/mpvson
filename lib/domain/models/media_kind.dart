/// The classification of a media source.
enum MediaKind {
  unknown,
  audio,
  video;

  bool get isAudio => this == MediaKind.audio;
  bool get isVideo => this == MediaKind.video;
  bool get isUnknown => this == MediaKind.unknown;
}
