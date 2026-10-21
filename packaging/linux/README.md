# Linux Desktop Integration and Packaging

This directory contains the desktop entry, scalable vector application icons, and user-space installation scripts for Mpvson on Linux:

- `mpvson.desktop`: FreeDesktop-compliant desktop entry specifying application metadata, categories (`AudioVideo;Player;Video;Audio;`), all audio and video MIME types, icon name (`mpvson`), and execution command (`mpvson %U`).
- `dev.mpvson.mpvson.desktop`: Reverse-DNS named desktop entry matching the Application ID `dev.mpvson.mpvson`.
- `mpvson.svg` and `dev.mpvson.mpvson.svg`: Scalable vector icons for desktop application menus, docks, and task switchers.
- `install.sh`: Automated user-space installer (no `sudo` / root required). Installs binary to `~/.local/bin/mpvson`, desktop file to `~/.local/share/applications/`, and icon to `~/.local/share/icons/hicolor/scalable/apps/`.
- `uninstall.sh`: Clean user-space uninstaller.

## Automated User Installation (Recommended)

To install Mpvson for your user account:

```bash
# If running directly from extracted release bundle:
./packaging/linux/install.sh

# Or specify bundle folder explicitly:
./packaging/linux/install.sh /path/to/extracted/bundle
```

To remove Mpvson:

```bash
./packaging/linux/uninstall.sh
```

---

## Manual User Installation

1. **Install the executable to your user PATH**:
   Assuming the extracted bundle is located at `~/.local/opt/mpvson`:

   ```bash
   mkdir -p ~/.local/bin ~/.local/opt/mpvson
   cp -r <bundle>/* ~/.local/opt/mpvson/
   ln -sf ~/.local/opt/mpvson/mpvson ~/.local/bin/mpvson
   ```

2. **Install application icons**:
   ```bash
   mkdir -p ~/.local/share/icons/hicolor/scalable/apps
   cp packaging/linux/mpvson.svg ~/.local/share/icons/hicolor/scalable/apps/
   cp packaging/linux/dev.mpvson.mpvson.svg ~/.local/share/icons/hicolor/scalable/apps/
   ```

3. **Install the desktop launcher**:
   ```bash
   mkdir -p ~/.local/share/applications
   cp packaging/linux/mpvson.desktop ~/.local/share/applications/
   ```

4. **Update the desktop and icon caches**:
   ```bash
   update-desktop-database ~/.local/share/applications/
   gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor 2>/dev/null || true
   ```

---

## System-Wide Installation (Optional)

For multi-user or system-wide installations:

```bash
sudo mkdir -p /opt/mpvson
sudo cp -r <bundle>/* /opt/mpvson/
sudo ln -sf /opt/mpvson/mpvson /usr/local/bin/mpvson
sudo cp packaging/linux/mpvson.svg /usr/local/share/icons/hicolor/scalable/apps/
sudo cp packaging/linux/mpvson.desktop /usr/local/share/applications/
sudo update-desktop-database /usr/local/share/applications/
sudo gtk-update-icon-cache -f -t /usr/local/share/icons/hicolor 2>/dev/null || true
```
