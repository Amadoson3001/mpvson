/// This file is a part of media_kit (https://github.com/media-kit/media-kit).

/// What the native engine reports for file lifecycle.
enum NativeLifecycleKind { startFile, fileLoaded, endFile }

/// Reason why an engine file ended.
enum NativeEndReason { eof, stop, quit, error, redirect, unknown }

/// Typed native file lifecycle event fired from libmpv.
class NativeLifecycleEvent {
  const NativeLifecycleEvent.startFile({required this.playlistEntryId})
    : kind = NativeLifecycleKind.startFile,
      reason = null,
      error = 0,
      playlistInsertId = null,
      playlistInsertNumEntries = 0;

  const NativeLifecycleEvent.fileLoaded()
    : kind = NativeLifecycleKind.fileLoaded,
      playlistEntryId = null,
      reason = null,
      error = 0,
      playlistInsertId = null,
      playlistInsertNumEntries = 0;

  const NativeLifecycleEvent.endFile({
    required this.playlistEntryId,
    required this.reason,
    required this.error,
    this.playlistInsertId,
    this.playlistInsertNumEntries = 0,
  }) : kind = NativeLifecycleKind.endFile;

  final NativeLifecycleKind kind;
  final int? playlistEntryId;
  final NativeEndReason? reason;
  final int error;
  final int? playlistInsertId;
  final int playlistInsertNumEntries;

  static NativeEndReason reasonFromCode(int code) {
    switch (code) {
      case 0:
        return NativeEndReason.eof;
      case 2:
        return NativeEndReason.stop;
      case 3:
        return NativeEndReason.quit;
      case 4:
        return NativeEndReason.error;
      case 5:
        return NativeEndReason.redirect;
      default:
        return NativeEndReason.unknown;
    }
  }

  @override
  String toString() =>
      'NativeLifecycleEvent($kind, id: $playlistEntryId, reason: $reason, error: $error)';
}
