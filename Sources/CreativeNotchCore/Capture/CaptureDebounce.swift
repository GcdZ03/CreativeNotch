import Foundation

/// Turns a stream of property notifications into a stable state.
///
/// **Measured, and this is why the type exists.** CoreMediaIO fires **three
/// events when a camera starts** -- values `0`, `1`, `1` within about 56
/// milliseconds -- and **one when it stops**. An indicator that toggled its own
/// state on every callback would flicker every time any application opened a
/// camera.
///
/// So the rule is: **read the value, do not react to the notification.** A
/// callback is a prompt to re-read, and a re-read that matches what is already
/// shown changes nothing. That is the same shape `MediaCoalescer` uses for
/// now-playing -- this project keeps meeting the same problem.
public struct CaptureDebounce: Equatable, Sendable {

    private var current: CaptureUse

    public init(initial: CaptureUse = .none) {
        self.current = initial
    }

    public var state: CaptureUse { current }

    /// Accepts a fresh reading. Returns the new state **only if it changed**,
    /// and `nil` otherwise -- so a caller that publishes on every non-nil
    /// result cannot produce a redundant redraw.
    public mutating func accept(_ next: CaptureUse) -> CaptureUse? {
        guard next != current else { return nil }
        current = next
        return next
    }
}
