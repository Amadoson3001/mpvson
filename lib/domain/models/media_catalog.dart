import 'package:path/path.dart' as p;
import 'media_kind.dart';

/// Authoritative media extension and MIME catalog for Mpvson.
class MediaCatalog {
  MediaCatalog._();

  static const Set<String> audioExtensions = <String>{
    'mp3',
    'flac',
    'wav',
    'm4a',
    'aac',
    'ogg',
    'oga',
    'opus',
    'wma',
    'aiff',
    'aif',
    'ape',
  };

  static const Set<String> videoExtensions = <String>{
    'mp4',
    'mkv',
    'avi',
    'webm',
    'mov',
    'flv',
    'wmv',
    'm4v',
    'ts',
    'm2ts',
    'vob',
    'ogv',
    '3gp',
  };

  static const Map<String, String> extensionToMimeType = <String, String>{
    // Audio
    'mp3': 'audio/mpeg',
    'flac': 'audio/flac',
    'wav': 'audio/wav',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'oga': 'audio/ogg',
    'opus': 'audio/opus',
    'wma': 'audio/x-ms-wma',
    'aiff': 'audio/x-aiff',
    'aif': 'audio/x-aiff',
    'ape': 'audio/x-ape',
    // Video
    'mp4': 'video/mp4',
    'mkv': 'video/x-matroska',
    'avi': 'video/x-msvideo',
    'webm': 'video/webm',
    'mov': 'video/quicktime',
    'flv': 'video/x-flv',
    'wmv': 'video/x-ms-wmv',
    'm4v': 'video/x-m4v',
    'ts': 'video/mp2t',
    'm2ts': 'video/mp2t',
    'vob': 'video/x-ms-vob',
    'ogv': 'video/ogg',
    '3gp': 'video/3gpp',
  };

  /// All supported media extensions in lowercase without dot.
  static final Set<String> supportedExtensions = <String>{
    ...audioExtensions,
    ...videoExtensions,
  };

  /// Returns whether a given file path has a supported extension.
  static bool isSupportedFile(String filePath) {
    final ext = p.extension(filePath).toLowerCase().replaceFirst('.', '');
    return supportedExtensions.contains(ext);
  }

  /// Initial hint of media kind based on file extension.
  static MediaKind kindFromExtension(String filePath) {
    final ext = p.extension(filePath).toLowerCase().replaceFirst('.', '');
    if (audioExtensions.contains(ext)) return MediaKind.audio;
    if (videoExtensions.contains(ext)) return MediaKind.video;
    return MediaKind.unknown;
  }

  /// Strips a recognized media extension from a name for display.
  static String displayName(String fileName) {
    final ext = p.extension(fileName).toLowerCase().replaceFirst('.', '');
    if (!audioExtensions.contains(ext) && !videoExtensions.contains(ext)) {
      return fileName;
    }
    final base = p.basenameWithoutExtension(fileName);
    return base.isEmpty ? fileName : base;
  }

  /// File selector extension list (e.g. for open file dialogs).
  static List<String> get filePickerExtensions =>
      supportedExtensions.toList()..sort();
}
