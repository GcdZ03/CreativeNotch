import Foundation
import Testing
@testable import CreativeNotchCore

/// The first-run welcome card: whether it shows, what dismisses it, and the
/// flag that keeps it dismissed.
struct WelcomeCardTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.gcdz.creativenotch.welcome-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - The flag

    /// A fresh domain is a first run. `bool(forKey:)`'s absent-means-false is
    /// the right polarity here, unlike the module toggles — but it is read
    /// through `resolveEnabled` all the same, so a hand-typed string cannot
    /// mean "seen" by accident.
    @Test func anEmptyDomainHasNotSeenTheWelcome() {
        #expect(PreferencesStore(defaults: makeIsolatedDefaults()).hasSeenWelcome == false)
    }

    @Test func markingItSeenSurvivesAReload() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setHasSeenWelcome(true)
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome == true)
    }

    /// "Show Welcome Again" clears the key rather than writing `false`, so the
    /// domain after it reads exactly like a fresh install's.
    @Test func showingItAgainClearsTheKey() {
        let defaults = makeIsolatedDefaults()
        let store = PreferencesStore(defaults: defaults)
        store.setHasSeenWelcome(true)
        store.setHasSeenWelcome(false)
        #expect(store.hasSeenWelcome == false)
        #expect(defaults.object(forKey: PreferenceKeys.welcomeSeen) == nil)
    }

    @Test func theFlagLivesUnderTheDocumentedKey() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setHasSeenWelcome(true)
        #expect(defaults.object(forKey: "welcome.seen") as? NSNumber == NSNumber(value: true))
    }

    /// Not the removed onboarding window's key. Someone who finished that
    /// window years ago has never seen this card, and reusing the key would
    /// hide it from exactly the people most likely to have forgotten it all.
    @Test func theLegacyOnboardingKeyDoesNotCountAsSeen() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome == false)
    }

    @Test func aHandWrittenStringDoesNotCountAsSeen() {
        let defaults = makeIsolatedDefaults()
        defaults.set("yes", forKey: PreferenceKeys.welcomeSeen)
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome == false)
    }

    // MARK: - Showing

    private static let nonCameraTabs = Tab.allCases.filter { $0 != .camera }

    @Test func itShowsInAnAskedForOpenOnAFirstRun() {
        for tab in Self.nonCameraTabs {
            #expect(WelcomeCard.isShown(seen: false, in: .open(tab), openedBy: .tap), "hidden on \(tab)")
            #expect(WelcomeCard.isShown(seen: false, in: .open(tab), openedBy: .hotKey), "hidden on \(tab)")
        }
    }

    @Test func itNeverShowsOnceSeen() {
        for tab in Tab.allCases {
            #expect(!WelcomeCard.isShown(seen: true, in: .open(tab), openedBy: .tap))
        }
    }

    /// A hover-open is a pointer crossing the notch, a swipe can begin as a
    /// scroll, and a drop is someone dragging whose file the card would
    /// cover. None of them is somebody about to read.
    @Test func itNeverShowsInAnAmbientOpen() {
        for reason: PanelOpenReason? in [.hover, .swipe, .drop, .unspecified, nil] {
            #expect(!WelcomeCard.isShown(seen: false, in: .open(.shelf), openedBy: reason),
                    "shown on \(String(describing: reason))")
        }
    }

    /// The camera tab starts the camera; an opaque card over it would hide
    /// the live preview and the controls that account for the light.
    @Test func itNeverShowsOverTheCamera() {
        #expect(!WelcomeCard.isShown(seen: false, in: .open(.camera), openedBy: .tap))
    }

    /// Inside the open panel only: a peek fires unprompted, and a card of
    /// instructions in it would be read by nobody.
    @Test func itNeverShowsOutsideTheOpenPanel() {
        let elsewhere: [NotchState] = [
            .closed, .receiving, .peek(.dragTarget), .peek(.power(.pluggedIn(level: 50))),
        ]
        for state in elsewhere {
            #expect(!WelcomeCard.isShown(seen: false, in: state, openedBy: .tap), "shown in \(state)")
        }
    }

    // MARK: - Dismissing

    /// Closing the panel after the card was on screen counts as reading it.
    @Test func closingThePanelItShowedInDismissesIt() {
        #expect(WelcomeCard.isDismissed(seen: false, from: .open(.shelf), openedBy: .tap, to: .closed))
    }

    /// The card covers every body, so a tab switch dismisses it to show the
    /// tab the user tried — the camera tab included.
    @Test func switchingTabsDismissesIt() {
        #expect(WelcomeCard.isDismissed(seen: false, from: .open(.shelf), openedBy: .tap, to: .open(.clipboard)))
        #expect(WelcomeCard.isDismissed(seen: false, from: .open(.shelf), openedBy: .hotKey, to: .open(.camera)))
    }

    /// A drag arriving is someone dragging, not someone who read anything.
    @Test func aDragArrivingDoesNotDismissIt() {
        #expect(!WelcomeCard.isDismissed(seen: false, from: .open(.timer), openedBy: .tap, to: .receiving))
    }

    /// It was never on screen, so nothing was read.
    @Test func closingFromElsewhereDoesNotDismissIt() {
        #expect(!WelcomeCard.isDismissed(seen: false, from: .peek(.dragTarget), openedBy: nil, to: .closed))
        #expect(!WelcomeCard.isDismissed(seen: false, from: .closed, openedBy: nil, to: .peek(.dragTarget)))
        #expect(!WelcomeCard.isDismissed(seen: false, from: .closed, openedBy: nil, to: .open(.shelf)))
    }

    /// An ambient open never showed it, so closing one spends nothing.
    @Test func closingAnAmbientOpenDoesNotDismissIt() {
        for reason: PanelOpenReason in [.hover, .swipe, .drop, .unspecified] {
            #expect(!WelcomeCard.isDismissed(seen: false, from: .open(.shelf), openedBy: reason, to: .closed))
        }
        #expect(!WelcomeCard.isDismissed(seen: false, from: .open(.camera), openedBy: .tap, to: .closed))
    }

    /// Already seen means nothing to write.
    @Test func anAlreadySeenCardIsNotDismissedAgain() {
        #expect(!WelcomeCard.isDismissed(seen: true, from: .open(.shelf), openedBy: .tap, to: .closed))
    }

    // MARK: - What it says

    /// Three or four lines, so it is read rather than skimmed past.
    @Test func itSaysThreeOrFourThings() {
        #expect((3...4).contains(WelcomeCard.tips.count))
        for tip in WelcomeCard.tips {
            #expect(!tip.text.isEmpty)
            #expect(!tip.symbolName.isEmpty)
        }
    }

    /// Only gestures the app has. There is no sideways swipe between tabs —
    /// a sideways swipe on the music peek skips tracks — so promising one
    /// would teach something that does nothing.
    @Test func itPromisesNoSwipeBetweenTabs() {
        for tip in WelcomeCard.tips {
            let text = tip.text.lowercased()
            #expect(!(text.contains("swipe") && (text.contains("left") || text.contains("right") || text.contains("between"))),
                    "\(tip.text)")
        }
    }
}
