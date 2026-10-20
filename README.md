# Mpvson

A desktop video player for Windows and Linux, built with Flutter and powered by mpv through media_kit. The UI runs as a compiled desktop application with native window chrome, OS file dialogs, keyboard controls, and drag and drop.

Mpvson is standalone: it stores its state in the OS application-support directory, does not modify a system mpv profile, and needs no separate mpv installation on Windows.

The interface gives video the full stage below the native title bar. A thin seek timeline and all controls sit along the bottom; the More menu contains open, recent-file and settings actions. Open the queue when needed; it docks on wide windows and becomes a drawer on smaller ones. Settings groups playback controls, shortcuts and application information into tabs. See [interface design notes](docs/ui-design.md).

Settings → Appearance offers Compact and Normal controls. Compact is the default: smaller buttons and a wider seek rail in a shallow bottom strip. Changes apply immediately and are remembered after restarting. See [control-size design](docs/control-density.md).

## Run on Windows

Release archives are built by the [desktop workflow](.github/workflows/desktop.yml). To run from source, install Flutter with the Visual Studio Desktop development with C++ workload, then:

```powershell
flutter pub get
flutter run -d windows
```

Build the release:

```powershell
flutter build windows --release
.\build\windows\x64\runner\Release\mpvson.exe
```

Keep the entire Release folder together. Its DLLs and `data` directory are required. The build includes its playback engine; no separate mpv installation is needed on Windows.

Pass local media paths to the executable to open them. Network sources can be opened through Open URL.

## Run on Linux

Install Flutter and the desktop build dependencies. For Debian/Ubuntu:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev libasound2-dev libepoxy-dev liblzma-dev
flutter pub get
flutter run -d linux
flutter build linux --release
./build/linux/x64/release/bundle/mpvson
```

Keep the full Linux bundle together. The platform's GTK, OpenGL, and mpv runtime dependencies must be available. A desktop entry and scalable icon are in `packaging/linux`.

### Optional Linux desktop launcher installation

To integrate the Linux release bundle with desktop application menus, docks, and file managers:

1. **Set up the executable on PATH**:
   Point a symlink in `~/.local/bin` to the extracted bundle's `mpvson` executable (ensure `~/.local/bin` is in your `$PATH`):
   ```sh
   mkdir -p ~/.local/bin
   ln -sf /path/to/mpvson-bundle/mpvson ~/.local/bin/mpvson
   ```
   *(Alternatively, edit the `Exec=` line in `dev.mpvson.mpvson.desktop` to specify the absolute path to the bundle's `mpvson` binary).*

2. **Install the application icon**:
   ```sh
   mkdir -p ~/.local/share/icons/hicolor/scalable/apps
   cp packaging/linux/dev.mpvson.mpvson.svg ~/.local/share/icons/hicolor/scalable/apps/
   ```

3. **Install the desktop launcher**:
   ```sh
   mkdir -p ~/.local/share/applications
   cp packaging/linux/dev.mpvson.mpvson.desktop ~/.local/share/applications/
   ```

4. **Update the desktop database**:
   ```sh
   update-desktop-database ~/.local/share/applications/
   ```

For system-wide installation across all users, copy the files to `/usr/local/bin/mpvson`, `/usr/local/share/icons/hicolor/scalable/apps/`, and `/usr/local/share/applications/`, then run `sudo update-desktop-database /usr/local/share/applications/`. See [Linux packaging guide](packaging/linux/README.md).

## Playback and desktop UX

- Open local videos or URLs, or drop files into the window.
- Maintain a searchable queue with reorder, removal, and undo. Queue removal never deletes the source file.
- Shuffle directly from the queue, with no repeated entries within a cycle and Previous following playback history.
- Queue cards show cover art or a generated video frame, with duration over the image. Hover or focus a card to reveal its drag grip on the left.
- Continue recent media from its saved position.
- Select audio and subtitle tracks, load an external subtitle file, and adjust playback speed.
- Tune quality, hardware decoding, picture and synchronization in Settings > Video & audio. See [playback tuning](docs/playback-tuning.md).
- Inspect the active decoder and dropped frames through More > Playback information or the I key.
- Control volume, seek, and enter fullscreen from the player or keyboard.
- Scroll over video to change volume, click to pause/play, and double-click to toggle fullscreen.
- Right-click for playback, speed, audio/subtitle, volume and file actions. The menu also opens with Shift+F10.
- Fullscreen controls and the cursor hide after inactivity. Keyboard focus, menus and dragging keep the controls available.
- Escape dismisses the compact queue drawer if open, or exits fullscreen.
- Restore the saved queue without unexpectedly starting playback on launch.

| Shortcut / Gesture | Action |
| --- | --- |
| Space | Pause or play |
| Hold Space | Temporarily play at 2× speed while held |
| Left / Right | Seek 5 seconds backward / forward (or adjust focused slider) |
| Up / Down | Adjust volume (or adjust focused slider) |
| Click video | Pause or play |
| Double-click video | Toggle fullscreen |
| Mouse wheel over video | Adjust volume |
| Right-click video | Open the player context menu |
| Shift+F10 | Open the player context menu |
| F / F11 | Toggle fullscreen |
| Escape | Dismiss compact queue drawer or exit fullscreen |
| P | Show or hide the queue |
| Delete | Remove the selected queue item |
| M | Mute or restore volume |
| I | Show playback information |
| Ctrl+O | Open files |
| Ctrl+L | Open URL |

Text fields retain normal typing behavior. Controls have accessible labels and tooltips.

## Data and privacy

Queue state, playback positions, and preferences are stored in the OS application-support directory, not beside the executable. Local media remains in its original location. There are no accounts or telemetry in this application.

Local queue thumbnails are cached in the OS application-cache directory. A same-name image beside the video is used when available, followed by embedded cover art or a representative video frame. Thumbnail decoding runs separately from playback and does not change the playing source or its position.

## Updates

Mpvson has separate application and playback-engine update channels. Windows
release bundles still include a tested fallback engine so the player can start
offline and recover from a bad staged engine. A verified engine package can be
downloaded into versioned application-support storage and becomes active after
Mpvson restarts. The previous engine and bundled fallback remain available for
rollback. Linux keeps using the distribution's libmpv runtime, which is updated
through the system package manager.

Configure the application update manifest when building:

```sh
flutter build linux --release --dart-define=MPVSON_UPDATE_MANIFEST=https://your-domain.example/releases/manifest.json
```

Use the same dart-define with the Windows build command. Builds with no source configured say so in Settings. The updater checks version and platform, downloads a release, verifies SHA-256, and exposes the verified download. Installation happens after closing the player; do not replace loaded libraries during playback. See [update and release instructions](docs/updates.md) for the manifest format, generation tool, install flow, and rollback.

Windows engine updates default to the stable channel. The latest upstream
stable release, mpv v0.41.0, publishes Windows player archives but no compatible
`libmpv` ZIP. The Update Center reports that package as unavailable and keeps
using the currently loaded engine. Select **Development** there to opt into mpv's rolling
`git-release` libmpv builds. mpv marks these builds as untested. Mpvson checks
the selected asset's size and GitHub-provided SHA-256 before staging, then
remembers the channel in its updater preferences. See the [stable release
assets](https://github.com/mpv-player/mpv/releases/expanded_assets/v0.41.0) and
[mpv's installation page](https://mpv.io/installation/).

An optional custom engine channel uses its own HTTPS manifest and a pinned
Ed25519 public key:

```powershell
flutter build windows --release `
  --dart-define=MPVSON_ENGINE_UPDATE_MANIFEST=https://your-domain.example/engine/stable.json `
  --dart-define=MPVSON_ENGINE_PUBLIC_KEY=<base64-ed25519-public-key>
```

The custom channel rejects unsigned manifests and incompatible media_kit or
Mpvson versions. Both sources reject unsafe archives and packages whose size
or SHA-256 differs from their metadata. The updater never replaces a DLL used
by the running process.
The Update Center also offers **Roll back engine**. The previous compatible
engine, or the bundled fallback, becomes active after restarting.

Application updates still need a separately published application manifest.
That does not disable mpv engine updates.

## Development and checks

```sh
dart format lib test tool
flutter analyze
flutter test
```

After a Windows release build, verify the native engine against a local video:

```powershell
.\verification\windows-smoke.ps1 -MediaPath 'C:\Videos\sample.mp4'
```

The smoke check uses an isolated session, mutes its own playback, verifies the engine version, opens/seeks/pauses a real video, captures the app, and writes its report under `test-output`. Use `-ExecutablePath` to point to a specific runner or freshly extracted portable executable (defaults to `build/windows/x64/runner/Release/mpvson.exe`).

The independent engine flow has an opt-in native check after a Windows release
build and creation of `test-output/smoke.mp4`:

```powershell
flutter test --no-pub --dart-define=MPVSON_NATIVE_ENGINE_SMOKE=true test/engine_native_smoke_test.dart
```

It signs a package containing the existing tested runtime, stages it in an
isolated store, verifies the player and renderer use the selected DLL, checks
recovery from an invalid DLL, and rolls back to the bundled engine. Its fixture
release labels exercise selection; they do not represent a newer upstream mpv
build. No production signing key or user engine installation is used.

To check the opt-in development source, download its current package, render
video with that engine and roll back in an isolated store:

```powershell
flutter test --no-pub --dart-define=MPVSON_LIVE_MPV_TEST=true test/mpv_upstream_native_test.dart
```

This opt-in check needs internet access. Its evidence is written beneath
`test-output/mpv-upstream-native/` and includes the actual upstream URL, hash
and loaded engine version.

Pass `-VerifyFullscreen` to also exercise native fullscreen and capture the video with the controls hidden. See [desktop interaction design and research](docs/desktop-ux.md).

The desktop workflow in `.github/workflows/desktop.yml` checks and builds Windows x64 and Linux x64, packages the release archives, extracts the bundles into clean staging directories, and executes native playback smoke-tests directly on the extracted binaries before publishing release artifacts.

The code uses MVVM with injected playback and session services. App controls use Flutter widgets and focus handling; mpv owns decoding, audio/video synchronization, subtitle rendering, and GPU video output. UI controls do not use mpv's ASS renderer.

## Source map

| Path | Purpose |
| --- | --- |
| `lib/domain` | Media/session models and release metadata |
| `lib/data` | Playback, storage, updates, and repositories |
| `lib/ui` | View models, theme, player, queue, and settings |
| `windows`, `linux` | Native desktop runners |
| `test` | Playback/session, update integrity, and UI regression tests |
| `tool` | Release tooling |
| `docs` | Architecture, design, and update notes |
| `packages/media_kit_video` | Vendored, patched media_kit video plugin |
| `packaging` | Desktop integration assets |

## License

Mpvson is released under the [MIT License](LICENSE).

Flutter, media_kit, libmpv, and their dependencies retain their upstream licenses. Include the relevant notices and source obligations when distributing a release built from these dependencies; see `packaging/windows/THIRD_PARTY.txt` and `packaging/windows/LICENSE.libmpv-GPL.txt`.
