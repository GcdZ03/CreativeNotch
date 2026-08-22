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
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                      .stationary, .ignoresCycle]
isOpaque = false, backgroundColor = .clear, hasShadow = false
isMovable = false
```

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

**Risk:** the adapter does not explicitly claim macOS 26 testing. The
mechanism is confirmed present, but this needs one runtime test before
anything depends on it.

## 6. Permissions

| Permission | Needed by | Notes |
|---|---|---|
| Accessibility | HUD, drag detection | Global event monitors |
| — | Clipboard | None required |
| — | Shelf drop target | None required |

Non-sandboxed: a private framework and a perl subprocess make sandboxing
impractical, and there is no App Store target.

Each module declares its required permissions and surfaces what is missing,
rather than silently doing nothing.

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

The `NSPanel` and global-monitor layer stays deliberately thin and is
verified by hand.

## 9. Build order

Cheapest and most self-contained first; riskiest last.

0. Panel skeleton, geometry, state machine, menu bar item
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
