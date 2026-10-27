import AppKit
import QuartzCore

/// Fades the panel window out on the display it leaves and in on the one it
/// arrives at (2026-10-28). `AppDelegate` decides when, and moves the window
/// in between; this only animates.
///
/// A seam so the wiring is testable without an animation: a test hands in a
/// fake that holds each completion until it says so, and a delegate a test
/// builds gets `InstantPanelFader`, so no suite has to await a trip.
@MainActor
protocol PanelFader {
    /// Takes the window to alpha 0 over `duration`, then calls `done`.
    func fadeOut(_ window: NSWindow, over duration: Double, then done: @escaping @MainActor () -> Void)

    /// Takes the window to alpha 1 over `duration`, its content starting
    /// `drop` points higher and coming down into place, then calls `done`.
    func fadeIn(
        _ window: NSWindow, over duration: Double, droppingFrom drop: CGFloat,
        then done: @escaping @MainActor () -> Void
    )
}

/// No animation: the alpha is set and `done` called before returning. What
/// every delegate starts with; only the real launch swaps in
/// `AnimatedPanelFader`.
struct InstantPanelFader: PanelFader {
    func fadeOut(_ window: NSWindow, over duration: Double, then done: @escaping @MainActor () -> Void) {
        window.alphaValue = 0
        done()
    }

    func fadeIn(
        _ window: NSWindow, over duration: Double, droppingFrom drop: CGFloat,
        then done: @escaping @MainActor () -> Void
    ) {
        window.alphaValue = 1
        done()
    }
}

/// The real fades: the window's own alpha through `NSAnimationContext`, and
/// the drop as a Core Animation offset on the content's layer.
///
/// **Why the window's alpha and not a SwiftUI opacity.** The window server
/// composites a window's alpha, so a fade redraws nothing: the SwiftUI tree,
/// which is the whole panel even while only the notch shows, is not asked
/// for a frame. And the window is invisible when it moves, so the move and
/// the redraw it needs can never be seen out of step on either display --
/// the one-frame flicker that was looked for, and not found, on the old jump.
///
/// **Why the drop is the content and not the window.** The window could
/// start a few points higher and slide down, but at the top of the built-in
/// display "higher" is the bottom of the display stacked above it, which
/// would show a sliver of black there. The content's layer is clipped by
/// the window instead, so the shape comes down out of the top edge on its
/// own display only. It animates the offset from `drop` to 0 over a layer
/// whose own value stays at none, so nothing is left offset if the animation
/// is cut short or the window is ordered out. Up is +y only because the
/// content view is not flipped, which a wiring test holds.
struct AnimatedPanelFader: PanelFader {
    func fadeOut(_ window: NSWindow, over duration: Double, then done: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in done() }
        })
    }

    func fadeIn(
        _ window: NSWindow, over duration: Double, droppingFrom drop: CGFloat,
        then done: @escaping @MainActor () -> Void
    ) {
        if drop > 0, let content = window.contentView {
            content.wantsLayer = true
            let fall = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
            fall.fromValue = drop
            fall.toValue = 0
            fall.duration = duration
            fall.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.layer?.add(fall, forKey: Self.dropKey)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }, completionHandler: {
            Task { @MainActor in done() }
        })
    }

    private static let dropKey = "creativeNotch.drop"
}
