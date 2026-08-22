<h1 align="center">CreativeNotch</h1>

<p align="center">
  Turn the MacBook notch into something useful — without the battery drain.
</p>

<p align="center">
  <a href="https://github.com/GcdZ03/CreativeNotch/actions/workflows/ci.yml">
    <img src="https://github.com/GcdZ03/CreativeNotch/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.3-orange" alt="Swift 6.3">
  <img src="https://img.shields.io/badge/tests-70-brightgreen" alt="70 tests">
</p>

<!-- Screenshot goes here once there is UI worth showing. -->

---

## Why this exists

There are a dozen notch apps for macOS. The good ones share a flaw: they
poll. Global mouse monitors run continuously, system stats tick on timers,
audio visualisers run FFT on a live tap. Users report idle battery drain as
high as 5%/hour and memory leaks reaching 2 GB.

CreativeNotch inverts that with a single architectural commitment:

> **No subsystem runs when it isn't needed, and that rule is enforced
> centrally rather than trusted to each module.**

Everything else follows from it. Hover uses an `NSTrackingArea` on the panel
instead of a global monitor. Screen following listens for notifications
instead of tracking the cursor. The one subsystem that genuinely cannot
avoid polling — clipboard history, because `NSPasteboard` has no change
notification — will be gated centrally on system activity rather than
trusted to behave.

This is a personal tool built for its author's own Macs. It is not
distributed, not sold, and not on the App Store.

---

## Status

**The foundation is complete. None of the four modules are built yet.**

| | |
|---|---|
| ✅ Panel anchored to the notch, or a pill on notchless Macs | Built |
| ✅ Hover to peek, click to open | Built |
| ✅ Follows the focused screen | Built |
| ✅ Menu bar item, first-launch onboarding | Built |
| ⬜ Media controls | Planned |
| ⬜ File shelf | Planned |
| ⬜ Clipboard history | Planned |
| ⬜ System HUD replacement | Planned |

Today the app draws a panel that reacts to hover and click. It does not yet
do anything useful with that panel — that is what the modules are for.

---

## Requirements

- **macOS 26 (Tahoe) or later.** There is no compatibility shim; the app
  targets 26 exclusively.
- **Apple Silicon or Intel.** Ad-hoc signing is applied either way (on
  Apple Silicon it is mandatory — an unsigned `arm64` binary will not
  launch at all).
- A physical notch is **not** required. Notchless Macs get a pill centred
  under the menu bar with identical behaviour.
- To build: **Xcode 26+** (or just the Command Line Tools — no `.xcodeproj`
  is used).

---

## Installation

There is no DMG, no Homebrew formula, and no release. Build it from source.

```bash
git clone https://github.com/GcdZ03/CreativeNotch.git
cd CreativeNotch
./Scripts/bundle.sh
open dist/CreativeNotch.app
```

`bundle.sh` compiles a release build, assembles `dist/CreativeNotch.app`,
and ad-hoc signs it. That takes a few seconds and needs no Apple Developer
account.

### Why you will not see a Gatekeeper warning

Because you built it yourself, the app never passes through a browser and
so never gets the `com.apple.quarantine` attribute that triggers Gatekeeper.
It launches straight away.

If you ever copy the `.app` to another Mac **via a browser, AirDrop, Mail,
or Messages**, that copy *will* be quarantined and macOS will refuse to open
it — the app is ad-hoc signed, not notarised, and notarisation requires the
$99/yr Apple Developer Program. Two ways around it:

```bash
# Strip the quarantine flag on the receiving Mac
xattr -dr com.apple.quarantine /Applications/CreativeNotch.app
```

…or transfer it with a tool that does not set the flag in the first place
(`scp`, `rsync`, `curl`, `git`).

### Permissions

On first launch an onboarding window explains that **Accessibility** access
is needed, and why:

- global key events, so the HUD can show volume and brightness in the notch
- drag detection, so the file shelf can open as a drop target

Clipboard history and the shelf's drop area work without it. You can skip
the prompt and grant it later from the menu bar item.

### Uninstalling

```bash
pkill -f CreativeNotch
rm -rf /Applications/CreativeNotch.app        # or wherever you put it
defaults delete com.gcdz.creativenotch        # only exists after onboarding
```

Also remove CreativeNotch from **System Settings → Privacy & Security →
Accessibility** if you granted it.

Once the file shelf module lands it will store copies under
`~/Library/Application Support/CreativeNotch` — nothing creates that
directory today.

---

## Usage

Launch the app. It has no Dock icon — it lives in the notch and the menu bar.

| Action | Result |
|---|---|
| Pause on the notch for ~300 ms | Peeks open |
| Move away | Collapses |
| Click the notch | Opens the full panel |
| Click again | Closes it |
| Menu bar icon | Accessibility status, Quit |

A quick cursor pass on the way to the menu bar does **not** trigger it — the
300 ms dwell is deliberate, because the notch sits directly on that path.

The panel is hidden entirely over fullscreen apps, so it never covers a film
or a presentation.

Quit from the menu bar item, or `pkill -f CreativeNotch`.

---

## Development

```bash
swift build          # build
swift test           # 70 tests, ~1s, no window server needed
./Scripts/bundle.sh  # assemble + ad-hoc sign dist/CreativeNotch.app
```

Xcode can open `Package.swift` directly — there is no `.xcodeproj` to
maintain. Note that a bare `swift run` produces an executable with no bundle
and therefore no stable identity for TCC, so Accessibility will not stick;
use `bundle.sh` and launch the `.app`.

### Project layout

```
Sources/
  CreativeNotchCore/   pure logic — geometry, hit-test shapes, state machine,
                       peek arbitration. Never imports AppKit or SwiftUI.
  CreativeNotchUI/     AppKit + SwiftUI — panel, hosting view, hover tracker,
                       menu bar, onboarding, app delegate.
  CreativeNotch/       18-line executable. Constructs the delegate and runs.
Tests/
  CreativeNotchCoreTests/   35 tests
  CreativeNotchUITests/     35 tests
```

The split is load-bearing, not cosmetic. `CreativeNotchCore` importing
AppKit or SwiftUI is a build-breaking mistake: its freedom from them is what
lets the geometry and state logic run headlessly in CI in under a second.

### Testing culture

Tests here are expected to **fail when the code is broken**, and that is
verified rather than assumed. During the foundation build, three tests
shipped that passed with their implementation deleted — every one was caught
by a reviewer mutating the source, not by reading it.

So: when adding a test, introduce the bug it targets, confirm the test
fails, then revert. A test you cannot make fail proves nothing.

---

## Roadmap

In build order. Each module gets its own spec and plan before any code.

1. **System HUD** — volume and brightness in the notch, rendered alongside
   Apple's own OSD. Cheapest and most self-contained.
2. **File shelf** — drag a file to the notch to stash it, drag it out later.
   Copies files, capped at 20 entries.
3. **Clipboard history** — 50-entry in-memory ring, cleared on quit, with
   `org.nspasteboard.ConcealedType` filtered so password managers never
   land on disk. The only subsystem that genuinely polls, and the reason
   `SystemActivity` exists.
4. **Media** — now-playing metadata and transport controls.

Deliberately **not** on the roadmap: an audio visualiser (it contradicts the
battery architecture), iCloud sync, a synthetic black notch on notchless
Macs, and the Mac App Store.

Before module work starts, see
[`docs/plans/2026-08-22-foundation-followups.md`](docs/plans/2026-08-22-foundation-followups.md)
— **F1** and **F2** are traps sitting directly in the file shelf's path.

---

## Documentation

| Document | What it covers |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | How it works, and the non-obvious parts |
| [`docs/specs/2026-08-22-creativenotch-design.md`](docs/specs/2026-08-22-creativenotch-design.md) | The design decisions and why |
| [`docs/plans/2026-08-22-foundation.md`](docs/plans/2026-08-22-foundation.md) | The foundation implementation plan |
| [`docs/plans/2026-08-22-foundation-followups.md`](docs/plans/2026-08-22-foundation-followups.md) | Known issues carried out of the build |

---

## Acknowledgements

- [**The Boring Notch**](https://github.com/TheBoredTeam/boring.notch) —
  the open-source notch app this category owes most to, and the reference
  for how a project like this presents itself.
- [**mediaremote-adapter**](https://github.com/ungive/mediaremote-adapter) —
  the technique the media module will depend on. Since macOS 15.4 the
  `mediaremoted` daemon gates Now Playing reads by code-signing identifier;
  the adapter works around it by running a helper through system `perl`,
  which is signed as `com.apple.perl`. No SIP changes required.

---

## License

Private project. All rights reserved.
