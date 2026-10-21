# Desktop Integration Architecture and Packaging Guide

Mpvson is designed as a first-class desktop citizen for both Windows and Linux. It bridges Flutter's rendering pipeline and mpv's playback core with native operating system APIs for single-instance activation, hardware media controls, power management, file associations, and desktop packaging.

---

## Architecture Summary

```
                           ┌───────────────────────────────┐
                           │      Desktop Application      │
                           │     (Mpvson Flutter Core)     │
                           └───────┬───────────────┬───────┘
                                   │               │
            ┌──────────────────────▼──────┐ ┌──────▼─────────────────────┐
            │       Windows Platform       │ │       Linux Platform       │
            └──────────────┬──────────────┘ └──────────────┬─────────────┘
                           │                               │
         ┌─────────────────┼─────────────────┐ ┌───────────┼───────────┐
         │                 │                 │ │           │           │
         ▼                 ▼                 ▼ ▼           ▼           ▼
   Named Pipe IPC         SMTC        Power Requests GApplication    MPRIS   Power Inhibit
(Single Instance)  (Media Controls)   (Display Awake) (Single Inst) (D-Bus)     (Portal)
```

---

## 1. Windows Desktop Integration

### Single-Instance Named Pipe

To ensure that opening files from Windows Explorer does not launch redundant application instances, Mpvson implements a Win32 named pipe IPC mechanism:

- **Primary Instance**: On startup, Mpvson attempts to create a unique named pipe server (e.g. `\\.\pipe\mpvson-single-instance-<UserHash>`) accompanied by a named mutex (`Global\Mpvson-SingleInstance-Mutex`).
- **Secondary Instances**: If the mutex or pipe already exists, the secondary instance connects to the pipe, transmits its serialized command-line arguments and file paths via JSON, and instructs the primary instance to bring its window to the foreground:
  ```cpp
  // Secondary instance activation
  HANDLE pipe = CreateFileW(pipeName, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
  if (pipe != INVALID_HANDLE_VALUE) {
    DWORD written;
    WriteFile(pipe, payload.data(), payload.size(), &written, NULL);
    CloseHandle(pipe);
    return 0; // Exit cleanly
  }
  ```
- **Window Activation**: Upon receiving an activation request over the pipe, the primary instance calls Win32 `ShowWindow(hwnd, SW_RESTORE)` and `SetForegroundWindow(hwnd)` to restore focus, and forwards the parsed paths to [`OpenRequestCoordinator`](file:///E:/mpvson/lib/data/services/open_request_coordinator.dart).

### System Media Transport Controls (SMTC)

Mpvson integrates with Windows System Media Transport Controls (`Windows.Media.SystemMediaTransportControls`) through WinRT interop:

- **Window Association**: The native runner attaches to the top-level window handle using `ISystemMediaTransportControlsInterop::GetForWindow(hwnd)`.
- **Hardware Media Keys & Lock Screen**: Automatically synchronizes with OS media keys (Play/Pause, Next, Previous, Stop, Seek) and taskbar volume flyouts.
- **Display Updater**: The `SystemMediaTransportControlsDisplayUpdater` receives active metadata updates:
  - Video/Music type detection.
  - Track title, artist, and album name.
  - Thumbnail artwork streams generated from local cache files.
- **Timeline Synchronization**: Publishes `MediaPlaybackStatus` (Playing, Paused, Stopped) and position bounds for the Windows timeline scrubber.

### Power Requests (Display Sleep Prevention)

To prevent screen savers or monitor sleep during playback without altering system-wide energy plans:

- **Win32 Power API**: Uses `PowerCreateRequest`, `PowerSetRequest`, and `PowerClearRequest` with:
  - `PowerRequestDisplayRequired`: Keeps the monitor illuminated during video playback.
  - `PowerRequestExecutionRequired`: Keeps the CPU running to prevent standby.
- **Smart Activation**:
  - Asserted **only** when video is actively playing and the user preference `keepAwakeDuringPlayback` is enabled.
  - Immediately released when playback is paused, stopped, buffering has stalled, or when playing **audio-only** media (allowing display panels to turn off to conserve energy).

### Windows Packaging: Inno Setup Installer vs Portable ZIP

Mpvson distributes two official Windows packaging formats:

| Feature | Portable ZIP (`mpvson-windows-x64.zip`) | Inno Setup Installer (`MpvsonSetup.exe`) |
| :--- | :--- | :--- |
| **Target Audience** | Flash drives, portable setups, restricted environments | Everyday desktop users, full shell integration |
| **Installation** | No install; unzip and run `mpvson.exe` | Guided Setup Wizard via `packaging/windows/installer.iss` |
| **Permissions** | Zero elevation required (standard user) | Non-elevated (`PrivilegesRequired=lowest` to `%LOCALAPPDATA%`) |
| **File Associations** | Manual ("Open with" browse) | Automatic registry integration for all media types |
| **Start Menu / Desktop** | None | Automatic Start Menu shortcut and optional Desktop icon |
| **Updates** | In-app engine updates; manual app replace | In-app engine updates; integrated uninstaller |
| **Registry Footprint** | None | HKCU only (`Software\Classes`, `RegisteredApplications`) |

#### Building the Inno Setup Installer

Compile the Inno Setup script after building the Windows release bundle:

```powershell
# 1. Build release bundle
flutter build windows --release

# 2. Compile installer using Inno Setup 6 (ISCC.exe)
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" packaging\windows\installer.iss
# Output is generated at build\windows\installer\MpvsonSetup.exe
```

#### Portable Registry Helpers

Users of the portable ZIP release can register or unregister shell file associations, ProgIDs, and Default Programs capabilities on demand using the included batch scripts or the Dart association tool:

```cmd
:: Register associations for the current user (in HKCU)
packaging\windows\register_portable.bat

:: Remove portable associations
packaging\windows\unregister_portable.bat
```

Alternatively, invoke the CLI tool directly:

```powershell
dart run tool/windows_associations.dart register
dart run tool/windows_associations.dart unregister
dart run tool/windows_associations.dart status
```

### Windows Explorer File Associations

The Inno Setup script (`packaging/windows/installer.iss`) configures non-elevated user-level associations in `HKCU`:

- **ProgID**: Registers `Mpvson.AssocFile` under `HKCU\Software\Classes\Mpvson.AssocFile`.
- **Shell Verbs**:
  - `open`: `&Play with Mpvson` executes `"{app}\mpvson.exe" "%1"`.
  - `enqueue`: `Add to &queue` executes `"{app}\mpvson.exe" --enqueue "%1"`.
- **Default Programs Registration**: Registers `HKCU\Software\RegisteredApplications\Mpvson` pointing to capabilities with complete `FileAssociations` and `MIMEAssociations` from [`MediaCatalog`](file:///E:/mpvson/lib/domain/models/media_catalog.dart).
- **Settings Shortcut**: Settings > Desktop integration includes a one-click button launching `ms-settings:defaultapps` to configure Mpvson as the default player.

---

## 2. Linux Desktop Integration

### GApplication Single Instance

On Linux, Mpvson utilizes GTK's `GtkApplication` / `GApplication` architecture:

- **Application ID**: Registered under `dev.mpvson.mpvson` with the `G_APPLICATION_HANDLES_OPEN` flag.
- **D-Bus Activation**: The primary instance acquires `dev.mpvson.mpvson` on the session bus. When a user launches a second instance (e.g. via file manager double-click), the secondary process routes file paths to the primary instance's `open` D-Bus signal and terminates.
- **Window Presentation**: The primary instance raises its GTK window via `gtk_window_present()` and processes the files through [`OpenRequestCoordinator`](file:///E:/mpvson/lib/data/services/open_request_coordinator.dart).

### MPRIS D-Bus Player Interface

Mpvson implements the FreeDesktop MPRIS 2.2 specification (`org.mpris.MediaPlayer2` and `org.mpris.MediaPlayer2.Player`):

- **Bus Registration**: Claims `org.mpris.MediaPlayer2.mpvson` on the user session bus.
- **Properties Exported**:
  - `PlaybackStatus`: `"Playing"`, `"Paused"`, or `"Stopped"`.
  - `LoopStatus`: `"None"`, `"Track"`, or `"Playlist"`.
  - `Rate`: Float playback rate multiplier.
  - `Shuffle`: Boolean shuffle state.
  - `Volume`: Linear volume scale `0.0` to `1.0`.
  - `Position`: 64-bit microsecond timeline position.
  - `Metadata`: Dictionary containing `xesam:title`, `xesam:artist`, `xesam:album`, `mpris:length`, `mpris:artUrl`, and `mpris:trackid`.
- **Methods Handled**: `Play`, `Pause`, `PlayPause`, `Stop`, `Next`, `Previous`, `Seek(offset)`, `SetPosition(trackId, pos)`, `OpenUri(uri)`.
- **Ecosystem Integration**: Seamlessly controllable via GNOME Shell top-bar media controls, KDE Plasma media controller plasmoids, lock screens, and CLI utilities like `playerctl`:
  ```sh
  playerctl --player=mpvson play-pause
  playerctl --player=mpvson metadata
  ```

### Power Inhibition Portal

To prevent display blanking and system sleep during video playback:

- **FreeDesktop ScreenSaver & Portal**: Calls `org.freedesktop.portal.Inhibit` (or fallback `org.freedesktop.ScreenSaver` `Inhibit`) requesting idle suspension with reason `"Playing video"`.
- **Release Semantics**: When video is paused, finished, stopped, or if an audio-only track is playing, the inhibition cookie is immediately released via `UnInhibit`. Respects the `keepAwakeDuringPlayback` setting.

### Desktop Entry & User Installer Scripts

The Linux release package (`dist/mpvson-linux-x64.tar.gz`) includes desktop integration assets located in `packaging/linux/`:

- **Desktop File** (`packaging/linux/dev.mpvson.mpvson.desktop` and `packaging/linux/mpvson.desktop`):
  ```ini
  [Desktop Entry]
  Version=1.0
  Type=Application
  Name=Mpvson
  GenericName=Video Player
  Comment=Play videos with a modern desktop interface and the mpv engine
  Exec=mpvson %U
  Icon=dev.mpvson.mpvson
  Terminal=false
  Categories=AudioVideo;Player;Video;Audio;
  MimeType=video/mp4;video/x-matroska;video/webm;video/quicktime;video/x-msvideo;video/mpeg;audio/mpeg;audio/flac;audio/ogg;
  StartupWMClass=dev.mpvson.mpvson
  ```
- **Scalable Icon** (`packaging/linux/dev.mpvson.mpvson.svg` and `packaging/linux/mpvson.svg`): Modern scalable SVG icons installed into `hicolor/scalable/apps`.
- **Automated User Installer** (`packaging/linux/install.sh`):
  Installs Mpvson cleanly for the current user without requiring `sudo` or root privileges:
  ```bash
  chmod +x packaging/linux/install.sh
  ./packaging/linux/install.sh /path/to/extracted/mpvson-bundle
  ```
  The script deploys the application bundle to `~/.local/opt/mpvson`, symlinks the executable into `~/.local/bin/mpvson`, copies icons to `~/.local/share/icons/hicolor/scalable/apps/`, installs the launcher into `~/.local/share/applications/`, and updates the desktop database and icon caches.
- **Automated User Uninstaller** (`packaging/linux/uninstall.sh`):
  Reverses all symlinks, launchers, and files cleanly:
  ```bash
  chmod +x packaging/linux/uninstall.sh
  ./packaging/linux/uninstall.sh
  ```

---

## 3. Opening Behavior Preferences and Settings

### Model & Preferences

Desktop preferences are managed by [`AppPreferencesRepository`](file:///E:/mpvson/lib/data/repositories/app_preferences_repository.dart) and persisted to `app_preferences.json` in the application support directory:

```dart
enum OpenBehaviorPreference {
  keepPlayingAndEnqueue,
  playNewFilesNow,
  askEveryTime,
}
```

- **`keepPlayingAndEnqueue`**: The active video or audio continues playing without interruption; newly opened files are appended to the queue.
- **`playNewFilesNow`**: The current playback stops immediately, the queue is replaced (or prepended), and the newly opened files begin playback right away.
- **`askEveryTime`**: Whenever new media is opened while playback is running or paused, the application displays [`OpenPreferenceDialog`](file:///E:/mpvson/lib/ui/player/views/open_preference_dialog.dart).
- **Default (Unset `null`)**: On the very first conflict, Mpvson prompts the user with the two primary choices and automatically saves their selection, explaining that it can be modified anytime in Settings.

### Request Coordination Flow

The [`OpenRequestCoordinator`](file:///E:/mpvson/lib/data/services/open_request_coordinator.dart) mediates all open operations:

```
[Incoming OpenRequest] (OS file association, CLI args, Drag & Drop, File Picker)
         │
         ▼
[Validate Sources] ── Filter nonexistent files & unsupported extensions
         │
         ▼
[Is Playback Active?]
   ├── NO  ──► Execute Playback (Play Immediately)
   └── YES ──► Check Intent
                 ├── OpenIntent.playNow  ──► Play immediately
                 ├── OpenIntent.enqueue  ──► Add to queue without interrupting
                 └── OpenIntent.normal   ──► Resolve OpenBehaviorPreference
                                               ├── playNewFilesNow ──► Play immediately
                                               ├── keepPlayingAndEnqueue ──► Add to queue
                                               └── askEveryTime / null ──► Show Dialog
```

### Settings UI

Under **Settings > Desktop integration**:
- **Opening files**: Toggle between "Keep playing and add to queue", "Play new files now", and "Ask every time".
- **Keep display awake during playback**: Checkbox enabling or disabling Win32 display power requests and Linux screensaver inhibition.
- **Default application**: Shortcut button to open the system's default apps configuration page.
