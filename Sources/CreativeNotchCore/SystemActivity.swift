import Foundation

/// What the machine is doing, as far as anything that wants to run on a
/// timer is concerned.
///
/// There is deliberately no `.idle` case. Detecting user idle means polling
/// `CGEventSource`, which would violate the very rule this enum exists to
/// serve. Idle back-off lives in `ClipboardPollSchedule` instead, which
/// already knows how long it has been since anything changed.
public enum SystemActivity: String, CaseIterable, Equatable, Sendable {
    case active, locked, asleep
}

/// The notifications this is folded from, named in the app's own terms so
/// `CreativeNotchCore` never has to know an `NSWorkspace` constant.
public enum SystemActivityEvent: Equatable, Sendable {
    case willSleep, didWake, screenLocked, screenUnlocked
}

/// Folds those events into a single activity.
///
/// Two independent booleans rather than one state, because sleeping and
/// locking overlap: macOS locks the screen on wake, so `didWake` arrives
/// while the lock screen is still up. A flat state would treat that wake as
/// a return to `.active` and resume polling behind the lock screen.
///
/// The flags are *set*, never counted. Distributed notifications are not
/// guaranteed to be delivered, and a missed `screenUnlocked` under a
/// counting scheme would leave the poller suspended until relaunch.
public struct SystemActivityReducer: Equatable, Sendable {

    private var isAsleep = false
    private var isLocked = false

    public init() {}

    /// Sleep outranks lock, which outranks active. A sleeping machine is
    /// asleep whether or not it is also locked, and it is the stronger
    /// suspension of the two.
    public var activity: SystemActivity {
        if isAsleep { return .asleep }
        if isLocked { return .locked }
        return .active
    }

    @discardableResult
    public mutating func apply(_ event: SystemActivityEvent) -> SystemActivity {
        switch event {
        case .willSleep:       isAsleep = true
        case .didWake:         isAsleep = false
        case .screenLocked:    isLocked = true
        case .screenUnlocked:  isLocked = false
        }
        return activity
    }
}
