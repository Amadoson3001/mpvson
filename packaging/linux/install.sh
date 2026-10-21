#!/usr/bin/env bash
# ==============================================================================
# Mpvson Linux User-Space Installer
# Installs Mpvson for the current user without requiring root privileges.
# Targets:
#   - Binary symlink: ~/.local/bin/mpvson
#   - Desktop entry:  ~/.local/share/applications/mpvson.desktop
#   - Scalable icon:  ~/.local/share/icons/hicolor/scalable/apps/mpvson.svg
#   - App bundle:     ~/.local/opt/mpvson
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.local/share/applications"
ICON_DIR="${HOME}/.local/share/icons/hicolor/scalable/apps"
OPT_DIR="${HOME}/.local/opt/mpvson"

echo "==> Installing Mpvson for user: ${USER:-$(whoami)}"

# 1. Create target directories
mkdir -p "${BIN_DIR}"
mkdir -p "${APP_DIR}"
mkdir -p "${ICON_DIR}"

# 2. Locate or install application bundle / binary
BUNDLE_SRC=""
if [[ $# -ge 1 && -d "$1" && -f "$1/mpvson" ]]; then
  BUNDLE_SRC="$1"
elif [[ -f "${SCRIPT_DIR}/../../build/linux/x64/release/bundle/mpvson" ]]; then
  BUNDLE_SRC="${SCRIPT_DIR}/../../build/linux/x64/release/bundle"
elif [[ -f "${SCRIPT_DIR}/../bundle/mpvson" ]]; then
  BUNDLE_SRC="${SCRIPT_DIR}/../bundle"
elif [[ -f "${SCRIPT_DIR}/mpvson" ]]; then
  BUNDLE_SRC="${SCRIPT_DIR}"
elif [[ -f "${PWD}/mpvson" ]]; then
  BUNDLE_SRC="${PWD}"
fi

if [[ -n "${BUNDLE_SRC}" ]]; then
  echo "--> Deploying application bundle from ${BUNDLE_SRC} to ${OPT_DIR}..."
  mkdir -p "${OPT_DIR}"
  cp -r "${BUNDLE_SRC}/"* "${OPT_DIR}/"
  chmod +x "${OPT_DIR}/mpvson"
  ln -sf "${OPT_DIR}/mpvson" "${BIN_DIR}/mpvson"
  echo "    Installed binary: ${BIN_DIR}/mpvson -> ${OPT_DIR}/mpvson"
else
  # If bundle was not located yet, ensure symlink points to future opt location
  mkdir -p "${OPT_DIR}"
  ln -sf "${OPT_DIR}/mpvson" "${BIN_DIR}/mpvson"
  echo "    Configured binary symlink: ${BIN_DIR}/mpvson -> ${OPT_DIR}/mpvson"
  echo "    (Place your Mpvson bundle files in ${OPT_DIR})"
fi

# 3. Install desktop entries
echo "--> Installing desktop entries..."
if [[ -f "${SCRIPT_DIR}/mpvson.desktop" ]]; then
  cp "${SCRIPT_DIR}/mpvson.desktop" "${APP_DIR}/mpvson.desktop"
  chmod 644 "${APP_DIR}/mpvson.desktop"
  echo "    Installed ${APP_DIR}/mpvson.desktop"
fi

if [[ -f "${SCRIPT_DIR}/dev.mpvson.mpvson.desktop" ]]; then
  cp "${SCRIPT_DIR}/dev.mpvson.mpvson.desktop" "${APP_DIR}/dev.mpvson.mpvson.desktop"
  chmod 644 "${APP_DIR}/dev.mpvson.mpvson.desktop"
  echo "    Installed ${APP_DIR}/dev.mpvson.mpvson.desktop"
fi

# 4. Install scalable vector icons
echo "--> Installing application icons..."
if [[ -f "${SCRIPT_DIR}/mpvson.svg" ]]; then
  cp "${SCRIPT_DIR}/mpvson.svg" "${ICON_DIR}/mpvson.svg"
  chmod 644 "${ICON_DIR}/mpvson.svg"
  echo "    Installed ${ICON_DIR}/mpvson.svg"
fi

if [[ -f "${SCRIPT_DIR}/dev.mpvson.mpvson.svg" ]]; then
  cp "${SCRIPT_DIR}/dev.mpvson.mpvson.svg" "${ICON_DIR}/dev.mpvson.mpvson.svg"
  chmod 644 "${ICON_DIR}/dev.mpvson.mpvson.svg"
  echo "    Installed ${ICON_DIR}/dev.mpvson.mpvson.svg"
fi

# 5. Refresh FreeDesktop caches
echo "--> Updating desktop database and icon caches..."
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "${APP_DIR}" 2>/dev/null || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
fi

# 6. Verify PATH
echo ""
echo "==> Mpvson user installation complete!"
if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
  echo "NOTE: ${BIN_DIR} is not in your current PATH."
  echo "To run 'mpvson' directly from the terminal, add this to your shell profile (~/.bashrc or ~/.zshrc):"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
