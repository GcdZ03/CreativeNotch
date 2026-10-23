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
///
/// The second row covers what system sleep and screen lock miss: the
/// display sleeping while the machine stays awake (the energy saver
/// timeout, a lid closed on an external display), and fast user switching,
/// which puts this session behind another user's without locking it.
public enum SystemActivityEvent: Equatable, Sendable {
    case willSleep, didWake, screenLocked, screenUnlocked
    case screensDidSleep, screensDidWake, sessionDidResignActive, sessionDidBecomeActive
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
///
/// Display sleep and a switched-away session get flags of their own rather
/// than sharing `isAsleep` and `isLocked`. The pairs do not arrive nested:
/// a `didWake` can land while the display is still dark, and a
/// `screenUnlocked` says nothing about whether this session is the one in
/// front. A shared flag would let either clear the other's suspension.
public struct SystemActivityReducer: Equatable, Sendable {

    private var isAsleep = false
    private var isLocked = false
    private var isDisplayAsleep = false
    private var isSessionInactive = false

    public init() {}

    /// Sleep outranks lock, which outranks active. A sleeping machine is
    /// asleep whether or not it is also locked, and it is the stronger
    /// suspension of the two.
    ///
    /// A dark display reads as asleep — nobody can see the notch — and a
    /// session switched away from reads as locked: its owner is not at the
    /// machine, exactly as behind a lock screen.
    public var activity: SystemActivity {
        if isAsleep || isDisplayAsleep { return .asleep }
        if isLocked || isSessionInactive { return .locked }
        return .active
    }

    @discardableResult
    public mutating func apply(_ event: SystemActivityEvent) -> SystemActivity {
        switch event {
        case .willSleep:       isAsleep = true
        case .didWake:         isAsleep = false
        case .screenLocked:    isLocked = true
        case .screenUnlocked:  isLocked = false
        case .screensDidSleep:         isDisplayAsleep = true
        case .screensDidWake:          isDisplayAsleep = false
        case .sessionDidResignActive:  isSessionInactive = true
        case .sessionDidBecomeActive:  isSessionInactive = false
        }
        return activity
    }
}
