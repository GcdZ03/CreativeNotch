# CreativeNotch Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A running, ad-hoc-signed `CreativeNotch.app` that renders a panel anchored to the notch (or a pill on notchless Macs), peeks after a 300ms hover dwell, opens on click, follows the focused screen, and has a menu bar item plus first-launch onboarding.

**Architecture:** A Swift Package with two targets. `CreativeNotchCore` is AppKit-free pure logic — screen geometry, hit-test shapes, the state machine, peek arbitration — and is fully unit-tested. `CreativeNotch` is a thin executable holding the `NSPanel`, tracking areas, and menu bar, verified by hand. A bundling script assembles the `.app` and ad-hoc signs it.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Swift Testing, SwiftPM. No third-party dependencies.

**Spec:** `docs/specs/2026-08-22-creativenotch-design.md`

## Global Constraints

- Minimum platform: **macOS 26.0**. Declared as `.macOS("26.0")` in `Package.swift`.
- **No third-party dependencies.** Standard library, AppKit, SwiftUI, Swift Testing only.
- **`CreativeNotchCore` must never `import AppKit` or `import SwiftUI`.** It imports `CoreGraphics` and `Foundation` only. This is what keeps it testable headlessly in CI, and it is the single most important structural rule in this plan.
- **No polling.** No `Timer` that runs unconditionally, no global mouse monitor that is always installed. Hover uses `NSTrackingArea`; screen changes use notifications.
- Signing is **ad-hoc** (`codesign -s -`). Never reference a Developer ID or a team identifier.
- All new types in `CreativeNotchCore` are `public`, `Equatable`, and `Sendable`.
- Commit after every task. Conventional commit prefixes (`feat:`, `test:`, `chore:`).

---

### Task 1: Package skeleton and CI

Establishes the two-target package and switches CI from `xcodebuild` to `swift test`.

**Why SwiftPM rather than an `.xcodeproj`:** the pure logic is the tested part, and `swift test` runs it in seconds with no signing, no scheme, and no project file to regenerate whenever a source file is added. Xcode still opens `Package.swift` directly for editing, previews, and debugging. The `.app` bundle that macOS needs for TCC permissions is produced by a script in Task 5.

**Files:**
- Create: `Package.swift`
- Create: `Sources/CreativeNotchCore/Version.swift`
- Create: `Sources/CreativeNotch/main.swift`
- Create: `Tests/CreativeNotchCoreTests/VersionTests.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: targets `CreativeNotchCore` (library) and `CreativeNotch` (executable); `CreativeNotchCore.version -> String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CreativeNotchCoreTests/VersionTests.swift`:

```swift
import Testing
@testable import CreativeNotchCore

@Test func versionIsNonEmpty() {
    #expect(!CreativeNotchCore.version.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL — no `Package.swift`, so the package does not resolve.

- [ ] **Step 3: Write minimal implementation**

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CreativeNotch",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CreativeNotchCore"),
        .executableTarget(
            name: "CreativeNotch",
            dependencies: ["CreativeNotchCore"]
        ),
        .testTarget(
            name: "CreativeNotchCoreTests",
            dependencies: ["CreativeNotchCore"]
        ),
    ]
)
```

Create `Sources/CreativeNotchCore/Version.swift`:

```swift
/// Namespace for the pure-logic core. Deliberately AppKit-free.
public enum CreativeNotchCore {
    public static let version = "0.1.0"
}
```

Create `Sources/CreativeNotch/main.swift`:

```swift
import CreativeNotchCore

print("CreativeNotch \(CreativeNotchCore.version)")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS — 1 test passing.

Also run: `swift run CreativeNotch`
Expected: prints `CreativeNotch 0.1.0`.

- [ ] **Step 5: Switch CI to SwiftPM**

Replace `.github/workflows/ci.yml` entirely:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-test:
    runs-on: macos-latest

    steps:
      - uses: actions/checkout@v4

      - name: Toolchain
        run: |
          sw_vers
          swift --version

      - name: Build
        run: swift build -v

      - name: Test
        run: swift test -v
```

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests .github/workflows/ci.yml
git commit -m "feat: SwiftPM package skeleton with Core/executable split"
git push origin main
```

Verify the run is green: `gh run watch --exit-status`

---

### Task 2: Screen geometry — notch and pill anchors

The abstraction that makes cross-device support one UI instead of two.

**Files:**
- Create: `Sources/CreativeNotchCore/ScreenMetrics.swift`
- Create: `Sources/CreativeNotchCore/Anchor.swift`
- Create: `Sources/CreativeNotchCore/NotchGeometry.swift`
- Create: `Tests/CreativeNotchCoreTests/NotchGeometryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ScreenMetrics(frame:safeAreaTopInset:auxiliaryTopLeftWidth:auxiliaryTopRightWidth:menuBarHeight:)`
  - `Anchor.notch(CGRect)` / `Anchor.pill(CGRect)`, with `.rect -> CGRect`
  - `NotchGeometry.anchor(for: ScreenMetrics) -> Anchor`
  - `NotchGeometry.panelFrame(for: Anchor, in: ScreenMetrics) -> CGRect`
  - Constants `NotchGeometry.pillSize`, `.pillTopGap`, `.expandedSize`

Note: macOS screen coordinates are **bottom-left origin, y increasing upward**. `frame.maxY` is the top edge of the screen.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/NotchGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import CreativeNotchCore

// A notched MacBook: 1470x956pt, 38pt notch inset, 620pt of menu bar
// usable on each side of the notch.
private let notched = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
    safeAreaTopInset: 38,
    auxiliaryTopLeftWidth: 620,
    auxiliaryTopRightWidth: 620,
    menuBarHeight: 38
)

// An external display: no safe area, no auxiliary areas.
private let external = ScreenMetrics(
    frame: CGRect(x: 1470, y: 0, width: 2560, height: 1440),
    safeAreaTopInset: 0,
    auxiliaryTopLeftWidth: 0,
    auxiliaryTopRightWidth: 0,
    menuBarHeight: 24
)

@Test func notchedScreenProducesNotchAnchor() {
    guard case .notch(let r) = NotchGeometry.anchor(for: notched) else {
        Issue.record("expected .notch"); return
    }
    #expect(r.width == 230)          // 1470 - (620 + 620)
    #expect(r.height == 38)
    #expect(r.minX == 620)
    #expect(r.maxY == 956)           // flush with the top of the screen
}

@Test func externalScreenProducesPillAnchor() {
    guard case .pill(let r) = NotchGeometry.anchor(for: external) else {
        Issue.record("expected .pill"); return
    }
    #expect(r.size == NotchGeometry.pillSize)
    #expect(r.midX == external.frame.midX)
    #expect(r.maxY == 1440 - 24 - NotchGeometry.pillTopGap)
}

@Test func zeroAuxiliaryWidthsFallBackToPill() {
    // A safe-area inset with no auxiliary areas is not a usable notch.
    let odd = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 38
    )
    guard case .pill = NotchGeometry.anchor(for: odd) else {
        Issue.record("expected .pill"); return
    }
}

@Test func panelIsCenteredOnAnchorAndTopAligned() {
    let anchor = NotchGeometry.anchor(for: notched)
    let frame = NotchGeometry.panelFrame(for: anchor, in: notched)
    #expect(frame.width == NotchGeometry.expandedSize.width)
    #expect(frame.height == NotchGeometry.expandedSize.height)
    #expect(frame.midX == anchor.rect.midX)
    #expect(frame.maxY == anchor.rect.maxY)
}

@Test func panelIsClampedToScreenBounds() {
    // A pill hard against the left edge must not push the panel off-screen.
    let narrow = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 24
    )
    let anchor = Anchor.pill(CGRect(x: 0, y: 560, width: 180, height: 32))
    let frame = NotchGeometry.panelFrame(for: anchor, in: narrow)
    #expect(frame.minX >= narrow.frame.minX)
    #expect(frame.maxX <= narrow.frame.maxX)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotchGeometryTests`
Expected: FAIL — `cannot find 'ScreenMetrics' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/ScreenMetrics.swift`:

```swift
import CoreGraphics

/// A pure snapshot of the parts of `NSScreen` that geometry depends on.
///
/// Keeping this AppKit-free is what allows `NotchGeometry` to be tested
/// headlessly. The executable target populates it from a real `NSScreen`.
public struct ScreenMetrics: Equatable, Sendable {
    public var frame: CGRect
    public var safeAreaTopInset: CGFloat
    public var auxiliaryTopLeftWidth: CGFloat
    public var auxiliaryTopRightWidth: CGFloat
    public var menuBarHeight: CGFloat

    public init(
        frame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftWidth: CGFloat,
        auxiliaryTopRightWidth: CGFloat,
        menuBarHeight: CGFloat
    ) {
        self.frame = frame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
        self.menuBarHeight = menuBarHeight
    }
}
```

Create `Sources/CreativeNotchCore/Anchor.swift`:

```swift
import CoreGraphics

/// Where the panel attaches on a given screen.
///
/// `.notch` is real hardware. `.pill` is synthesised below the menu bar on
/// notchless Macs and external displays — deliberately *not* a fake black
/// notch, which is the thing reviewers single out as jarring in NotchNook.
public enum Anchor: Equatable, Sendable {
    case notch(CGRect)
    case pill(CGRect)

    public var rect: CGRect {
        switch self {
        case .notch(let r), .pill(let r): return r
        }
    }

    public var isNotch: Bool {
        if case .notch = self { return true }
        return false
    }
}
```

Create `Sources/CreativeNotchCore/NotchGeometry.swift`:

```swift
import CoreGraphics

public enum NotchGeometry {
    public static let pillSize = CGSize(width: 180, height: 32)
    public static let pillTopGap: CGFloat = 8
    public static let expandedSize = CGSize(width: 620, height: 260)

    /// Resolves the anchor for a screen. Real notch when the hardware has
    /// one, a synthesised pill otherwise.
    public static func anchor(for m: ScreenMetrics) -> Anchor {
        let auxWidth = m.auxiliaryTopLeftWidth + m.auxiliaryTopRightWidth
        if m.safeAreaTopInset > 0, auxWidth > 0, auxWidth < m.frame.width {
            return .notch(CGRect(
                x: m.frame.minX + m.auxiliaryTopLeftWidth,
                y: m.frame.maxY - m.safeAreaTopInset,
                width: m.frame.width - auxWidth,
                height: m.safeAreaTopInset
            ))
        }
        return .pill(CGRect(
            x: m.frame.midX - pillSize.width / 2,
            y: m.frame.maxY - m.menuBarHeight - pillTopGap - pillSize.height,
            width: pillSize.width,
            height: pillSize.height
        ))
    }

    /// The window frame. Always the fully-expanded size so the window never
    /// resizes — content animates inside it instead, which avoids resize
    /// jank. The cost is a large transparent rect, which `NotchShape`
    /// handles via hit-testing.
    public static func panelFrame(for anchor: Anchor, in m: ScreenMetrics) -> CGRect {
        let width = max(expandedSize.width, anchor.rect.width)
        let height = expandedSize.height
        let unclampedX = anchor.rect.midX - width / 2
        let x = min(max(unclampedX, m.frame.minX), m.frame.maxX - width)
        return CGRect(x: x, y: anchor.rect.maxY - height, width: width, height: height)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NotchGeometryTests`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CreativeNotchCore Tests/CreativeNotchCoreTests
git commit -m "feat: notch/pill anchor resolution and panel framing"
```

---

### Task 3: Hit-test shapes

The panel is a large transparent rectangle. Without this, it swallows every menu bar click in a 620pt band. This is the fiddliest part of the app, which is exactly why the geometry is pure and tested here rather than buried in an `NSView`.

**Files:**
- Create: `Sources/CreativeNotchCore/NotchShape.swift`
- Create: `Tests/CreativeNotchCoreTests/NotchShapeTests.swift`
- Modify: `Sources/CreativeNotchCore/NotchGeometry.swift` (add `peekSize`)

**Interfaces:**
- Consumes: `Anchor`, `NotchGeometry`, `NotchState` (defined in Task 4 — this task uses a local `Presentation` enum instead to avoid the dependency).
- Produces:
  - `NotchShape.Presentation` — `.closed`, `.peek`, `.expanded`
  - `NotchShape.visibleRect(presentation:anchor:panelFrame:) -> CGRect` in **panel-local, bottom-left-origin** coordinates
  - `NotchShape.contains(_:presentation:anchor:panelFrame:) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/NotchShapeTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import CreativeNotchCore

private let anchor = Anchor.notch(
    CGRect(x: 620, y: 918, width: 230, height: 38)
)
private let panel = CGRect(x: 415, y: 696, width: 620, height: 260)

@Test func closedVisibleRectMatchesTheAnchorExactly() {
    let r = NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel)
    #expect(r.width == 230)
    #expect(r.height == 38)
    #expect(r.minX == 205)      // 620 - 415
    #expect(r.maxY == 260)      // flush with the panel's top edge
}

@Test func peekIsWiderThanClosedAndStillTopAligned() {
    let r = NotchShape.visibleRect(presentation: .peek, anchor: anchor, panelFrame: panel)
    #expect(r.width == NotchGeometry.peekSize.width)
    #expect(r.height == NotchGeometry.peekSize.height)
    #expect(r.maxY == 260)
    #expect(r.midX == 320)      // centred on the anchor: 205 + 230/2
}

@Test func expandedFillsThePanel() {
    let r = NotchShape.visibleRect(presentation: .expanded, anchor: anchor, panelFrame: panel)
    #expect(r == CGRect(origin: .zero, size: panel.size))
}

@Test func clickBesideTheClosedNotchPassesThrough() {
    // A point in the menu bar, level with the notch but well to its left.
    let p = CGPoint(x: 20, y: 250)
    #expect(!NotchShape.contains(p, presentation: .closed, anchor: anchor, panelFrame: panel))
}

@Test func clickInsideTheClosedNotchIsCaptured() {
    let p = CGPoint(x: 320, y: 250)
    #expect(NotchShape.contains(p, presentation: .closed, anchor: anchor, panelFrame: panel))
}

@Test func clickBelowTheClosedNotchPassesThrough() {
    // Directly under the notch but below its 38pt height — desktop, not us.
    let p = CGPoint(x: 320, y: 100)
    #expect(!NotchShape.contains(p, presentation: .closed, anchor: anchor, panelFrame: panel))
}

@Test func sameClickIsCapturedWhenExpanded() {
    let p = CGPoint(x: 320, y: 100)
    #expect(NotchShape.contains(p, presentation: .expanded, anchor: anchor, panelFrame: panel))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotchShapeTests`
Expected: FAIL — `cannot find 'NotchShape' in scope`.

- [ ] **Step 3: Add the peek size constant**

In `Sources/CreativeNotchCore/NotchGeometry.swift`, add below `pillTopGap`:

```swift
    public static let peekSize = CGSize(width: 320, height: 44)
```

- [ ] **Step 4: Write the implementation**

Create `Sources/CreativeNotchCore/NotchShape.swift`:

```swift
import CoreGraphics

/// The visible region of the panel, in panel-local coordinates.
///
/// The window is always the full expanded size, so everything outside this
/// rect must pass clicks through to whatever is underneath — otherwise the
/// panel eats menu bar clicks across a 620pt band.
public enum NotchShape {

    /// How much of the panel is currently drawn. Deliberately coarser than
    /// `NotchState`: `.receiving` and `.open` are both `.expanded` here.
    public enum Presentation: Equatable, Sendable {
        case closed
        case peek
        case expanded
    }

    /// Panel-local, bottom-left origin, y increasing upward — matching an
    /// unflipped `NSView`.
    public static func visibleRect(
        presentation: Presentation,
        anchor: Anchor,
        panelFrame: CGRect
    ) -> CGRect {
        let local = CGRect(
            x: anchor.rect.minX - panelFrame.minX,
            y: anchor.rect.minY - panelFrame.minY,
            width: anchor.rect.width,
            height: anchor.rect.height
        )

        switch presentation {
        case .closed:
            return local

        case .peek:
            let size = NotchGeometry.peekSize
            return CGRect(
                x: local.midX - size.width / 2,
                y: local.maxY - size.height,
                width: size.width,
                height: size.height
            )

        case .expanded:
            return CGRect(origin: .zero, size: panelFrame.size)
        }
    }

    public static func contains(
        _ point: CGPoint,
        presentation: Presentation,
        anchor: Anchor,
        panelFrame: CGRect
    ) -> Bool {
        visibleRect(presentation: presentation, anchor: anchor, panelFrame: panelFrame)
            .contains(point)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter NotchShapeTests`
Expected: PASS — 7 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore Tests/CreativeNotchCoreTests
git commit -m "feat: hit-test shapes so the panel only captures its visible region"
```

---

### Task 4: State machine and peek arbitration

**Files:**
- Create: `Sources/CreativeNotchCore/NotchState.swift`
- Create: `Sources/CreativeNotchCore/PeekArbiter.swift`
- Create: `Tests/CreativeNotchCoreTests/PeekArbiterTests.swift`

**Interfaces:**
- Consumes: `NotchShape.Presentation`.
- Produces:
  - `Tab` — `.shelf`, `.clipboard`, `.hud`
  - `TrackSnapshot(title:artist:isPlaying:)`
  - `HUDEvent(kind:)` with `HUDKind` — `.volume(Double)`, `.brightness(Double)`, `.mute(Bool)`
  - `PeekContent` — `.hud(HUDEvent)`, `.dragTarget`, `.nowPlaying(TrackSnapshot)`
  - `NotchState` — `.closed`, `.peek(PeekContent)`, `.open(Tab)`, `.receiving`, with `.presentation -> NotchShape.Presentation`
  - `PeekArbiter` — `recordHUD(_:now:)`, `setDragActive(_:)`, `setNowPlaying(_:)`, `content(now:) -> PeekContent?`, `static hudTTL`

`content(now:)` takes the current time as a **parameter** rather than reading a clock. That is what makes TTL expiry testable without sleeping.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/PeekArbiterTests.swift`:

```swift
import Testing
@testable import CreativeNotchCore

private let track = TrackSnapshot(title: "Song", artist: "Artist", isPlaying: true)
private let volumeUp = HUDEvent(kind: .volume(0.6))

@Test func emptyArbiterShowsNothing() {
    let a = PeekArbiter()
    #expect(a.content(now: 0) == nil)
}

@Test func playingTrackIsShownAsAmbient() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    #expect(a.content(now: 0) == .nowPlaying(track))
}

@Test func pausedTrackIsNotShown() {
    var a = PeekArbiter()
    a.setNowPlaying(TrackSnapshot(title: "Song", artist: "Artist", isPlaying: false))
    #expect(a.content(now: 0) == nil)
}

@Test func hudPreemptsAmbientMedia() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.recordHUD(volumeUp, now: 100)
    #expect(a.content(now: 100.5) == .hud(volumeUp))
}

@Test func hudExpiresAndFallsBackToMedia() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.recordHUD(volumeUp, now: 100)
    #expect(a.content(now: 100 + PeekArbiter.hudTTL + 0.01) == .nowPlaying(track))
}

@Test func hudExpiresToNothingWhenNoMedia() {
    var a = PeekArbiter()
    a.recordHUD(volumeUp, now: 100)
    #expect(a.content(now: 200) == nil)
}

@Test func dragPreemptsEverything() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.recordHUD(volumeUp, now: 100)
    a.setDragActive(true)
    #expect(a.content(now: 100.1) == .dragTarget)
}

@Test func dragHasNoTimeoutOfItsOwn() {
    var a = PeekArbiter()
    a.setDragActive(true)
    #expect(a.content(now: 99_999) == .dragTarget)
}

@Test func clearingDragRestoresWhateverWasUnderneath() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.setDragActive(true)
    a.setDragActive(false)
    #expect(a.content(now: 0) == .nowPlaying(track))
}

@Test func stateMapsToPresentation() {
    #expect(NotchState.closed.presentation == .closed)
    #expect(NotchState.peek(.dragTarget).presentation == .peek)
    #expect(NotchState.open(.clipboard).presentation == .expanded)
    #expect(NotchState.receiving.presentation == .expanded)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PeekArbiterTests`
Expected: FAIL — `cannot find 'PeekArbiter' in scope`.

- [ ] **Step 3: Write the state types**

Create `Sources/CreativeNotchCore/NotchState.swift`:

```swift
import Foundation

public enum Tab: String, CaseIterable, Equatable, Sendable {
    case shelf, clipboard, hud
}

public struct TrackSnapshot: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var isPlaying: Bool

    public init(title: String, artist: String, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
    }
}

public enum HUDKind: Equatable, Sendable {
    case volume(Double)
    case brightness(Double)
    case mute(Bool)
}

public struct HUDEvent: Equatable, Sendable {
    public var kind: HUDKind

    public init(kind: HUDKind) { self.kind = kind }
}

/// What occupies the single peek slot.
public enum PeekContent: Equatable, Sendable {
    case hud(HUDEvent)
    case dragTarget
    case nowPlaying(TrackSnapshot)
}

/// The one state the panel is ever in.
public enum NotchState: Equatable, Sendable {
    case closed
    case peek(PeekContent)
    case open(Tab)
    case receiving

    public var presentation: NotchShape.Presentation {
        switch self {
        case .closed:            return .closed
        case .peek:              return .peek
        case .open, .receiving:  return .expanded
        }
    }
}
```

- [ ] **Step 4: Write the arbiter**

Create `Sources/CreativeNotchCore/PeekArbiter.swift`:

```swift
import Foundation

/// Decides what occupies the peek slot.
///
/// Transient sources preempt ambient ones, then fall back — the same model
/// as the iPhone Dynamic Island. Priority is drag, then HUD, then media.
///
/// `content(now:)` takes the time as a parameter rather than reading a
/// clock so TTL expiry is testable without sleeping.
public struct PeekArbiter: Equatable, Sendable {

    public static let hudTTL: TimeInterval = 1.5

    private var hud: HUDEvent?
    private var hudExpiry: TimeInterval = 0
    private var dragActive = false
    private var nowPlaying: TrackSnapshot?

    public init() {}

    public mutating func recordHUD(_ event: HUDEvent, now: TimeInterval) {
        hud = event
        hudExpiry = now + Self.hudTTL
    }

    public mutating func setDragActive(_ active: Bool) {
        dragActive = active
    }

    public mutating func setNowPlaying(_ track: TrackSnapshot?) {
        nowPlaying = track
    }

    public func content(now: TimeInterval) -> PeekContent? {
        if dragActive { return .dragTarget }
        if let hud, now < hudExpiry { return .hud(hud) }
        if let nowPlaying, nowPlaying.isPlaying { return .nowPlaying(nowPlaying) }
        return nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — all tests across all three suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore Tests/CreativeNotchCoreTests
git commit -m "feat: notch state machine and peek arbitration"
git push origin main
```

---

### Task 5: The panel on screen, and a runnable .app

First task with a visible result. Verified by hand, not by tests.

**Files:**
- Delete: `Sources/CreativeNotch/main.swift`
- Create: `Sources/CreativeNotch/App.swift`
- Create: `Sources/CreativeNotch/NotchPanel.swift`
- Create: `Sources/CreativeNotch/HitTestingHostingView.swift`
- Create: `Sources/CreativeNotch/NotchRootView.swift`
- Create: `Sources/CreativeNotch/ScreenMetrics+AppKit.swift`
- Create: `Scripts/bundle.sh`
- Create: `Resources/Info.plist`

**Interfaces:**
- Consumes: `Anchor`, `NotchGeometry`, `NotchShape`, `NotchState` from Task 2–4.
- Produces:
  - `NSScreen.metrics -> ScreenMetrics`
  - `NotchPanel(contentRect:)`
  - `HitTestingHostingView<Content>` with `visibleRectProvider: () -> CGRect`
  - `AppState` — an `@Observable` holding `state: NotchState` and `anchor: Anchor`
  - `Scripts/bundle.sh` producing `dist/CreativeNotch.app`

- [ ] **Step 1: Bridge NSScreen to ScreenMetrics**

Create `Sources/CreativeNotch/ScreenMetrics+AppKit.swift`:

```swift
import AppKit
import CreativeNotchCore

extension NSScreen {
    /// Snapshots this screen into the AppKit-free value type the core uses.
    var metrics: ScreenMetrics {
        ScreenMetrics(
            frame: frame,
            safeAreaTopInset: safeAreaInsets.top,
            auxiliaryTopLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryTopRightWidth: auxiliaryTopRightArea?.width ?? 0,
            menuBarHeight: NSApplication.shared.mainMenu?.menuBarHeight ?? 24
        )
    }
}
```

- [ ] **Step 2: Write the panel**

Create `Sources/CreativeNotch/NotchPanel.swift`:

```swift
import AppKit

/// A non-activating, borderless panel pinned above the menu bar.
///
/// `.fullScreenAuxiliary` is deliberately absent from `collectionBehavior`.
/// That single omission is what hides the panel entirely over fullscreen
/// apps — no frontmost-window detection, no edge cases.
final class NotchPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
}
```

- [ ] **Step 3: Write the hit-testing host view**

Create `Sources/CreativeNotch/HitTestingHostingView.swift`:

```swift
import AppKit
import SwiftUI

/// Passes clicks through everywhere except the currently-visible shape.
///
/// Without this the panel is a 620x260 transparent rectangle that swallows
/// every menu bar click behind it.
final class HitTestingHostingView<Content: View>: NSHostingView<Content> {

    /// Panel-local, bottom-left origin. Supplied by the controller so this
    /// view holds no geometry logic of its own.
    var visibleRectProvider: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard visibleRectProvider().contains(local) else { return nil }
        return super.hitTest(point)
    }
}
```

- [ ] **Step 4: Write the root view and app state**

Create `Sources/CreativeNotch/NotchRootView.swift`:

```swift
import SwiftUI
import CreativeNotchCore

@Observable
final class AppState {
    var state: NotchState = .closed
    var anchor: Anchor = .pill(.zero)
}

struct NotchRootView: View {
    @Bindable var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            shape
                .frame(width: width, height: height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: app.state)
    }

    private var shape: some View {
        RoundedRectangle(cornerRadius: app.anchor.isNotch && app.state == .closed ? 0 : 14)
            .fill(.black)
            .overlay {
                if app.state != .closed {
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
    }

    private var label: String {
        switch app.state {
        case .closed:          return ""
        case .peek:            return "CreativeNotch"
        case .open(let tab):   return tab.rawValue.capitalized
        case .receiving:       return "Drop here"
        }
    }

    private var width: CGFloat {
        switch app.state.presentation {
        case .closed:   return app.anchor.rect.width
        case .peek:     return NotchGeometry.peekSize.width
        case .expanded: return NotchGeometry.expandedSize.width
        }
    }

    private var height: CGFloat {
        switch app.state.presentation {
        case .closed:   return app.anchor.rect.height
        case .peek:     return NotchGeometry.peekSize.height
        case .expanded: return NotchGeometry.expandedSize.height
        }
    }
}
```

- [ ] **Step 5: Write the app entry point**

Delete `Sources/CreativeNotch/main.swift`, then create `Sources/CreativeNotch/App.swift`:

```swift
import AppKit
import SwiftUI
import CreativeNotchCore

@main
struct CreativeNotchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var hostView: HitTestingHostingView<NotchRootView>?
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        install(on: screen)
    }

    private func install(on screen: NSScreen) {
        let metrics = screen.metrics
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)

        state.anchor = anchor

        let panel = NotchPanel(contentRect: frame)
        let host = HitTestingHostingView(rootView: NotchRootView(app: state))
        host.visibleRectProvider = { [weak self] in
            guard let self else { return .zero }
            return NotchShape.visibleRect(
                presentation: self.state.state.presentation,
                anchor: anchor,
                panelFrame: frame
            )
        }

        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostView = host
    }
}
```

- [ ] **Step 6: Write Info.plist and the bundling script**

Create `Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CreativeNotch</string>
  <key>CFBundleDisplayName</key><string>CreativeNotch</string>
  <key>CFBundleExecutable</key><string>CreativeNotch</string>
  <key>CFBundleIdentifier</key><string>com.gcdz.creativenotch</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

Create `Scripts/bundle.sh`:

```bash
#!/usr/bin/env bash
# Builds CreativeNotch.app and ad-hoc signs it.
#
# Ad-hoc signing is mandatory on Apple Silicon — an unsigned arm64 binary
# will not launch at all — and unlike a development certificate it carries
# no device restrictions, so the same bundle runs on any Mac.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/CreativeNotch.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CreativeNotch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CreativeNotch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign -s - --force --timestamp=none "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'

echo "built $APP"
```

Then: `chmod +x Scripts/bundle.sh`

- [ ] **Step 7: Build and verify by hand**

Run:

```bash
./Scripts/bundle.sh
open dist/CreativeNotch.app
```

Expected, on the MacBook Air:
- A black rectangle sits exactly over the notch, indistinguishable from it.
- No Dock icon appears.
- **Clicking the menu bar to the left and right of the notch still works** — this is the hit-test check, and the whole reason Task 3 exists.
- `codesign -dv` reports `Signature=adhoc`.

To quit: `pkill -f CreativeNotch`

- [ ] **Step 8: Commit**

```bash
git add Sources/CreativeNotch Scripts Resources
git rm --cached Sources/CreativeNotch/main.swift 2>/dev/null || true
git commit -m "feat: notch panel renders on screen, ad-hoc signed app bundle"
git push origin main
```

---

### Task 6: Hover dwell, click to open, and screen following

**Files:**
- Create: `Sources/CreativeNotch/HoverTracker.swift`
- Modify: `Sources/CreativeNotch/App.swift`
- Modify: `Sources/CreativeNotch/HitTestingHostingView.swift`

**Interfaces:**
- Consumes: `AppState`, `NotchShape`, `NotchGeometry`.
- Produces: `HoverTracker` with `onDwell: () -> Void`, `onExit: () -> Void`, and `updateTrackingRect(_:)`.

- [ ] **Step 1: Write the hover tracker**

Create `Sources/CreativeNotch/HoverTracker.swift`:

```swift
import AppKit

/// Hover detection via `NSTrackingArea` on the panel itself — never a global
/// mouse monitor, so it costs nothing when the cursor is elsewhere.
///
/// A 300ms dwell is required before peeking. The notch sits directly on the
/// path to the menu bar and the traffic lights, so a deliberate pause is
/// what separates intent from a cursor passing through.
final class HoverTracker: NSView {

    static let dwell: Duration = .milliseconds(300)

    var onDwell: () -> Void = {}
    var onExit: () -> Void = {}

    private var trackingRect: CGRect = .zero
    private var dwellTask: Task<Void, Never>?

    func updateTrackingRect(_ rect: CGRect) {
        trackingRect = rect
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard !trackingRect.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            self?.onDwell()
        }
    }

    override func mouseExited(with event: NSEvent) {
        dwellTask?.cancel()
        dwellTask = nil
        onExit()
    }

    override func mouseDown(with event: NSEvent) {
        dwellTask?.cancel()
        super.mouseDown(with: event)
    }
}
```

- [ ] **Step 2: Wire hover and click into the app delegate**

Replace the body of `install(on:)` in `Sources/CreativeNotch/App.swift` with:

```swift
    private func install(on screen: NSScreen) {
        let metrics = screen.metrics
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)

        state.anchor = anchor
        currentAnchor = anchor
        currentFrame = frame

        let panel = NotchPanel(contentRect: frame)

        let host = HitTestingHostingView(rootView: NotchRootView(app: state))
        host.visibleRectProvider = { [weak self] in self?.visibleRect() ?? .zero }

        let hover = HoverTracker(frame: CGRect(origin: .zero, size: frame.size))
        hover.autoresizingMask = [.width, .height]
        hover.onDwell = { [weak self] in self?.peek() }
        hover.onExit  = { [weak self] in self?.collapse() }
        hover.updateTrackingRect(visibleRect())

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.addSubview(host)
        container.addSubview(hover)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]

        panel.contentView = container
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostView = host
        self.hoverView = hover

        observeScreenChanges()
    }

    private func visibleRect() -> CGRect {
        NotchShape.visibleRect(
            presentation: state.state.presentation,
            anchor: currentAnchor,
            panelFrame: currentFrame
        )
    }

    private func peek() {
        guard state.state == .closed else { return }
        state.state = .peek(.nowPlaying(
            TrackSnapshot(title: "CreativeNotch", artist: "", isPlaying: true)
        ))
        hoverView?.updateTrackingRect(visibleRect())
    }

    private func collapse() {
        guard case .open = state.state else {
            state.state = .closed
            hoverView?.updateTrackingRect(visibleRect())
            return
        }
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let screen = NSScreen.main else { return }
            self.reposition(on: screen)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let screen = NSScreen.main else { return }
            self.reposition(on: screen)
        }
    }

    private func reposition(on screen: NSScreen) {
        let metrics = screen.metrics
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)
        currentAnchor = anchor
        currentFrame = frame
        state.anchor = anchor
        panel?.setFrame(frame, display: true)
        hoverView?.updateTrackingRect(visibleRect())
    }
```

And add these stored properties to `AppDelegate`:

```swift
    private var hoverView: HoverTracker?
    private var currentAnchor: Anchor = .pill(.zero)
    private var currentFrame: CGRect = .zero
```

- [ ] **Step 3: Add click-to-open**

In `Sources/CreativeNotch/NotchRootView.swift`, add to `shape`, after `.overlay { ... }`:

```swift
            .onTapGesture {
                switch app.state {
                case .open:  app.state = .closed
                default:     app.state = .open(.shelf)
                }
            }
```

- [ ] **Step 4: Rebuild and verify by hand**

Run:

```bash
pkill -f CreativeNotch || true
./Scripts/bundle.sh && open dist/CreativeNotch.app
```

Expected:
- Moving the cursor **through** the notch quickly does nothing.
- **Pausing** on the notch for ~300ms expands it to the peek size.
- Moving away collapses it.
- Clicking opens the full panel showing "Shelf"; clicking again closes it.
- Menu bar clicks either side of the notch still work at every state.

- [ ] **Step 5: Commit**

```bash
git add Sources/CreativeNotch
git commit -m "feat: 300ms hover dwell, click to open, focused-screen following"
git push origin main
```

---

### Task 7: Menu bar item

**Files:**
- Create: `Sources/CreativeNotch/MenuBarController.swift`
- Modify: `Sources/CreativeNotch/App.swift`

**Interfaces:**
- Consumes: `AppState`.
- Produces: `MenuBarController(state:)` with `install()`.

- [ ] **Step 1: Write the controller**

Create `Sources/CreativeNotch/MenuBarController.swift`:

```swift
import AppKit
import CreativeNotchCore

/// The only settings surface. A four-module personal tool does not need a
/// preferences window.
@MainActor
final class MenuBarController {

    private var item: NSStatusItem?
    private let state: AppState
    private let onShowOnboarding: () -> Void

    init(state: AppState, onShowOnboarding: @escaping () -> Void) {
        self.state = state
        self.onShowOnboarding = onShowOnboarding
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "CreativeNotch"
        )

        let menu = NSMenu()

        let accessibility = NSMenuItem(
            title: accessibilityTitle(),
            action: #selector(openOnboarding),
            keyEquivalent: ""
        )
        accessibility.target = self
        menu.addItem(accessibility)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit CreativeNotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        self.item = item
    }

    private func accessibilityTitle() -> String {
        AXIsProcessTrusted()
            ? "Accessibility: granted"
            : "Accessibility: not granted — set up…"
    }

    @objc private func openOnboarding() {
        onShowOnboarding()
    }
}
```

- [ ] **Step 2: Install it at launch**

In `Sources/CreativeNotch/App.swift`, add a stored property to `AppDelegate`:

```swift
    private var menuBar: MenuBarController?
```

And at the end of `applicationDidFinishLaunching(_:)`:

```swift
        let menuBar = MenuBarController(state: state) { [weak self] in
            self?.showOnboarding()
        }
        menuBar.install()
        self.menuBar = menuBar
```

Add a temporary stub — Task 8 replaces it:

```swift
    func showOnboarding() {}
```

- [ ] **Step 3: Rebuild and verify by hand**

```bash
pkill -f CreativeNotch || true
./Scripts/bundle.sh && open dist/CreativeNotch.app
```

Expected: a status item appears in the menu bar; its menu shows the Accessibility status and Quit; Quit terminates the app.

- [ ] **Step 4: Commit**

```bash
git add Sources/CreativeNotch
git commit -m "feat: menu bar item with accessibility status and quit"
git push origin main
```

---

### Task 8: First-launch onboarding and Accessibility

**Files:**
- Create: `Sources/CreativeNotch/OnboardingWindow.swift`
- Create: `Sources/CreativeNotch/Permissions.swift`
- Modify: `Sources/CreativeNotch/App.swift`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: nothing from Core.
- Produces:
  - `Permissions.isAccessibilityTrusted -> Bool`
  - `Permissions.requestAccessibility()`
  - `Permissions.openAccessibilitySettings()`
  - `OnboardingController.showIfNeeded()` / `.show()`

- [ ] **Step 1: Write the permissions helper**

Create `Sources/CreativeNotch/Permissions.swift`:

```swift
import AppKit
import ApplicationServices

/// Accessibility is needed for two things: global key events for the HUD
/// module, and drag detection for the shelf. Clipboard and the shelf drop
/// target need no permission and always work.
enum Permissions {

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt. Only call this from onboarding, where the
    /// user has just been told why it is needed.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Write the onboarding window**

Create `Sources/CreativeNotch/OnboardingWindow.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class OnboardingController {

    private static let seenKey = "hasCompletedOnboarding"
    private var window: NSWindow?

    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to CreativeNotch"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView {
            UserDefaults.standard.set(true, forKey: Self.seenKey)
            window.close()
        })
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct OnboardingView: View {
    let onDone: () -> Void
    @State private var trusted = Permissions.isAccessibilityTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CreativeNotch needs Accessibility access")
                .font(.title2.weight(.semibold))

            Text("""
                 Two features depend on it:

                 • The HUD reads volume and brightness key presses so it can \
                 show them in the notch.
                 • The file shelf notices when you pick up a file, so it can \
                 open as a drop target.

                 The clipboard and the shelf's drop area work without it.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Label(
                    trusted ? "Granted" : "Not granted",
                    systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .foregroundStyle(trusted ? .green : .secondary)

                Spacer()

                if !trusted {
                    Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    Button("Grant Access") {
                        Permissions.requestAccessibility()
                    }
                    .keyboardShortcut(.defaultAction)
                }

                Button(trusted ? "Done" : "Skip for now", action: onDone)
                    .keyboardShortcut(trusted ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 320)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // Re-check when the user comes back from System Settings.
            // Event-driven, not polled.
            trusted = Permissions.isAccessibilityTrusted
        }
    }
}
```

- [ ] **Step 3: Replace the stub in the app delegate**

In `Sources/CreativeNotch/App.swift`, add a stored property:

```swift
    private let onboarding = OnboardingController()
```

Replace the stub:

```swift
    func showOnboarding() {
        onboarding.show()
    }
```

And at the end of `applicationDidFinishLaunching(_:)`:

```swift
        onboarding.showIfNeeded()
```

- [ ] **Step 4: Rebuild and verify by hand**

```bash
pkill -f CreativeNotch || true
defaults delete com.gcdz.creativenotch hasCompletedOnboarding 2>/dev/null || true
./Scripts/bundle.sh && open dist/CreativeNotch.app
```

Expected:
- The onboarding window appears on first launch and explains why Accessibility is needed.
- "Grant Access" triggers the system prompt; "Open Settings" opens the right pane.
- Returning to the app updates the status to "Granted" without a restart.
- Quitting and relaunching does **not** show onboarding again.
- The menu bar item reopens it on demand.

- [ ] **Step 5: Run the full test suite and commit**

```bash
swift test
git add Sources/CreativeNotch Resources
git commit -m "feat: first-launch onboarding and accessibility request"
git push origin main
gh run watch --exit-status
```

---

## Definition of done

- `swift test` passes; CI green on `main`.
- `./Scripts/bundle.sh` produces an ad-hoc-signed `dist/CreativeNotch.app`.
- The panel renders over the real notch on a MacBook, and as a pill on a notchless screen.
- Menu bar clicks either side of the notch work in every state.
- 300ms dwell peeks; click opens; the panel is absent over fullscreen apps.
- Menu bar item shows Accessibility status and quits cleanly.
- Onboarding shows once and is reopenable.

## What this plan deliberately does not build

The four modules. Each gets its own plan once the foundation is real:

- **Plan 2 — HUD.** `.systemDefined` monitor, CoreAudio volume read, rendering alongside Apple's OSD.
- **Plan 3 — File shelf.** Lazy drag monitor, 20-entry copy store, drop target.
- **Plan 4 — Clipboard.** The gated poller, `ConcealedType` filtering, 50-entry in-memory ring.
- **Plan 5 — Media.** The perl MediaRemote helper, supervision, ungated transport controls.

Deferred spikes: `OSDUIHelper` suppression, brightness read.
