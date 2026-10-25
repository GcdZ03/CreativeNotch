import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

@MainActor
struct TimerDonePeekRenderingTests {
    private static let done = TimerCompletion(duration: 1500, lateness: 0)

    private static func peekPixels(_ content: PeekContent) -> Data? {
        let state = AppState()
        state.transition(to: .peek(content))
        let renderer = ImageRenderer(
            content: NotchRootView(app: state).frame(width: 400, height: 120)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Delete `case .peek(.timerDone…)` from `NotchRootView` and this fails:
    /// the peek falls through to `default`, which draws the app name. That
    /// is exactly how the now-playing peek shipped broken.
    @Test func theTimerPeekDoesNotDrawTheAppName() throws {
        let timer = try #require(Self.peekPixels(.timerDone(Self.done)))
        let fallback = try #require(Self.peekPixels(.dragTarget))
        #expect(Render.differs(timer, fallback))
    }

    @Test func theTimerPeekDrawsItsOwnDetail() throws {
        let onTime = try #require(Self.peekPixels(.timerDone(Self.done)))
        let late = try #require(Self.peekPixels(
            .timerDone(TimerCompletion(duration: 1500, lateness: 7200))
        ))
        #expect(Render.differs(onTime, late))
    }

    /// "Timer | 1m" read as a timer's name, not a timer that had finished
    /// (2026-10-25, seen after a full-screen app hid the notch). The peek
    /// says so in words, in both layouts.
    @Test func thePeekSaysTheTimerIsDone() {
        let peek = TimerDonePeekView(completion: TimerCompletion(duration: 60, lateness: 0))
        #expect(peek.title == "Timer done")
        #expect(peek.singleLine == "Timer done · 1m")
    }

    /// Rendered directly, not through the root view: switching the anchor
    /// also changes the panel *shape*, so a root-view comparison would
    /// differ regardless of whether the gap was honoured.
    @Test func theTimerPeekLaysOutAroundAPhysicalNotch() throws {
        func pixels(gap: CGFloat) -> Data? {
            let renderer = ImageRenderer(
                content: TimerDonePeekView(completion: Self.done, notchGap: gap)
                    .frame(width: 400, height: 32)
            )
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }
        #expect(try #require(pixels(gap: 0)) != (try #require(pixels(gap: 179))))
    }
}
