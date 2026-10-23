#!/usr/bin/env bash
#
# Exercises Scripts/install.sh end to end against a fake $INSTALL_DIR, with
# every external it reaches for (GitHub, codesign, pgrep, the OS probes, and
# -- for the failure case -- mv) stubbed on PATH. Covers what a mistake would
# cost a user most: the move-aside backup, its restore when the install move
# fails, the backup's cleanup on success, and the escaped, anchored pattern
# handed to pgrep/pkill.
#
#   Scripts/tests/install-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { printf 'ok:   %s\n' "$1"; }

# The release the stubbed GitHub serves: a bundle carrying a marker file.
FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE/CreativeNotch.app/Contents/MacOS"
echo new > "$FIXTURE/CreativeNotch.app/marker"
tar -czf "$WORK/app.tar.gz" -C "$FIXTURE" CreativeNotch.app

STUBS="$WORK/stubs"
mkdir -p "$STUBS"
REAL_MV="$(command -v mv)"

cat > "$STUBS/curl" <<STUB
#!/usr/bin/env bash
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift ;; esac
  shift
done
if [ -n "\$out" ]; then cp "$WORK/app.tar.gz" "\$out"; exit 0; fi
printf '%s\n' '{"tag_name": "v9.9.9", "browser_download_url": "https://example.invalid/CreativeNotch.tar.gz"}'
STUB
cat > "$STUBS/sw_vers" <<'STUB'
#!/usr/bin/env bash
echo 26.0
STUB
cat > "$STUBS/sysctl" <<'STUB'
#!/usr/bin/env bash
echo 1
STUB
cat > "$STUBS/codesign" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
# Reports a running copy and logs the pattern it was asked to match.
cat > "$STUBS/pgrep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$WORK/pgrep.log"
exit 0
STUB
cat > "$STUBS/pkill" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$WORK/pkill.log"
exit 0
STUB
cat > "$STUBS/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
# Fails the one move that installs the new bundle when FAIL_INSTALL_MV is set.
cat > "$STUBS/mv" <<STUB
#!/usr/bin/env bash
if [ -n "\${FAIL_INSTALL_MV:-}" ] && [ "\${1##*/}" = CreativeNotch.app ] && [ "\${2##*/}" = CreativeNotch.app ]; then
  # Leave a partial bundle behind, as a cross-filesystem mv dying halfway would.
  mkdir -p "\$2/Contents"
  exit 1
fi
exec "$REAL_MV" "\$@"
STUB
chmod +x "$STUBS"/*

# A destination with characters pgrep would read as regex syntax.
fresh_dest() {
  local dest="$WORK/Apps.d (x+y)"
  rm -rf "$dest"
  mkdir -p "$dest/CreativeNotch.app/Contents/MacOS"
  echo old > "$dest/CreativeNotch.app/marker"
  rm -f "$WORK/pgrep.log" "$WORK/pkill.log"
  printf '%s' "$dest"
}

run_installer() {
  PATH="$STUBS:$PATH" INSTALL_DIR="$1" bash "$INSTALLER" >"$WORK/out.log" 2>&1
}

leftover_backups() { find "$1" -maxdepth 1 -name '.CreativeNotch.app.previous.*' | wc -l | tr -d ' '; }

# --- A successful update replaces the app and removes the backup.
DEST="$(fresh_dest)"
if run_installer "$DEST"; then pass "update exits 0"; else fail "update exited non-zero: $(cat "$WORK/out.log")"; fi
[ "$(cat "$DEST/CreativeNotch.app/marker" 2>/dev/null)" = new ] \
  && pass "update installs the new bundle" || fail "update did not install the new bundle"
[ "$(leftover_backups "$DEST")" = 0 ] \
  && pass "update removes the backup" || fail "update left a backup behind"

# --- pgrep/pkill match only the target, anchored and regex-escaped.
EXPECTED="^$(printf '%s' "$DEST" | sed 's/[][\\.^$*+?(){}|]/\\&/g')/CreativeNotch\\.app/Contents/MacOS/CreativeNotch"
[ "$(head -1 "$WORK/pgrep.log")" = "$EXPECTED" ] \
  && pass "pgrep pattern is anchored and escaped" || fail "pgrep pattern was: $(head -1 "$WORK/pgrep.log"), expected $EXPECTED"
[ "$(head -1 "$WORK/pkill.log")" = "$EXPECTED" ] \
  && pass "pkill pattern matches pgrep's" || fail "pkill pattern was: $(head -1 "$WORK/pkill.log")"
if printf '%s\n' "/elsewhere/dist/CreativeNotch.app/Contents/MacOS/CreativeNotch" | grep -Eq "$EXPECTED"; then
  fail "pattern matches a dev build elsewhere"
else
  pass "pattern does not match a dev build elsewhere"
fi
printf '%s\n' "$DEST/CreativeNotch.app/Contents/MacOS/CreativeNotch" | grep -Eq "$EXPECTED" \
  && pass "pattern matches the installed copy" || fail "pattern does not match the installed copy"

# --- A failed install move puts the previous copy back.
DEST="$(fresh_dest)"
if FAIL_INSTALL_MV=1 run_installer "$DEST"; then fail "a failed install exited 0"; else pass "a failed install exits non-zero"; fi
[ "$(cat "$DEST/CreativeNotch.app/marker" 2>/dev/null)" = old ] \
  && pass "a failed install restores the previous copy" || fail "previous copy not restored: $(ls -R "$DEST")"
[ ! -e "$DEST/CreativeNotch.app/CreativeNotch.app" ] \
  && pass "the restore does not nest the backup in a partial bundle" || fail "backup nested inside partial bundle"
[ "$(leftover_backups "$DEST")" = 0 ] \
  && pass "a failed install leaves no stray backup" || fail "a failed install left a backup behind"
grep -q "previous copy is back in place" "$WORK/out.log" \
  && pass "a failed install says the copy is back" || fail "unexpected message: $(cat "$WORK/out.log")"

if [ "$FAILURES" -gt 0 ]; then
  printf '%d install test(s) failed\n' "$FAILURES" >&2
  exit 1
fi
echo "all install tests passed"
