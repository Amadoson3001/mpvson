# Mpvson

A modern desktop video and music player for Windows and Linux, powered by Flutter and `libmpv`.

## Features

- **Hardware-accelerated playback (`libmpv`)** with subtitle styling (`libass`), chapter markers, multi-track audio/subtitle switching, playback speed controls, seek-bar frame previews, and dynamic quality presets.
- **Media library & playlists** backed by an isolate-hosted SQLite database, pure-Dart container/tag probing (fast scans without booting `libmpv` per file), live folder watchers, favorites, and drag-and-drop playlists.
- **Desktop OS integration**:
  - Single-instance launch & Explorer/file-manager `--enqueue` support
  - Windows System Media Transport Controls (SMTC) & Linux MPRIS D-Bus integration
  - Power-saving / display keep-awake during active video playback and AC-power-aware GPU selection on Windows
- **Customizable projector-room UI**: dark, OLED black, and light themes, 6 accent presets plus dynamic artwork accent extraction, WCAG AA contrast adaptation, calm/reduced-motion mode, remappable shortcuts, and an in-app docking mini-player.
- **Verified updates & engine recovery**: HTTPS release checks, SHA-256 verified downloads, and on Windows a staged `libmpv` updater with automatic fallback/recovery to the bundled `v0.42.0` engine.

## Requirements

- **Windows**: Windows 10 (version 1809 or later) or Windows 11 (64-bit). Release packages bundle the required MSVC C++ runtime DLLs and a pinned `libmpv-2.dll` (`v0.42.0`).
- **Linux**: 64-bit Linux with GTK 3 and `libmpv` installed (`libmpv2` on Debian/Ubuntu, `mpv-libs` on Fedora, `mpv` on Arch).

## Installation

### Windows
- **Installer**: Run `MpvsonSetup.exe` (per-user, no administrator elevation required) to install and register supported audio/video file associations.
- **Portable**: Extract `mpvson-windows-x64.zip` and run `mpvson.exe` (keep all DLLs and `data/` beside it). Optional portable file associations are in `packaging/windows/register_portable.bat`.
- **Verification**: Release binaries are currently unsigned (Windows SmartScreen may prompt on first launch). Verify downloads against `SHA256SUMS` before running:
  ```powershell
  Get-FileHash mpvson-windows-x64.zip -Algorithm SHA256
  Get-FileHash MpvsonSetup.exe -Algorithm SHA256
  ```

### Linux
Extract `mpvson-linux-x64.tar.gz` and run the user-space installer:
```bash
./install.sh
```
To uninstall later, run `./uninstall.sh` (or `~/.local/opt/mpvson/uninstall.sh`).

## Default Shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / Pause (hold for 2x speed) |
| `←` / `→` | Seek backward / forward |
| `↑` / `↓` | Volume up / down |
| `M` | Mute / Unmute |
| `F` / `F11` | Toggle fullscreen |
| `P` | Show / Hide queue |
| `I` | Playback information |
| `Shift + I` | Mini player |
| `Ctrl + L` | Open URL |
| `Z` / `Shift + Z` | Subtitles earlier / later |
| `[` / `]` | Audio earlier / later |

All player shortcuts can be customized in **Settings → Shortcuts**.

## Building from Source

Prerequisites: Flutter SDK (`>= 3.50.0` / Dart `^3.12.0`), Visual Studio 2022 C++ toolchain on Windows (or `clang`, `cmake`, `ninja-build`, `libgtk-3-dev`, `libmpv-dev`, `libasound2-dev`, `libepoxy-dev`, `liblzma-dev` on Linux).

```bash
flutter pub get

# Windows: configure plugin junctions, verify engine cache, and bundle VC++ runtime
dart run tool/setup_windows_build.dart

# Verify formatting, version sync, static analysis, and tests
dart format --output=none --set-exit-if-changed lib tool test
dart run tool/version.dart check
flutter analyze --no-fatal-infos
flutter test

# Build release
flutter build windows --release --tree-shake-icons --target=lib/main.dart
dart run tool/engine_provenance.dart verify
```

## Versioning

`pubspec.yaml` (`version: X.Y.Z+N`) is the single source of truth for the application version, and `packaging/windows/engine-provenance.json` pins the bundled `libmpv` version.

```bash
dart run tool/version.dart show              # Show app and engine versions
dart run tool/version.dart check             # Verify all files match pubspec.yaml
dart run tool/version.dart sync              # Sync runtime constants & packaging files
dart run tool/version.dart bump patch        # Bump patch version (+build) and sync
dart run tool/version.dart set 0.2.0+1       # Set an explicit version and sync
```

## License

Mpvson's own source code is licensed under the [MIT License](LICENSE).

Compiled Windows release distributions bundle `libmpv-2.dll` (built with GPLv3-enabled FFmpeg) and are distributed under **GPL-3.0-or-later** terms. See [packaging/windows/THIRD_PARTY.txt](packaging/windows/THIRD_PARTY.txt) and [packaging/windows/LICENSE.libmpv-GPL.txt](packaging/windows/LICENSE.libmpv-GPL.txt) for component notices and corresponding source information.
