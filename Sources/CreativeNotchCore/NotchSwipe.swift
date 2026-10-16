import CoreGraphics

/// A two-finger trackpad swipe on the notch (spec 2026-10-17).
///
/// Down opens, following the fingers; up closes the open panel; sideways on
/// the music peek skips a track. Pure: it is fed finger movement and asked
/// what it means, so every rule here is testable without a trackpad.
///
/// Everything is in **finger space** — positive y is the fingers moving
/// down the trackpad, positive x moving right — so the rules read the same
/// whichever scroll direction the user has chosen. `fingerDelta` converts.
public struct NotchSwipe: Equatable, Sendable {

    public enum Axis: Equatable, Sendable { case undecided, vertical, horizontal }

    public enum Outcome: Equatable, Sendable { case none, open, close, nextTrack, previousTrack }

    /// How far the fingers travel before a pull commits to opening or
    /// closing. Short enough to be a flick, long enough that resting two
    /// fingers on the notch while scrolling past does not open it.
    public static let commitDistance: CGFloat = 36

    /// Skipping a track is harder to undo than opening a panel, so it asks
    /// for a longer, deliberate swipe.
    public static let skipDistance: CGFloat = 60

    /// The first movement this large decides the axis for the whole swipe.
    public static let axisLockDistance: CGFloat = 8

    public private(set) var axis: Axis = .undecided
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var crossed = false

    public init() {}

    /// Event deltas into finger space. With natural scrolling the event's
    /// delta already points the way the fingers moved; without it, it is
    /// reversed.
    public static func fingerDelta(deltaX: CGFloat, deltaY: CGFloat, invertedFromDevice: Bool) -> CGVector {
        invertedFromDevice ? CGVector(dx: deltaX, dy: deltaY) : CGVector(dx: -deltaX, dy: -deltaY)
    }

    public mutating func began() {
        self = NotchSwipe()
    }

    /// Adds one step of finger movement. Returns `true` exactly once per
    /// swipe: on the step a vertical pull first reaches `commitDistance`,
    /// which is where a haptic belongs.
    @discardableResult
    public mutating func changed(fingerDX: CGFloat, fingerDY: CGFloat) -> Bool {
        dx += fingerDX
        dy += fingerDY
        if axis == .undecided, max(abs(dx), abs(dy)) >= Self.axisLockDistance {
            axis = abs(dx) > abs(dy) ? .horizontal : .vertical
        }
        guard axis == .vertical, !crossed, abs(dy) >= Self.commitDistance else { return false }
        crossed = true
        return true
    }

    /// How far the shape should follow the fingers: positive toward
    /// opening, negative toward closing, 1 at the commit threshold, and
    /// rubber-banded past it. Zero for a pull that would do nothing where
    /// it is, so nothing is drawn moving that will not act.
    public func pull(on presentation: NotchShape.Presentation) -> CGFloat {
        guard axis == .vertical else { return 0 }
        switch presentation {
        case .closed, .peek, .statusPeek, .mediaPeek:
            return dy > 0 ? Self.stretch(dy / Self.commitDistance) : 0
        case .expanded:
            return dy < 0 ? -Self.stretch(-dy / Self.commitDistance) : 0
        }
    }

    /// What the swipe does when the fingers lift.
    public func ended(on presentation: NotchShape.Presentation) -> Outcome {
        switch axis {
        case .undecided:
            return .none
        case .vertical:
            switch presentation {
            case .closed, .peek, .statusPeek, .mediaPeek:
                return dy >= Self.commitDistance ? .open : .none
            case .expanded:
                return dy <= -Self.commitDistance ? .close : .none
            }
        case .horizontal:
            guard presentation == .mediaPeek else { return .none }
            if dx <= -Self.skipDistance { return .nextTrack }
            if dx >= Self.skipDistance { return .previousTrack }
            return .none
        }
    }

    /// Linear to the threshold, then giving less and less.
    static func stretch(_ p: CGFloat) -> CGFloat {
        guard p > 1 else { return p }
        return 1 + (1 - 1 / (1 + (p - 1) * 0.5)) * 0.6
    }
}
