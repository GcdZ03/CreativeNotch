import Testing
import Foundation
@testable import CreativeNotchUI

/// `OnboardingController.show()` pops a real `NSWindow` and, indirectly
/// through `OnboardingView`, can trigger `NSApp.activate()` — side effects
/// this suite must never cause. Two things are covered without ever
/// reaching either:
///
/// 1. The pure "have we already shown onboarding" decision, driven through
///    an injected, isolated `UserDefaults` suite rather than `.standard`.
/// 2. Whether `showIfNeeded()` reaches `show()`'s window-presenting path
///    at all — verified with a spy `presenter` (the internal, test-only
///    initializer, reached here via `@testable import`) that records the
///    call instead of touching AppKit, so the guard's behavior has a real
///    assertion behind it in both directions.
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

    /// A controller whose `presenter` never touches AppKit — it only flips
    /// `Spy.reached` — so calling `show()` (directly or via `showIfNeeded()`)
    /// is always safe to do in a test, regardless of which branch the guard
    /// takes.
    private func makeSpyController(defaults: UserDefaults) -> (OnboardingController, Spy) {
        let spy = Spy()
        let controller = OnboardingController(defaults: defaults) { _ in spy.reached = true }
        return (controller, spy)
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

    /// The actual no-op claim: once onboarding has been seen,
    /// `showIfNeeded()` must never reach `show()`'s window-presenting path.
    /// This has real teeth — deleting the guard in `showIfNeeded()` makes
    /// this fail, because the spy `presenter` would then record a call
    /// that should never have happened.
    @Test func showIfNeededDoesNotReachThePresentingPathOnceAlreadySeen() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let (controller, spy) = makeSpyController(defaults: defaults)

        controller.showIfNeeded()

        #expect(spy.reached == false)
    }

    /// The mirror case: when onboarding has not yet been seen,
    /// `showIfNeeded()` must reach `show()`'s presenting path. Covering
    /// both directions confirms the spy actually distinguishes the two
    /// branches, rather than always reading one way.
    @Test func showIfNeededReachesThePresentingPathWhenNotYetSeen() {
        let (controller, spy) = makeSpyController(defaults: makeIsolatedDefaults())

        controller.showIfNeeded()

        #expect(spy.reached == true)
    }

    /// `show()` called directly (as the menu bar's "reopen onboarding"
    /// action does) must always reach the presenting path, regardless of
    /// the completion flag — it has no guard of its own.
    @Test func showAlwaysReachesThePresentingPathRegardlessOfCompletion() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let (controller, spy) = makeSpyController(defaults: defaults)

        controller.show()

        #expect(spy.reached == true)
    }
}

/// A tiny `@MainActor` box so the spy `presenter` closure can mutate state
/// without capturing a `var` across the concurrency boundary — same
/// pattern as `Flag`/`Counter` in `HoverTrackerTests`.
@MainActor
private final class Spy {
    var reached = false
}
