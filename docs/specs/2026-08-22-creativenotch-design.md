# CreativeNotch — Design

**Date:** 2026-08-22
**Status:** Approved design, pre-implementation
**Target:** macOS 26+, Apple Silicon

## 1. Purpose

A personal macOS notch utility with four modules: media controls, a file
shelf, clipboard history, and a system HUD. Built for the author's own
machines, not for distribution.

The category is crowded (NotchNook, Alcove, Boring Notch, Atoll, and others),
and its defining flaw is well documented: idle battery drain reported as high
as 5%/hour, memory leaks reaching 2GB+, and crashes after sleep/wake. The
cause is structural — these apps poll. Global mouse monitors run
continuously, system stats run on timers, audio visualizers run FFT on a live
tap.

CreativeNotch's one architectural commitment is the inverse:

> **No subsystem runs when it isn't needed, and that rule is enforced
> centrally rather than trusted to each module.**

## 2. Decisions

| Question | Decision |
|---|---|
| Purpose | Personal tool. No distribution, no support, no App Store |
| Signing | Ad-hoc (`codesign -s -`). No Developer Program |
| Minimum OS | macOS 26+ only. All target Macs are on Tahoe |
| Cross-device | Runs correctly on any Mac. No sync, no shared state |
| Notchless Macs | Floating pill centered under the menu bar |
| Multi-display | Follows the focused screen |
| Interaction | Hover to peek, click to expand |
| Clipboard storage | In memory only, cleared on quit |
| File shelf storage | Copy into shelf storage |
| Media depth | Metadata + transport controls. No scrubber, no visualizer |
| Peek arbitration | Transient events preempt ambient, then fall back |
| Settings | Menu bar menu only |
| Panel layout | Media header always on top; shelf / clipboard / HUD tabbed below |
| Shelf cap | 20 entries, oldest evicted |
| CI | GitHub Actions — build + test on push |
| Fullscreen apps | Hidden entirely |
| Hover delay | 300ms deliberate pause |
| Permissions | Requested during first-launch onboarding |
| Dev workflow | TDD on pure logic, manual verification of AppKit |
| OSD suppression | Deferred to its own spike; v1 renders alongside Apple's |

## 3. Architecture

One process (`LSUIElement = true`), launch-at-login via `SMAppService`.

One child process — the perl MediaRemote helper — spawned lazily, only while
media is actually on screen, and killed 30s after it leaves.

```
event sources ──▶ SystemActivity gate ──▶ modules ──▶ NotchState ──▶ SwiftUI
```

Strictly one direction. No module talks to another module.

## 4. Core components

### 4.1 NotchPanel

```swift
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool  { false }
    override var canBecomeMain: Bool { false }
}
```

```
styleMask          = [.borderless, .nonactivatingPanel]
level              = .statusBar + 1
collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
isOpaque = false, backgroundColor = .clear, hasShadow = false
isMovable = false
```

`.fullScreenAuxiliary` is deliberately **omitted**. That single omission is
what hides the panel entirely over fullscreen apps — no detection logic, no
frontmost-window inspection, no edge cases. NotchNook's persistent
now-playing preview obscuring fullscreen content is a documented complaint;
this avoids it by construction.

The consequence is that the HUD module does nothing in fullscreen. Since v1
does not suppress `OSDUIHelper`, Apple's native volume and brightness OSD
still appears there, so the behaviour degrades cleanly rather than silently.

The panel is **always sized to fully-expanded bounds**; content animates
inside it. This avoids window-resize jank, but leaves a large transparent
rect that would swallow clicks — so `contentView.hitTest(_:)` returns `nil`
outside the currently-visible shape.

That hit-test override is the fiddliest single piece of the app. It is also
where "the notch ate my menu bar click" bugs will come from, so it gets a
unit-tested pure geometry function backing it.

### 4.2 NotchGeometry

Resolves an anchor per-screen. This is what makes cross-device support one
UI instead of two.

```swift
enum Anchor {
    case notch(CGRect)   // real hardware notch
    case pill(CGRect)    // synthesized, centered under the menu bar
}
```

- **Notch** when `screen.safeAreaInsets.top > 0`.
  Width is `screen.frame.width - (auxiliaryTopLeftArea.width + auxiliaryTopRightArea.width)`,
  height is `safeAreaInsets.top`. All public API.
- **Pill** otherwise. Fixed 180×32, centered horizontally, sitting just below
  the menu bar.

Recomputed on `NSApplication.didChangeScreenParametersNotification` only.

Deliberately **not** drawing a synthetic black notch on notchless Macs —
that is the specific thing reviewers single out as jarring in NotchNook.

### 4.3 Focused-screen tracking

Driven by `NSWorkspace.didActivateApplicationNotification` and
`NSWindow.didBecomeKeyNotification`. Event-driven, so cursor position is
never polled.

### 4.3b Hover

Hover is detected with an `NSTrackingArea` on the panel itself — never a
global mouse monitor — so it costs nothing when the cursor is elsewhere.

A **300ms dwell** is required before peeking. The notch sits directly on the
path to the menu bar and the traffic lights, so a deliberate pause is what
separates intent from a cursor passing through. The timer is cancelled on
exit.

### 4.4 NotchState

```swift
enum NotchState: Equatable {
    case closed              // exactly the anchor rect, invisible
    case peek(PeekContent)   // glanceable
    case open(Tab)           // media header + selected tab
    case receiving           // drag in flight, shelf target shown
}

enum Tab: Equatable { case shelf, clipboard, hud }

enum PeekContent: Equatable {
    case hud(HUDEvent)              // transient, TTL 1.5s
    case dragTarget                 // transient, until drag ends
    case nowPlaying(TrackSnapshot)  // ambient, no TTL
}
```

State transitions are the **only** thing that triggers a redraw.

When open, the panel renders a persistent now-playing header above a tabbed
area holding the shelf, clipboard, and HUD history. Music is ambient and
always worth seeing; the rest is on demand.

### 4.5 PeekArbiter

Transient content preempts ambient content. On expiry, falls back to the
highest-priority ambient source, or `.closed` if none. Pure logic, fully
unit-testable, no UI dependency.

### 4.6 NotchModule

```swift
protocol NotchModule: AnyObject {
    var id: ModuleID { get }
    var isEnabled: Bool { get set }
    func start() async
    func stop()
    func peek() -> PeekContent?
    @MainActor func openView() -> AnyView
}
```

`start()`/`stop()` are lifecycle, not convenience. A disabled module holds
no monitors, no timers, and no child processes.

### 4.7 SystemActivity

```swift
enum SystemActivity { case active, locked, asleep }
```

Sources: `NSWorkspace` sleep/wake and session notifications, plus
`DistributedNotificationCenter` for `com.apple.screenIsLocked` /
`screenIsUnlocked`.

**No poller may run outside `.active`.** Enforced once, here.

Note there is deliberately no `.idle` case — detecting user idle requires
polling `CGEventSource`, which would violate the rule it exists to serve.
Idle back-off is handled inside the clipboard poller instead, which already
knows how long it has been since anything changed.

## 5. Modules

### 5.1 HUD — push, effectively free

> **Superseded** by [`2026-08-25-system-hud-design.md`](2026-08-25-system-hud-design.md).
> A spike found this section wrong on both halves: volume and brightness are
> better observed as *values*, and `OSDUIHelper` — the suppression target
> below — no longer runs on macOS 26. The goal changed from replacing
> Apple's HUD to **coexisting** with it, which is both achievable and
> better: the notch covers the triggers Apple ignores.

Global monitor on `.systemDefined`, filtering `subtype == 8`:

```swift
let keyCode = Int32((event.data1 & 0xFFFF0000) >> 16)
// 0 = SOUND_UP, 1 = SOUND_DOWN, 7 = MUTE
// 2 = BRIGHTNESS_UP, 3 = BRIGHTNESS_DOWN
```

Volume read via CoreAudio
(`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`). Brightness read is
deferred — v1 renders a relative indicator.

**v1 renders alongside Apple's own OSD.** Suppressing `OSDUIHelper` is a
separate spike; the known techniques are fragile and unverified on macOS 26,
and must not block the easiest of the four modules.

### 5.2 File shelf — lazy monitor

> **Superseded 2026-08-22** by
> [`2026-08-22-file-shelf-design.md`](2026-08-22-file-shelf-design.md). The
> lazy drag monitor below is not needed at all: AppKit delivers dragging
> events to the window under the cursor, so the shelf needs no monitoring
> and no permission. Removal also goes to the Trash rather than deleting.

Drop target via `.dropDestination(for: URL.self)`.

Expanding the notch when a drag *starts* is where naive implementations burn
battery. The rule here:

1. Monitor `.leftMouseDown` only — discrete and cheap.
2. On mouse-down, check `NSPasteboard(name: .drag).changeCount`.
3. Only if it moved, install the `.leftMouseDragged` monitor.
4. Tear it down on `.leftMouseUp`.

A permanent drag monitor is never installed.

Files are **copied** into `~/Library/Application Support/CreativeNotch/Shelf/`,
so moving or deleting the original never breaks a shelf entry.

**Capped at 20 entries, oldest evicted.** This is a staging shelf, not
storage — a hard count cap cannot run away and needs no timestamp logic.
Also clearable on demand from the menu bar item.

### 5.3 Clipboard — the only genuine poller

`NSPasteboard` has no change notification. This module is the sole exception
to the no-polling rule, so it is the most tightly constrained.

- 0.75s interval while `.active`
- Backs off to 3s after 2 minutes with no change; resets on any change
- Fully suspended on `.locked` and `.asleep`
- Floor raised to 2s under Low Power Mode
- 50-entry ring buffer, **in memory only**, cleared on quit

**Skipped pasteboard types:**

- `org.nspasteboard.ConcealedType` — the convention password managers use
- `org.nspasteboard.TransientType`
- `org.nspasteboard.AutoGeneratedType`

Most clipboard managers ignore `ConcealedType` and quietly write passwords
to disk. Combined with in-memory-only storage, secrets never leave RAM.

**Captured content.** Text and images. File URLs are the shelf's job — a URL
entry would go stale the moment the original moved, and the shelf already
solves that by copying.

Both are capped per entry, and content over the cap is **skipped, never
truncated**: a half-written string pastes back as corrupt data, which is
worse than an absent entry.

| Kind | Per-entry cap |
|---|---|
| Text | 1 MB |
| Image | 10 MB |

**Images are stored as PNG, transcoded at capture if they arrive as TIFF.**
`NSPasteboard` TIFF is uncompressed — roughly `width × height × 4` bytes —
so a 14" MacBook Pro full-screen grab reaches the pasteboard at about 24 MB.
Judged at that size it would fail the 10 MB cap and be silently dropped,
which is the wrong answer for the single most common thing this app will be
asked to remember. Re-encoded first, the same image is a couple of megabytes
and is kept. **The cap applies to what the ring will actually hold**, not to
what the pasteboard handed over.

The transcode runs on the main actor at roughly 50–150 ms for a large image.
Image copies are rare enough that this should not be visible; if it ever is,
it moves off the main actor — after a measurement, not before.

**The ring is also capped in total, at 100 MB.** A count cap alone bounds it
at fifty times the per-entry image cap, which is half a gigabyte resident for
the life of the process. Transcoding makes the typical entry roughly a tenth
of its raw size; the total budget is the guarantee that holds even when it
does not, since a screenshot of noise compresses to nothing at all. Over
budget, the oldest entries are evicted until the ring is back under it — the
entry just copied is never the one evicted.

**Duplicates promote rather than append.** Copying something already in the
ring moves that entry to the front and refreshes its timestamp. Fifty slots
therefore hold fifty *distinct* things, and re-copying one value cannot flush
the history.

**Resuming from `.locked` or `.asleep` resyncs without capturing.** The
poller is suspended across those states, so `changeCount` will have moved if
anything was copied meanwhile. That new value is adopted as the baseline and
its content is never read. Capturing it would mean recording whatever another
session or a background process put on the pasteboard while the screen was
locked — exactly the content this module has the least claim to.

**Clicking an entry writes it back to the pasteboard and nothing more.** No
synthesized paste keystroke: section 6 commits this module to needing no
permission, and key synthesis would require Accessibility. The write is seen
by the poller as an ordinary change, and promotion resolves it to the same
entry returning to the front — the correct outcome, reached with no special
case.

### 5.4 Media — out-of-process by necessity

**Verified on macOS 26.6.2:** `mediaremoted` gates Now Playing reads by
code-signing identifier, allowing `com.apple.*`. `/usr/bin/perl` reports
`Identifier=com.apple.perl`, so the
[`ungive/mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter)
technique (BSD-3) is viable and requires no SIP changes.

- **Transport controls** — `MRMediaRemoteSendCommand` via `dlopen`/`dlsym`.
  Not gated. Works today, no helper needed.
- **Metadata** — bundled helper framework run via system perl, streaming
  newline-delimited JSON on stdout, read with a `readabilityHandler`.
- Helper spawns when media enters the peek slot **or when the panel opens**
  (the now-playing header is always visible there), and is killed 30s after
  both conditions clear. Opening the panel to check the clipboard therefore
  starts the helper — acceptable, because panel opens are brief and always
  user-initiated.
- Artwork cached by track identity; documented as arriving late or never.

> **Risk closed 2026-08-29** by
> [`docs/research/2026-08-29-media-feasibility.md`](../research/2026-08-29-media-feasibility.md).
> Both halves above are confirmed on macOS 26.6.2 — and they fall on
> opposite sides of the no-dependencies rule, which splits the module in
> two.

**The module ships in two parts.**

**Part one — transport controls. Verified, and built first.**
`MRMediaRemoteSendCommand` works from an **ad-hoc-signed** binary, ground-
truthed against a real player: `pause` and `togglePlayPause` both took
effect in both directions. No helper, no subprocess, no third-party code,
so the no-dependencies rule is untouched. `nextTrack` and `previousTrack`
are the same call with a different constant; they were not sent as part of
the original spike, because doing so moves the user's queue position, but
were subsequently verified during this plan's Step 9 real-app check —
sent against Spotify with its AppleScript state as independent ground
truth, moving the track forward twice and back once as expected. All three
commands are now verified, not inferred.

Two traps recorded by the spike, both of which produced wrong conclusions
before they were understood:

- `SendCommand` returns `true` for commands that are **ignored**, and for
  nonsense command ids. It means "dispatched", not "obeyed"; there is no
  in-process success signal.
- The now-playing client is frequently **not the obvious app** — a browser
  tab holding the media session will outrank a running music app.

**Part two — metadata. Gated, and deferred to its own spike, spec and
plan.** An ad-hoc-signed process gets nothing: not the track fields, not
even `MRMediaRemoteGetNowPlayingApplicationPID`, which answers `0` rather
than the real pid. The `com.apple.*` helper route is genuinely required.

Metadata is deferred rather than dropped because it is the only part of
this application that needs a subprocess, and the only part that puts the
no-dependencies rule in play — either by vendoring the BSD-3 adapter or by
writing an equivalent bridge. It deserves the same spike → spec → plan
treatment every other module got, rather than riding along with a
fifty-line feature that carries none of that risk.

⚠️ Its spike must start by verifying an assumption this one did **not**
test: that a dylib *loaded into* the perl process inherits the exemption,
i.e. that the daemon checks the main executable's identity rather than the
loaded code. The entire helper approach rests on it.

Until part two exists, `PeekArbiter.setNowPlaying` and the
`.peek(.nowPlaying)` case stay dormant: `TrackSnapshot` needs a title and
artist, which is exactly what part one cannot obtain.

## 6. Permissions

| Permission | Needed by | Notes |
|---|---|---|
| Accessibility | HUD, drag detection | Global event monitors |
| — | Clipboard | None required |
| — | Shelf drop target | None required |

Non-sandboxed: a private framework and a perl subprocess make sandboxing
impractical, and there is no App Store target.

### 6.1 Onboarding

A first-launch window explains why Accessibility is needed — global key
events for the HUD, and drag detection for the shelf — and then triggers the
system prompt. Shown once, re-openable from the menu bar.

Modules that lack their permission disable themselves and say so in the menu
rather than silently doing nothing. Clipboard and the shelf drop target need
no permission and always work.

## 7. Error handling

- **Perl helper** — supervised, exponential backoff (1s→30s cap, 5 attempts),
  then degrades to **controls-only**. Since `MRMediaRemoteSendCommand` is
  ungated, play/pause/skip keep working even if metadata never arrives.
- **Screen changes** — geometry recomputed; anchor kind may flip between
  notch and pill mid-session, which is a supported transition.
- **Missing Accessibility** — HUD and drag detection disable themselves and
  say so in the menu; the other modules are unaffected.

## 8. Testing

Pure and unit-tested:

- `NotchGeometryTests` — synthetic screen metrics → expected notch/pill rects
- `HitTestTests` — the visible-shape containment function
- `PeekArbiterTests` — priority, preemption, TTL expiry, fallback
- `ClipboardFilterTests` — concealed-type skipping, dedup, ring eviction
- `MediaAdapterParsingTests` — NDJSON fixtures including malformed lines

**Workflow: test-first for the pure logic above, manual verification for the
AppKit layer.** That boundary is deliberate — the pure logic is where real
bugs live and it runs headlessly in CI, whereas a panel mostly needs to look
right, and wrapping AppKit in protocols to fake it would buy ceremony rather
than confidence.

The `NSPanel` and global-monitor layer stays deliberately thin for exactly
this reason.

## 9. Build order

Cheapest and most self-contained first; riskiest last.

0. Panel skeleton, geometry, state machine, menu bar item
0.5 First-launch onboarding and Accessibility request
1. HUD (alongside Apple's OSD)
2. File shelf
3. Clipboard
4. Media (perl helper)

Deferred spikes: OSD suppression, brightness read.

## 10. CI

GitHub Actions on push to `main` and on pull requests: `xcodebuild test`
against a macOS runner with code signing disabled.

The pure logic in section 8 — geometry, hit-testing, peek arbitration,
clipboard filtering, NDJSON parsing — is where the real bugs will live, and
all of it runs headlessly. The AppKit layer is untested by design and stays
thin for that reason.

The workflow no-ops until an Xcode project exists, so it will not report red
during step 0.

## 11. Non-goals

- No sync, no CloudKit, no iCloud entitlement
- No audio visualizer — directly contradicts the battery architecture
- No scrubbing in v1
- No synthetic black notch on notchless Macs
- No Mac App Store, no notarization, no Developer Program
- No calendar, webcam mirror, or shortcuts widgets in v1
