import Foundation

/// A fresh, isolated `UserDefaults` suite per call.
///
/// Every suite that builds an `AppDelegate` must use one. Without it the
/// wiring suites read the developer's real `com.gcdz.creativenotch` domain --
/// so a developer who switched media metadata off in the actual app would make
/// `lockingStopsTheMediaHelper` fail on their machine and nowhere else, which
/// is the worst shape a test failure can take.
///
/// Cleared with `removePersistentDomain` before use, the same shape
/// `OnboardingControllerTests` established.
enum TestDefaults {
    static func isolated(_ label: String = "wiring") -> UserDefaults {
        let suiteName = "com.gcdz.creativenotch.\(label)-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
