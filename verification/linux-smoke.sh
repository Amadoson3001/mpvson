#!/usr/bin/env bash
set -euo pipefail

# Mpvson Linux Playback Smoke Test
# Runs the native application under xvfb and verifies reporting and visual capture.

MEDIA_PATH=""
EXECUTABLE_PATH="./build/linux/x64/release/bundle/mpvson"
OUTPUT_DIR="./test-output"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --media-path|-MediaPath|--media|-m)
      MEDIA_PATH="$2"
      shift 2
      ;;
    --executable-path|-ExecutablePath|--executable|-Executable|-e)
      EXECUTABLE_PATH="$2"
      shift 2
      ;;
    --output-directory|-OutputDirectory|--output|-o)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      if [ -z "$MEDIA_PATH" ]; then
        MEDIA_PATH="$1"
        shift
      elif [ "$EXECUTABLE_PATH" = "./build/linux/x64/release/bundle/mpvson" ]; then
        EXECUTABLE_PATH="$1"
        shift
      else
        OUTPUT_DIR="$1"
        shift
      fi
      ;;
  esac
done

if [ -z "$MEDIA_PATH" ]; then
  echo "Usage: $0 --media-path <path> [--executable-path <path>] [--output-directory <dir>]"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
SMOKE_REPORT="$OUTPUT_DIR/native-smoke.json"
SMOKE_SCREENSHOT="$OUTPUT_DIR/native-smoke.png"

rm -f "$SMOKE_REPORT" "$SMOKE_SCREENSHOT"

export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11

timeout 25s xvfb-run -a -s '-screen 0 1280x800x24' "$EXECUTABLE_PATH" \
  --smoke-test="$MEDIA_PATH" \
  --smoke-report="$SMOKE_REPORT" \
  --smoke-screenshot="$SMOKE_SCREENSHOT"

cat "$SMOKE_REPORT"
jq -e '.success == true and .visualCaptureSuccess == true' "$SMOKE_REPORT"
