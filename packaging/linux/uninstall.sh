#!/usr/bin/env bash
# ==============================================================================
# Mpvson Linux User-Space Uninstaller
# Removes user-installed Mpvson desktop entries, icons, and binary symlinks.
# ==============================================================================

set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.local/share/applications"
ICON_DIR="${HOME}/.local/share/icons/hicolor/scalable/apps"
OPT_DIR="${HOME}/.local/opt/mpvson"

echo "==> Uninstalling Mpvson for user: ${USER:-$(whoami)}"

# 1. Remove binary and wrapper symlinks
if [[ -L "${BIN_DIR}/mpvson" || -f "${BIN_DIR}/mpvson" ]]; then
  echo "--> Removing binary symlink: ${BIN_DIR}/mpvson"
  rm -f "${BIN_DIR}/mpvson"
fi

# 2. Remove desktop entries
for desktop_file in "${APP_DIR}/mpvson.desktop" "${APP_DIR}/dev.mpvson.mpvson.desktop"; do
  if [[ -f "${desktop_file}" ]]; then
    echo "--> Removing desktop entry: ${desktop_file}"
    rm -f "${desktop_file}"
  fi
done

# 3. Remove scalable icons
for icon_file in "${ICON_DIR}/mpvson.svg" "${ICON_DIR}/dev.mpvson.mpvson.svg"; do
  if [[ -f "${icon_file}" ]]; then
    echo "--> Removing icon: ${icon_file}"
    rm -f "${icon_file}"
  fi
done

# 4. Remove installed bundle directory if present
if [[ -d "${OPT_DIR}" ]]; then
  echo "--> Removing application directory: ${OPT_DIR}"
  rm -rf "${OPT_DIR}"
fi

# 5. Refresh FreeDesktop caches
echo "--> Updating desktop database and icon caches..."
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "${APP_DIR}" 2>/dev/null || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
fi

echo "==> Mpvson uninstallation complete."
