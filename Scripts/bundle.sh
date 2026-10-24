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
#                              TCC grants survive rebuilds. Use for dev.
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

# The media bridge goes in Frameworks/, not Resources/. codesign seals
# Frameworks/ as nested *code*; a dylib in Resources/ is sealed as an
# opaque resource, and loading it later breaks signature validation.
# Nothing links it -- the perl helper dlopens it at runtime.
mkdir -p "$APP/Contents/Frameworks"
cp "$(swift build -c "$CONFIG" --show-bin-path)/libCreativeNotchMediaBridge.dylib" \
   "$APP/Contents/Frameworks/libCreativeNotchMediaBridge.dylib"
cp "$ROOT/Resources/media-helper.pl" "$APP/Contents/Resources/media-helper.pl"

# Every user-facing string: Core's resource bundle, which the
# StringCatalogCompiler plugin filled with the compiled .lproj tables. In
# Resources/, not beside Contents/ where SwiftPM's own accessor would look --
# anything at the bundle root breaks the signature, which is why
# `Bundle.creativeNotch` looks here first.
STRINGS_BUNDLE="$(swift build -c "$CONFIG" --show-bin-path)/CreativeNotch_CreativeNotchCore.bundle"
if [ ! -f "$STRINGS_BUNDLE/en.lproj/Localizable.strings" ]; then
  echo "the string catalog was not compiled into $STRINGS_BUNDLE" >&2
  exit 1
fi
cp -R "$STRINGS_BUNDLE" "$APP/Contents/Resources/"
# The permission prompt is read by macOS from the app's own .lproj folders,
# not from Core's bundle, so its catalog is compiled straight into them.
xcrun xcstringstool compile "$ROOT/Resources/InfoPlist.xcstrings" \
  --output-directory "$APP/Contents/Resources" >/dev/null
# macOS chooses the nested bundle's language from the languages the *main*
# bundle has .lproj folders for. A language only in Localizable.xcstrings
# would ship and never be used, so refuse to build it.
for LPROJ in "$APP/Contents/Resources/CreativeNotch_CreativeNotchCore.bundle"/*.lproj; do
  if [ ! -d "$APP/Contents/Resources/$(basename "$LPROJ")" ]; then
    echo "$(basename "$LPROJ" .lproj) is in Localizable.xcstrings but not Resources/InfoPlist.xcstrings;" >&2
    echo "macOS would never choose it. Add it there too (CONTRIBUTING.md)." >&2
    exit 1
  fi
done

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
# rebuild revokes every TCC grant — and because that fallback was silent, a
# rebuild in a shell that happened not to export CODESIGN_IDENTITY dropped
# the grant with nothing on screen to say so. An explicit CODESIGN_IDENTITY
# still wins; ad-hoc is now only ever chosen out loud.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"CreativeNotch Dev"'; then
    IDENTITY="CreativeNotch Dev"
  else
    IDENTITY="-"
    echo "warning: signing ad-hoc — TCC grants will be revoked on every rebuild." >&2
    echo "         run Scripts/setup-signing.sh once to fix this permanently." >&2
  fi
fi
echo "signing identity: $IDENTITY"

# Inside out: nested code must be signed BEFORE the bundle containing it,
# or the outer signature seals unsigned code and --deep --strict fails.
codesign -s "$IDENTITY" --force --timestamp=none \
  "$APP/Contents/Frameworks/libCreativeNotchMediaBridge.dylib"
codesign -s "$IDENTITY" --force --timestamp=none "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'

echo "built $APP"
