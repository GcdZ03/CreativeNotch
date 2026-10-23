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
# Overriding this disables the "Open at login" switch. That toggle refuses to
# touch the system's login-item record unless the app is directly inside
# /Applications or ~/Applications -- because reading the record repoints it at
# whichever copy read it, and a copy somewhere unexpected can steal it from the
# installed one. See LaunchAtLoginEligibility.
DEST="${INSTALL_DIR:-/Applications}"
API="https://api.github.com/repos/$REPO/releases/latest"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || die "CreativeNotch is macOS only."

MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 26 ]; then
  die "requires macOS 26 or later (found $(sw_vers -productVersion))."
fi

# The published .tar.gz is a single-architecture arm64 build -- the release
# workflow runs on macos-latest and passes no --arch. Without this check an
# Intel Mac on macOS 26 passes every test above, reports a successful install,
# and then fails at launch with nothing to explain why. Refuse here instead,
# where there is somewhere to put the reason.
#
# `uname -m` is the wrong probe: a Terminal opened under Rosetta reports
# x86_64 on an Apple Silicon Mac, which would turn away a machine that is
# perfectly capable. `hw.optional.arm64` describes the hardware rather than
# the calling process, so it survives translation. It is absent, not 0, on
# Intel.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]; then
  die "requires an Apple Silicon Mac. The published build is arm64 only.
  You can still build from source on Intel:
    git clone https://github.com/$REPO && cd CreativeNotch
    ./Scripts/bundle.sh release && cp -R dist/$APP_NAME /Applications/"
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

TARGET="$DEST/$APP_NAME"

# Only the copy being replaced. A bare "$APP_NAME/Contents/MacOS/..." pattern
# also matches a dev build running out of dist/, which this installer has no
# business stopping. pgrep takes an extended regex, so the path's dots (and
# anything else special in a custom INSTALL_DIR) are escaped, and the pattern
# is anchored to the start of the command line.
RUNNING="^$(printf '%s' "$TARGET/Contents/MacOS/CreativeNotch" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
if pgrep -f "$RUNNING" >/dev/null 2>&1; then
  info "stopping the running copy"
  pkill -f "$RUNNING" || true
  sleep 1
fi

# Every filesystem step below goes through `run`, which adds sudo only when
# $DEST is not writable -- so a removal never lacks the permission the move
# beside it had.
SUDO=""
run() { if [ -n "$SUDO" ]; then sudo "$@"; else "$@"; fi; }
if [ ! -w "$DEST" ]; then
  info "$DEST needs elevated permission"
  SUDO=1
fi

# The old copy is moved aside, not deleted, until the new one is in place. A
# declined or failed sudo, or a move that dies halfway, then puts it back
# rather than leaving the machine with no CreativeNotch at all. The aside
# copy sits in $DEST itself so both renames stay on one filesystem.
info "installing to $DEST"
BACKUP=""
if [ -e "$TARGET" ]; then
  BACKUP="$DEST/.$APP_NAME.previous.$$"
  run mv "$TARGET" "$BACKUP" || die "could not install to $DEST; the existing copy is untouched."
fi

if ! run mv "$TMP/$APP_NAME" "$TARGET"; then
  if [ -n "$BACKUP" ]; then
    # A cross-filesystem mv copies, so a failure can leave a partial bundle
    # at $TARGET; mv'ing the backup onto it would nest it inside instead.
    run rm -rf "$TARGET" 2>/dev/null || true
    run mv "$BACKUP" "$TARGET" \
      || die "could not install to $DEST, and the previous copy could not be restored. It is at $BACKUP."
    die "could not install to $DEST; the previous copy is back in place."
  fi
  die "could not install to $DEST."
fi

if [ -n "$BACKUP" ]; then
  run rm -rf "$BACKUP" || info "could not remove the previous copy at $BACKUP"
fi

xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

cat <<DONE

  CreativeNotch $TAG installed to $DEST

  Launch it:   open "$DEST/$APP_NAME"
  Quit it:     pkill -f CreativeNotch
  Update it:   re-run this installer

  It has no Dock icon — look for it in the notch and the menu bar.

DONE
