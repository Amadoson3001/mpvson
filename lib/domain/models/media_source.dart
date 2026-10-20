import 'dart:io';

/// User-supplied media source validation shared by every entry point.
///
/// Command-line arguments, drag and drop, file dialogs, the URL dialog and
/// restored sessions all funnel through [validate] so an unsupported URI scheme
/// is reported explicitly instead of silently becoming a bogus local path.
abstract final class MediaSource {
  /// Schemes that reach the network directly.
  static const Set<String> networkSchemes = <String>{'http', 'https'};

  static final RegExp _windowsDrive = RegExp(r'^[a-zA-Z]:[\\/]');
  static final RegExp _textualScheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*):');

  /// Splits a raw user string into a usable source or an explicit reason.
  static MediaSourceValidation validate(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const MediaSourceValidation.invalid(
        'No media source was provided.',
      );
    }

    // A Windows drive path parses as a URI with a single-letter scheme, so it
    // must be recognized before any scheme handling.
    if (_windowsDrive.hasMatch(trimmed)) {
      return MediaSourceValidation.valid(trimmed);
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      // A string that starts with a scheme but cannot be parsed must not become
      // a local path. `file:` keeps its historical local-path fallback because
      // the URI parser cannot represent it.
      final textualScheme = _textualScheme
          .firstMatch(trimmed)
          ?.group(1)
          ?.toLowerCase();
      if (textualScheme == null ||
          textualScheme.length == 1 ||
          textualScheme == 'file') {
        return MediaSourceValidation.valid(trimmed);
      }
      if (networkSchemes.contains(textualScheme)) {
        return MediaSourceValidation.invalid(
          'The stream URL could not be parsed: ${redact(trimmed)}',
        );
      }
      return MediaSourceValidation.invalid(
        'Unsupported source scheme "$textualScheme". Mpvson opens local files, '
        'file URIs and HTTP(S) streams.',
      );
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme.isEmpty || scheme.length == 1) {
      return MediaSourceValidation.valid(trimmed);
    }

    if (networkSchemes.contains(scheme)) {
      if (uri.host.isEmpty) {
        return MediaSourceValidation.invalid(
          'The stream URL is missing a host name: ${redact(trimmed)}',
        );
      }
      return MediaSourceValidation.valid(trimmed);
    }

    if (scheme == 'file') {
      try {
        final path = uri.toFilePath(windows: Platform.isWindows);
        if (path.trim().isEmpty) {
          return MediaSourceValidation.invalid(
            'The file URI does not name a file: ${redact(trimmed)}',
          );
        }
        return MediaSourceValidation.valid(trimmed);
      } on Object {
        return MediaSourceValidation.invalid(
          'The file URI could not be read: ${redact(trimmed)}',
        );
      }
    }

    return MediaSourceValidation.invalid(
      'Unsupported source scheme "$scheme". Mpvson opens local files, file URIs '
      'and HTTP(S) streams.',
    );
  }

  static final RegExp _urlInText = RegExp(
    r'''https?://[^\s"'<>]+''',
    caseSensitive: false,
  );
  static final RegExp _trailingUrlPunctuation = RegExp(r'[.,;:!?)}\]]+$');

  /// Strips credentials, query strings and fragments from a source or text so it
  /// can be written to a local diagnostic record.
  static String redact(String source) {
    final trimmed = source.trim();
    return redactText(trimmed);
  }

  /// Strips credentials, query strings and fragments from all URLs in [text].
  static String redactText(String text) {
    if (text.isEmpty) return text;
    return text.replaceAllMapped(_urlInText, (match) {
      return _redactUrl(match.group(0)!);
    });
  }

  static String _redactUrl(String source) {
    var raw = source.trim();
    var trailing = '';
    final punctuation = _trailingUrlPunctuation.firstMatch(raw);
    if (punctuation != null) {
      trailing = punctuation.group(0)!;
      raw = raw.substring(0, punctuation.start);
    }
    try {
      final uri = Uri.tryParse(raw);
      if (uri == null) {
        return _redactMalformedUrl(raw) + trailing;
      }
      if (!networkSchemes.contains(uri.scheme.toLowerCase())) return source;
      if (uri.host.isEmpty) {
        return _redactMalformedUrl(raw) + trailing;
      }
      // Rebuilding instead of `Uri.replace` keeps no empty `?`/`#` markers
      // behind.
      return Uri(
            scheme: uri.scheme,
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
            path: uri.path,
          ).toString() +
          trailing;
    } on Object {
      // A parser/constructor failure must never send the original URL to logs.
      return _redactMalformedUrl(raw) + trailing;
    }
  }

  /// Keeps only the portion of a malformed URL that cannot contain user info,
  /// a query token, or a fragment. Diagnostics must remain safe even when the
  /// URI parser rejects the URL before it can identify its authority.
  static String _redactMalformedUrl(String raw) {
    final scheme = RegExp(
      r'^(https?)://',
      caseSensitive: false,
    ).firstMatch(raw);
    if (scheme == null) return raw;

    final remainder = raw.substring(scheme.end);
    var authorityEnd = remainder.length;
    for (final delimiter in <String>['/', '?', '#']) {
      final index = remainder.indexOf(delimiter);
      if (index >= 0 && index < authorityEnd) authorityEnd = index;
    }
    final authority = remainder.substring(0, authorityEnd);
    final at = authority.lastIndexOf('@');
    final safeAuthority = at >= 0 ? authority.substring(at + 1) : authority;

    final rest = remainder.substring(authorityEnd);
    var pathEnd = rest.length;
    for (final delimiter in <String>['?', '#']) {
      final index = rest.indexOf(delimiter);
      if (index >= 0 && index < pathEnd) pathEnd = index;
    }
    final safePath = rest.substring(0, pathEnd);
    return '${scheme.group(0)}$safeAuthority$safePath';
  }
}

/// Outcome of [MediaSource.validate].
class MediaSourceValidation {
  const MediaSourceValidation.valid(String this.source) : error = null;
  const MediaSourceValidation.invalid(String this.error) : source = null;

  /// Normalized source when the input is usable, otherwise null.
  final String? source;

  /// Explicit, user-readable reason when the input is rejected.
  final String? error;

  bool get isValid => source != null;
}
