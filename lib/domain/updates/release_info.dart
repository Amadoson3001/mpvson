/// A verified release candidate selected from the update manifest.
final class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.engineVersion,
    required this.downloadUri,
    required this.sha256,
    this.releaseUri,
  });

  final String version;
  final String notes;
  final String engineVersion;
  final Uri downloadUri;
  final String sha256;
  final Uri? releaseUri;
}
