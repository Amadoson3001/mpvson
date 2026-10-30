import 'package:meta/meta.dart';

/// One chapter marker reported by the playback engine for the current source.
@immutable
class PlaybackChapter {
  const PlaybackChapter({required this.title, required this.start});

  /// Chapter title as embedded in the source; may be empty.
  final String title;

  /// Offset from the start of the source where the chapter begins.
  final Duration start;

  @override
  bool operator ==(Object other) =>
      other is PlaybackChapter && other.title == title && other.start == start;

  @override
  int get hashCode => Object.hash(title, start);

  @override
  String toString() => 'PlaybackChapter($title @ $start)';
}
