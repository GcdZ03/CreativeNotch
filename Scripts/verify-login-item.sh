#!/usr/bin/env bash
# Does macOS actually START this app at login?
#
#   ./Scripts/verify-login-item.sh arm     before you log out
#   ./Scripts/verify-login-item.sh check   after you log back in
#   ./Scripts/verify-login-item.sh reset   throw the saved state away
#
# This is the one check in the project that needs a human, and the reason is
# worth stating: every measurement behind the launch-at-login module is about
# the *record*, never about a launch. `SMAppService` reporting `enabled` is
# not evidence — a Background Task Management record survives deleting the
# app entirely, so the status can read enabled over nothing at all. Only a
# real logout, a real login, and a process that is running before you have
# touched anything proves the feature works.
#
# See docs/research/2026-09-19-launch-at-login-probe.md.
#
# It never launches the app, never registers anything, and never calls
# SMAppService: doing any of those would be the thing under test doing itself
# a favour. You flip the switch; this only looks.
set -euo pipefail

APP="/Applications/CreativeNotch.app"
BUNDLE_ID="com.gcdz.creativenotch"
STATE="$HOME/.creativenotch-login-check"

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
amber() { printf '\033[33m%s\033[0m\n' "$1"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$1"; }
die()   { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# The system's record for this bundle identifier, or empty when there is
# none. One record exists per bundle id; its URL follows whichever copy last
# read its status, which is exactly why the app refuses to read from anywhere
# but an install directory.
#
# `|| true` is load-bearing: grep exits 1 when there is no record, and under
# `pipefail` that killed the whole script before it could report the very
# absence it was looking for. "No record" is an answer here, not an error.
btm_record() {
  sfltool dumpbtm 2>/dev/null \
    | grep -B9 "^ *Bundle Identifier: ${BUNDLE_ID}\$" || true
}

# One field out of a record already fetched, so `sfltool` runs once per mode.
btm_field() {
  printf '%s\n' "$1" | sed -n "s/^ *$2: *//p" | tail -1
}

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

cmd_arm() {
  [ -d "$APP" ] || die "no copy at $APP. Build one from this branch and install it:
    CODESIGN_IDENTITY=- ./Scripts/bundle.sh release
    cp -R dist/CreativeNotch.app /Applications/
  The released installer will not do: it fetches the latest release, which
  predates this module."

  local record signature cdhash quarantine disposition url running_pid
  record=$(btm_record)
  signature=$(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p' || true)
  cdhash=$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p' || true)
  quarantine=$(xattr -p com.apple.quarantine "$APP" 2>/dev/null || echo "none")
  disposition=$(btm_field "$record" Disposition)
  url=$(btm_field "$record" URL)
  running_pid=$(pgrep -f "$APP/Contents/MacOS/CreativeNotch" | head -1 || true)

  info "installed at  $APP"
  info "signature     ${signature:-unknown}"
  info "cdhash        ${cdhash:-unknown}"
  info "quarantine    $quarantine"
  info "btm record    ${disposition:-<none>}"
  info "btm url       ${url:-<none>}"

  if [ "${signature:-}" != "adhoc" ]; then
    amber "This copy is not ad-hoc signed. Releases are, and whether macOS will
       launch an ad-hoc, non-notarised app at login is the open question --
       so a pass here would not answer it. Rebuild with CODESIGN_IDENTITY=-."
  fi

  [ "$quarantine" = "none" ] || amber "This copy is quarantined, which is its own reason not to launch.
       Clear it: xattr -dr com.apple.quarantine $APP"

  # "[enabled, ...]" or "[disabled, ...]". Anchored on the bracket, because
  # "disabled" contains "enabled" and a substring match reads a disabled
  # record as an enabled one -- which would arm a test that cannot pass.
  case "$disposition" in
    "[enabled"*)
      case "$url" in
        *"/Applications/CreativeNotch.app"*) : ;;
        *) die "the record points at ${url:-nothing}, not at $APP.
  Another copy took it. Open Settings in the installed copy and toggle
  Open at login off and on again." ;;
      esac
      ;;
    *)
      die "no enabled record for $BUNDLE_ID.
  Open $APP, open Settings from the menu bar icon, and switch
  \"Open at login\" on. Use the switch rather than registering by hand --
  the path a user takes is the path under test." ;;
  esac

  local cycle=0
  [ -f "$STATE" ] && cycle=$(sed -n 's/^cycle=//p' "$STATE" | tail -1)

  cat > "$STATE" <<EOF
armed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cycle=$cycle
app=$APP
signature=${signature:-unknown}
cdhash=${cdhash:-unknown}
disposition=$disposition
url=$url
pid_before=${running_pid:-none}
EOF

  green "Armed. Record is enabled and points at the installed copy."
  echo
  info "Now: log out, log back in, and TOUCH NOTHING -- do not open the app,"
  info "do not click the notch. Then run:"
  echo
  echo "    ./Scripts/verify-login-item.sh check"
  echo
  info "The roadmap asks for two cycles; a registration that works once can"
  info "still lapse on the second. This script counts them for you."
}

cmd_check() {
  [ -f "$STATE" ] || die "nothing armed. Run: ./Scripts/verify-login-item.sh arm"

  local record armed_at pid_before cycle disposition url pid elapsed
  armed_at=$(sed -n 's/^armed_at=//p' "$STATE")
  pid_before=$(sed -n 's/^pid_before=//p' "$STATE")
  cycle=$(( $(sed -n 's/^cycle=//p' "$STATE") + 1 ))

  record=$(btm_record)
  disposition=$(btm_field "$record" Disposition)
  url=$(btm_field "$record" URL)
  pid=$(pgrep -f "$APP/Contents/MacOS/CreativeNotch" | head -1 || true)
  if [ -n "$pid" ]; then
    elapsed=$(ps -o etime= -p "$pid" | tr -d ' ' || true)
  else
    elapsed="-"
  fi

  info "armed at      $armed_at"
  info "btm record    ${disposition:-<none>}"
  info "btm url       ${url:-<none>}"
  info "process       ${pid:-not running}"
  info "running for   $elapsed"
  echo

  if [ -n "$pid" ] && [ "$pid" = "$pid_before" ]; then
    red "INCONCLUSIVE -- same process id as before arming ($pid)."
    echo "  Nothing was restarted, so you did not actually log out. Log out"
    echo "  properly (Apple menu > Log Out) rather than locking the screen."
    exit 2
  fi

  if [ -n "$pid" ]; then
    sed -i '' "s/^cycle=.*/cycle=$cycle/" "$STATE"
    green "PASS (cycle $cycle) -- macOS started it at login."
    echo "  Nothing else launched it, so this is the launch the record promised."
    if [ "$cycle" -lt 2 ]; then
      echo
      info "One more cycle. Log out, log back in, touch nothing, run check again."
    else
      echo
      green "Two cycles passed. The module is verified end to end."
      info "Afterwards: switch Open at login off in Settings, and remove"
      info "$APP if you do not want the ad-hoc copy."
    fi
    exit 0
  fi

  case "$disposition" in
    "[enabled"*)
      red "FAIL -- the record is still enabled and nothing started."
      echo "  macOS accepted the registration and refuses to honour it. That is"
      echo "  the switch reading on over nothing, which is the one failure this"
      echo "  module exists to prevent -- the status read cannot detect it."
      echo
      echo "  Planned response, spec section 8: the LaunchAgent fallback, which"
      echo "  is path-based and signature-blind, or ship the explanation rather"
      echo "  than the toggle. Do NOT merge the toggle as it stands."
      exit 1 ;;
    "")
      red "FAIL -- the record is gone."
      echo "  Something revoked it between arming and now. Capture this before"
      echo "  touching anything: sfltool dumpbtm | grep -B9 $BUNDLE_ID"
      exit 1 ;;
    *)
      red "FAIL -- the record is present but not enabled: $disposition"
      echo "  Most likely it needs approval in System Settings > General >"
      echo "  Login Items, which is the .needsApproval state the probe could"
      echo "  not produce. Worth recording either way."
      exit 1 ;;
  esac
}

case "${1:-}" in
  arm)   cmd_arm ;;
  check) cmd_check ;;
  reset) rm -f "$STATE"; green "cleared $STATE" ;;
  -h|--help|help|"") usage 0 ;;
  *) die "unknown mode: $1 (try arm, check, or reset)" ;;
esac
