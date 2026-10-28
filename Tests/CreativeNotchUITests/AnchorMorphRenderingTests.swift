import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Where a morph draws the shape, rendered (2026-10-28, review of #81).
///
/// `AnchorMorphWiringTests` proves the app hands the view the right start,
/// and `theViewStartsTheShapeWhereTheMorphSays` that the view flips it. Not
/// that the view draws there: replacing the keyframe animator with the
/// resting frame passed every test. These render `NotchRootView` at a
/// pinned instant of the morph (`morphTime`) and look for the shape's ink,
/// the way the other rendering suites look for theirs.
@MainActor
struct AnchorMorphRenderingTests {

    /// A pill in the middle of a 620x260 window, its closed capsule at rest
    /// near the top centre, and a morph that starts it far to the left and
    /// lower: far enough that the two never overlap, so ink at one is not
    /// ink at the other.
    private static let from = CGRect(x: 60, y: 190, width: 40, height: 26)

    private func state(morph: Bool) -> AppState {
        let s = AppState()
        let anchor = CreativeNotchCore.Anchor.pill(CGRect(x: 666, y: 942, width: 180, height: 32))
        let frame = CGRect(x: 446, y: 714, width: 620, height: 260)
        s.setGeometry(anchor: anchor, panelFrame: frame.offsetBy(dx: -100, dy: 0))
        s.setGeometry(
            anchor: anchor, panelFrame: frame,
            morph: morph ? ShapeMorph(morph: AnchorMorph(from: Self.from), id: 1) : nil
        )
        return s
    }

    private func bitmap(_ s: AppState, at time: Double) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(
            content: NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0), morphTime: time)
                .frame(width: 620, height: 260)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Whether the shape is drawn at the middle of `rect` (top-left origin).
    private func inked(_ b: NSBitmapImageRep, _ rect: CGRect) -> Bool {
        LayoutRenderingTests.covered(b, CGPoint(x: rect.midX, y: rect.midY))
    }

    /// `from`, in the top-left space the render is in.
    private var start: CGRect {
        CGRect(x: Self.from.minX, y: 260 - Self.from.maxY, width: Self.from.width, height: Self.from.height)
    }

    /// The first frame of a morph is the old shape where it was, not the
    /// new one: drawn at `from`, nothing yet where it is going.
    @Test func theFirstFrameIsWhereTheOldShapeWas() throws {
        let s = state(morph: true)
        let resting = NotchRootView.drawnRect(for: s, now: Date(timeIntervalSinceReferenceDate: 0))
        #expect(!resting.intersects(start))
        let b = try #require(bitmap(s, at: 0))
        #expect(inked(b, start), "nothing drawn where the morph starts")
        #expect(!inked(b, resting), "the first frame is already the new shape")
    }

    /// Halfway through its time it is where the eased curve says, between
    /// the two; at the end it is the new shape, and nothing is left where
    /// it started.
    @Test func itEasesToTheNewShapeAndEndsThere() throws {
        let s = state(morph: true)
        let resting = NotchRootView.drawnRect(for: s, now: Date(timeIntervalSinceReferenceDate: 0))
        let half = AnchorMorph.rect(from: start, to: resting, progress: 0.5)
        #expect(!half.intersects(start))
        #expect(!resting.contains(CGPoint(x: half.midX, y: half.midY)))

        let middle = try #require(bitmap(s, at: AnchorMorph.standardDuration / 2))
        #expect(inked(middle, half), "not on the eased curve halfway")
        #expect(!inked(middle, start))

        let end = try #require(bitmap(s, at: AnchorMorph.standardDuration))
        #expect(inked(end, resting))
        #expect(!inked(end, start))
    }

    /// With no morph the shape is at rest from the first instant: the
    /// keyframes hold the progress at its end.
    @Test func withoutAMorphTheShapeIsAtRest() throws {
        let s = state(morph: false)
        let resting = NotchRootView.drawnRect(for: s, now: Date(timeIntervalSinceReferenceDate: 0))
        let b = try #require(bitmap(s, at: 0))
        #expect(inked(b, resting))
        #expect(!inked(b, start))
    }

    /// The keyframes the animator plays: from 0 evenly to 1 over the
    /// morph's time, and held at 1 without one.
    @Test func theKeyframesStepEvenlyOverTheMorph() {
        let morph = ShapeMorph(morph: AnchorMorph(from: Self.from), id: 1)
        let d = AnchorMorph.standardDuration
        #expect(NotchRootView.morphProgress(morph, at: 0) == 0)
        #expect(abs(NotchRootView.morphProgress(morph, at: d / 2) - 0.5) < 0.0001)
        #expect(NotchRootView.morphProgress(morph, at: d) == 1)
        #expect(NotchRootView.morphProgress(nil, at: 0) == 1)
    }
}
