/// A decision request for a media entry with a saved playback position.
///
/// The id is unique to a single open operation, so a stale UI callback cannot
/// resolve a prompt that belongs to a later source.
final class ResumePrompt {
  const ResumePrompt({
    required this.id,
    required this.source,
    required this.title,
    required this.position,
  });

  final int id;
  final String source;
  final String title;
  final Duration position;

  @override
  bool operator ==(Object other) =>
      other is ResumePrompt &&
      other.id == id &&
      other.source == source &&
      other.title == title &&
      other.position == position;

  @override
  int get hashCode => Object.hash(id, source, title, position);
}
