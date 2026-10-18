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

    /// The tracker's dwell is the peek's 300ms either way — open on hover
    /// now peeks first (2026-10-18) — unless the chosen delay is shorter,
    /// when the dwell is the delay so the panel is not held back.
    @Test func theDwellIsThePeeksUnlessTheDelayIsShorter() {
        #expect(HoverBehaviour(opensOnHover: false, openDelay: 0.8).dwell == .milliseconds(300))
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0.8).dwell == .milliseconds(300))
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0.2).dwell == .milliseconds(200))
    }

    // MARK: - Peek first, then open

    @Test func withTheSettingOffNothingOpens() {
        let b = HoverBehaviour(opensOnHover: false, openDelay: 0.5)
        #expect(b.openWait(afterPeek: true) == nil)
        #expect(b.openWait(afterPeek: false) == nil)
    }

    /// With something to peek, the peek gets the whole chosen delay on
    /// screen before the panel replaces it — long enough to read, or to
    /// swipe sideways to skip. Peek at 0.3s, panel at 0.3 + 0.5s.
    @Test func aPeekStaysForTheChosenDelayBeforeThePanelOpens() {
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0.5).openWait(afterPeek: true) == .milliseconds(500))
    }

    /// With nothing to peek there is nothing to wait for: the panel opens
    /// at the chosen delay from arriving, the dwell already counted.
    @Test func withNothingToPeekThePanelOpensAtTheDelay() {
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0.5).openWait(afterPeek: false) == .milliseconds(200))
        #expect(HoverBehaviour(opensOnHover: true, openDelay: 0.2).openWait(afterPeek: false) == .zero)
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
