# Media Transport Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play/pause, next and previous track from the notch, controlling whatever application currently holds the system media session.

**Architecture:** `MRMediaRemoteSendCommand`, resolved from the private MediaRemote framework by `dlopen`/`dlsym`, exactly as `BrightnessObserver` resolves DisplayServices. The spike proved this works from an **ad-hoc-signed** binary, so there is no helper, no subprocess, and no third-party code. The command constants live in `CreativeNotchCore` as a typed enum so no raw integer appears at a call site; everything that touches AppKit or `dlopen` stays in `CreativeNotchUI`.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, MediaRemote (private, via `dlopen`), Swift Testing, SwiftPM. No third-party dependencies.

**Spec:** `docs/specs/2026-08-22-creativenotch-design.md` section 5.4
**Research:** `docs/research/2026-08-29-media-feasibility.md`

## Global Constraints

- Minimum platform **macOS 26.0**.
- **No third-party dependencies.** Standard library, AppKit, SwiftUI, Swift Testing only. This module needs none — that is precisely why it was scoped this way.
- **`CreativeNotchCore` must never `import AppKit`, `import SwiftUI`, `import UIKit` or `import Cocoa`.** `CorePurityTests` enforces this recursively and sees through attributed imports. `MediaCommand` is pure data and must not reach for MediaRemote.
- **No polling.** No `Timer`, no mouse monitors, no new global monitors. This module is entirely user-initiated: a command is sent because a button was clicked. The clipboard poller remains the only timer in the codebase.
- **Never mutate `AppState.state` directly.** It is `private(set)`; go through `transition(to:)`.
- **Tests must never send a real media command.** Doing so changes playback on the developer's machine. The button-to-command wiring is proven through an injected closure; the real call is covered by the spike, not by the suite.
- **`dlopen` the framework once, statically.** `BrightnessObserver` holds a `static let handle`; follow it. Repeated `dlopen` per call is wasteful and unnecessary.
- All new types in `CreativeNotchCore` are `public`, `Equatable`, and `Sendable`.
- **No `Task.sleep` in tests.**
- **Every new test must be proven to fail against the bug it targets** — introduce it, watch it fail, revert. Verify the build succeeds before interpreting a mutation result: an invalid mutation breaks the build, produces no test failures, and looks identical to an uncaught bug.
- Conventional commit prefixes (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).
- Baseline before this plan: **375 tests in 41 suites, all passing.**

## What the spike established, and what it did not

Read `docs/research/2026-08-29-media-feasibility.md` before starting. The three findings that shape this plan:

1. **`SendCommand` returns `true` for commands that are ignored**, and for nonsense command ids. It means "dispatched", not "obeyed". **Never present its return value to the user as success**, and never assert on it as evidence a command worked.
2. **`togglePlayPause` (2) and `pause` (1) are verified** in both directions against a real player. **`nextTrack` (4) and `previousTrack` (5) are inferred**, not proven — same function, different constant. They were not sent because that moves the user's queue position.
3. **Metadata is gated and is not part of this module.** `PeekArbiter.setNowPlaying` and `.peek(.nowPlaying)` stay dormant. Do not attempt to populate `TrackSnapshot`.

## File Structure

**`CreativeNotchCore` — pure**

| File | Responsibility |
|---|---|
| `Media/MediaCommand.swift` | The MediaRemote command constants as a typed enum — the only place the raw numbers appear |

**`CreativeNotchUI` — AppKit**

| File | Responsibility |
|---|---|
| `Media/MediaRemoteBridge.swift` | `dlopen`/`dlsym` MediaRemote once; expose `isAvailable` and `send(_:)` |
| `Media/MediaControlsView.swift` | The three buttons |

**Modified:** `NotchRootView.swift` (controls row above the tab bar), `AppDelegate.swift` (owns the bridge, provides the send closure), `CorePurityTests.swift` (recursion anchor for the new `Media/` subdirectory), `README.md`.

---

### Task 1: `MediaCommand` — the constants, named once

A raw `2` at a call site is unreadable and unverifiable. This enum is the only place the MediaRemote command numbers appear, and its test pins them against the values the spike actually verified.

**Files:**
- Create: `Sources/CreativeNotchCore/Media/MediaCommand.swift`
- Create: `Tests/CreativeNotchCoreTests/MediaCommandTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum MediaCommand: Int32, CaseIterable, Equatable, Sendable` with cases `togglePlayPause = 2`, `nextTrack = 4`, `previousTrack = 5`
  - `MediaCommand.isVerified: Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/MediaCommandTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// The MediaRemote command constants.
///
/// These numbers are not documented by Apple and cannot be checked by the
/// compiler — a wrong one silently sends a different command, or none.
/// They are pinned here against what
/// `docs/research/2026-08-29-media-feasibility.md` actually verified.
struct MediaCommandTests {

    @Test func theConstantsAreWhatTheSpikeVerified() {
        #expect(MediaCommand.togglePlayPause.rawValue == 2)
        #expect(MediaCommand.nextTrack.rawValue == 4)
        #expect(MediaCommand.previousTrack.rawValue == 5)
    }

    /// 3 is `stop` in the MediaRemote enum, and is deliberately absent —
    /// nothing in this module stops playback. This pins the gap so a
    /// future contributor does not "fix" the numbering by making the cases
    /// contiguous, which would silently repoint next and previous.
    @Test func theNumberingIsNotContiguous() {
        let values = MediaCommand.allCases.map(\.rawValue).sorted()
        #expect(values == [2, 4, 5])
        #expect(values.contains(3) == false)
    }

    /// The spike sent togglePlayPause and confirmed it both ways against a
    /// real player. It did not send next or previous, because doing so
    /// moves the user's queue position. That distinction is recorded in
    /// the type so it cannot quietly be forgotten.
    @Test func onlyTogglePlayPauseIsProven() {
        #expect(MediaCommand.togglePlayPause.isVerified)
        #expect(MediaCommand.nextTrack.isVerified == false)
        #expect(MediaCommand.previousTrack.isVerified == false)
    }

    @Test func everyCaseIsDistinct() {
        let values = Set(MediaCommand.allCases.map(\.rawValue))
        #expect(values.count == MediaCommand.allCases.count)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MediaCommandTests`
Expected: FAIL — `cannot find 'MediaCommand' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/Media/MediaCommand.swift`:

```swift
import Foundation

/// A MediaRemote transport command.
///
/// The raw values are MediaRemote's own command numbers. They are not
/// documented by Apple and the compiler cannot check them, so they appear
/// exactly once — here — rather than as bare integers at call sites, and
/// `MediaCommandTests` pins them against what the spike verified.
///
/// `3` (stop) is absent on purpose: nothing in this module stops playback.
/// The gap in the numbering is deliberate, not an oversight.
public enum MediaCommand: Int32, CaseIterable, Equatable, Sendable {
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5

    /// Whether the spike actually sent this command and confirmed the
    /// effect against a real player.
    ///
    /// `togglePlayPause` was confirmed in both directions.
    /// `nextTrack` and `previousTrack` are the same call with a different
    /// constant and are expected to behave identically, but were never
    /// sent — doing so moves the user's queue position. Recorded on the
    /// type so the difference between "proven" and "assumed" survives
    /// past the research document.
    public var isVerified: Bool {
        self == .togglePlayPause
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MediaCommandTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Prove the tests bite**

Change `nextTrack` to `= 3`. Build, then run `swift test --filter MediaCommandTests`. Expected: `theConstantsAreWhatTheSpikeVerified` and `theNumberingIsNotContiguous` fail. Revert.

Change `isVerified` to `true`. Build, run again. Expected: `onlyTogglePlayPauseIsProven` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 379 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Media Tests/CreativeNotchCoreTests/MediaCommandTests.swift
git commit -m "feat: add MediaCommand, the MediaRemote transport constants"
```

---

### Task 2: `MediaRemoteBridge` — one `dlopen`, one call

The AppKit half. Shaped after `BrightnessObserver`: a `static let` handle resolved once, a `symbolsAvailable`-style availability check, and a typed function pointer.

The important design decision is what `send` returns. The spike found `SendCommand` returns `true` for commands that are **ignored**, and for a nonsense command id. Its return value is therefore not a success signal, and this type must not launder it into one. `send` returns `Void`; anything wanting to know whether playback actually changed would have to observe the system, which is the deferred metadata module's problem.

**Files:**
- Create: `Sources/CreativeNotchUI/Media/MediaRemoteBridge.swift`
- Create: `Tests/CreativeNotchUITests/MediaRemoteBridgeTests.swift`

**Interfaces:**
- Consumes: `MediaCommand` (Task 1).
- Produces:
  - `@MainActor enum MediaRemoteBridge` with `static var isAvailable: Bool` and `static func send(_ command: MediaCommand)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/MediaRemoteBridgeTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Resolving MediaRemote and sending a transport command.
///
/// **No test here sends a real command.** `MRMediaRemoteSendCommand`
/// actually changes playback on whatever application holds the media
/// session, and a test suite must not do that to the machine running it.
/// What is tested is that the framework resolves; that a command really
/// reaches a real player is covered by the spike
/// (`docs/research/2026-08-29-media-feasibility.md`), which ground-truthed
/// it against a live player and restored the state afterwards.
@MainActor
struct MediaRemoteBridgeTests {

    /// Not safe to assert bare: `dlopen`ing a private framework and
    /// resolving its symbols by name is unverified on a restricted or
    /// sandboxed host. Same treatment as `BrightnessObserver`'s
    /// DisplayServices check.
    @Test func theMediaRemoteSymbolResolves() {
        expectOrKnownHardwareIssue(
            MediaRemoteBridge.isAvailable,
            "MediaRemote is a private framework; dlopen/dlsym resolving it is unverified on a restricted or sandboxed host"
        )
    }

    /// Availability must not depend on having sent anything first, and
    /// must be stable across reads — the handle is resolved once and
    /// cached, so a second read that disagreed would mean the cache is
    /// being rebuilt per call.
    @Test func availabilityIsStableAcrossReads() {
        #expect(MediaRemoteBridge.isAvailable == MediaRemoteBridge.isAvailable)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MediaRemoteBridgeTests`
Expected: FAIL — `cannot find 'MediaRemoteBridge' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/Media/MediaRemoteBridge.swift`:

```swift
import AppKit
import CreativeNotchCore

/// Sends transport commands through the private MediaRemote framework.
///
/// There is no public API for controlling whatever application holds the
/// system media session. MediaRemote is not permission-gated for
/// *commands*: the spike confirmed `MRMediaRemoteSendCommand` takes effect
/// from an **ad-hoc-signed** binary, which is what this app ships as.
///
/// Reading now-playing *metadata* through the same framework **is** gated
/// by code-signing identifier and returns nothing to this process. That is
/// why this type sends and never reads, and why `TrackSnapshot` stays
/// unpopulated until the deferred metadata module exists. See
/// `docs/research/2026-08-29-media-feasibility.md`.
///
/// An `enum` with static members rather than a class: there is no state to
/// hold beyond the cached handle, and nothing to start or stop.
@MainActor
public enum MediaRemoteBridge {

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool

    /// Resolved once. `BrightnessObserver` holds its DisplayServices
    /// handle the same way — re-`dlopen`ing per call would buy nothing.
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_NOW
    )

    private static let sendCommand: SendCommand? = {
        guard let handle, let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    public static var isAvailable: Bool { sendCommand != nil }

    /// Sends `command` to whichever application holds the media session.
    ///
    /// Returns nothing, deliberately. `MRMediaRemoteSendCommand` returns a
    /// `Bool`, but the spike found it returns `true` for commands that are
    /// **ignored** by the receiving application, and `true` for a nonsense
    /// command id. It reports "dispatched", not "obeyed". Surfacing it
    /// would be handing callers a success signal that is not one, so it is
    /// discarded here rather than laundered upward.
    ///
    /// There is no in-process way to confirm a command took effect.
    /// Confirming it needs the now-playing state, which is gated.
    public static func send(_ command: MediaCommand) {
        guard let sendCommand else { return }
        _ = sendCommand(command.rawValue, nil)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MediaRemoteBridgeTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Prove the test bites**

Change the `dlsym` name to `"MRMediaRemoteSendCommandXX"`. Build, then run `swift test --filter MediaRemoteBridgeTests`. Expected: `theMediaRemoteSymbolResolves` is recorded as a known issue rather than a hard failure — read the output and confirm the issue is reported, which is what this helper is for. Revert.

Then verify the resolution is real rather than vacuous: temporarily add `#expect(MediaRemoteBridge.isAvailable)` as a bare assertion, run, and confirm it passes on this machine. Remove it again — the bare form is exactly what `expectOrKnownHardwareIssue` exists to avoid on CI.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 381 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchUI/Media Tests/CreativeNotchUITests/MediaRemoteBridgeTests.swift
git commit -m "feat: send transport commands through MediaRemote"
```

---

### Task 3: `MediaControlsView` — the three buttons

Rendering is not unit-tested in this project. What *is* tested is the button-to-command mapping, which is why `onCommand` is injected rather than the view calling `MediaRemoteBridge` directly: it keeps a real command out of the test suite while still proving the wiring.

**Files:**
- Create: `Sources/CreativeNotchUI/Media/MediaControlsView.swift`
- Create: `Tests/CreativeNotchUITests/MediaControlsTests.swift`

**Interfaces:**
- Consumes: `MediaCommand` (Task 1).
- Produces:
  - `struct MediaControlsView: View` with `init(onCommand: @escaping (MediaCommand) -> Void)`
  - `MediaControlsView.buttons: [(command: MediaCommand, symbol: String, label: String)]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/MediaControlsTests.swift`:

```swift
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The buttons, and what each one sends.
///
/// Views are not unit-tested here, so what is pinned is the mapping — the
/// part with a right answer, and the part where a copy-paste slip would
/// wire "next" to the previous-track command with nothing to catch it.
@MainActor
struct MediaControlsTests {

    @Test func thereAreThreeButtonsInTransportOrder() {
        #expect(MediaControlsView.buttons.map(\.command) == [
            .previousTrack, .togglePlayPause, .nextTrack,
        ])
    }

    /// Each button sends its own command and no other. A slip here is
    /// invisible on screen — the icons would still look right.
    @Test func eachButtonSendsADistinctCommand() {
        let commands = MediaControlsView.buttons.map(\.command)
        #expect(Set(commands).count == commands.count)
    }

    @Test func everyButtonHasASymbolAndALabel() {
        for button in MediaControlsView.buttons {
            #expect(button.symbol.isEmpty == false)
            #expect(button.label.isEmpty == false)
        }
    }

    /// Accessibility labels are how this is operated without sight, and
    /// the notch is small enough that the icons alone are ambiguous.
    @Test func theLabelsDescribeTheAction() {
        let labels = Dictionary(
            uniqueKeysWithValues: MediaControlsView.buttons.map { ($0.command, $0.label) }
        )
        #expect(labels[.previousTrack] == "Previous track")
        #expect(labels[.togglePlayPause] == "Play or pause")
        #expect(labels[.nextTrack] == "Next track")
    }

    /// The injected closure is what the panel wires to the bridge. If a
    /// button did not call it, the control would be dead on screen with
    /// nothing failing.
    @Test func tappingAButtonInvokesTheHandler() {
        var sent: [MediaCommand] = []
        let view = MediaControlsView { sent.append($0) }

        for button in MediaControlsView.buttons {
            view.onCommand(button.command)
        }

        #expect(sent == [.previousTrack, .togglePlayPause, .nextTrack])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MediaControlsTests`
Expected: FAIL — `cannot find 'MediaControlsView' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/Media/MediaControlsView.swift`:

```swift
import SwiftUI
import CreativeNotchCore

/// Play/pause, next and previous, for whatever holds the media session.
///
/// `onCommand` is injected rather than calling `MediaRemoteBridge`
/// directly. A real command changes playback on the machine running the
/// tests, so the suite must never send one — injecting the sink is what
/// lets the button-to-command mapping be proven without that.
///
/// There is no play/pause *state* here, and the icon does not change: this
/// module cannot read whether anything is playing, because that read is
/// code-signing gated. Hence one toggle button rather than separate play
/// and pause buttons — the app genuinely does not know which it would be.
struct MediaControlsView: View {

    /// In transport order, left to right, as they appear on every physical
    /// remote and media key row.
    static let buttons: [(command: MediaCommand, symbol: String, label: String)] = [
        (.previousTrack, "backward.fill", "Previous track"),
        (.togglePlayPause, "playpause.fill", "Play or pause"),
        (.nextTrack, "forward.fill", "Next track"),
    ]

    let onCommand: (MediaCommand) -> Void

    init(onCommand: @escaping (MediaCommand) -> Void) {
        self.onCommand = onCommand
    }

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Self.buttons, id: \.command) { button in
                Button {
                    onCommand(button.command)
                } label: {
                    Image(systemName: button.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(button.label)
            }
        }
        .padding(.top, 10)
    }
}
```

`MediaCommand` needs `Hashable` for `ForEach(id: \.command)`. It already is: `Int32` raw values give it for free through `RawRepresentable`, and `Equatable` is declared in Task 1. No change needed — but if the compiler disagrees, add `Hashable` to the declaration rather than switching to `id: \.symbol`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MediaControlsTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Prove the tests bite**

Swap `.previousTrack` and `.nextTrack` in `buttons`. Build, then run `swift test --filter MediaControlsTests`. Expected: `thereAreThreeButtonsInTransportOrder`, `theLabelsDescribeTheAction` and `tappingAButtonInvokesTheHandler` fail. Revert.

Change the `.nextTrack` row's command to `.previousTrack` — the copy-paste slip this suite exists to catch. Build, run again. Expected: `eachButtonSendsADistinctCommand` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 386 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchUI/Media/MediaControlsView.swift Tests/CreativeNotchUITests/MediaControlsTests.swift
git commit -m "feat: add the media transport buttons"
```

---

### Task 4: Wire it into the panel and the app

Spec section 5.4's layout note puts the media row at the top of the open panel, above the tab bar. That is where it goes — the same position the deferred metadata module will later fill with a title and artwork.

The row is hidden entirely when MediaRemote does not resolve. A dead control is worse than an absent one: the buttons would look identical and simply do nothing.

**Files:**
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift`
- Create: `Tests/CreativeNotchUITests/MediaWiringTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `AppState.onMediaCommand: ((MediaCommand) -> Void)?`
  - `AppState.showsMediaControls: Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/MediaWiringTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the buttons are actually connected to the bridge, rather than
/// merely existing next to it.
@MainActor
struct MediaWiringTests {

    /// The same literal `AppDelegateStateFunnelTests` uses.
    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchMediaWiring-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    /// Left unset, every media button would be dead on screen with nothing
    /// failing — the exact bug this test exists for.
    @Test func installingWiresTheMediaHandler() {
        #expect(makeDelegate().state.onMediaCommand != nil)
    }

    /// The row is hidden when the framework does not resolve. Buttons that
    /// look identical and do nothing are worse than no buttons.
    @Test func theControlsFollowAvailability() {
        #expect(makeDelegate().state.showsMediaControls == MediaRemoteBridge.isAvailable)
    }

    /// Sending must not depend on the panel being open, or on any tab
    /// being selected — the handler is set once at install.
    @Test func theHandlerSurvivesStateChanges() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.clipboard))
        delegate.state.transition(to: .closed)

        #expect(delegate.state.onMediaCommand != nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MediaWiringTests`
Expected: FAIL — `value of type 'AppState' has no member 'onMediaCommand'`.

- [ ] **Step 3: Add the hooks to `AppState`**

In `Sources/CreativeNotchUI/NotchRootView.swift`, beside `onPasteClipboard`:

```swift
    /// How the media buttons reach `MediaRemoteBridge`.
    ///
    /// A closure rather than calling the bridge from the view, for the
    /// same reason `onPasteClipboard` is one: it keeps a real transport
    /// command — which changes playback on the machine — out of anything
    /// a test constructs.
    @ObservationIgnored
    public var onMediaCommand: ((MediaCommand) -> Void)?

    /// Whether to show the media row at all.
    ///
    /// Set once at install from `MediaRemoteBridge.isAvailable`. Buttons
    /// that resolve to nothing would look identical to working ones and
    /// silently do nothing, which is worse than not offering them.
    @ObservationIgnored
    public var showsMediaControls: Bool = false
```

- [ ] **Step 4: Render the row**

In the same file, the `.open` case currently reads:

```swift
                case .open(let tab):
                    VStack(spacing: 0) {
                        PanelTabBar(selected: tab) { app.transition(to: .open($0)) }
                        openContent(for: tab)
                    }
```

Put the media row above the tab bar, per spec section 5.4's layout note:

```swift
                case .open(let tab):
                    VStack(spacing: 0) {
                        if app.showsMediaControls {
                            MediaControlsView { app.onMediaCommand?($0) }
                        }
                        PanelTabBar(selected: tab) { app.transition(to: .open($0)) }
                        openContent(for: tab)
                    }
```

- [ ] **Step 5: Wire `AppDelegate`**

In `Sources/CreativeNotchUI/AppDelegate.swift`, inside `install(metrics:)`, after the clipboard wiring:

```swift
        // No object to own: `MediaRemoteBridge` is stateless beyond its
        // cached handle, and there is nothing to start or stop. Unlike the
        // HUD and clipboard controllers it needs no lifecycle hook in
        // `applicationDidFinishLaunching` or `applicationWillTerminate` —
        // a command is sent only because a button was clicked.
        state.showsMediaControls = MediaRemoteBridge.isAvailable
        state.onMediaCommand = { command in MediaRemoteBridge.send(command) }
```

- [ ] **Step 6: Extend `CorePurityTests`**

`Media/` is a new Core subdirectory, and the recursion anchors name one file per subdirectory. Without an entry the check could silently stop scanning it, exactly as it once stopped scanning `HUD/` and `Shelf/`.

In `Tests/CreativeNotchCoreTests/CorePurityTests.swift`, add to `expectedInSubdirectories`:

```swift
            "MediaCommand.swift",
```

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 389 tests.

- [ ] **Step 8: Prove the wiring tests bite**

Delete the `state.onMediaCommand = ...` line. Build, then run `swift test --filter MediaWiringTests`. Expected: `installingWiresTheMediaHandler` and `theHandlerSurvivesStateChanges` fail. Revert.

Change `state.showsMediaControls = MediaRemoteBridge.isAvailable` to `= false`. Build, run again. Expected: `theControlsFollowAvailability` fails on a host where the framework resolves. Revert.

- [ ] **Step 9: Verify it works in the real app**

The suite deliberately never sends a command, so this step is the only thing that proves the module works end to end. It cannot be skipped.

```bash
./Scripts/dev.sh
```

Start playback in any player, then:

1. Open the panel. The three buttons appear above the tab bar.
2. Click play/pause — playback stops. Click again — it resumes.
3. Click next — the track changes. **This is the first real execution of `nextTrack`,** which the spike never sent. Confirm it moves forward, not backward.
4. Click previous — confirm it goes back.

⚠️ Check which application actually responds. The spike found a browser tab can hold the media session ahead of an obvious music app, so if nothing seems to happen, confirm what is holding it before concluding the module is broken.

If `nextTrack` or `previousTrack` misbehaves, the constants in `MediaCommand` are wrong — that is the one thing here that no test can catch, and the reason `isVerified` marks them as unproven.

- [ ] **Step 10: Update the documentation**

In `README.md`:

- Change the module table row to `| ✅ Media controls | Done |`.
- Add to the usage table:
  ```markdown
  | Click the media buttons in the panel | Controls whatever is playing |
  ```
- Update the test count to what `swift test` reports.
- In the Status prose, note that media controls ship **without** now-playing metadata, and why: the read is code-signing gated and needs a helper process, deferred to its own module.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: wire media transport controls into the panel"
```

---

## Definition of done

- [ ] `swift build` succeeds with no warnings.
- [ ] `swift test` passes; the suite has grown from 375 to roughly 389 tests.
- [ ] `CorePurityTests` passes with `MediaCommand.swift` among its recursion anchors.
- [ ] No test sends a real media command — `MediaRemoteBridge.send` appears in no test file.
- [ ] No new `Timer`, monitor, or subprocess exists. The clipboard poller is still the only timer in the codebase.
- [ ] No third-party code was added, and `Package.swift` has no new dependency.
- [ ] Every mutation listed under "Prove the tests bite" was performed, seen to fail, and reverted — with the build confirmed good first.
- [ ] **Task 4 Step 9 was actually performed in the running app**, including `nextTrack` and `previousTrack`, which no automated test covers.
- [ ] `README.md` marks the module done, states the real test count, and says metadata is not included.
- [ ] Spec section 5.4 matches what was built.

## Deliberately not built

- **Now-playing metadata** — title, artist, artwork. Gated by code-signing identifier; needs a `com.apple.*` helper process. Deferred to its own spike, spec and plan, starting from the unverified dylib-inheritance question in the research document.
- **The `.peek(.nowPlaying)` slot.** `PeekArbiter.setNowPlaying` exists and is tested, but `TrackSnapshot` needs a title and artist this module cannot obtain. It stays dormant rather than being fed a placeholder.
- **A play/pause state icon.** The button cannot reflect state, because reading whether anything is playing is gated. One toggle icon is honest; an icon that guessed would be wrong half the time.
- **Scrubbing, volume, or a position bar.** All need now-playing state.
- **Reacting to the media keys.** `MediaKeyMonitor` already observes them for HUD attribution and must stay observation-only — acting on them would duplicate what macOS already routes to the media session.
- **Any use of `SendCommand`'s return value.** It reports dispatch, not effect; treating it as success would be a lie the UI then tells the user.
