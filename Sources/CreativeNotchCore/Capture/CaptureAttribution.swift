import Foundation

/// Deciding whether a capture is somebody else's.
///
/// **`IsRunningSomewhere` reports *that* something is capturing, never *who*.**
/// So the raw property cannot answer the one question this module must get
/// right: an indicator that lights because CreativeNotch opened its own camera
/// preview tells the user nothing and reads as a bug.
///
/// The answer is a per-process read, and it is pure: the caller hands over the
/// process list it read from the system, and this decides. That is the same
/// split `PowerController` uses -- the observer is stupid, the policy is
/// testable.
public enum CaptureAttribution {

    /// One process's capture state, as read from CoreAudio's process objects.
    public struct Process: Equatable, Sendable {
        public var pid: pid_t
        public var isRunningInput: Bool

        public init(pid: pid_t, isRunningInput: Bool) {
            self.pid = pid
            self.isRunningInput = isRunningInput
        }
    }

    /// Whether anybody **other than us** is capturing audio input.
    ///
    /// `ownPID` is resolved through
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`, which maps a PID
    /// straight to its process object -- so "is that me?" is a lookup rather
    /// than an enumeration, and needs no permission at all.
    ///
    /// The alternative considered and rejected was
    /// `AVCaptureDevice.inUseByAnotherApplication`, which is documented to mean
    /// exactly this. It read `false` throughout a probe in which a genuinely
    /// separate application was capturing, and the measurement is confounded --
    /// the observer had never requested camera access. Either explanation
    /// disqualifies it: **a privacy indicator that must hold camera permission
    /// in order to report camera use is the wrong shape.**
    public static func isSomebodyElseCapturing(
        processes: [Process],
        ownPID: pid_t
    ) -> Bool {
        processes.contains { $0.pid != ownPID && $0.isRunningInput }
    }

    /// Whether the device-global flag should be believed, given who is running.
    ///
    /// The device property is the *notification*; this is the *attribution*.
    /// Used together: the property says something changed, the process list
    /// says whether it was us.
    public static func othersAreCapturing(
        deviceIsRunningSomewhere: Bool,
        processes: [Process],
        ownPID: pid_t
    ) -> Bool {
        guard deviceIsRunningSomewhere else { return false }
        return isSomebodyElseCapturing(processes: processes, ownPID: ownPID)
    }
}
