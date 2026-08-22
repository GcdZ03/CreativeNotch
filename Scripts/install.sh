#!/usr/bin/env bash
#
#   curl -fsSL https://raw.githubusercontent.com/GcdZ03/CreativeNotch/main/Scripts/install.sh | bash
#
# Installs or updates CreativeNotch in /Applications.
#
# Downloading with curl rather than a browser matters: browsers set the
# com.apple.quarantine attribute, and this app is ad-hoc signed rather than
# notarised, so a quarantined copy would be refused by Gatekeeper. Fetched
# this way, it just runs.
set -euo pipefail

REPO="GcdZ03/CreativeNotch"
APP_NAME="CreativeNotch.app"
DEST="${INSTALL_DIR:-/Applications}"
API="https://api.github.com/repos/$REPO/releases/latest"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || die "CreativeNotch is macOS only."

MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 26 ]; then
  die "requires macOS 26 or later (found $(sw_vers -productVersion))."
fi

info "looking up the latest release"
JSON=$(curl -fsSL "$API") || die "could not reach GitHub. Is the repo public and has a release been published?"

TAG=$(printf '%s' "$JSON" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
URL=$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*\.tar\.gz"' | head -1 | cut -d'"' -f4)

[ -n "$TAG" ] || die "no release found."
[ -n "$URL" ] || die "release $TAG has no .tar.gz asset attached."

if [ -d "$DEST/$APP_NAME" ]; then
  CURRENT=$(defaults read "$DEST/$APP_NAME/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
  if [ "v$CURRENT" = "$TAG" ] || [ "$CURRENT" = "$TAG" ]; then
    info "already on $TAG — nothing to do."
    exit 0
  fi
  info "updating $CURRENT -> $TAG"
else
  info "installing $TAG"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

info "downloading"
curl -fsSL "$URL" -o "$TMP/app.tar.gz" || die "download failed."

info "extracting"
tar -xzf "$TMP/app.tar.gz" -C "$TMP" || die "archive could not be extracted."
[ -d "$TMP/$APP_NAME" ] || die "archive did not contain $APP_NAME."

if ! codesign --verify --deep --strict "$TMP/$APP_NAME" 2>/dev/null; then
  die "signature verification failed — refusing to install."
fi

if pgrep -f "$APP_NAME/Contents/MacOS/CreativeNotch" >/dev/null 2>&1; then
  info "stopping the running copy"
  pkill -f "$APP_NAME/Contents/MacOS/CreativeNotch" || true
  sleep 1
fi

info "installing to $DEST"
rm -rf "$DEST/$APP_NAME"
if ! mv "$TMP/$APP_NAME" "$DEST/$APP_NAME" 2>/dev/null; then
  info "$DEST needs elevated permission"
  sudo mv "$TMP/$APP_NAME" "$DEST/$APP_NAME" || die "could not install to $DEST."
fi

xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

cat <<DONE

  CreativeNotch $TAG installed to $DEST

  Launch it:   open "$DEST/$APP_NAME"
  Quit it:     pkill -f CreativeNotch
  Update it:   re-run this installer

  It has no Dock icon — look for it in the notch and the menu bar.

DONE
