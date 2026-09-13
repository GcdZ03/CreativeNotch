import Foundation

/// Whether the capture session should be running, and why.
///
/// **This is where the module's exemption from the activity gate lives**, and
/// it is pure so that it can be argued with exhaustively rather than
/// discovered in a battery graph.
///
/// The obvious design gates the session on the panel being open. That is
/// wrong, and the case that makes it wrong is the one a user hits first: press
/// record, then click away. A stray cursor would end the take.
///
/// So there are two reasons, and the second is the exemption:
///
/// | Reason | What runs |
/// | --- | --- |
/// | The camera tab is visible | preview and session |
/// | A recording is in progress | session, no preview |
///
/// The same shape as the timer's: a countdown's purpose is to fire while
/// nobody is watching, and a recording's purpose is to capture while you are
/// doing something else. In both, the *drawing* is gated and the *work* is not.
public enum CameraRunReason: Equatable, Sendable {

    /// The inputs. Deliberately a struct rather than four parameters, so a
    /// caller cannot transpose two Bools and still compile.
    public struct Inputs: Equatable, Sendable {
        /// The camera tab is on screen.
        public var isTabVisible: Bool
        /// A clip is being written right now.
        public var isRecording: Bool
        /// The module's preference. Off means off, including mid-recording:
        /// flipping the switch is a stronger statement than the cursor moving.
        public var isEnabled: Bool
        /// The system-activity gate. Locked or asleep stops the preview, but
        /// not a recording.
        public var activity: SystemActivity

        public init(
            isTabVisible: Bool,
            isRecording: Bool,
            isEnabled: Bool = true,
            activity: SystemActivity = .active
        ) {
            self.isTabVisible = isTabVisible
            self.isRecording = isRecording
            self.isEnabled = isEnabled
            self.activity = activity
        }
    }

    /// Whether the session should be running at all.
    ///
    /// A disabled module runs nothing, whatever else is true -- the Preferences
    /// rule is that switching a module off stops its subsystem, and a camera
    /// that kept capturing because a recording happened to be in progress
    /// would be the sharpest possible violation of it.
    public static func shouldRun(_ inputs: Inputs) -> Bool {
        guard inputs.isEnabled else { return false }
        if inputs.isRecording { return true }
        return inputs.isTabVisible && inputs.activity == .active
    }

    /// Whether the preview should be drawn.
    ///
    /// Narrower than `shouldRun`: a recording that outlives the panel keeps the
    /// session but draws nothing, because there is nowhere to draw it. What
    /// the user sees instead is the recording badge in the ear -- the session
    /// is never running with nothing on screen to account for it.
    public static func shouldPreview(_ inputs: Inputs) -> Bool {
        guard inputs.isEnabled else { return false }
        return inputs.isTabVisible && inputs.activity == .active
    }

    /// Whether the ear should show that a recording is in progress.
    ///
    /// **This is what makes the exemption honest.** A capture running with
    /// nothing on screen to explain it is precisely what this project exists
    /// to prevent, so whenever the session outlives the panel, the notch says
    /// so.
    public static func shouldBadge(_ inputs: Inputs) -> Bool {
        inputs.isEnabled && inputs.isRecording
    }
}
