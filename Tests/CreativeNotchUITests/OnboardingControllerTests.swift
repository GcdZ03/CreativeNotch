import Testing
import Foundation
import CreativeNotchUI

/// `OnboardingController.show()` pops a real `NSWindow` and, indirectly
/// through `OnboardingView`, can trigger `NSApp.activate()` — side effects
/// this suite must never cause. What's covered here is the pure "show only
/// if not yet seen" decision, driven through an injected, isolated
/// `UserDefaults` suite rather than `.standard`.
@MainActor
struct OnboardingControllerTests {

    /// A fresh, isolated `UserDefaults` suite per test so runs never see
    /// each other's state and never touch the real `com.gcdz.creativenotch`
    /// domain.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.gcdz.creativenotch.onboarding-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func freshDefaultsHaveNotCompletedOnboarding() {
        let controller = OnboardingController(defaults: makeIsolatedDefaults())
        #expect(controller.hasCompletedOnboarding == false)
    }

    @Test func onceMarkedSeenTheDecisionFlips() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let controller = OnboardingController(defaults: defaults)

        #expect(controller.hasCompletedOnboarding == true)
    }

    /// `showIfNeeded()` must be a genuine no-op once onboarding has been
    /// seen — it must not create or present the window. Calling it here is
    /// safe specifically because the guard returns before `show()` ever
    /// runs, so this never pops UI.
    @Test func showIfNeededDoesNothingOnceAlreadySeen() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let controller = OnboardingController(defaults: defaults)
        controller.showIfNeeded()

        // The only observable surface here is the decision itself — it
        // must remain unchanged by a call that should have done nothing.
        #expect(controller.hasCompletedOnboarding == true)
    }

    /// Two controllers backed by two different `UserDefaults` suites must
    /// not observe each other's completion flag — otherwise the "isolated
    /// suite" tests above would all be sharing state under the hood.
    @Test func controllersOnSeparateSuitesDoNotShareState() {
        let seenDefaults = makeIsolatedDefaults()
        seenDefaults.set(true, forKey: "hasCompletedOnboarding")

        let seen = OnboardingController(defaults: seenDefaults)
        let unseen = OnboardingController(defaults: makeIsolatedDefaults())

        #expect(seen.hasCompletedOnboarding == true)
        #expect(unseen.hasCompletedOnboarding == false)
    }
}
