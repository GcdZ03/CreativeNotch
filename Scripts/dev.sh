#!/usr/bin/env bash
# Development loop: stop, rebuild, sign, relaunch.
#
#   ./Scripts/dev.sh              debug build, relaunch
#   ./Scripts/dev.sh --release    release build
#   ./Scripts/dev.sh --fresh      also reset onboarding, so first-run UI replays
#   ./Scripts/dev.sh --logs       stream the app's log output after launching
#
# Most work does not need this at all — `swift test` runs the whole suite in
# about a second and needs no window server. Reach for this only when you
# need to see something on screen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=debug
FRESH=false
LOGS=false

for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --fresh)   FRESH=true ;;
    --logs)    LOGS=true ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

echo "==> stopping any running instance"
pkill -f 'CreativeNotch.app/Contents/MacOS/CreativeNotch' 2>/dev/null || true

if $FRESH; then
  echo "==> resetting onboarding state"
  defaults delete com.gcdz.creativenotch 2>/dev/null || true
fi

echo "==> building ($CONFIG)"
"$ROOT/Scripts/bundle.sh" "$CONFIG"

echo "==> launching"
open "$ROOT/dist/CreativeNotch.app"

if $LOGS; then
  echo "==> streaming logs (ctrl-c to stop)"
  log stream --predicate 'process == "CreativeNotch"' --level debug
else
  echo
  echo "running. quit with:  pkill -f CreativeNotch"
fi
