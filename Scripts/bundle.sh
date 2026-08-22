#!/usr/bin/env bash
# Builds CreativeNotch.app and ad-hoc signs it.
#
# Ad-hoc signing is mandatory on Apple Silicon — an unsigned arm64 binary
# will not launch at all — and unlike a development certificate it carries
# no device restrictions, so the same bundle runs on any Mac.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/CreativeNotch.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CreativeNotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CreativeNotch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign -s - --force --timestamp=none "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'

echo "built $APP"
