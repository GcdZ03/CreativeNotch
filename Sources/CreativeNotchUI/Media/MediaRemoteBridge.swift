import AppKit
import CreativeNotchCore

/// Sends transport commands through the private MediaRemote framework.
///
/// There is no public API for controlling whatever application holds the
/// system media session. MediaRemote is not permission-gated for
/// *commands*: the spike confirmed `MRMediaRemoteSendCommand` takes effect
/// from an **ad-hoc-signed** binary, which is what this app ships as.
///
/// Reading now-playing *metadata* through the same framework **is** gated
/// by code-signing identifier and returns nothing to this process. That is
/// why this type sends and never reads, and why `TrackSnapshot` stays
/// unpopulated until the deferred metadata module exists. See
/// `docs/research/2026-08-29-media-feasibility.md`.
///
/// An `enum` with static members rather than a class: there is no state to
/// hold beyond the cached handle, and nothing to start or stop.
@MainActor
public enum MediaRemoteBridge {

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool

    /// Resolved once. `BrightnessObserver` holds its DisplayServices
    /// handle the same way — re-`dlopen`ing per call would buy nothing.
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_NOW
    )

    private static let sendCommand: SendCommand? = {
        guard let handle, let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    public static var isAvailable: Bool { sendCommand != nil }

    /// Sends `command` to whichever application holds the media session.
    ///
    /// Returns nothing, deliberately. `MRMediaRemoteSendCommand` returns a
    /// `Bool`, but the spike found it returns `true` for commands that are
    /// **ignored** by the receiving application, and `true` for a nonsense
    /// command id. It reports "dispatched", not "obeyed". Surfacing it
    /// would be handing callers a success signal that is not one, so it is
    /// discarded here rather than laundered upward.
    ///
    /// There is no in-process way to confirm a command took effect.
    /// Confirming it needs the now-playing state, which is gated.
    public static func send(_ command: MediaCommand) {
        guard let sendCommand else { return }
        _ = sendCommand(command.rawValue, nil)
    }
}
