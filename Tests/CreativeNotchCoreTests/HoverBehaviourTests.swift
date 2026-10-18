import Foundation
import Testing
@testable import CreativeNotchCore

/// "Open on hover", with a delay (2026-10-17). Off by default: hovering
/// peeks, and a click or a swipe opens the panel. On, resting the pointer on
/// the notch for the delay opens the panel instead of peeking.
struct HoverBehaviourTests {

    private func defaults() -> UserDefaults {
        let name = "hover-\(UUID())"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - The value

    @Test func theShippedDefaultPeeksRatherThanOpens() {
        let b = HoverBehaviour()
        #expect(!b.opensOnHover)
        #expect(b.openDelay == HoverBehaviour.defaultDelay)
    }

    /// Peeking keeps the 300ms dwell it always had; opening waits for the
    /// chosen delay and goes straight to the panel — one expansion, no peek
    /// first (2026-10-18: peek-then-open felt like the notch expanding twice
    /// on its own).
    @Test func theDwellFollowsTheSetting() {
        #expect(HoverBehaviour(opensOnHover: false, openDelay: 0.8).dwell == .milliseconds(300))
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0.8).dwell == .milliseconds(800))
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0.2).dwell == .milliseconds(200))
    }

    @Test func theDelayIsKeptInRange() {
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0).openDelay == HoverBehaviour.delayRange.lowerBound)
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 9).openDelay == HoverBehaviour.delayRange.upperBound)
        #expect(HoverBehaviour(opensOnHover: true, openDelay: .nan).openDelay == HoverBehaviour.defaultDelay)
    }

    /// The slider moves in tenths, so a stored 0.4999 reads back as 0.5
    /// rather than drifting.
    @Test func theDelaySnapsToTenths() {
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0.47).openDelay == 0.5)
    }

    // MARK: - Storage

    @Test func anEmptyStoreGivesTheShippedDefault() {
        #expect(HoverBehaviourStore(defaults: defaults()).load() == HoverBehaviour())
    }

    @Test func whatIsSavedIsWhatLoads() {
        let store = HoverBehaviourStore(defaults: defaults())
        let b = HoverBehaviour(opensOnHover: true, openDelay: 0.7)
        store.save(b)
        #expect(store.load() == b)
    }

    /// Nothing is cached: a value written behind the store's back — by
    /// `defaults write`, say — is what the next load sees.
    @Test func itReadsTheDomainEveryTime() {
        let d = defaults()
        let store = HoverBehaviourStore(defaults: d)
        _ = store.load()
        d.set(true, forKey: HoverBehaviourStore.Keys.opensOnHover)
        #expect(store.load().opensOnHover)
    }

    /// A value of the wrong type reads as unset, the policy the module
    /// toggles and the shortcut already follow.
    @Test func aWronglyTypedValueReadsAsTheDefault() {
        let d = defaults()
        d.set("yes", forKey: HoverBehaviourStore.Keys.opensOnHover)
        d.set("soon", forKey: HoverBehaviourStore.Keys.openDelay)
        #expect(HoverBehaviourStore(defaults: d).load() == HoverBehaviour())
    }
}
