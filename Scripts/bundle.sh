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

# Prefer the local dev identity whenever it exists, rather than defaulting
# to ad-hoc. Ad-hoc's designated requirement is the code hash, so every
# rebuild revokes Accessibility — and because that fallback was silent, a
# rebuild in a shell that happened not to export CODESIGN_IDENTITY dropped
# the grant with nothing on screen to say so. An explicit CODESIGN_IDENTITY
# still wins; ad-hoc is now only ever chosen out loud.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"CreativeNotch Dev"'; then
    IDENTITY="CreativeNotch Dev"
  else
    IDENTITY="-"
    echo "warning: signing ad-hoc — Accessibility will be revoked on every rebuild." >&2
    echo "         run Scripts/setup-signing.sh once to fix this permanently." >&2
  fi
fi
echo "signing identity: $IDENTITY"
codesign -s "$IDENTITY" --force --timestamp=none "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'

echo "built $APP"
