import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Resolving MediaRemote and sending a transport command.
///
/// **No test here sends a real command.** `MRMediaRemoteSendCommand`
/// actually changes playback on whatever application holds the media
/// session, and a test suite must not do that to the machine running it.
/// What is tested is that the framework resolves; that a command really
/// reaches a real player is covered by the spike
/// (`docs/research/2026-08-29-media-feasibility.md`), which ground-truthed
/// it against a live player and restored the state afterwards.
@MainActor
struct MediaRemoteBridgeTests {

    /// Not safe to assert bare: `dlopen`ing a private framework and
    /// resolving its symbols by name is unverified on a restricted or
    /// sandboxed host. Same treatment as `BrightnessObserver`'s
    /// DisplayServices check.
    @Test func theMediaRemoteSymbolResolves() {
        expectOrKnownHardwareIssue(
            MediaRemoteBridge.isAvailable,
            "MediaRemote is a private framework; dlopen/dlsym resolving it is unverified on a restricted or sandboxed host"
        )
    }

}
