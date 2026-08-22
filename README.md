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
  <img src="https://img.shields.io/badge/tests-112-brightgreen" alt="112 tests">
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0">
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

```bash
curl -fsSL https://raw.githubusercontent.com/GcdZ03/CreativeNotch/main/Scripts/install.sh | bash
```

Installs to `/Applications`. Run the same command again to update — it
checks the installed version and exits early if you are current.

<details>
<summary>What that script does, before you pipe it to bash</summary>

Checks you are on macOS 26+, fetches the latest release from the GitHub API,
downloads the `.tar.gz`, verifies its code signature, stops any running copy,
and moves it into `/Applications`. It asks for `sudo` only if `/Applications`
needs it. Read it first if you like — it is
[`Scripts/install.sh`](Scripts/install.sh), and piping a script from the
internet into your shell deserves a look.

</details>

### Why `curl` rather than a download button

CreativeNotch is **ad-hoc signed, not notarised** — notarisation requires the
$99/yr Apple Developer Program, which this project deliberately does not use.

Browsers, Mail, Messages, and AirDrop stamp downloads with
`com.apple.quarantine`, and Gatekeeper refuses to open a quarantined app that
is not notarised. `curl` does not set that flag, so an install fetched this
way simply runs.

If you download the `.tar.gz` from the releases page by hand instead, strip
the flag yourself:

```bash
xattr -dr com.apple.quarantine /Applications/CreativeNotch.app
```

### Build from source

```bash
git clone https://github.com/GcdZ03/CreativeNotch.git
cd CreativeNotch
./Scripts/bundle.sh
open dist/CreativeNotch.app
```

Needs the Xcode Command Line Tools; a full Xcode install is not required, and
there is no `.xcodeproj`. A locally built app is never quarantined, so it runs
immediately.

### Permissions

On first launch an onboarding window explains that **Accessibility** access is
needed, and why:

- global key events, so the HUD can show volume and brightness in the notch
- drag detection, so the file shelf can open as a drop target

Clipboard history and the shelf's drop area work without it. You can skip the
prompt and grant it later from the menu bar item.

### Uninstalling

```bash
pkill -f CreativeNotch
rm -rf /Applications/CreativeNotch.app
defaults delete com.gcdz.creativenotch        # only exists after onboarding
```

Also remove CreativeNotch from **System Settings → Privacy & Security →
Accessibility** if you granted it.

Once the file shelf module lands it will store copies under
`~/Library/Application Support/CreativeNotch` — nothing creates that
directory today.

## Usage

Launch the app. It has no Dock icon — it lives in the notch and the menu bar.

| Action | Result |
|---|---|
| Pause on the notch for ~300 ms | Peeks open |
| Move away | Collapses |
| Click the notch | Opens the full panel |
| Click it again | Closes it |
| Click anywhere outside | Closes it |
| Switch to another app | Closes it |
| Move the cursor away | Closes it, after a 400 ms grace |
| Menu bar icon | Accessibility status, Quit |

A quick cursor pass on the way to the menu bar does **not** trigger it — the
300 ms dwell is deliberate, because the notch sits directly on that path.

The panel is hidden entirely over fullscreen apps, so it never covers a film
or a presentation.

Quit from the menu bar item, or `pkill -f CreativeNotch`.

---

## Development

```bash
swift test           # 112 tests, ~1s, no window server needed
./Scripts/dev.sh     # stop, rebuild, sign, relaunch
```

Xcode opens `Package.swift` directly — there is no project file to maintain.

**Set up signing before touching any module that needs Accessibility.** An
ad-hoc signature's designated requirement is the hash of the code, so macOS
revokes your Accessibility grant on every rebuild. A one-time local
certificate fixes it:

```bash
./Scripts/setup-signing.sh
export CODESIGN_IDENTITY="CreativeNotch Dev"
```

### Project layout

```
Sources/
  CreativeNotchCore/   pure logic — geometry, hit-test shapes, state machine,
                       peek arbitration. Never imports AppKit or SwiftUI.
  CreativeNotchUI/     AppKit + SwiftUI — panel, hosting view, hover tracker,
                       menu bar, onboarding, app delegate.
  CreativeNotch/       18-line executable. Constructs the delegate and runs.
Tests/
  CreativeNotchCoreTests/   42 tests
  CreativeNotchUITests/     70 tests
```

The split is load-bearing, not cosmetic. `CreativeNotchCore` importing AppKit
or SwiftUI is a mistake: its freedom from them is what lets the geometry and
state logic run headlessly in CI in under a second.

Tests here are expected to **fail when the code is broken**, and that gets
verified rather than assumed — three tests shipped during the foundation
build that passed with their implementation deleted. When adding a test,
introduce the bug it targets, confirm it fails, then revert.

Full detail in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Roadmap

In build order. Each module gets its own spec and plan before any code.

1. **File shelf** — drag a file to the notch to stash it, drag it out later.
   Copies files, capped at 20 entries.
2. **Clipboard history** — 50-entry in-memory ring, cleared on quit, with
   `org.nspasteboard.ConcealedType` filtered so password managers never
   land on disk. The only subsystem that genuinely polls, and the reason
   `SystemActivity` exists.
3. **Media** — now-playing metadata and transport controls.
4. **System HUD** — volume and brightness in the notch. *Deferred*: the
   observation half is solved and needs no permission, but suppressing
   Apple's own HUD has no known solution on macOS 26 — `OSDUIHelper`, the
   documented target, no longer runs. See
   [`docs/research/2026-08-22-hud-feasibility.md`](docs/research/2026-08-22-hud-feasibility.md).

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
| [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) | Dev loops, signing setup, release process |
| [`docs/specs/2026-08-22-creativenotch-design.md`](docs/specs/2026-08-22-creativenotch-design.md) | The design decisions and why |
| [`docs/plans/2026-08-22-foundation.md`](docs/plans/2026-08-22-foundation.md) | The foundation implementation plan |
| [`docs/plans/2026-08-22-foundation-followups.md`](docs/plans/2026-08-22-foundation-followups.md) | Known issues carried out of the build |
| [`docs/research/2026-08-22-hud-feasibility.md`](docs/research/2026-08-22-hud-feasibility.md) | Why the HUD is deferred, and what was proven |

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

[GPL-3.0](LICENSE).

You may use, modify, and redistribute this, including commercially — but
derivative works must also be released under GPL-3.0. That is deliberate:
this category has a pattern of open work being repackaged as closed paid
apps, and the copyleft is there to prevent it.
