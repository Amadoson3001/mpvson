/// Identity of the Mpvson desktop application version.
///
/// The canonical version lives in `pubspec.yaml` (`version: X.Y.Z+N`).
/// `tool/version.dart sync` keeps [pubspecVersion], [defaultSemantic], and
/// [buildNumber] synchronized with `pubspec.yaml`, and `tool/version.dart check`
/// fails CI if they ever drift.
///
/// Releases may override [current] at build time via
/// `--dart-define=MPVSON_APP_VERSION=<version>`.
abstract final class AppVersion {
  static const String pubspecVersion = '0.1.1+2';
  static const String defaultSemantic = '0.1.1';
  static const int buildNumber = 2;

  static const String _override = String.fromEnvironment('MPVSON_APP_VERSION');

  /// Active semantic application version used as the runtime/service default.
  static const String current = _override != '' ? _override : defaultSemantic;
}
