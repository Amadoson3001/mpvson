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

### Windows packaging: Portable ZIP vs Inno Setup Installer

Mpvson provides two distribution formats on Windows:

- **Portable ZIP (`mpvson-windows-x64.zip`)**: A self-contained, zero-install archive. Extract anywhere and launch `mpvson.exe`. It writes state exclusively to `%APPDATA%\dev.mpvson.mpvson`, requires no administrative privileges, and makes no registry alterations.
- **Inno Setup Installer (`MpvsonSetup.exe`)**: Created via `packaging/windows/installer.iss`. Installs to the user's local profile (`%LOCALAPPDATA%\Programs\Mpvson`) without prompting for UAC elevation, adds Start Menu and Desktop shortcuts, registers the uninstaller in Windows Settings, and configures Windows Explorer file associations and Default Apps capabilities (`Software\RegisteredApplications\Mpvson`).

### Windows desktop integration

- **Single-instance named pipe**: Launching files from Explorer or the command line connects to the running instance over a local named pipe, brings the existing window to the foreground, and routes media to the player without starting multiple processes.
- **System Media Transport Controls (SMTC)**: Native WinRT SMTC integration synchronizes playback state, track metadata (title, artist, album, and thumbnail artwork), timeline positions, and hardware media keys with the Windows 10/11 taskbar volume flyout and lock screen.
- **Power requests (display awake)**: Uses Win32 power request APIs (`PowerRequestDisplayRequired`) to prevent monitor sleep and screen savers during video playback. The request automatically clears on pause, stop, or during audio-only playback, and can be toggled in Settings.
- **Explorer file associations & context menus**: Registers file type capabilities across all supported media formats. Right-clicking media in Explorer offers both **Play with Mpvson** (default open) and **Add to queue** (`--enqueue`).

See the [desktop integration guide](docs/desktop-integration.md) for architecture and packaging details.

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

### Linux desktop integration and installation

Mpvson integrates with Linux desktop environments via standard FreeDesktop specifications:

- **GApplication single instance**: GTK `GApplication` IPC (`dev.mpvson.mpvson`) ensures secondary launches forward file paths to the primary instance over D-Bus and raise the existing window.
- **MPRIS D-Bus player interface**: Implements `org.mpris.MediaPlayer2` and `org.mpris.MediaPlayer2.Player` on the session bus. Allows full control (Play, Pause, Stop, Seek, Next, Previous) and metadata observation (track artist, title, album, art URL, position) through GNOME Shell media controls, KDE Plasma media widgets, lock screens, and CLI tools like `playerctl`.
- **Power inhibition portal**: Automatically requests idle inhibition via `org.freedesktop.portal.Inhibit` or `org.freedesktop.ScreenSaver` during active video playback, releasing the lock on pause, stop, or audio playback.

#### Automated user installation

Use the included helper scripts in `packaging/linux` to install or uninstall Mpvson for your user without root privileges:

```sh
# Install launcher, icon, and ~/.local/bin symlink
chmod +x packaging/linux/install.sh
./packaging/linux/install.sh /path/to/extracted/mpvson-bundle

# Uninstall
chmod +x packaging/linux/uninstall.sh
./packaging/linux/uninstall.sh
```

#### Manual Linux desktop launcher installation

To integrate manually with desktop application menus, docks, and file managers:

1. **Set up the executable on PATH**:
   Point a symlink in `~/.local/bin` to the extracted bundle's `mpvson` executable (ensure `~/.local/bin` is in your `$PATH`):
   ```sh
   mkdir -p ~/.local/bin
   ln -sf /path/to/mpvson-bundle/mpvson ~/.local/bin/mpvson
   ```

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

## Local media library and music browsing

Mpvson includes an integrated local media library designed for fast indexing, rich music browsing, unified search, favorites curation, and custom playlists without bogging down system resources:

- **Broad media catalog**: Indexes both video and high-resolution audio formats (FLAC, MP3, WAV, M4A, AAC, OGG, OPUS, WMA, AIFF, APE, MP4, MKV, WebM, AVI, MOV, and more).
- **Two-stage scanning**: A fast directory walk identifies supported media files immediately, followed by asynchronous background enrichment that extracts tags (ID3, Vorbis, MP4), technical stream properties (codecs, bitrates, sample rates), and embedded artwork.
- **Music browsing**: Navigate music hierarchically by Artist and Album with chronological sorting and track numbering.
- **Unified search**: Rapid case-insensitive substring search matching titles, artists, albums, and folder paths.
- **Favorites & playlists**: Star tracks for one-click access and create custom ordered playlists with drag-and-drop reordering.
- **Detachable storage resilience**: Tracks located on unmounted external drives or folders are marked unavailable rather than removed. Playback history, favorites, and playlist orders remain intact.
- **SQLite backend**: Uses indexed SQLite storage (`media_library.db`) in application-support storage. Library indexing operates independently of the playback engine and never alters source files on disk.

See the [library architecture guide](docs/library-architecture.md) for data schemas, indexing pipelines, and query design.

## Opening behavior and desktop settings

When opening new media files (via Explorer double-click, command-line arguments, drag-and-drop, or file dialogs) while media is already playing or paused, Mpvson coordinates the request through a configurable opening behavior preference:

- **Keep playing and add to queue** (`keepPlayingAndEnqueue`): Continues active playback uninterrupted and appends newly opened files to the active queue.
- **Play new files now** (`playNewFilesNow`): Halts active playback and starts playing the newly opened files immediately.
- **Ask every time** (`askEveryTime`): Prompts the user with a modal preference dialog on each conflict.
- **Initial choice prompt**: If unset, opening files during active playback displays a first-conflict dialog with "Keep playing and add to queue" or "Play new files now", automatically remembering the selection and noting that it can be modified anytime in Settings.
- **Display sleep setting**: Under **Settings > Desktop integration**, toggle display sleep prevention (`keepAwakeDuringPlayback`) or launch the OS default applications settings.

See the [desktop integration guide](docs/desktop-integration.md) for IPC flow, SMTC, MPRIS, and platform hooks.

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
dart format lib tool test
flutter analyze
flutter test --no-pub --concurrency=1
```

### Release builds and engine verification

Compile release binaries for Windows and Linux:

```powershell
# Windows release build
flutter build windows --release --target=lib/main.dart

# Verify bundled engine provenance and generate inventory
dart run tool/engine_provenance.dart verify
dart run tool/engine_provenance.dart inventory
```

```sh
# Linux release build
flutter build linux --release --target=lib/main.dart
```

Engine provenance verification (`tool/engine_provenance.dart verify`) checks the pinned engine archive, SHA-256 digest, and license against `packaging/windows/engine-provenance.json`. The `inventory` command records the engine version, ffmpeg version, and build components for distribution.

The desktop workflow in `.github/workflows/desktop.yml` validates formatting, static analysis, and tests before building Windows x64 and Linux x64 release binaries. It also verifies engine provenance and inventory, then packages release distribution archives (`dist/mpvson-windows-x64.zip` and `dist/mpvson-linux-x64.tar.gz`) with SHA-256 checksums.

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
| `docs` | Architecture, desktop integration, library, design, and update notes |
| `packages/media_kit_video` | Vendored, patched media_kit video plugin |
| `packaging` | Desktop integration assets |

## License

Mpvson is released under the [MIT License](LICENSE).

Flutter, media_kit, libmpv, and their dependencies retain their upstream licenses. Include the relevant notices and source obligations when distributing a release built from these dependencies; see `packaging/windows/THIRD_PARTY.txt` and `packaging/windows/LICENSE.libmpv-GPL.txt`.
