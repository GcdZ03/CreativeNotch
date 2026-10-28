import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the recomposed panel draws where the spec says (spec §5).
///
/// Pixel tests, in the shape `PowerPanelRenderingTests` established: build
/// an `AppState`, give it real geometry, render `NotchRootView` offscreen,
/// and ask where the ink is. `ImageRenderer` does not run `ScrollView`
/// content, so list *contents* are asserted through their pure functions;
/// what is asserted here is the frame around them.
@MainActor
struct PanelRenderingTests {

    /// 14" MacBook Pro-ish: a 190×32 notch, a 620×260 panel centred on it.
    /// In the rendered image the notch band is x 215..405, y 0..32.
    static func state(notch: Bool = true, media: Bool = true) -> AppState {
        let s = AppState()
        let anchor: CreativeNotchCore.Anchor = notch
            ? .notch(CGRect(x: 661, y: 950, width: 190, height: 32))
            : .pill(CGRect(x: 666, y: 942, width: 180, height: 32))
        s.setGeometry(
            anchor: anchor,
            panelFrame: CGRect(x: 446, y: anchor.rect.maxY - 260, width: 620, height: 260)
        )
        s.hasBattery = true
        s.showsMediaControls = media
        s.power = PowerSnapshot(level: 67, source: .battery, isCharging: false, isLowPowerMode: false)
        return s
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(
            content: NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
                .frame(width: 620, height: 260)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Fraction of pixels in `rect` (top-left origin, points) that are not
    /// black. Transparent pixels count as black, which is what they are on
    /// top of the black shape.
    static func ink(_ b: NSBitmapImageRep, in rect: CGRect) -> Double {
        var lit = 0, total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let c = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if c.alphaComponent > 0.05,
                   c.redComponent + c.greenComponent + c.blueComponent > 0.15 {
                    lit += 1
                }
            }
        }
        return total == 0 ? 0 : Double(lit) / Double(total)
    }

    /// The header draws in the ears and leaves the camera housing black.
    /// The old layout centred the tab bar straight under the notch.
    @Test func theHeaderStaysOutOfTheNotch() throws {
        let s = Self.state()
        s.transition(to: .open(.shelf))
        let b = try #require(Self.bitmap(s))

        #expect(Self.ink(b, in: CGRect(x: 220, y: 2, width: 180, height: 28)) == 0,
                "something was drawn behind the camera housing")
        #expect(Self.ink(b, in: CGRect(x: 0, y: 2, width: 215, height: 28)) > 0.01,
                "no tabs in the leading ear")
        #expect(Self.ink(b, in: CGRect(x: 405, y: 2, width: 215, height: 28)) > 0.01,
                "no gear in the trailing ear")
    }

    /// The media column is a fixed left column when controls are on, and
    /// absent when they are off. The cover tile's own rectangle is what is
    /// checked: lit by the placeholder tile with the column, black without.
    @Test func theMediaColumnIsDrawnOnTheLeftWhenControlsAreOn() throws {
        let with = Self.state(media: true)
        with.transition(to: .open(.timer))
        let without = Self.state(media: false)
        without.transition(to: .open(.timer))
        let a = try #require(Self.bitmap(with))
        let c = try #require(Self.bitmap(without))

        let cover = CGRect(x: 22, y: 60, width: 60, height: 56)
        #expect(Self.ink(a, in: cover) > 0.5, "no cover tile where the column should be")
        #expect(Self.ink(c, in: cover) < 0.05, "something drawn where the absent column would be")
    }

    /// The camera takes the whole body: no column beside the preview.
    @Test func theCameraTabHasNoMediaColumn() throws {
        let s = Self.state(media: true)
        s.transition(to: .open(.camera))
        let b = try #require(Self.bitmap(s))
        #expect(Self.ink(b, in: CGRect(x: 22, y: 60, width: 60, height: 56)) < 0.05)
    }

    /// On a pill there is no housing to avoid; the tabs start at the left.
    @Test func aPillDrawsTheHeaderAcrossTheMiddle() throws {
        let s = Self.state(notch: false)
        s.transition(to: .open(.shelf))
        let b = try #require(Self.bitmap(s))
        #expect(Self.ink(b, in: CGRect(x: 4, y: 2, width: 60, height: 28)) > 0.01)
    }

    /// A dashed border lights the top edge of the content area; the old
    /// bare centred label left it black.
    @Test func receivingDrawsATargetNotJustALabel() throws {
        let s = Self.state()
        s.transition(to: .receiving)
        let b = try #require(Self.bitmap(s))
        #expect(Self.ink(b, in: CGRect(x: 30, y: 41, width: 560, height: 5)) > 0.05)
    }

    /// The edge (spec §4): a hairline on the expanded shape, none on the
    /// closed notch, which must vanish into the housing.
    @Test func theHairlineIsOnTheOpenPanelOnly() throws {
        let open = Self.state()
        open.transition(to: .open(.shelf))
        let closed = Self.state()
        let a = try #require(Self.bitmap(open))
        let c = try #require(Self.bitmap(closed))
        // The panel's left edge, well below the header.
        #expect(Self.ink(a, in: CGRect(x: 0, y: 100, width: 1, height: 100)) > 0.5)
        // The closed notch occupies x 215..405, y 0..32; its left edge is black.
        #expect(Self.ink(c, in: CGRect(x: 215, y: 4, width: 1, height: 20)) == 0)
    }

    @Test func theShelfCountReadsAsEnglish() {
        #expect(NotchRootView.shelfCount(0) == "empty")
        #expect(NotchRootView.shelfCount(1) == "1 item")
        #expect(NotchRootView.shelfCount(4) == "4 items")
    }
}

/// The tabs, restyled (spec §5.4–5.8, §5.10).
@MainActor
struct TabRenderingTests {

    /// The empty shelf draws the dashed target; its bottom edge sits near
    /// the pane's bottom, where a bare centred label leaves black.
    @Test func theEmptyShelfDrawsATarget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID())")
        let s = PanelRenderingTests.state(media: false)
        s.shelf = try ShelfStore(directory: dir, trash: TestTrash.shelf)
        s.transition(to: .open(.shelf))
        let b = try #require(PanelRenderingTests.bitmap(s))
        #expect(PanelRenderingTests.ink(b, in: CGRect(x: 40, y: 243, width: 540, height: 6)) > 0.03)
    }

    /// Stock styles resolve colours against the appearance and once drew
    /// black-on-black (`NotchPanel.swift`). The panel has its own; and
    /// nothing in the UI may loop (spec §9) — with one named exception.
    ///
    /// `EqualizerBarsView` repeats while the music peek is on screen and
    /// only then (spec 2026-10-15). The exemption is by file, not by
    /// token, so a loop anywhere else still fails here, and `TimelineView`
    /// stays banned even there.
    ///
    /// The animators that loop are banned too (2026-10-28, review of #81):
    /// one with no trigger, which cycles for as long as it is on screen. A
    /// keyframe animator repeats unless told `repeating: false`, so leaving
    /// the word out loops too (second review). One on a trigger -- the
    /// morph's -- plays once per change and is allowed.
    @Test func noStockControlStyleOrRepeatingAnimationSurvivesInTheUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CreativeNotchUI")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let banned = [".borderedProminent", ".bordered)", ".roundedBorder", "TimelineView", ".repeatForever"]
        let loopAllowed = ["EqualizerBarsView.swift"]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Code only. A doc comment that says "no `TimelineView`" is the
            // rule being stated, not broken.
            let code = text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in banned {
                if token == ".repeatForever", loopAllowed.contains(url.lastPathComponent) { continue }
                #expect(!code.contains(token), "\(url.lastPathComponent) still uses \(token)")
            }
            for call in Self.loopingAnimators(in: code) {
                Issue.record("\(url.lastPathComponent) loops an animator: \(call)")
            }
        }
    }

    /// The keyframe and phase animator calls in `code` that loop: any whose
    /// arguments have no `trigger:`, unless they say `repeating: false`
    /// (which only a keyframe animator takes). SwiftUI defaults `repeating`
    /// to true, and only a literal `false` is known to stop; a flag might be
    /// true. The arguments are read to their closing bracket, so a nested
    /// call in them is not the end.
    static func loopingAnimators(in code: String) -> [String] {
        var found: [String] = []
        for name in ["keyframeAnimator(", "KeyframeAnimator(", "phaseAnimator(", "PhaseAnimator("] {
            var rest = code[...]
            while let hit = rest.range(of: name) {
                var depth = 1
                var end = hit.upperBound
                while end < rest.endIndex, depth > 0 {
                    if rest[end] == "(" { depth += 1 }
                    if rest[end] == ")" { depth -= 1 }
                    end = rest.index(after: end)
                }
                let call = String(rest[hit.lowerBound..<end])
                let loops = !call.contains("trigger:") && !call.contains("repeating: false")
                if loops { found.append(call) }
                rest = rest[end...]
            }
        }
        return found
    }

    /// The reader above, on calls written out: it is what decides, and a
    /// reader that found nothing would pass the ban whatever the UI did.
    @Test func theLoopingAnimatorsAreTheOnesThatRepeat() {
        #expect(Self.loopingAnimators(in: ".keyframeAnimator(initialValue: 1.0, trigger: morph) { c, v in c }").isEmpty)
        #expect(Self.loopingAnimators(in: ".keyframeAnimator(initialValue: CGSize(width: 1, height: 2), repeating: true) { c, v in c }").count == 1)
        #expect(Self.loopingAnimators(in: "KeyframeAnimator(initialValue: 0.0, repeating: true) { v in }").count == 1)
        #expect(Self.loopingAnimators(in: ".phaseAnimator([0.0, 1.0]) { c, p in c }").count == 1)
        #expect(Self.loopingAnimators(in: "PhaseAnimator([false, true]) { p in }").count == 1)
        #expect(Self.loopingAnimators(in: ".phaseAnimator([0.0, 1.0], trigger: tick) { c, p in c }").isEmpty)
        #expect(Self.loopingAnimators(in: "[UInt32](repeating: 0, count: 4)").isEmpty)
        // A keyframe animator repeats by default (`repeating: Bool = true`
        // in SwiftUICore), so the plain way to write one loops with neither
        // word in its arguments (2026-10-28, second review of #81).
        #expect(Self.loopingAnimators(in: ".keyframeAnimator(initialValue: 0.0) { c, v in c } keyframes: { _ in LinearKeyframe(1.0, duration: 1) }").count == 1)
        #expect(Self.loopingAnimators(in: "KeyframeAnimator(initialValue: 0.0) { v in } keyframes: { _ in LinearKeyframe(1.0, duration: 1) }").count == 1)
        // Only a literal `false` plays once; a flag may be true.
        #expect(Self.loopingAnimators(in: ".keyframeAnimator(initialValue: 0.0, repeating: false) { c, v in c }").isEmpty)
        #expect(Self.loopingAnimators(in: "KeyframeAnimator(initialValue: 0.0, repeating: spins) { v in }").count == 1)
    }

    @Test func theTrackFillsFromCore() throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        let at = t0.addingTimeInterval(150)
        #expect(TimerTabView.trackFraction(c, at: at) == TimerProgress.fraction(c, at: at))
        #expect(TimerTabView.trackFraction(c, at: at) == 0.25)
    }

    @Test func theGaugeReadsItsToneFromCore() {
        #expect(PowerView.fill(for: PowerSnapshot(level: 15, source: .battery, isCharging: false, isLowPowerMode: false)) == .yellow)
        #expect(PowerView.fill(for: PowerSnapshot(level: 15, source: .wall, isCharging: true, isLowPowerMode: false)) == .green)
        #expect(PowerView.fill(for: PowerSnapshot(level: 80, source: .battery, isCharging: false, isLowPowerMode: false)) == .white)
    }

    /// The paused word must be the easiest thing to read when paused, not
    /// the hardest: it no longer inherits the digits' dimming.
    @Test func thePausedCaptionReadsAboveTheDimmedDigits() {
        #expect(TimerTabView.captionOpacity(isPaused: true)
                > TimerTabView.digitsOpacity(isPaused: true))
        // Running, it stays the quieter of the two, as it always was.
        #expect(TimerTabView.captionOpacity(isPaused: false)
                < TimerTabView.digitsOpacity(isPaused: false))
        #expect(abs(TimerTabView.captionOpacity(isPaused: false) - 0.95 * 0.55) < 0.0001)
    }

    /// The gauge and the header cell draw the glyph Core picks, so the two
    /// cannot disagree about whether a low battery is marked.
    @Test func theBatteryGlyphComesFromCore() {
        let low = PowerSnapshot(level: 15, source: .battery, isCharging: false, isLowPowerMode: false)
        let charging = PowerSnapshot(level: 15, source: .wall, isCharging: true, isLowPowerMode: false)
        let normal = PowerSnapshot(level: 80, source: .battery, isCharging: false, isLowPowerMode: false)

        #expect(PowerView.glyph(for: charging, differentiateWithoutColor: false) == "bolt.fill")
        #expect(PowerView.glyph(for: low, differentiateWithoutColor: false) == nil)
        #expect(PowerView.glyph(for: low, differentiateWithoutColor: true) == "exclamationmark")
        #expect(PowerView.glyph(for: normal, differentiateWithoutColor: true) == nil)
        #expect(BatteryCell.glyph(level: 15, isCharging: false, differentiateWithoutColor: true)
                == "exclamationmark")
        #expect(BatteryCell.glyph(level: 50, isCharging: true, differentiateWithoutColor: false)
                == "bolt.fill")
    }

    @Test func theClipboardRowLabelIsTheCoreClockTime() {
        let added = Date(timeIntervalSinceReferenceDate: 800_000)
        let now = added.addingTimeInterval(120)
        let entry = ClipboardEntry(id: UUID(), content: .text("x"), addedAt: added)
        #expect(ClipboardRowModel.timeText(entry: entry, now: now)
                == ClipboardTimeLabel.text(addedAt: added, now: now))
    }
}
