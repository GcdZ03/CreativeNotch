#!/usr/bin/env bash
# Builds CreativeNotch.app and signs it.
#
# Signing is mandatory on Apple Silicon — an unsigned arm64 binary will not
# launch at all. Two identities are supported:
#
#   ad-hoc ("-", the default)  no device restrictions, runs on any Mac, but
#                              its designated requirement is the code hash,
#                              so macOS revokes TCC grants on every rebuild.
#
#   $CODESIGN_IDENTITY         a stable local identity (see setup-signing.sh).
#                              Accessibility survives rebuilds. Use for dev.
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
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# One version string, not two. Info.plist carries a placeholder and the
# real value comes from CoreInfo -- they used to be maintained by hand in
# both places, which is a drift waiting to happen. (Follow-up F9.)
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
  "$ROOT/Sources/CreativeNotchCore/Version.swift")
if [ -z "$VERSION" ]; then
  echo "could not read the version from Version.swift" >&2
  exit 1
fi
/usr/bin/sed -i '' "s/__VERSION__/$VERSION/" "$APP/Contents/Info.plist"
echo "version $VERSION"

IDENTITY="${CODESIGN_IDENTITY:--}"
codesign -s "$IDENTITY" --force --timestamp=none "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'

echo "built $APP"
