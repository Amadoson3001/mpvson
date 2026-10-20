/// Identity of the libmpv engine that ships with the Windows build.
///
/// The build-time pin lives in `packaging/windows/engine-provenance.json` and
/// the Windows CMake step verifies that package before bundling it. This
/// constant is the runtime identity the updater keeps for that same engine, in
/// the SemVer form [MpvGithubRelease.engineVersionFromAssetName] produces, so a
/// bundled engine is never reported as an available update.
///
/// Releases may override it with
/// `--dart-define=MPVSON_BUNDLED_ENGINE_VERSION=<version>` when they pin a
/// different package. [bundledEngineVersion] is checked against the provenance
/// record by `test/bundled_engine_test.dart`.
const String bundledEngineVersion = String.fromEnvironment(
  'MPVSON_BUNDLED_ENGINE_VERSION',
  defaultValue: '0.41.0-dev.39086651352+gfffe7a23a',
);
