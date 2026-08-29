import Testing

/// Wraps a hardware- or permission-dependent expectation so a plausible
/// host or CI limitation — no audio output device
/// (`actions/runner-images#13668`), no backlight, Accessibility withheld,
/// a private framework failing to load — is *attributed and visible* in
/// the test output rather than either failing the whole run (masking
/// every other assertion in the suite) or being silently deleted (which
/// would let a test "pass" for a source that never ran).
///
/// A genuine regression on a host where the precondition truly held is
/// still caught: the caller captures the flag once, asserts it here
/// softly, and then asserts anything that only makes sense when it held
/// *hard and unconditionally*, outside this helper.
///
/// Extracted from `HUDControllerTests.stopStopsAllThreeOwnedSources`,
/// which worked out this shape first; `VolumeObserverTests` and
/// `BrightnessObserverTests` had the identical risk with a bare
/// `#expect` and no such treatment.
func expectOrKnownHardwareIssue(
    _ condition: @autoclosure () -> Bool,
    _ reason: Comment
) {
    withKnownIssue(reason, isIntermittent: true) {
        #expect(condition())
    }
}
