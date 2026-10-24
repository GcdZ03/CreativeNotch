#!/usr/bin/env bash
# Brings Sources/CreativeNotchCore/Localizable.xcstrings up to date with the
# strings the code actually uses.
#
# Xcode does this on every build; SwiftPM does not, so this is the same
# pipeline by hand: the compiler extracts every `String(localized:)` and
# `Text(_:bundle:)` literal into .stringsdata files, and xcstringstool merges
# them into the catalog -- adding new keys, marking removed ones stale, and
# leaving every existing translation and plural variation alone.
#
# Then one step Xcode would not take: every key gets an explicit English
# value. A source-language entry with no value compiles to nothing, which
# resolves correctly by falling back to the key -- and is exactly what an
# uncompiled catalog looks like too. With every value present,
# LocalizationTests can tell the two apart by reading the compiled table.
#
# Run it after adding, changing or removing a user-facing string, then
# review the diff: a new plural needs its `one`/`other` variations added by
# hand (see CONTRIBUTING.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/Sources/CreativeNotchCore/Localizable.xcstrings"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
# A scratch build directory, so the extraction flags never leave .build in
# a state the next ordinary `swift build` would have to rebuild from.
if ! swift build --scratch-path "$WORK/build" \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >"$WORK/build.log" 2>&1; then
  grep -E 'error' "$WORK/build.log" >&2 || cat "$WORK/build.log" >&2
  exit 1
fi

xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/strings/*.stringsdata

/usr/bin/python3 -I - "$CATALOG" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    catalog = json.load(f)
# A key the code no longer uses is deleted rather than left marked stale:
# git keeps any translation it had, and a catalog holding only live keys is
# one a translator can trust is all there is to do.
stale = [k for k, e in catalog["strings"].items() if e.get("extractionState") == "stale"]
for key in stale:
    print(f"removed unused key: {key!r}")
    del catalog["strings"][key]
for key, entry in catalog["strings"].items():
    english = entry.setdefault("localizations", {}).setdefault("en", {})
    if "stringUnit" not in english and "variations" not in english:
        english["stringUnit"] = {"state": "translated", "value": key}
    # sync writes a key with several arguments as a positional English
    # value ("%1$@ %2$@ ago") in state "new", and compile leaves "new" out.
    # English is the source: whatever it says is, by definition, translated.
    if english.get("stringUnit", {}).get("state") == "new":
        english["stringUnit"]["state"] = "translated"
with open(path, "w", encoding="utf-8") as f:
    # Xcode's own layout (" : " separators, two-space indent, sorted keys),
    # so a catalog touched by both stays a small diff.
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    f.write("\n")
PY

echo "synced $(/usr/bin/python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["strings"]))' "$CATALOG") strings into ${CATALOG#$ROOT/}"
