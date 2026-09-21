#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/docs/screenshot.png}"

resolve_app() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return
  fi

  local candidates=(
    "$ROOT/build/Release/Echo.app"
    "$ROOT/build/Debug/Echo.app"
  )
  local derived
  for derived in "$HOME/Library/Developer/Xcode/DerivedData"/Echo-*/Build/Products/Debug/Echo.app \
                 "$HOME/Library/Developer/Xcode/DerivedData"/Echo-*/Build/Products/Release/Echo.app; do
    candidates+=("$derived")
  done

  local newest="" newest_mtime=0 path mtime
  for path in "${candidates[@]}"; do
    [[ -d "$path" ]] || continue
    mtime="$(stat -f %m "$path")"
    if (( mtime >= newest_mtime )); then
      newest="$path"
      newest_mtime="$mtime"
    fi
  done

  if [[ -n "$newest" ]]; then
    printf '%s\n' "$newest"
    return
  fi

  echo "Echo.app not found. Build the Echo scheme in Xcode, then rerun:" >&2
  echo "  $0" >&2
  echo "  $0 /path/to/docs/screenshot.png /path/to/Echo.app" >&2
  exit 1
}

APP="$(resolve_app "${2:-}")"
BIN="$APP/Contents/MacOS/Echo"

if [[ ! -x "$BIN" ]]; then
  echo "Echo binary not found at $BIN" >&2
  exit 1
fi

echo "Using $APP"
mkdir -p "$(dirname "$OUTPUT")"

"$BIN" --screenshot --screenshot-output "$OUTPUT" &
pid=$!
SECONDS=0
while kill -0 "$pid" 2>/dev/null; do
  if (( SECONDS >= 10 )); then
    kill "$pid" 2>/dev/null || true
    echo "Timed out waiting for $OUTPUT" >&2
    exit 1
  fi
  sleep 0.2
done
wait "$pid"
status=$?
if (( status != 0 )); then
  exit "$status"
fi
if [[ ! -f "$OUTPUT" ]]; then
  echo "Screenshot was not written to $OUTPUT" >&2
  exit 1
fi
