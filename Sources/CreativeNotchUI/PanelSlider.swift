import AppKit
import QuartzCore

/// Slides the panel window along the menu bar when the pill moves on its own
/// display (2026-10-28). `AppDelegate` decides when (`PanelMove.slide`); this
/// only animates.
///
/// A seam so the wiring is testable without an animation: a test hands in a
/// fake that holds each completion until it says so, and a delegate a test
/// builds gets `InstantPanelSlider`, so no suite has to await a slide.
@MainActor
protocol PanelSlider {
    /// Takes the window from wherever it is now to `frame` over `duration`,
    /// then calls `done`. Asked again before it has arrived, it sets off for
    /// the new frame from where it has got to, and the first slide's `done`
    /// is called at once.
    func slide(
        _ window: NSWindow, to frame: CGRect, over duration: Double,
        then done: @escaping @MainActor () -> Void
    )

    /// Puts the window at `frame` now, ending any slide under way.
    func stop(_ window: NSWindow, at frame: CGRect)
}

/// No animation: the frame is set and `done` called before returning. What
/// every delegate starts with; only the real launch swaps in
/// `AnimatedPanelSlider`.
struct InstantPanelSlider: PanelSlider {
    func slide(
        _ window: NSWindow, to frame: CGRect, over duration: Double,
        then done: @escaping @MainActor () -> Void
    ) {
        window.setFrame(frame, display: true)
        done()
    }

    func stop(_ window: NSWindow, at frame: CGRect) {
        window.setFrame(frame, display: true)
    }
}

/// The real slide: the window's own frame through `NSAnimationContext`.
///
/// **Why the window and not the drawing.** A slide is only ever the same
/// picture further along (`PanelMove.isAlongTheBar`): the window keeps its
/// size, so moving it is all there is to do. AppKit steps the frame on the
/// main thread -- measured, a step every ~8.5ms, on a 60Hz display as on the
/// 120Hz built-in -- and the window server draws the window at each place
/// from what it already has: nothing in the SwiftUI tree is laid out or
/// redrawn on the way. Profiled over twelve slides, SwiftUI rendered in 2 of
/// the main thread's 1ms samples, and the steps took ~60, inside
/// `NSWindow`'s frame change and its window-server transactions. Moving the
/// shape inside a still window instead would mean a window moved at once to
/// where the pill ends up, the region it accepts clicks in there before the
/// shape is, and a SwiftUI frame for every step.
///
/// **Why a frame is never just set during a slide.** Measured: a
/// `setFrame` on a window whose frame is animating is undone by the
/// animation's next step, ~2ms later, and the slide carries on to where it
/// was going. A new animated frame replaces the running one and starts from
/// where the window is, so `stop` is an animated frame of no duration.
struct AnimatedPanelSlider: PanelSlider {
    func slide(
        _ window: NSWindow, to frame: CGRect, over duration: Double,
        then done: @escaping @MainActor () -> Void
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = Self.curve
            window.animator().setFrame(frame, display: true)
        }, completionHandler: {
            Task { @MainActor in done() }
        })
    }

    func stop(_ window: NSWindow, at frame: CGRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Off at a fair pace and settling gently. Not ease-in-out: a slide
    /// replaced halfway sets off again from where it is, and ease-in-out
    /// would hold it there at a standstill before it turned back.
    private static let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
}
