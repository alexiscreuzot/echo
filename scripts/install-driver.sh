#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Library/Audio/Plug-Ins/HAL/Echo.driver"

resolve_driver() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return
  fi

  local candidates=(
    "$ROOT/build/Release/Echo.driver"
    "$ROOT/build/Debug/Echo.driver"
  )
  local derived
  derived="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Echo.driver/Contents/MacOS/Echo" -print 2>/dev/null | head -n 1 || true)"
  if [[ -n "$derived" ]]; then
    candidates+=("$(dirname "$(dirname "$(dirname "$derived")")")")
  fi

  local path
  for path in "${candidates[@]}"; do
    if [[ -d "$path" ]]; then
      printf '%s\n' "$path"
      return
    fi
  done

  echo "Echo.driver not found. Build the EchoDriver target, then rerun:" >&2
  echo "  $0 /path/to/Echo.driver" >&2
  exit 1
}

DRIVER="$(resolve_driver "${1:-}")"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "Signing $DRIVER with $CODESIGN_IDENTITY"
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp --options runtime "$DRIVER"
fi

echo "Installing $DRIVER → $DEST"
sudo rm -rf "$DEST"
sudo cp -R "$DRIVER" "$DEST"
sudo chown -R root:wheel "$DEST"

echo "Restarting coreaudiod"
sudo killall coreaudiod

echo "Done. Echo should appear in Audio MIDI Setup."
