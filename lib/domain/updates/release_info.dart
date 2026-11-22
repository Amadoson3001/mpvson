enum AppUpdateArtifact {
  windowsInstaller,
  windowsPortable,
  linuxBundle,
  unknown,
}

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

  AppUpdateArtifact get artifact {
    final path = downloadUri.path.toLowerCase();
    if (path.endsWith('.exe')) return AppUpdateArtifact.windowsInstaller;
    if (path.endsWith('.zip')) return AppUpdateArtifact.windowsPortable;
    if (path.endsWith('.tar.gz')) return AppUpdateArtifact.linuxBundle;
    return AppUpdateArtifact.unknown;
  }
}
