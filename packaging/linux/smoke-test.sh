#!/usr/bin/env bash
# Runs inside a fresh ubuntu:24.04 container on the CI Ubuntu runner.
# Verifies the packaged tarball: SHA256SUMS, shared-library resolution, and a
# real GUI startup with a media file under Xvfb.
# Mounts: /dist (release artifacts, ro), /packaging (this directory, ro),
# /out (writable log directory uploaded on failure).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  libgtk-3-0t64 libmpv2 libasound2t64 libpulse0 libepoxy0 liblzma5 \
  libgl1 libgl1-mesa-dri libegl1 libva2 libva-drm2 libva-x11-2 \
  libdrm2 libxkbcommon0 libvulkan1 libssl3t64 \
  gsettings-desktop-schemas fonts-dejavu-core \
  xvfb xdotool xauth

cd /dist
sha256sum -c SHA256SUMS

mkdir -p /opt/mpvson
tar -xzf mpvson-linux-x64.tar.gz -C /opt/mpvson

ldd /opt/mpvson/mpvson /opt/mpvson/lib/*.so* > /out/ldd.log 2>&1
cat /out/ldd.log
if grep 'not found' /out/ldd.log; then
  echo 'Unresolved shared libraries detected.' >&2
  exit 1
fi

Xvfb :99 -screen 0 1280x800x24 &
xvfb_pid=$!
sleep 2
export DISPLAY=:99

/opt/mpvson/mpvson /packaging/smoke-sample.mp4 > /out/startup.log 2>&1 &
app_pid=$!

window_found=0
for _ in $(seq 1 30); do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo 'mpvson exited during startup.' >&2
    cat /out/startup.log >&2
    exit 1
  fi
  if xdotool search --name 'Mpvson' > /dev/null 2>&1; then
    window_found=1
    break
  fi
  sleep 1
done

if [ "$window_found" -ne 1 ]; then
  echo 'Mpvson window never appeared under Xvfb.' >&2
  cat /out/startup.log >&2
  exit 1
fi

# The startup-failure fallback app shows a window with the same title but
# never loads the playback engine, so require libmpv in the process maps.
if ! grep -q 'libmpv' "/proc/$app_pid/maps"; then
  echo 'Window appeared but libmpv is not loaded: engine startup failed.' >&2
  cat /out/startup.log >&2
  exit 1
fi

sleep 5
if ! kill -0 "$app_pid" 2>/dev/null; then
  echo 'mpvson crashed after the window appeared.' >&2
  cat /out/startup.log >&2
  exit 1
fi

echo 'Smoke test passed: checksums OK, libraries resolved, window mapped, process alive.'
kill "$app_pid" 2>/dev/null || true
kill "$xvfb_pid" 2>/dev/null || true