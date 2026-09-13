# UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redraw the open panel — header in the ears, music as a column, a
titled module pane, one control vocabulary — and regroup Settings and
onboarding, without moving a single hit-test rectangle or adding a single
timer.

**Architecture:** Every layout and classification decision with a right
answer becomes a pure function in `CreativeNotchCore` (`PanelLayout`,
`Tab.symbolName`, `ClipboardKind`, `ClipboardTimeLabel`, `TimerProgress`,
`PowerGaugeTone`). `CreativeNotchUI` gains a header, a media column, a pane
wrapper and a shared control style file; the existing tab views are restyled
in place. `AppState` gains four verb closures, wired in `install(metrics:)` to
verbs that already exist.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Observation, Swift Testing,
SwiftPM. macOS 26+. No third-party dependencies.

**Spec:** [`docs/specs/2026-09-13-ui-redesign-design.md`](../specs/2026-09-13-ui-redesign-design.md).
Read it before Task 1. Where a step's reasoning is one line here, the spec
section named beside it is the argument.

## Global Constraints

- **`CreativeNotchCore` imports no UI framework.** `CorePurityTests` enforces
  it. Files created in a Core *subdirectory* must be added to the
  `expectedInSubdirectories` manifest in `CorePurityTests.swift` in the same
  commit; root-level Core files are picked up automatically.
- **No geometry changes.** `NotchGeometry.expandedSize`, `NotchShape.visibleRect`,
  `NotchShape.badgeSlot` and every badge width are untouched (spec §3). The
  only constant that changes is `panelCornerRadius`.
- **Nothing repeats.** No `Timer`, `TimelineView`, `.repeatForever`, or
  `Date()` read inside a view body. Views take `now` from `NotchRootView`'s
  single per-body instant (spec §9).
- **Every test must fail when the code it covers is deleted.** For each new
  test: introduce the bug, `swift build` green, `swift test` red, revert.
  `CONTRIBUTING.md` calls this the one non-negotiable demand.
- **No stock control styles under `Sources/CreativeNotchUI/` after Task 11.**
  `.borderedProminent`, `.bordered`, `.roundedBorder` are gone, pinned by a
  source scan.
- **`PanelTabBarTests.theBodyRendersTheListItWasGiven` keeps passing.** The
  `ForEach(Self.visible(enabled: enabled, hasBattery: hasBattery)` line stays
  verbatim in `PanelTabBar.swift`.
- Conventional commit prefixes. Baseline at the branch point (`82c447e`): 989
  tests, all passing. Every task leaves the suite green.

## File Structure

```
Sources/CreativeNotchCore/
  PanelLayout.swift                    NEW  header/ear/column split (§3.1)
  TabSymbols.swift                     NEW  Tab.symbolName (§5.1)
  Clipboard/ClipboardKind.swift        NEW  text/link/code/image (§5.6)
  Clipboard/ClipboardTimeLabel.swift   NEW  HH:mm or d MMM (§5.6)
  Timer/TimerProgress.swift            NEW  filled fraction (§5.7)
  Power/PowerGaugeTone.swift           NEW  normal/low/charging (§5.8)
  NotchGeometry.swift                  MOD  panelCornerRadius 14 → 20

Sources/CreativeNotchUI/
  NotchControls.swift                  NEW  NotchButtonStyle, NotchFieldStyle (§5.10)
  PanelHeader.swift                    NEW  ears + gap (§5.1)
  PanelTabBar.swift                    MOD  icon buttons
  Media/MediaColumn.swift              NEW  cover, glow, text, transport (§5.2)
  Media/ArtworkTint.swift              NEW  average colour of artwork data
  ModulePane.swift                     NEW  title row + content (§5.3)
  NotchRootView.swift                  MOD  AppState closures; body composition
  Shelf/ShelfView.swift                MOD  tiles, empty state, remove (§5.4)
  Shelf/DropTargetView.swift           NEW  dashed target, used by shelf-empty and .receiving (§5.5)
  Clipboard/ClipboardView.swift        MOD  rows (§5.6)
  Timer/TimerTabView.swift             MOD  restyle (§5.7)
  Power/PowerView.swift                MOD  gauge (§5.8)
  PreferencesWindow.swift              MOD  grouped form (§6)
  OnboardingWindow.swift               MOD  three rows (§7)
  AppDelegate.swift                    MOD  wire four closures

Tests/CreativeNotchCoreTests/
  PanelLayoutTests.swift               NEW
  TabSymbolsTests.swift                NEW
  ClipboardKindTests.swift             NEW
  ClipboardTimeLabelTests.swift        NEW
  TimerProgressTests.swift             NEW
  PowerGaugeToneTests.swift            NEW
  CorePurityTests.swift                MOD  manifest

Tests/CreativeNotchUITests/
  PanelActionsWiringTests.swift        NEW  the four closures are wired
  PanelRenderingTests.swift            NEW  header ears, media column, receiving, no stock styles
  PanelTabBarTests.swift               MOD  source scan strings
  PreferencesWindowTests.swift         MOD  rows still cover ModuleID.allCases; sections
```

## Why the order is what it is

Core first (Tasks 1–4): pure, one-second feedback, and every later view
reads them. Then the shared controls (5) and the wiring (6), so the panel
recomposition (7) can be built against real verbs. Then each tab in
isolation (8–11), then the windows (12–13), then the docs (14).

---

### Task 1: `PanelLayout` and the corner radius

**Files:**
- Create: `Sources/CreativeNotchCore/PanelLayout.swift`
- Modify: `Sources/CreativeNotchCore/NotchGeometry.swift:76`
- Test: `Tests/CreativeNotchCoreTests/PanelLayoutTests.swift`

**Interfaces:**
- Produces: `PanelLayout.resolve(anchor:panelFrame:showsMedia:) -> PanelLayout`
  with `headerHeight`, `leadingEarWidth`, `notchGap`, `trailingEarWidth`,
  `mediaColumnWidth`; `PanelLayout.mediaColumnWidth: CGFloat = 212` static.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CoreGraphics
@testable import CreativeNotchCore

/// The one place the open panel's header and body are split up (spec §3.1).
struct PanelLayoutTests {

    // 14" MacBook Pro-ish: panel 620 wide centred on a 190-wide notch.
    private let notch = Anchor.notch(CGRect(x: 661, y: 950, width: 190, height: 32))
    private let notchPanel = CGRect(x: 446, y: 722, width: 620, height: 260)
    private let pill = Anchor.pill(CGRect(x: 666, y: 942, width: 180, height: 32))
    private let pillPanel = CGRect(x: 446, y: 714, width: 620, height: 260)

    @Test func theHeaderIsAsTallAsTheAnchor() {
        let l = PanelLayout.resolve(anchor: notch, panelFrame: notchPanel, showsMedia: true)
        #expect(l.headerHeight == 32)
    }

    @Test func theEarsAndTheGapSpanThePanelExactly() {
        let l = PanelLayout.resolve(anchor: notch, panelFrame: notchPanel, showsMedia: true)
        #expect(l.leadingEarWidth + l.notchGap + l.trailingEarWidth == notchPanel.width)
        #expect(l.notchGap == 190)
        #expect(l.leadingEarWidth == 215)
        #expect(l.trailingEarWidth == 215)
    }

    /// An off-centre panel (clamped to a screen edge) keeps the gap over
    /// the real notch rather than the panel's middle.
    @Test func theGapFollowsTheNotchNotThePanelCentre() {
        let shifted = CGRect(x: 500, y: 722, width: 620, height: 260)
        let l = PanelLayout.resolve(anchor: notch, panelFrame: shifted, showsMedia: true)
        #expect(l.leadingEarWidth == 161)
        #expect(l.trailingEarWidth == 269)
    }

    @Test func aPillHasNoGapAndTwoEqualHalves() {
        let l = PanelLayout.resolve(anchor: pill, panelFrame: pillPanel, showsMedia: true)
        #expect(l.notchGap == 0)
        #expect(l.leadingEarWidth == 310)
        #expect(l.trailingEarWidth == 310)
    }

    @Test func theMediaColumnIsFixedWhenShownAndAbsentWhenNot() {
        #expect(PanelLayout.resolve(anchor: notch, panelFrame: notchPanel, showsMedia: true)
                    .mediaColumnWidth == PanelLayout.mediaColumnWidth)
        #expect(PanelLayout.resolve(anchor: notch, panelFrame: notchPanel, showsMedia: false)
                    .mediaColumnWidth == 0)
    }

    @Test func theOpenPanelRoundsMoreThanTheClosedNotch() {
        #expect(NotchGeometry.panelCornerRadius == 20)
        #expect(NotchGeometry.panelCornerRadius > NotchGeometry.notchCornerRadius)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PanelLayoutTests`
Expected: compile error, `PanelLayout` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/CreativeNotchCore/PanelLayout.swift
import CoreGraphics

/// How the open panel is split up: a header as tall as the anchor, whose
/// middle is the camera housing on a notched Mac, and a body that is a
/// fixed media column beside the module pane.
///
/// One function, because the header's three columns and the peek's
/// `notchGap` are the same fact about the same hardware. Every view reads
/// its widths from here rather than deriving them, for the reason
/// ARCHITECTURE.md gives for `visibleRect`: two derivations of one number
/// drift.
public struct PanelLayout: Equatable, Sendable {

    /// The width of the music column while media controls are on. Fixed
    /// whether or not a track is playing, so the pane never reflows under
    /// the user when one starts (spec §3.1).
    public static let mediaColumnWidth: CGFloat = 212

    public let headerHeight: CGFloat
    public let leadingEarWidth: CGFloat
    public let notchGap: CGFloat
    public let trailingEarWidth: CGFloat
    public let mediaColumnWidth: CGFloat

    public static func resolve(anchor: Anchor, panelFrame: CGRect, showsMedia: Bool) -> PanelLayout {
        let header = anchor.rect.height
        let media = showsMedia ? Self.mediaColumnWidth : 0
        guard anchor.isNotch else {
            let half = panelFrame.width / 2
            return PanelLayout(
                headerHeight: header, leadingEarWidth: half, notchGap: 0,
                trailingEarWidth: panelFrame.width - half, mediaColumnWidth: media
            )
        }
        let leading = anchor.rect.minX - panelFrame.minX
        let gap = anchor.rect.width
        return PanelLayout(
            headerHeight: header,
            leadingEarWidth: leading,
            notchGap: gap,
            trailingEarWidth: panelFrame.width - leading - gap,
            mediaColumnWidth: media
        )
    }
}
```

And in `NotchGeometry.swift` change `panelCornerRadius` to `20`, updating
its doc comment: "20 rather than the closed notch's 12: once it is a panel
it reads as an island, and the reference apps sit at 14–24."

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "PanelLayoutTests|NotchCornerRadiiTests"`
Expected: all pass.

- [ ] **Step 5: Mutation check.** Change `leading` to `panelFrame.width / 2 - gap / 2`; `theGapFollowsTheNotchNotThePanelCentre` must fail. Revert.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore/PanelLayout.swift Sources/CreativeNotchCore/NotchGeometry.swift Tests/CreativeNotchCoreTests/PanelLayoutTests.swift
git commit -m "feat: the open panel's layout, as one pure function"
```

---

### Task 2: `Tab.symbolName`

**Files:**
- Create: `Sources/CreativeNotchCore/TabSymbols.swift`
- Test: `Tests/CreativeNotchCoreTests/TabSymbolsTests.swift`

**Interfaces:**
- Produces: `extension Tab { public var symbolName: String }`

- [ ] **Step 1: Failing test**

```swift
import Testing
@testable import CreativeNotchCore

/// Icon tabs need a glyph per tab; a duplicate would make two tabs
/// indistinguishable, and an empty string draws nothing.
struct TabSymbolsTests {
    @Test func everyTabHasADistinctNonEmptySymbol() {
        let names = Tab.allCases.map(\.symbolName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test func theSymbolsAreTheOnesTheSpecNames() {
        #expect(Tab.shelf.symbolName == "tray.full")
        #expect(Tab.clipboard.symbolName == "doc.on.clipboard")
        #expect(Tab.timer.symbolName == "timer")
        #expect(Tab.power.symbolName == "battery.100percent")
        #expect(Tab.camera.symbolName == "camera")
    }
}
```

- [ ] **Step 2: Run** `swift test --filter TabSymbolsTests` — compile error.

- [ ] **Step 3: Implement**

```swift
// Sources/CreativeNotchCore/TabSymbols.swift

/// The SF Symbol each tab is drawn with in the header (spec §5.1).
///
/// A string, so it lives in Core and is testable for distinctness; the UI
/// turns it into an `Image(systemName:)`. `.hud` has one so the switch is
/// exhaustive without a `default` — it is never offered as a tab.
public extension Tab {
    var symbolName: String {
        switch self {
        case .shelf:     return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .hud:       return "speaker.wave.2"
        case .power:     return "battery.100percent"
        case .timer:     return "timer"
        case .camera:    return "camera"
        }
    }
}
```

- [ ] **Step 4: Run** — passes. **Step 5:** make `.camera` return `"timer"`; distinctness test fails. Revert.

- [ ] **Step 6: Commit** `feat: a symbol per tab`

---

### Task 3: `ClipboardKind` and `ClipboardTimeLabel`

**Files:**
- Create: `Sources/CreativeNotchCore/Clipboard/ClipboardKind.swift`
- Create: `Sources/CreativeNotchCore/Clipboard/ClipboardTimeLabel.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift` (manifest)
- Test: `Tests/CreativeNotchCoreTests/ClipboardKindTests.swift`, `ClipboardTimeLabelTests.swift`

**Interfaces:**
- Produces: `enum ClipboardKind { case text, link, code, image; static func classify(_: ClipboardContent) -> ClipboardKind; var symbolName: String }`
- Produces: `enum ClipboardTimeLabel { static func text(addedAt: Date, now: Date, calendar: Calendar = .current) -> String }`

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

struct ClipboardKindTests {
    @Test func aBareURLIsALink() {
        #expect(ClipboardKind.classify(.text("https://developer.apple.com/x")) == .link)
        #expect(ClipboardKind.classify(.text("  https://a.b  ")) == .link)
    }
    @Test func proseWithAURLInsideIsText() {
        #expect(ClipboardKind.classify(.text("see https://a.b for details")) == .text)
    }
    @Test func newlinesOrBracesAreCode() {
        #expect(ClipboardKind.classify(.text("let a = 1\nlet b = 2")) == .code)
        #expect(ClipboardKind.classify(.text("func f() { }")) == .code)
    }
    @Test func imagesAreImages() {
        #expect(ClipboardKind.classify(.image(Data([1]), ext: "png")) == .image)
    }
    @Test func everyKindHasADistinctSymbol() {
        let all: [ClipboardKind] = [.text, .link, .code, .image]
        #expect(Set(all.map(\.symbolName)).count == all.count)
    }
}

struct ClipboardTimeLabelTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    @Test func sameDayIsAClockTime() {
        let t = ClipboardTimeLabel.text(addedAt: date("2026-09-13T23:38:00Z"),
                                        now: date("2026-09-13T23:41:00Z"), calendar: cal)
        #expect(t == "23:38")
    }
    @Test func anotherDayIsADate() {
        let t = ClipboardTimeLabel.text(addedAt: date("2026-09-12T23:38:00Z"),
                                        now: date("2026-09-13T00:01:00Z"), calendar: cal)
        #expect(t == "12 Sept" || t == "12 Sep")
    }
    /// The label is a function of two instants and nothing else — no
    /// "2m ago" that goes stale while the panel is open (spec §9).
    @Test func theLabelDoesNotDependOnHowLongAgo() {
        let a = ClipboardTimeLabel.text(addedAt: date("2026-09-13T10:00:00Z"),
                                        now: date("2026-09-13T10:01:00Z"), calendar: cal)
        let b = ClipboardTimeLabel.text(addedAt: date("2026-09-13T10:00:00Z"),
                                        now: date("2026-09-13T22:00:00Z"), calendar: cal)
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter "ClipboardKindTests|ClipboardTimeLabelTests"` — compile error.

- [ ] **Step 3: Implement**

```swift
// Sources/CreativeNotchCore/Clipboard/ClipboardKind.swift
import Foundation

/// What a clipboard row's leading tile says about its entry (spec §5.6).
///
/// Display only. The stored content is untouched; this decides a glyph.
public enum ClipboardKind: Equatable, Sendable {
    case text, link, code, image

    public static func classify(_ content: ClipboardContent) -> ClipboardKind {
        switch content {
        case .image:
            return .image
        case .text(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            // A link is the *whole* entry being one URL with a scheme. Prose
            // that mentions a URL is prose.
            if !trimmed.contains(where: \.isWhitespace),
               let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
                return .link
            }
            if trimmed.contains("\n") || trimmed.contains("{") || trimmed.contains("}") {
                return .code
            }
            return .text
        }
    }

    public var symbolName: String {
        switch self {
        case .text:  return "text.alignleft"
        case .link:  return "link"
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        }
    }
}
```

```swift
// Sources/CreativeNotchCore/Clipboard/ClipboardTimeLabel.swift
import Foundation

/// When an entry was copied, as a clock time — never as "2m ago".
///
/// Relative text is wrong within a minute of being drawn unless something
/// redraws it, and this app has no timer to do that with. A clock time
/// stays true for as long as the panel is open (spec §5.6, §9).
public enum ClipboardTimeLabel {
    public static func text(addedAt: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? .current
        if calendar.isDate(addedAt, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("HH:mm")
        } else {
            f.setLocalizedDateFormatFromTemplate("d MMM")
        }
        return f.string(from: addedAt)
    }
}
```

Add `"ClipboardKind.swift"` and `"ClipboardTimeLabel.swift"` to
`expectedInSubdirectories` in `CorePurityTests.swift`.

- [ ] **Step 4: Run** — passes (also `CorePurityTests`). **Step 5:** make `classify` return `.text` for URLs; `aBareURLIsALink` fails. Revert.

- [ ] **Step 6: Commit** `feat: a clipboard row's kind and its clock time, as pure functions`

---

### Task 4: `TimerProgress` and `PowerGaugeTone`

**Files:**
- Create: `Sources/CreativeNotchCore/Timer/TimerProgress.swift`
- Create: `Sources/CreativeNotchCore/Power/PowerGaugeTone.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift`
- Test: `Tests/CreativeNotchCoreTests/TimerProgressTests.swift`, `PowerGaugeToneTests.swift`

**Interfaces:**
- Produces: `enum TimerProgress { static func fraction(_ countdown: Countdown, at now: Date) -> Double }`
- Produces: `enum PowerGaugeTone { case normal, low, charging; static func tone(level: Int, isCharging: Bool) -> PowerGaugeTone; static let lowThreshold: Int }`

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

struct TimerProgressTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func aFreshCountdownIsEmpty() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        #expect(TimerProgress.fraction(c, at: t0) == 0)
    }
    @Test func halfwayIsHalf() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        #expect(TimerProgress.fraction(c, at: t0.addingTimeInterval(300)) == 0.5)
    }
    @Test func aFinishedCountdownIsFullAndNeverOverflows() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        #expect(TimerProgress.fraction(c, at: t0.addingTimeInterval(900)) == 1)
    }
    @Test func aPausedCountdownHoldsItsFraction() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0)).paused(at: t0.addingTimeInterval(150))
        #expect(TimerProgress.fraction(c, at: t0.addingTimeInterval(150)) == 0.25)
        #expect(TimerProgress.fraction(c, at: t0.addingTimeInterval(500)) == 0.25)
    }
}

struct PowerGaugeToneTests {
    @Test func chargingWinsOverLow() {
        #expect(PowerGaugeTone.tone(level: 5, isCharging: true) == .charging)
    }
    @Test func atOrBelowTheMacOSThresholdIsLow() {
        #expect(PowerGaugeTone.tone(level: 20, isCharging: false) == .low)
        #expect(PowerGaugeTone.tone(level: 21, isCharging: false) == .normal)
    }
    /// The same 20 the low-battery peek arms on. One threshold, spelled once.
    @Test func theThresholdIsTheArmingModulesTopThreshold() {
        #expect(PowerGaugeTone.lowThreshold == LowBatteryArming.thresholds.max())
    }
}
```

- [ ] **Step 2: Run** — compile error.

- [ ] **Step 3: Implement**

```swift
// Sources/CreativeNotchCore/Timer/TimerProgress.swift
import Foundation

/// How much of the countdown has elapsed, for the track under the digits.
///
/// A function of the same `now` `TimerDisplay.text` is given, so the track
/// redraws exactly when the digits do and never on a clock of its own
/// (spec §5.7, §9).
public enum TimerProgress {
    public static func fraction(_ countdown: Countdown, at now: Date) -> Double {
        guard countdown.duration > 0 else { return 1 }
        let remaining = max(0, countdown.remaining(at: now))
        return min(1, max(0, 1 - remaining / countdown.duration))
    }
}
```

```swift
// Sources/CreativeNotchCore/Power/PowerGaugeTone.swift

/// The one colour decision on the battery tab (spec §5.8).
///
/// White is the default, as everywhere in this notch. Yellow is the colour
/// the power module already uses for a low battery; green while charging is
/// what the menu bar item does, and it is the only time the gauge is telling
/// good news.
public enum PowerGaugeTone: Equatable, Sendable {
    case normal, low, charging

    /// The higher of the two thresholds macOS itself warns at, taken from
    /// `LowBatteryArming` rather than restated.
    public static let lowThreshold: Int = LowBatteryArming.thresholds.max() ?? 20

    public static func tone(level: Int, isCharging: Bool) -> PowerGaugeTone {
        if isCharging { return .charging }
        if level <= lowThreshold { return .low }
        return .normal
    }
}
```

Add `"TimerProgress.swift"` and `"PowerGaugeTone.swift"` to the manifest.

- [ ] **Step 4: Run** — passes. **Step 5:** swap the two `if`s in `tone`; `chargingWinsOverLow` fails. Revert.

- [ ] **Step 6: Commit** `feat: the timer's progress and the gauge's tone, as pure functions`

---

### Task 5: `NotchControls` — one vocabulary

**Files:**
- Create: `Sources/CreativeNotchUI/NotchControls.swift`

**Interfaces:**
- Produces: `struct NotchButtonStyle: ButtonStyle { enum Emphasis { case quiet, prominent }; init(_ emphasis: Emphasis = .quiet) }`,
  `struct NotchFieldStyle: TextFieldStyle`, and `extension View { func notchTitleRow(...) }` is **not** here — it is `ModulePane` (Task 7).

- [ ] **Step 1: Implement** (no unit test: styles have no logic; Task 11's source scan is what pins their adoption)

```swift
import SwiftUI

/// The panel's one button: a capsule, white on black (spec §5.10).
///
/// Stock `.bordered` styles resolve their colours against the appearance and
/// once rendered the timer's Pause button black-on-black (`NotchPanel.swift`).
/// Styling everything explicitly, as every other view here already does, is
/// what keeps that from recurring.
struct NotchButtonStyle: ButtonStyle {
    enum Emphasis { case quiet, prominent }
    var emphasis: Emphasis = .quiet

    init(_ emphasis: Emphasis = .quiet) { self.emphasis = emphasis }

    func makeBody(configuration: Configuration) -> some View {
        NotchButtonBody(configuration: configuration, emphasis: emphasis)
    }

    private struct NotchButtonBody: View {
        let configuration: Configuration
        let emphasis: Emphasis
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(emphasis == .prominent ? Color.black : Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(fill))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                // A tracking area inside the panel, alive only while it is.
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            switch emphasis {
            case .prominent:
                return .white.opacity(configuration.isPressed ? 0.8 : 1)
            case .quiet:
                let base = configuration.isPressed ? 0.22 : (hovering ? 0.16 : 0.10)
                return .white.opacity(base)
            }
        }
    }
}

/// The panel's one field (spec §5.10). Dark, ringed, centred tabular digits.
struct NotchFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }
    }
}

/// A 34×24 icon button for the header and title rows.
struct NotchIconButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
            .frame(width: 34, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(selected ? 0.14 : (configuration.isPressed ? 0.10 : 0)))
            }
            .contentShape(.rect)
    }
}
```

- [ ] **Step 2: Build** `swift build` — green.
- [ ] **Step 3: Commit** `feat: one button, one field, one icon button for the panel`

---

### Task 6: Four verbs on `AppState`, wired

**Files:**
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift:60-97` (AppState closures)
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift` in `install(metrics:)` next to `state.onPasteClipboard = …` (line ~464)
- Test: `Tests/CreativeNotchUITests/PanelActionsWiringTests.swift`

**Interfaces:**
- Produces on `AppState`: `onClearShelf: (() -> Void)?`, `onRemoveShelfItem: ((UUID) -> Void)?`, `onClearClipboard: (() -> Void)?`, `onOpenSettings: (() -> Void)?`.

- [ ] **Step 1: Failing test**

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The pane's title-row actions reach the verbs that already exist. Left
/// unwired, a Clear button that does nothing is worse than no button.
@MainActor
struct PanelActionsWiringTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38, auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620, menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchPanelActions-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func installingWiresEveryPaneAction() {
        let d = makeDelegate()
        #expect(d.state.onClearShelf != nil)
        #expect(d.state.onRemoveShelfItem != nil)
        #expect(d.state.onClearClipboard != nil)
        #expect(d.state.onOpenSettings != nil)
    }

    @Test func clearShelfEmptiesTheStore() throws {
        let d = makeDelegate()
        let shelf = try #require(d.shelf)
        let file = d.shelfDirectory.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        try shelf.addReference(to: file, now: Date())
        #expect(shelf.items.count == 1)
        d.state.onClearShelf?()
        #expect(shelf.items.isEmpty)
    }

    @Test func removeShelfItemRemovesJustThatOne() throws {
        let d = makeDelegate()
        let shelf = try #require(d.shelf)
        let a = d.shelfDirectory.appendingPathComponent("a.txt")
        let b = d.shelfDirectory.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: a); try Data("y".utf8).write(to: b)
        let ia = try shelf.addReference(to: a, now: Date())
        try shelf.addReference(to: b, now: Date())
        d.state.onRemoveShelfItem?(ia.id)
        #expect(shelf.items.map(\.displayName) == ["b.txt"])
    }

    @Test func clearClipboardEmptiesTheRing() throws {
        let d = makeDelegate()
        let store = try #require(d.state.clipboard)
        _ = store.record(.text("hello"), now: Date())
        #expect(store.entries.count == 1)
        d.state.onClearClipboard?()
        #expect(store.entries.isEmpty)
    }

    /// Settings is an activating window; the panel closes before it opens.
    @Test func openSettingsClosesThePanelFirst() {
        let d = makeDelegate()
        d.state.transition(to: .open(.shelf))
        d.state.onOpenSettings?()
        #expect(d.state.state == .closed)
    }
}
```

Note: `openSettingsClosesThePanelFirst` will create a real `PreferencesController`
window. Guard it: in `AppDelegate`, route `onOpenSettings` through a
`presentPreferences: () -> Void` seam that defaults to `showPreferences()` and
that the test overrides with `{}` before calling — add
`var presentPreferences: (() -> Void)?` (internal) to the delegate and have the
closure call `self.presentPreferences?() ?? self.showPreferences()`. In the
test, set `d.presentPreferences = {}`.

- [ ] **Step 2: Run** `swift test --filter PanelActionsWiringTests` — compile error.

- [ ] **Step 3: Implement**

In `AppState` (NotchRootView.swift), after `onPasteClipboard`:

```swift
    /// The pane's title-row verbs. Closures, like `onPasteClipboard`, so the
    /// view gets a verb and never a store or a controller. Wired in
    /// `AppDelegate.install(metrics:)` to the same `clear()` the menu bar
    /// calls — `ShelfStore.clear()` moves real files to the Trash, which is
    /// exactly why the verb is not duplicated (spec §5.3).
    @ObservationIgnored public var onClearShelf: (() -> Void)?
    @ObservationIgnored public var onRemoveShelfItem: ((UUID) -> Void)?
    @ObservationIgnored public var onClearClipboard: (() -> Void)?

    /// The header's gear. Closes the panel, then opens Settings.
    @ObservationIgnored public var onOpenSettings: (() -> Void)?
```

In `AppDelegate`:

```swift
    /// Test seam: what the gear presents. `nil` means the real window.
    var presentPreferences: (() -> Void)?
```

and in `install(metrics:)`, beside `state.onPasteClipboard`:

```swift
        state.onClearShelf = { [weak self] in try? self?.shelf?.clear() }
        state.onRemoveShelfItem = { [weak self] id in try? self?.shelf?.remove(id) }
        state.onClearClipboard = { [weak self] in self?.clipboard?.store.clear() }
        state.onOpenSettings = { [weak self] in
            guard let self else { return }
            self.state.transition(to: .closed)
            if let presentPreferences { presentPreferences() } else { self.showPreferences() }
        }
```

- [ ] **Step 4: Run** — passes. **Step 5:** delete the `onClearClipboard` line; `installingWiresEveryPaneAction` and `clearClipboardEmptiesTheRing` fail. Revert.

- [ ] **Step 6: Commit** `feat: the pane's verbs reach the verbs that already exist`

---

### Task 7: The panel recomposed — header, column, pane

**Files:**
- Create: `Sources/CreativeNotchUI/PanelHeader.swift`
- Create: `Sources/CreativeNotchUI/Media/MediaColumn.swift`
- Create: `Sources/CreativeNotchUI/Media/ArtworkTint.swift`
- Create: `Sources/CreativeNotchUI/ModulePane.swift`
- Modify: `Sources/CreativeNotchUI/PanelTabBar.swift` (icon buttons)
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift:527-807` (`shape`, `mediaBar` → removed, `openContent`)
- Modify: `Tests/CreativeNotchUITests/PanelTabBarTests.swift:75-80` (source-scan strings if needed)
- Test: `Tests/CreativeNotchUITests/PanelRenderingTests.swift`

**Interfaces:**
- Consumes: `PanelLayout` (T1), `Tab.symbolName` (T2), `NotchIconButtonStyle` (T5), `AppState.onOpenSettings` (T6).
- Produces: `PanelHeader(layout:selected:enabled:hasBattery:power:onSelect:onSettings:)`,
  `MediaColumn(snapshot:artwork:showsControls:onCommand:)`,
  `ModulePane<Content>(title:count:action:content:)` where `action: (label: String, perform: () -> Void)?`,
  `ArtworkTint.color(for: Data) -> Color?`.

- [ ] **Step 1: Failing rendering tests**

```swift
import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the recomposed panel draws where the spec says (spec §5).
@MainActor
struct PanelRenderingTests {

    static func state(notch: Bool = true, media: Bool = true) -> AppState {
        let s = AppState()
        let anchor: CreativeNotchCore.Anchor = notch
            ? .notch(CGRect(x: 661, y: 950, width: 190, height: 32))
            : .pill(CGRect(x: 666, y: 942, width: 180, height: 32))
        s.setGeometry(anchor: anchor,
                      panelFrame: CGRect(x: 446, y: anchor.rect.maxY - 260, width: 620, height: 260))
        s.hasBattery = true
        s.showsMediaControls = media
        s.power = PowerSnapshot(level: 67, source: .battery, isCharging: false, isLowPowerMode: false)
        return s
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        let r = ImageRenderer(content: NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
            .frame(width: 620, height: 260))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Fraction of non-black pixels in a rect (top-left origin, points).
    static func ink(_ b: NSBitmapImageRep, in rect: CGRect) -> Double {
        var lit = 0, total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let c = b.colorAt(x: x, y: y) else { continue }
                total += 1
                if c.redComponent + c.greenComponent + c.blueComponent > 0.15 { lit += 1 }
            }
        }
        return total == 0 ? 0 : Double(lit) / Double(total)
    }

    /// The header draws in the ears and leaves the camera housing black.
    @Test func theHeaderStaysOutOfTheNotch() throws {
        let s = Self.state(); s.transition(to: .open(.shelf))
        let b = try #require(Self.bitmap(s))
        // Notch band: x 215..405 on this anchor, y 0..32.
        #expect(Self.ink(b, in: CGRect(x: 220, y: 2, width: 180, height: 28)) == 0)
        // Left ear has the tabs; right ear has the gear.
        #expect(Self.ink(b, in: CGRect(x: 0, y: 2, width: 215, height: 28)) > 0.01)
        #expect(Self.ink(b, in: CGRect(x: 405, y: 2, width: 215, height: 28)) > 0.01)
    }

    /// The old layout centred the tab bar under the media header; the notch
    /// band below the header must now be pane content, not empty.
    @Test func theMediaColumnIsDrawnOnTheLeftWhenControlsAreOn() throws {
        let with = Self.state(media: true); with.transition(to: .open(.power))
        let without = Self.state(media: false); without.transition(to: .open(.power))
        let a = try #require(Self.bitmap(with)), c = try #require(Self.bitmap(without))
        let column = CGRect(x: 0, y: 40, width: 200, height: 200)
        #expect(Self.ink(a, in: column) > Self.ink(c, in: column))
    }

    @Test func aPillDrawsTheHeaderAcrossTheMiddle() throws {
        let s = Self.state(notch: false); s.transition(to: .open(.shelf))
        let b = try #require(Self.bitmap(s))
        // Tabs start at the panel's left edge on a pill; nothing is skipped.
        #expect(Self.ink(b, in: CGRect(x: 4, y: 2, width: 60, height: 28)) > 0.01)
    }

    @Test func receivingDrawsATargetNotJustALabel() throws {
        let s = Self.state(); s.transition(to: .receiving)
        let b = try #require(Self.bitmap(s))
        // A dashed border lights the edges of the content area; a bare
        // centred label would leave them black.
        #expect(Self.ink(b, in: CGRect(x: 20, y: 44, width: 580, height: 3)) > 0.05)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter PanelRenderingTests` — fails (notch band has ink from the centred tab bar today; column test fails).

- [ ] **Step 3: Implement the pieces**

`Sources/CreativeNotchUI/Media/ArtworkTint.swift`:

```swift
import AppKit
import SwiftUI

/// The artwork's average colour, for the glow behind the cover (spec §5.2).
///
/// Computed once per artwork change, in a `.task(id:)`; never on a clock.
/// Downsampling to one pixel is the whole algorithm.
enum ArtworkTint {
    static func color(for data: Data) -> Color? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return Color(red: Double(p[0]) / 255, green: Double(p[1]) / 255, blue: Double(p[2]) / 255)
    }
}
```

`Sources/CreativeNotchUI/PanelTabBar.swift` body becomes icon buttons; the
pinned `ForEach` line is unchanged:

```swift
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.visible(enabled: enabled, hasBattery: hasBattery), id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    Image(systemName: tab.symbolName)
                }
                .buttonStyle(NotchIconButtonStyle(selected: tab == selected))
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab == selected ? .isSelected : [])
            }
        }
    }
```

(Remove the `.padding(.top, 8)`; the header positions it.)

`Sources/CreativeNotchUI/PanelHeader.swift`:

```swift
import SwiftUI
import CreativeNotchCore

/// The open panel's top band: tabs in the leading ear, battery and the gear
/// in the trailing ear, and the camera housing black between them (spec §5.1).
///
/// Widths come from `PanelLayout`, the same function that gives the peeks
/// their `notchGap`; this view draws three columns and decides nothing.
struct PanelHeader: View {
    let layout: PanelLayout
    let selected: CreativeNotchCore.Tab
    let enabled: Preferences
    let hasBattery: Bool
    let power: PowerSnapshot?
    let onSelect: (CreativeNotchCore.Tab) -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            PanelTabBar(selected: selected, enabled: enabled, hasBattery: hasBattery, onSelect: onSelect)
                .padding(.leading, 12)
                .frame(width: layout.leadingEarWidth, alignment: .leading)

            Color.clear.frame(width: layout.notchGap)

            HStack(spacing: 10) {
                if hasBattery, let power {
                    BatteryCell(level: power.level, isCharging: power.isCharging)
                }
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(NotchIconButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.trailing, 12)
            .frame(width: layout.trailingEarWidth, alignment: .trailing)
        }
        .frame(height: layout.headerHeight)
    }
}

/// A small battery glyph with the level beside it. Static.
struct BatteryCell: View {
    let level: Int
    let isCharging: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 22, height: 11)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tone)
                    .frame(width: max(2, 16 * CGFloat(min(100, max(0, level))) / 100), height: 6)
                    .padding(.leading, 3)
            }
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.55))
                    .frame(width: 2, height: 4).offset(x: 3)
            }
            Text("\(level)%")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(level) percent")
    }

    private var tone: Color {
        switch PowerGaugeTone.tone(level: level, isCharging: isCharging) {
        case .normal:   return .white
        case .low:      return .yellow
        case .charging: return .green
        }
    }
}
```

`Sources/CreativeNotchUI/Media/MediaColumn.swift`:

```swift
import SwiftUI
import CreativeNotchCore

/// What is playing and the controls for it, as a column (spec §5.2).
///
/// Fixed width, present whenever media controls are on. With no track it
/// shows a placeholder tile and dimmed controls rather than collapsing, so
/// the pane beside it never reflows when a track starts.
struct MediaColumn: View {
    let snapshot: TrackSnapshot?
    let artwork: Data?
    let showsControls: Bool
    let onCommand: (MediaCommand) -> Void

    @State private var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot?.title ?? "Nothing playing")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(snapshot == nil ? 0.5 : 0.95))
                    .lineLimit(1).truncationMode(.tail)
                if let snapshot, !snapshot.artist.isEmpty {
                    Text(snapshot.artist)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            if showsControls {
                MediaControlsView(onCommand: onCommand)
                    .opacity(snapshot == nil ? 0.6 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 18).padding(.leading, 18).padding(.trailing, 16).padding(.bottom, 14)
        .frame(width: PanelLayout.mediaColumnWidth, alignment: .topLeading)
        .background(alignment: .topLeading) {
            if let tint {
                Circle().fill(tint.opacity(0.35))
                    .frame(width: 170, height: 170)
                    .blur(radius: 18)
                    .offset(x: -30, y: -20)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
        }
        .clipped()
        .task(id: artwork) {
            tint = artwork.flatMap(ArtworkTint.color(for:))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var cover: some View {
        Group {
            if let artwork, let image = NSImage(data: artwork) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }
}
```

Update `MediaControlsView` button sizing to the spec: `HStack(spacing: 8)`,
each button a `RoundedRectangle(cornerRadius: 8)` at `.white.opacity(0.08)`
32×28, play/pause 40 wide at 0.16.

`Sources/CreativeNotchUI/ModulePane.swift`:

```swift
import SwiftUI

/// A tab's content with the title row above it (spec §5.3).
struct ModulePane<Content: View>: View {
    let title: String
    var count: String? = nil
    var action: (label: String, perform: () -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                if let count {
                    Text(count)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 8)
                if let action {
                    Button(action.label, action: action.perform)
                        .buttonStyle(NotchButtonStyle(.quiet))
                        .controlSize(.small)
                }
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
```

`NotchRootView.shape(badge:at:)` — replace the `.open(.camera)` and
`.open(let tab)` cases and `mediaBar`:

```swift
                case .open(let tab):
                    let layout = PanelLayout.resolve(
                        anchor: app.anchor, panelFrame: app.panelFrame,
                        showsMedia: tab != .camera && app.showsMediaControls
                    )
                    VStack(spacing: 0) {
                        PanelHeader(
                            layout: layout, selected: tab, enabled: app.preferences,
                            hasBattery: app.hasBattery, power: app.power,
                            onSelect: { app.transition(to: .open($0)) },
                            onSettings: { app.onOpenSettings?() }
                        )
                        HStack(spacing: 0) {
                            if layout.mediaColumnWidth > 0 {
                                MediaColumn(
                                    snapshot: app.nowPlaying, artwork: app.nowPlayingArtwork,
                                    showsControls: app.showsMediaControls
                                ) { app.onMediaCommand?($0) }
                            }
                            openContent(for: tab, at: now)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))

                case .receiving:
                    VStack(spacing: 0) {
                        Color.clear.frame(height: app.anchor.rect.height)
                        DropTargetView(prominent: true)
                            .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 20)
                    }
```

Delete `mediaBar` and `cameraContent`'s separate branch (camera now goes
through `openContent(for: .camera)` which returns `CameraTabView` filling the
pane). Wrap the other tabs in `ModulePane` inside `openContent`:

```swift
        case .shelf:
            if let shelf = app.shelf {
                ModulePane(
                    title: "Shelf",
                    count: shelf.items.isEmpty ? "empty" : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")",
                    action: shelf.items.isEmpty ? nil : ("Clear", { app.onClearShelf?() })
                ) {
                    ShelfView(store: shelf) { app.onRemoveShelfItem?($0) }
                }
            }
        case .clipboard:
            if let clipboard = app.clipboard {
                ModulePane(
                    title: "Clipboard",
                    count: clipboard.entries.isEmpty ? nil : "\(clipboard.entries.count) of \(ClipboardStore.capacity)",
                    action: clipboard.entries.isEmpty ? nil : ("Clear", { app.onClearClipboard?() })
                ) {
                    ClipboardView(store: clipboard, now: now) { app.onPasteClipboard?($0) }
                }
            }
        case .timer:
            ModulePane(title: "Timer", count: app.countdown.map { TimerDisplay.durationText($0.duration) }) {
                TimerTabView(...)   // unchanged arguments
            }
        case .power:
            ModulePane(title: "Battery") { PowerView(snapshot: app.power) }
        case .camera:
            cameraContent
```

`TimerDisplay.durationText(_:)` does not exist; use
`"\(Int(app.countdown!.duration / 60)) min"` inline via a small private
helper `durationLabel(_ countdown: Countdown) -> String` in the root view.

The hairline (spec §4): in `shape(badge:at:)`, after `.fill(.black)` add

```swift
            .overlay {
                if app.state.presentation == .expanded {
                    backgroundShape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
            }
```

`backgroundShape` is `AnyShape`; `strokeBorder` needs `InsettableShape`, so
return `UnevenRoundedRectangle` directly from `backgroundShape` instead of
wrapping in `AnyShape`.

Add the `DropTargetView` (Task 8 owns its final styling; create it here
minimal so `.receiving` compiles):

```swift
// Sources/CreativeNotchUI/Shelf/DropTargetView.swift
import SwiftUI
import CreativeNotchCore

/// The dashed target the shelf shows when empty and the panel shows while a
/// drag is in flight (spec §5.4, §5.5). One view, two brightnesses.
struct DropTargetView: View {
    var prominent = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: prominent ? 28 : 22, weight: .medium))
            Text(prominent ? "Drop to stash on the shelf" : "Drop files on the notch to stash them")
                .font(.system(size: prominent ? 14 : 12, weight: .medium, design: .rounded))
            if !prominent {
                Text("Kept \(Self.retentionDays) days · drag them out anywhere")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .foregroundStyle(.white.opacity(prominent ? 1 : 0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(prominent ? 0.05 : 0))
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.white.opacity(prominent ? 0.7 : 0.28))
        }
    }

    /// `ShelfStore.maxAge` in days, not a literal 7.
    static var retentionDays: Int { Int(ShelfStore.maxAge / 86_400) }
}
```

(`RoundedRectangle.fill(...).strokeBorder` does not chain; use a `ZStack` of
the fill and the stroke.)

- [ ] **Step 4: Run** `swift test` — whole suite. Expect `PanelRenderingTests`
  green; fix any `PanelTabBarTests` scan string (the `ForEach(...)` line is
  unchanged so it should pass); `CameraControllerTests` unaffected.

- [ ] **Step 5: Mutation.** In `PanelHeader`, replace `Color.clear.frame(width: layout.notchGap)` with `EmptyView()`; `theHeaderStaysOutOfTheNotch` must fail. Revert.

- [ ] **Step 6: Commit** `feat: the panel opens into the ears — header, media column, module pane`

---

### Task 8: Shelf tiles and the empty state

**Files:**
- Modify: `Sources/CreativeNotchUI/Shelf/ShelfView.swift`
- Test: extend `PanelRenderingTests` with `theEmptyShelfDrawsATarget`.

**Interfaces:**
- Consumes: `DropTargetView`, `AppState.onRemoveShelfItem` via `ShelfView(store:onRemove:)`.

- [ ] **Step 1: Failing test** (append to `PanelRenderingTests`)

```swift
    @Test func theEmptyShelfDrawsATarget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID())")
        let s = Self.state(media: false); s.shelf = try ShelfStore(directory: dir)
        s.transition(to: .open(.shelf))
        let b = try #require(Self.bitmap(s))
        // The dashed border's bottom edge sits near the pane's bottom.
        #expect(Self.ink(b, in: CGRect(x: 40, y: 236, width: 540, height: 6)) > 0.03)
    }
```

- [ ] **Step 2: Run** — fails (today's empty state is one centred label).

- [ ] **Step 3: Implement**

```swift
struct ShelfView: View {
    let store: ShelfStore
    var onRemove: (UUID) -> Void = { _ in }

    private let itemSize = CGSize(width: 64, height: 64)

    var body: some View {
        if store.items.isEmpty {
            DropTargetView()
        } else {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.items) { item in
                            ShelfItemView(item: item, size: itemSize) { onRemove(item.id) }
                                .draggable(item.url)
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 6)
                    .frame(minWidth: proxy.size.width, alignment: .center)
                }
            }
        }
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    let size: CGSize
    let onRemove: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    }
                Image(nsImage: image ?? ShelfThumbnails.shared.icon(for: item.url))
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: size.width - 20, height: size.height - 20)
                    .frame(width: size.width, height: size.height)
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color(white: 0.2)))
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .accessibilityLabel("Remove \(item.displayName)")
                }
            }
            .frame(width: size.width, height: size.height)

            Text(item.displayName)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: size.width + 8)
        }
        .onHover { hovering = $0 }
        .task { image = await ShelfThumbnails.shared.thumbnail(for: item.url, size: size) }
    }
}
```

- [ ] **Step 4: Run** `swift test` — green. **Step 5:** make the empty branch return `Text("Drag files here")`; the new test fails. Revert.
- [ ] **Step 6: Commit** `feat: shelf tiles with a backing, a remove affordance, and an empty state that explains itself`

---

### Task 9: Clipboard rows

**Files:**
- Modify: `Sources/CreativeNotchUI/Clipboard/ClipboardView.swift`
- Test: `Tests/CreativeNotchUITests/ClipboardPreviewTests.swift` — add `theRowLabelIsTheCoreClockTime`.

**Interfaces:**
- Consumes: `ClipboardKind`, `ClipboardTimeLabel` (T3). New signature `ClipboardView(store:now:onPaste:)`.
- Produces: `ClipboardRowModel.timeText(entry:now:) -> String` (a thin, testable pass-through so the view's argument order is pinned).

- [ ] **Step 1: Failing test**

```swift
    @Test func theRowLabelIsTheCoreClockTime() {
        let added = Date(timeIntervalSinceReferenceDate: 800_000)
        let now = added.addingTimeInterval(120)
        let entry = ClipboardEntry(id: UUID(), content: .text("x"), addedAt: added)
        #expect(ClipboardRowModel.timeText(entry: entry, now: now)
                == ClipboardTimeLabel.text(addedAt: added, now: now))
    }
```

- [ ] **Step 2: Run** — compile error.

- [ ] **Step 3: Implement**

```swift
/// The row's derived strings, kept out of the view so the argument order
/// into Core is pinned by a test.
enum ClipboardRowModel {
    static func timeText(entry: ClipboardEntry, now: Date) -> String {
        ClipboardTimeLabel.text(addedAt: entry.addedAt, now: now)
    }
}

struct ClipboardView: View {
    let store: ClipboardStore
    let now: Date
    let onPaste: (ClipboardEntry) -> Void

    var body: some View {
        if store.entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 22, weight: .medium))
                Text("Nothing copied yet").font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(store.entries) { entry in
                        ClipboardRow(entry: entry, time: ClipboardRowModel.timeText(entry: entry, now: now)) {
                            onPaste(entry)
                        }
                    }
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let time: String
    let onPaste: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPaste) {
            HStack(spacing: 9) {
                tile
                Text(ClipboardPreview.text(for: entry.content))
                    .font(kind == .code
                          ? .system(size: 11, design: .monospaced)
                          : .system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(hovering ? "Paste ↩" : time)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.4))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.08 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Paste \(ClipboardPreview.text(for: entry.content)), copied \(time)")
    }

    private var kind: ClipboardKind { ClipboardKind.classify(entry.content) }

    @ViewBuilder
    private var tile: some View {
        Group {
            if case .image(let data, _) = entry.content, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08))
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
```

Update the call site in `NotchRootView.openContent` (already passes `now:`
from Task 7).

- [ ] **Step 4: Run** `swift test` — green. **Step 5:** swap `addedAt`/`now` in `timeText`; the test fails. Revert.
- [ ] **Step 6: Commit** `feat: clipboard rows with a kind tile and the time they were copied`

---

### Task 10: Battery gauge

**Files:**
- Modify: `Sources/CreativeNotchUI/Power/PowerView.swift`
- Test: `Tests/CreativeNotchUITests/PowerPanelRenderingTests.swift` — add `chargingIsDrawnInADifferentColourThanLow`.

- [ ] **Step 1: Failing test**

```swift
    /// The gauge's fill is the one colour on the tab, and it must change.
    @Test func chargingAndLowDrawDifferently() throws {
        #expect(try #require(Self.panelPixels(level: 15, source: .wall, isCharging: true))
                != #require(Self.panelPixels(level: 15, source: .battery, isCharging: false)))
    }
```

(This passes today because the state string differs — so also assert the
tone directly through the view's helper:)

```swift
    @Test func theGaugeReadsItsToneFromCore() {
        #expect(PowerView.fill(for: PowerSnapshot(level: 15, source: .battery, isCharging: false, isLowPowerMode: false)) == .yellow)
        #expect(PowerView.fill(for: PowerSnapshot(level: 15, source: .wall, isCharging: true, isLowPowerMode: false)) == .green)
        #expect(PowerView.fill(for: PowerSnapshot(level: 80, source: .battery, isCharging: false, isLowPowerMode: false)) == .white)
    }
```

- [ ] **Step 2: Run** — compile error (`PowerView.fill(for:)`).

- [ ] **Step 3: Implement**

```swift
struct PowerView: View {
    let snapshot: PowerSnapshot?

    /// The gauge's fill, from Core's rule. Static so the mapping is testable
    /// without rendering.
    static func fill(for snapshot: PowerSnapshot) -> Color {
        switch PowerGaugeTone.tone(level: snapshot.level, isCharging: snapshot.isCharging) {
        case .normal:   return .white
        case .low:      return .yellow
        case .charging: return .green
        }
    }

    var body: some View {
        if let snapshot {
            HStack(spacing: 18) {
                gauge(snapshot)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(snapshot.level)%")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text(PowerLabel.state(source: snapshot.source, isCharging: snapshot.isCharging, isCharged: snapshot.isCharged))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    HStack(spacing: 8) {
                        Text("Low Power Mode")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(snapshot.isLowPowerMode ? "On" : "Off")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.10)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 8)
        } else {
            Text("Reading power state…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func gauge(_ s: PowerSnapshot) -> some View {
        let level = CGFloat(min(100, max(0, s.level))) / 100
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.6), lineWidth: 2.5)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Self.fill(for: s))
                .frame(width: max(6, (88 - 12) * level))
                .padding(6)
        }
        .frame(width: 88, height: 44)
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.6))
                .frame(width: 5, height: 16).offset(x: 8)
        }
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 4: Run** — green. **Step 5:** make `fill(for:)` always return `.white`; the tone test fails. Revert.
- [ ] **Step 6: Commit** `feat: the battery tab draws a gauge`

---

### Task 11: Timer restyled, stock styles gone

**Files:**
- Modify: `Sources/CreativeNotchUI/Timer/TimerTabView.swift`
- Test: `Tests/CreativeNotchUITests/PanelRenderingTests.swift` — add `noStockControlStyleSurvivesInTheUI` (source scan) and `theTrackFillsFromCore`.

- [ ] **Step 1: Failing tests**

```swift
    /// Stock styles resolve colours against the appearance and once drew
    /// black-on-black (`NotchPanel.swift:43`). The panel has its own.
    @Test func noStockControlStyleSurvivesInTheUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CreativeNotchUI")
        let e = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for banned in [".borderedProminent", ".bordered)", ".roundedBorder"] {
                #expect(!text.contains(banned), "\(url.lastPathComponent) still uses \(banned)")
            }
        }
    }

    @Test func theTrackFillsFromCore() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        #expect(TimerTabView.trackFraction(c, at: t0.addingTimeInterval(150)) == TimerProgress.fraction(c, at: t0.addingTimeInterval(150)))
    }
```

- [ ] **Step 2: Run** — the scan fails on `TimerTabView.swift`; the second fails to compile.

- [ ] **Step 3: Implement** — rewrite `idle` and `running` in `TimerTabView`:

```swift
    static func trackFraction(_ countdown: Countdown, at now: Date) -> Double {
        TimerProgress.fraction(countdown, at: now)
    }

    private var idle: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { minutes in
                    Button("\(minutes) min") { onStart(TimeInterval(minutes) * 60) }
                        .buttonStyle(NotchButtonStyle(.quiet))
                }
            }
            HStack(spacing: 8) {
                stepButton("minus", disabled: customMinutes == TimerStepper.minimum) {
                    customMinutes = TimerStepper.decrement(customMinutes)
                }
                TextField("", value: $customMinutes, format: .number)
                    .textFieldStyle(NotchFieldStyle())
                    .frame(width: 52)
                    .onSubmit { start() }
                    .onChange(of: customMinutes) { _, typed in
                        customMinutes = min(TimerStepper.maximum, max(TimerStepper.minimum, typed))
                    }
                    .accessibilityLabel("Minutes")
                stepButton("plus", disabled: customMinutes == TimerStepper.maximum) {
                    customMinutes = TimerStepper.increment(customMinutes)
                }
                Button("Start", action: start)
                    .buttonStyle(NotchButtonStyle(.prominent))
                    .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 12, height: 12)
        }
        .buttonStyle(NotchButtonStyle(.quiet))
        .disabled(disabled)
        .accessibilityLabel(symbol == "plus" ? "Longer" : "Shorter")
    }

    private func running(_ countdown: Countdown) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(TimerDisplay.text(remaining: countdown.remaining(at: now)))
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text("left")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white.opacity(countdown.isPaused ? 0.45 : 0.95))

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(.white.opacity(countdown.isPaused ? 0.45 : 0.95))
                        .frame(width: g.size.width * Self.trackFraction(countdown, at: now))
                }
            }
            .frame(width: 220, height: 4)

            HStack(spacing: 8) {
                if countdown.isPaused {
                    Button("Resume", action: onResume).buttonStyle(NotchButtonStyle(.prominent))
                } else {
                    Button("Pause", action: onPause).buttonStyle(NotchButtonStyle(.quiet))
                }
                Button("Cancel", action: onCancel).buttonStyle(NotchButtonStyle(.quiet))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

`TimerDisplay.text` returns `"18m"` for minutes and `"0:45"` for the last
minute; the "left" suffix reads correctly after both.

- [ ] **Step 4: Run** `swift test` — green (includes `TimerTabTests`, which test the presets and stepper logic, not styles).
- [ ] **Step 5:** reintroduce `.buttonStyle(.bordered)` on Cancel; the scan fails. Revert.
- [ ] **Step 6: Commit** `feat: the timer speaks the panel's vocabulary`

---

### Task 12: Settings as a grouped form

**Files:**
- Modify: `Sources/CreativeNotchUI/PreferencesWindow.swift` (`PreferencesRow`, `PreferencesView`, window size)
- Modify: `Tests/CreativeNotchUITests/PreferencesWindowTests.swift` — add `everySectionIsNonEmptyAndEveryRowHasASymbol`.

**Interfaces:**
- Produces: `PreferencesRow` gains `section: PreferencesSection`, `symbolName: String`, `tint: Color`; `enum PreferencesSection: CaseIterable { case notch, music, camera, system, shortcut; var title: String; var footer: String? }`.

- [ ] **Step 1: Failing test**

```swift
    @Test func everySectionIsNonEmptyAndEveryRowHasASymbol() {
        for section in PreferencesSection.allCases {
            #expect(PreferencesView.rows.contains { $0.section == section }, "\(section) has no rows")
        }
        #expect(PreferencesView.rows.allSatisfy { !$0.symbolName.isEmpty })
    }
```

- [ ] **Step 2: Run** — compile error.

- [ ] **Step 3: Implement.** Keep `rows` as the single list (the existing test
  compares it against `ModuleID.allCases`). Add:

```swift
enum PreferencesSection: CaseIterable {
    case notch, music, camera, system, shortcut

    var title: String {
        switch self {
        case .notch:    return "In the notch"
        case .music:    return "Music"
        case .camera:   return "Camera and privacy"
        case .system:   return "System"
        case .shortcut: return "Shortcut"
        }
    }

    /// The longer, honest note that used to sit under every toggle.
    var footer: String? {
        switch self {
        case .notch:
            return "The shelf costs nothing when idle; switching it off hides the tab and refuses drops, it does not save battery. Clipboard history is the only repeating timer in the app."
        case .music:
            return "Now playing runs a helper process; switching it off terminates it. The media framework stays mapped until the next launch."
        case .camera:
            return "The camera is the only module that costs anything while it runs: the light is on whenever the preview is, and a clip keeps recording if you close the notch. The indicator is notification-driven and costs nothing while nothing is capturing."
        case .system:
            return "Releases a global event tap when switched off."
        case .shortcut:
            return "No shortcut is set until you choose one — any default would risk colliding with a launcher you already use."
        }
    }
}
```

Each `PreferencesRow` gets `section`, `symbolName`, `tint` and a **one-line**
`detail`:

| module | section | symbol | tint | detail |
|---|---|---|---|---|
| shelf | .notch | tray.full | .blue | Drag files onto the notch to stash them for a week. |
| clipboard | .notch | doc.on.clipboard | .purple | The last 50 things you copied. |
| timer | .notch | timer | .orange | A countdown, in the ear of the notch. |
| power | .notch | battery.100percent | .green | Level, charging state and Low Power Mode. |
| mediaMetadata | .music | music.note | .pink | Title, artist and artwork. |
| mediaControls | .music | playpause | .pink | Play, pause and skip. |
| camera | .camera | camera | .gray | A mirror under the lens, a shutter and a record button. |
| captureIndicator | .camera | record.circle | .red | Shows when another app is using the camera or microphone. |
| hud | .system | speaker.wave.2 | .indigo | Volume and brightness where macOS shows nothing. |
| hotkey | .shortcut | command | .gray | Open the notch from anywhere. |

Body:

```swift
    var body: some View {
        Form {
            ForEach(PreferencesSection.allCases, id: \.self) { section in
                Section {
                    ForEach(Self.rows.filter { $0.section == section }) { row in
                        moduleRow(row)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer { Text(footer) }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func moduleRow(_ row: PreferencesRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { controller.isEnabled(row.module) },
                set: { controller.setEnabled($0, for: row.module) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.body.weight(.medium))
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: row.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(row.tint))
                }
            }
            if row.module == .hotkey, controller.isEnabled(.hotkey), let hotKey = controller.hotKeyController {
                HotKeyRow(controller: hotKey, recorder: controller.recorder(for: hotKey),
                          label: hotKey.combo.map { HotKeyGlyphs.label($0, key: KeyCodeDisplay.character(for: $0.keyCode)) })
                    .padding(.leading, 36)
            }
            if let warning = Self.warning(for: row.module, controller: controller) {
                Text(warning).font(.caption).foregroundStyle(.orange).padding(.leading, 36)
            }
        }
    }
```

Window: `NSRect(x: 0, y: 0, width: 520, height: 620)`, title "CreativeNotch Settings".

- [ ] **Step 4: Run** `swift test` — green (existing `PreferencesWindowTests` still see all `ModuleID`s in `rows`).
- [ ] **Step 5:** remove the `hud` row's section membership by giving it `.notch`; the "System has no rows" assertion fails. Revert.
- [ ] **Step 6: Commit** `feat: Settings as a grouped form`

---

### Task 13: Onboarding, three rows

**Files:**
- Modify: `Sources/CreativeNotchUI/OnboardingWindow.swift` (`OnboardingView.body`)

- [ ] **Step 1: Implement** (behaviour unchanged, `OnboardingControllerTests` cover the controller)

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("One permission, to stay quiet")
                    .font(.title2.weight(.semibold))
                Text("CreativeNotch asks for Accessibility access for a single reason.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                point("keyboard", "It notices the volume and brightness keys.",
                      "That is the only thing the permission is used for.")
                point("speaker.slash", "So it can stand aside.",
                      "macOS already shows its own overlay for those keys. The notch speaks up only where macOS gives no feedback — Control Center, Siri, another app.")
                point("rectangle.on.rectangle", "Without it, everything still works.",
                      "You will just see both indicators at once when you use the keys.")
            }

            Spacer()

            HStack {
                Label(trusted ? "Granted" : "Not granted",
                      systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(trusted ? .green : .secondary)
                Spacer()
                if !trusted {
                    Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    Button("Grant Access") { Permissions.requestAccessibility() }
                        .keyboardShortcut(.defaultAction)
                }
                Button(trusted ? "Done" : "Skip for now", action: onDone)
                    .keyboardShortcut(trusted ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 340)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = Permissions.isAccessibilityTrusted
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
```

Window `contentRect` height 340.

- [ ] **Step 2: Run** `swift test` — green. **Step 3: Commit** `feat: onboarding in three rows`

---

### Task 14: Docs and a look at the real thing

**Files:**
- Modify: `README.md` (Status table: one line "Redesigned panel"; remove the "Screenshot goes here" comment only if a screenshot is added), `docs/ARCHITECTURE.md` (a paragraph under Geometry: `PanelLayout` is the one place the header split is computed; the hairline and radius; why no shadow).

- [ ] **Step 1:** `./Scripts/dev.sh` and open the panel on each tab, on the real notch. Check: header stays out of the housing; tabs have tooltips; gear closes the panel and opens Settings; Clear and × work; a drag shows the target; the timer field still takes typing.
- [ ] **Step 2:** Write the ARCHITECTURE paragraph and README line.
- [ ] **Step 3: Commit** `docs: record the redesigned panel`

## Definition of done

- `swift test` green; count printed in the PR.
- Every new test's mutation named in the PR.
- No file under `Sources/CreativeNotchUI/` contains `.borderedProminent`, `.bordered)` or `.roundedBorder`.
- `NotchShape.visibleRect` and `NotchGeometry.expandedSize` unchanged (`git diff main -- Sources/CreativeNotchCore/NotchShape.swift` is empty).
- PR against `main` with the before/after renders from the proposal page.

## Deliberately not built

Spec §11: ⌘1–5 tab switching, shelf reordering, reveal-in-Finder, a
sidebar in Settings.
