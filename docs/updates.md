# Desktop updates

Mpvson has two independent update channels.

| Channel | Configuration | Scope | Activation |
| --- | --- | --- | --- |
| Application package | `MPVSON_UPDATE_MANIFEST` | Windows or Linux app archive | Download and install manually after closing Mpvson |
| Windows engine | mpv stable releases by default; development builds are an explicit saved opt-in; optional signed custom feed | Compatible upstream x64 Windows GPL libmpv ZIP, or an explicitly configured signed package | Stage in app support and activate after restart |

Linux continues to use the distribution's libmpv and FFmpeg packages. Windows
defaults to mpv's stable release channel. The Update Center can opt into the
first-party rolling `git-release` development builds and remembers that choice
in the updater's own preferences file. mpv describes these builds as untested.
The stable and development feeds use GitHub's HTTPS metadata and asset digests;
neither feed is signed by Mpvson. A custom signed engine feed takes precedence
when both its manifest URL and public key are configured. The app-package
channel remains a separate manual download/install workflow.

## Configure the application package source

The application package channel remains opt-in. Build with its public manifest
URL supplied as a Dart define:

```powershell
flutter build windows --release --dart-define=MPVSON_UPDATE_MANIFEST=https://downloads.example.org/mpvson/stable.json
```

For Linux, pass the same define to the Linux release build. When this value is
omitted or empty, the update view reports that no source is configured. The
application has no hard-coded or simulated update endpoint.

The application manifest is JSON with `schemaVersion` 1. URLs must use HTTPS, may redirect
up to four times, and may not contain credentials or fragments. The selected
manifest is limited to 256 KiB. Artifact downloads are limited to 2 GiB and 30
minutes, with a 20 second request and stream-idle timeout. A missing artifact
for the running platform is an error.

```json
{
  "schemaVersion": 1,
  "version": "0.2.0",
  "notes": "Fixes playback resume and improves queue handling.",
  "engineVersion": "0.40.0",
  "releaseUrl": "https://downloads.example.org/mpvson/releases/0.2.0",
  "artifacts": {
    "windows": {
      "url": "https://downloads.example.org/mpvson/0.2.0/mpvson-windows-x64.zip",
      "sha256": "<64 lowercase hexadecimal characters>"
    },
    "linux": {
      "url": "https://downloads.example.org/mpvson/0.2.0/mpvson-linux-x64.tar.gz",
      "sha256": "<64 lowercase hexadecimal characters>"
    }
  }
}
```

`version` follows SemVer 2.0.0, including prerelease precedence. The notes and
engine version are shown as release information; they do not alter which
artifact is selected. The URLs should be stable, publicly readable download
locations so the app can fetch them without credentials.

## Download management, caching, and retention

The updater downloads artifacts with active lifecycle tracking and integrity safeguards:

- **Abortable requests and cancellation**: In-flight HTTP requests and response
  stream subscriptions are tracked with abort triggers. When a request or stream
  times out or the service is disposed, the underlying HTTP request and stream
  subscriptions are actively cancelled. Partial download files (`.part`) are
  immediately cleaned up on error, timeout, or disposal. Operations completed or
  aborted after disposal never publish finished archives or mark the status ready.
- **Ownership records (`updates.json`)**: Verified downloads are recorded in an
  ownership record file in the updater storage directory
  (`<appSupport>/updates/updates.json`), storing the release version, expected
  SHA-256 digest, filename, file size, and timestamp.
- **Cached bundle reuse**: When `download()` is called, the service checks whether
  a verified archive matching the release version and SHA-256 already exists on
  disk and in the ownership record. If so, it verifies the local file's digest
  and reuses it immediately without making an HTTP request.
- **Archive retention**: The storage directory retains at most the current and
  previous verified archives. Older recorded archives are safely pruned to reclaim
  disk space.
- **Pruning safety**: Pruning only deletes recorded, unchanged files tracked in
  `updates.json` whose size and SHA-256 digest match their original recorded state.
  If a tracked archive was modified or corrupted, it is not pruned. Any unrelated
  files, user notes, or manual downloads in the storage directory are left untouched.

## Package and publish a release

Build each target with the same Flutter and media_kit versions used for the
release. The Windows application archive includes the app, plugins and its
tested bundled media_kit/libmpv runtime. Keep that bundled engine because it is
the fallback when mpv has no compatible stable libmpv package. A custom feed,
when explicitly configured, must provide a complete signed versioned engine
ZIP, not loose DLL replacements.

The Linux release archive contains the Flutter app and plugins, while
`media_kit_libs_linux` loads the system `libmpv`. The archive does not update
that system library or FFmpeg. Linux users need a compatible distro runtime;
on Debian or Ubuntu, install or update it through the package manager, for
example `sudo apt install libmpv2`. Distro package names and versions vary.
Use the release notes to state which distro/runtime versions were tested.
`engineVersion` is release information and does not mean the Linux archive
contains that engine build.

1. Build the Windows and Linux release apps on their matching CI/build hosts.
2. Package the full Windows release output, including the bundled engine, as a
   ZIP. Package the Linux Flutter bundle as a `tar.gz` so executable
   permissions are retained; document its system `libmpv` requirement.
3. Manually verify each archive after extracting it on a clean machine or VM for
   that OS. On Linux, test against each distro/runtime combination you claim
   to support. Confirm startup, video, audio, subtitles, and representative
   media before publishing.
4. Upload both immutable archives to HTTPS locations and note their final URLs.
5. Generate the manifest from those exact uploaded files or byte-identical
   local archives. For example:

```powershell
dart run tool/create_release_manifest.dart `
  --version 0.2.0 `
  --engine-version 0.40.0 `
  --windows-file dist/mpvson-windows-x64.zip `
  --windows-url https://downloads.example.org/mpvson/0.2.0/mpvson-windows-x64.zip `
  --linux-file dist/mpvson-linux-x64.tar.gz `
  --linux-url https://downloads.example.org/mpvson/0.2.0/mpvson-linux-x64.tar.gz `
  --release-url https://downloads.example.org/mpvson/releases/0.2.0 `
  --notes-file release-notes.txt `
  --output dist/stable.json
```

6. Review the generated URLs and hashes, then publish `stable.json` at the URL
configured into the application.

### Manifest generation safety

The CLI tool (`tool/create_release_manifest.dart`) enforces safety constraints:

- **Collision prevention**: The output path is validated against both `windows-file`
  and `linux-file`. The tool checks canonical absolute normalized paths and resolves
  all symbolic links and aliases. If the output manifest would overwrite either release
  artifact, it halts immediately with a descriptive error.
- **Atomic manifest writes**: The manifest is written to a temporary file in the
  target directory and renamed to the final destination path, ensuring no broken or
  partial JSON file is ever left in place.
- **Validation**: Both target archives must exist, SemVer and HTTPS URLs are validated,
  archive digests are computed via SHA-256, and the generated JSON is verified with
  the exact parser used by the application.

The application manifest is not digitally signed. Its SHA-256 detects a
damaged or incomplete archive relative to the fetched manifest, but it does
not protect against a compromised application-manifest host or release
account. This application manifest setting does not configure the independent
Windows engine source.

## Bundled playback engine

The Windows bundle ships a pinned libmpv module as the tested fallback engine.
The pin lives in `packaging/windows/engine-provenance.json`: the upstream package
URL and byte size, the ZIP SHA-256, the `libmpv-2.dll` member size and SHA-256,
the upstream `LICENSE.GPL` digest, the engine version, commit and build date, and
the component inventory the module reports about itself.

The Windows CMake configure step reads that record, reuses a verified cache in
`build/windows/x64/engine`, otherwise downloads the exact asset and verifies its
SHA-256, then extracts `libmpv-2.dll`, verifies the member digest and size, and
replaces the 2023 module that `media_kit_libs_windows_video` would otherwise
bundle. Any digest, size or license mismatch fails the configure step instead of
shipping an unverified engine. A pre-verified module can be supplied instead of a
download with `-DMPVSON_ENGINE_DLL=<path>`, which keeps offline builds and CI
caches working; the module is still digest-checked.

The same JSON and the extracted license text are installed beside the
application as `engine-provenance.json` and `LICENSE.libmpv-GPL.txt`.

The runtime identity of this engine is `bundledEngineVersion` in
`lib/domain/updates/bundled_engine.dart`, in the SemVer form the updater stores
for the matching upstream package. `test/bundled_engine_test.dart` keeps that
constant, the asset name in the pin and the runtime version equal, so the
bundled engine is never reported as an available update.

The current upstream stable tag, `v0.41.0`, publishes Windows `mpv` player
archives but no compatible `libmpv` ZIP. The first-party Windows libmpv package
is under the rolling `git-release` development tag. The bundled pin remains the
tested fallback and is identified by its exact build in
`packaging/windows/engine-provenance.json`; selecting the stable channel does
not relabel that bundled development build. The updater reports when a stable
tag has no compatible package and leaves the currently loaded engine selected.

Because upstream refreshes the `git-release` tag in place, a pinned URL can
disappear after a rebuild. The failure mode is explicit: the configure step
reports the digest mismatch or download error and points at the refresh command.
An intentional engine change is a reviewed two-step:

```powershell
dart run tool/engine_provenance.dart refresh --accept v0.41.0-dev-g<commit>
flutter test test/bundled_engine_test.dart
```

Verified on 18 Oct 2026 against the pinned module in the release bundle:

- The explicit development channel still publishes the exact pinned package
  (`libmpv-v0.41.0-dev-gfffe7a23a-39086651352-x86_64-w64-mingw32-gpl.zip`,
  SHA-256 `0f8f9bffbc2fa38b7e036a3d927c38a3e7494fd8a374e671344021e756a6304c`),
  so the pin matches what the updater would download today and the bundled engine
  is not offered as an update.
- The live upstream test downloaded it through the normal update path, staged it in
  an isolated store, activated it after restart, rendered video with the player and
  renderer bound to that DLL, and rolled back to the bundle.
- In historical test records, the engine activation test staged the bundled module under synthetic labels, activated,
  recovered from an invalid module and rolled back; `dart run
  tool/engine_provenance.dart verify` and `inventory`, the thumbnail native tests and
  the native source probe passed with the same module, and
  `test-output/engine-inventory.json` records what the loaded module reports about
  itself.

`refresh` reads the upstream release metadata, refuses to change the pin unless
the operator names the version they reviewed, downloads the package, recomputes
every digest, rewrites the record and refreshes the build cache. `verify`
re-checks the record, the checked-in license text, the cache and the built
bundle, and `inventory` writes `build/engine/engine-inventory.json` for release
provenance. Optional native probes run the same checks against a running engine:

```powershell
flutter build windows --release
flutter test --dart-define=MPVSON_PROBE_ENGINE_INVENTORY=true test/native_engine_inventory_probe_test.dart
```

The probe compares the bundled module digest with the pin, loads it, and records
the `mpv-version`, `ffmpeg-version`, `libass-version`, `platform` and
`mpv-configuration` values it reports into `test-output/engine-inventory.json`.

The `libEGL`, `libGLESv2`, `d3dcompiler_47`, `vk_swiftshader`, `vulkan-1` and
`zlib` modules still come from `media_kit_libs_windows_video`. They serve the
video renderer's ANGLE path, not the engine, and are unchanged.

## Windows engine update channels

The default channel checks mpv's latest stable release at
`https://api.github.com/repos/mpv-player/mpv/releases/latest`. Mpvson accepts
only a published stable version tag and a compatible x64 MinGW GPL `libmpv`
ZIP named `libmpv-v<major>.<minor>.<patch>-x86_64-w64-mingw32-gpl.zip`. If a
stable release has no matching package, the Update Center says so and leaves the
currently loaded engine selected. It does not report the bundled development build as a stable
update or call the missing package up to date.

For reference, the official [mpv v0.41.0 release assets](https://github.com/mpv-player/mpv/releases/expanded_assets/v0.41.0)
include x64 Windows `mpv` player ZIPs but no `libmpv` ZIP. mpv's
[installation page](https://mpv.io/installation/) says first-party CI builds
are intended mainly for testing. The updater therefore offers the development
channel only after the user selects it in the Update Center. It checks the
rolling `git-release` at
`https://api.github.com/repos/mpv-player/mpv/releases/tags/git-release` and
accepts only a published x64 MinGW GPL `libmpv` ZIP named
`libmpv-v<major>.<minor>.<patch>-dev-g<commit>-<build>-x86_64-w64-mingw32-gpl.zip`.
The UI identifies development versions and warns that upstream calls them
untested.

For both channels, the selected asset must use the expected HTTPS GitHub
release URL and publish a positive byte size and `sha256:` asset digest. The
download is checked against that size and digest again before staging. This
integrity check trusts GitHub's HTTPS API and release metadata. It is not an
Ed25519 signature and does not mean Mpvson has certified the package.

The engine channel is separate from the manual app-package channel. An optional
custom signed feed is selected by explicitly configuring both its URL and the
matching base64 public key at Windows build time:

```powershell
flutter build windows --release `
  --dart-define=MPVSON_ENGINE_UPDATE_MANIFEST=https://downloads.example.org/mpvson/engine/stable.json `
  --dart-define=MPVSON_ENGINE_PUBLIC_KEY=REPLACE_WITH_BASE64_PUBLIC_KEY
```

When both values are set, that custom Ed25519 feed is used instead of the
first-party source. To use the stable default or select the development channel
in Update Center, omit both values. Do not publish
a custom manifest or seed unless you intend to operate that separate release
channel.

You can configure both channels on the same build. The application channel
still downloads a complete app archive for manual installation. The engine
channel downloads a verified runtime package, stages it in the app support
directory, and activates it after Mpvson restarts. The running process keeps
using its current engine.

### Optional custom signed manifest

Only the custom-feed mode uses the signed manifest below. It has
`schemaVersion` 1 and this shape:

```json
{
  "schemaVersion": 1,
  "payload": {
    "engineVersion": "0.40.0",
    "notes": "Windows engine update notes.",
    "mediaKitVersion": "1.2.6",
    "minimumAppVersion": "0.1.0",
    "maximumAppVersionExclusive": "1.0.0",
    "artifacts": {
      "windows": {
        "url": "https://downloads.example.org/mpvson/engine/0.40.0/windows-x64.zip",
        "sha256": "<64 lowercase hexadecimal characters>",
        "size": 12345678
      }
    }
  },
  "signature": "<base64 Ed25519 signature>"
}
```

`maximumAppVersionExclusive` is optional. Versions use SemVer 2.0.0. The
minimum app version is inclusive and the maximum is exclusive. The signature
is a base64 encoding of the 64-byte Ed25519 signature over the compact UTF-8
JSON encoding of `payload`, with object keys sorted recursively. The
`schemaVersion` and outer `signature` field are not included in the signed
bytes. The ZIP's byte size and SHA-256 must match the payload exactly.

### Prepare a custom engine package and signing key

For a custom signed feed, create the ZIP from the Windows runtime files selected
by the exact `media_kit_libs_windows_video` version in `pubspec.lock`, not from
an unrelated standalone mpv download. For the currently locked version
`1.0.11`, its Windows `CMakeLists.txt` defines these bundled runtime files:

```text
libmpv-2.dll
d3dcompiler_47.dll
libEGL.dll
libGLESv2.dll
vk_swiftshader.dll
vulkan-1.dll
zlib.dll
```

Put all seven DLLs at the ZIP root, including `libmpv-2.dll` with this exact
lower-case spelling. Build the ZIP from the corresponding tested Windows
release output or the exact dependency artifacts selected by that CMake file.
Keep the license, notice, and attribution files supplied with the plugin and
runtime bundles, preserving their contents and relative paths. Do not include
the Mpvson executable, Flutter/plugin binaries, unrelated files, or a different
mpv build. If the lockfile changes, inspect that version's CMake bundled-file
list and rebuild and test the package against the changed inventory. Set
`mediaKitVersion` and `engineVersion` to the versions used to build and test
this exact ZIP.

Mpvson loads the selected `libmpv-2.dll` by its versioned path. On Windows the
runner configures the native video bridge first; the CMake setup removes the
video plugin's direct link to `libmpv.dll.a`, and the bridge resolves both
MediaKit and renderer symbols from that same selected module. This prevents
the player and video renderer from silently using different mpv builds.

The generator rejects absolute paths, traversal segments, Windows-invalid
names, duplicate paths, symbolic links, and a missing, empty, or wrongly
cased root `libmpv-2.dll`. It also rejects more than 4,096 entries, ZIPs larger
than 512 MiB, or packages with more than 2 GiB of uncompressed data. Generated
manifests must fit the app's 256 KiB UTF-8 download limit; notes are limited to
80 KiB of characters and the artifact URL to 4,096 characters. The generator
validates its result with the same manifest parser used by the app. These
limits match the engine updater's download and extraction limits.

The generator checks package structure, not the origin of its binaries or
whether they work together. Treat a package as release-ready only after a
clean Windows machine has installed it through the updater using an isolated
app-support profile and passed startup plus representative video, audio, and
subtitle playback tests. The CLI does not certify the binaries. The release
maintainer certifies the package by recording its source build and versions,
plus the machine and verification result, with the release.

Create a 32-byte seed with a cryptographically secure random number generator
on an offline release machine. Keep it outside the repository. For example,
Windows PowerShell can write a raw seed under the current user's local data
directory:

```powershell
$secretDirectory = Join-Path $env:LOCALAPPDATA 'mpvson-release-secrets'
New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
$seedPath = Join-Path $secretDirectory 'engine-ed25519.seed'
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$seed = New-Object byte[] 32
$rng.GetBytes($seed)
[IO.File]::WriteAllBytes($seedPath, $seed)
$rng.Dispose()
```

Restrict access to that file and store a protected backup offline. The CLI
accepts the raw 32 bytes, 64 hexadecimal digits, or base64 encoding of those
same bytes. Never commit or upload the seed, include it in an app build, or
place it beside the public manifest. The CLI prints the derived public key in
base64 so it can be supplied as `MPVSON_ENGINE_PUBLIC_KEY`. The app only needs
that public key. Changing it requires a new app build with the replacement
public key. Neither this signing key nor the custom manifest is needed for
the default first-party mpv source.

This generator creates a manifest only for the optional custom signed feed;
it is not used to enable or publish the default mpv source. Generate the
manifest only after uploading the immutable ZIP to its final
HTTPS URL:

```powershell
dart run tool/create_engine_manifest.dart `
  --engine-zip dist/mpvson-engine-windows-x64.zip `
  --engine-url https://downloads.example.org/mpvson/engine/0.40.0/windows-x64.zip `
  --engine-version 0.40.0 `
  --media-kit-version 1.2.6 `
  --min-app-version 0.1.0 `
  --max-app-version-exclusive 1.0.0 `
  --notes-file release-notes.txt `
  --signing-key $seedPath `
  --output dist/engine-stable.json
```

Omit `--max-app-version-exclusive` when there is no upper compatibility bound.
Use either `--notes` or `--notes-file`; both may be omitted. The CLI validates
SemVer and HTTPS values, checks the ZIP entries, hashes the exact ZIP bytes,
signs the canonical payload, refuses to overwrite the ZIP or signing key, and
writes the result atomically. It also refuses to overwrite a notes file passed
with `--notes-file`.

Upload `engine-stable.json` to a static HTTPS location and configure that URL
with `MPVSON_ENGINE_UPDATE_MANIFEST` together with the matching public key.
The custom manifest can be hosted separately from the application manifest.
No Mpvson-hosted custom engine feed is provided by this repository.

### Stage, activate, and roll back

By default, the updater uses the HTTPS GitHub release metadata and verifies the
downloaded ZIP against the published size and SHA-256 digest. In custom-feed
mode, it verifies the manifest's Ed25519 signature with the configured public
key, then checks the declared ZIP size and SHA-256. In either mode, it validates
the package archive before staging under
`<app support>/mpvson/engines/<engine-version>`. It does not overwrite the
engine used by the running process. The pending package activates after
restart. Mpvson records a boot attempt before loading a pending engine and
confirms it after MediaKit and the playback controller initialize. The update
view offers **Discard pending engine** before restart; this clears the pending
selection and removes its unused staged package so the same version can be
downloaded again. Active and previous packages remain available.

After an engine has become active, **Roll back engine** selects the previous
compatible package, or the bundled engine when no previous compatible package
exists. This is queued for the next restart. The currently loaded engine keeps
running until Mpvson closes. A queued rollback can also be discarded before
restarting. The update view names the rollback target and distinguishes it from
a newly downloaded release.

Each saved install retains its app and media_kit compatibility bounds.
Bootstrap checks those bounds again after an application update. It also
checks the saved DLL digest before loading an install. Mutating store
operations are serialized across app instances with a bounded file lock.

At startup Mpvson selects the applicable engine choices in order: pending,
active, previous, then the bundled engine. A pending package gets one boot
attempt and is confirmed only after MediaKit and the playback controller
initialize. An unconfirmed attempt from an earlier launch is cleared before
fallback. If a selected custom engine fails during native loading or playback
controller startup, Mpvson persists the rejected selection and automatically
relaunches in a fresh process with the next fallback. A fresh process is
required because MediaKit caches native bindings; switching to another DLL in
the same process could mix engine modules. Recovery is bounded and falls back
to the bundled engine as the final candidate. Keep the previous working engine
and the original bundled engine available.

This rollback chain is why engine updates must be complete packages with
version and media_kit compatibility metadata. A loose DLL cannot prove which
matching dependencies it needs or whether it fits the app's architecture.
The default source relies on GitHub's HTTPS release metadata and digest; custom
feeds add an independent Ed25519 approval signature. Do not copy a DLL into
the application directory by hand.

Engine-store directories are only removed when Mpvson owns them. Every package
the updater stages or installs contains a `.mpvson-engine.json` ownership marker
naming the version and the installed DLL digest. A directory without that marker
— a manual copy, another tool's data, or an install created by an older release —
is never deleted: staging fails with an explicit message instead, so an archive
that turns out to be unusable cannot destroy a directory it would not replace.
Packages are extracted and verified in a unique staging directory, and only a
verified package replaces an owned, unreferenced directory.

If the selection file is damaged, Mpvson validates the records of the selection
file and its backup before choosing between them, so a file whose records no
longer resolve cannot hide a usable backup. An explicit "use the bundled engine"
decision and an interrupted boot attempt always win over records from the
backup, and recovery never proposes a pending install, so an engine this startup
rejected cannot come back.

When only one half of the custom-feed configuration is present — the manifest URL
without the public key, or the key without the manifest URL — Mpvson keeps the
selected official channel and shows a configuration warning in the update view
instead of silently disabling engine updates. A complete configuration that fails
validation (a non-HTTPS manifest URL, or a malformed or wrong-length key) reports
its validation error in the update view and disables engine update checks.

The engine feed is Windows-only. On Linux, install or update libmpv and FFmpeg
through the distribution package manager. There is no independent Linux
engine package channel.

## Install after closing Mpvson

When the application download is ready, use **Open package** to reveal the
verified archive. The app must be fully closed before replacing files. Install
into a user-writable directory when possible so no administrator access is
needed.

1. Close Mpvson and confirm its process has exited.
2. Keep a copy of the current application directory as a rollback backup.
3. Extract the downloaded application beside the current directory first. On
   Linux, extract the `tar.gz` without stripping executable permissions and
   ensure the required system `libmpv` runtime is installed separately.
4. Launch the new copy from that staging directory and verify normal playback.
5. Rename the old directory to a dated backup, then move the verified new
   directory into the old installation path.
6. Keep the backup until the new version has been used successfully.

If the new copy fails to start or play media, close it, move the failed copy
aside, and rename the backup directory back to the original installation
path. On Windows this restores the app and bundled engine together. The
independent engine channel keeps its own previous and bundled rollback path.
On Linux,
the system `libmpv` is managed separately; if a system runtime update caused
the failure, use the distro package manager to restore a compatible version
as well as restoring the app directory.
