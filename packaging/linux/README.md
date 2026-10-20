# Linux Desktop Integration

This directory contains the desktop entry and scalable application icon for Mpvson on Linux:

- `dev.mpvson.mpvson.desktop`: FreeDesktop-compliant desktop entry specifying application metadata, categories, MIME types, icon name, and execution command.
- `dev.mpvson.mpvson.svg`: Scalable vector icon used for application menus, docks, and task switchers.

## Installation

When installing the extracted Linux release bundle (`dist/mpvson-linux-x64.tar.gz`), you can optionally integrate Mpvson with your desktop environment.

### User Installation (Recommended)

1. **Install the executable to your user PATH**:
   Assuming the extracted bundle is located at `~/.local/opt/mpvson` (or any persistent location):

   ```bash
   mkdir -p ~/.local/bin
   ln -sf ~/.local/opt/mpvson/mpvson ~/.local/bin/mpvson
   ```

   Ensure `~/.local/bin` is in your `PATH` environment variable. Alternatively, you can edit `Exec=` in the `.desktop` file to provide the absolute path to the bundle's `mpvson` executable:
   ```ini
   Exec=/home/username/.local/opt/mpvson/mpvson %U
   ```

2. **Install the application icon**:
   ```bash
   mkdir -p ~/.local/share/icons/hicolor/scalable/apps
   cp packaging/linux/dev.mpvson.mpvson.svg ~/.local/share/icons/hicolor/scalable/apps/
   ```

3. **Install the desktop launcher**:
   ```bash
   mkdir -p ~/.local/share/applications
   cp packaging/linux/dev.mpvson.mpvson.desktop ~/.local/share/applications/
   ```

4. **Update the desktop and icon caches**:
   ```bash
   update-desktop-database ~/.local/share/applications/
   gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor 2>/dev/null || true
   ```

---

### System-Wide Installation (Optional)

For multi-user or system-wide installations:

1. Place the bundle in `/opt/mpvson/` and symlink the binary:
   ```bash
   sudo ln -sf /opt/mpvson/mpvson /usr/local/bin/mpvson
   ```

2. Install the icon and desktop file:
   ```bash
   sudo cp packaging/linux/dev.mpvson.mpvson.svg /usr/local/share/icons/hicolor/scalable/apps/
   sudo cp packaging/linux/dev.mpvson.mpvson.desktop /usr/local/share/applications/
   ```

3. Update the system database:
   ```bash
   sudo update-desktop-database /usr/local/share/applications/
   sudo gtk-update-icon-cache -f -t /usr/local/share/icons/hicolor 2>/dev/null || true
   ```
