import AppKit
import Carbon.HIToolbox
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The one hotkey: what it is, whether it is registered, and whether the user
/// has proved it works.
///
/// Drives the real `HotKeyCenter`, so every test clears up after itself -- a
/// leaked registration is process-wide and would make the next test lie.
@MainActor
struct HotKeyControllerTests {

    private func isolatedStore() -> HotKeyStore {
        let suiteName = "com.gcdz.creativenotch.hotkey-ctl.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HotKeyStore(defaults: defaults)
    }

    private let combo = HotKeyCombo(
        keyCode: UInt32(kVK_F13),
        carbonModifiers: HotKeyModifier.control | HotKeyModifier.option | HotKeyModifier.shift
    )
    private let other = HotKeyCombo(
        keyCode: UInt32(kVK_F14),
        carbonModifiers: HotKeyModifier.control | HotKeyModifier.option | HotKeyModifier.shift
    )

    private func makeController() -> HotKeyController {
        HotKeyCenter.shared.unregisterAll()
        return HotKeyController(store: isolatedStore())
    }

    // MARK: - The shipped state

    /// There is no default combination. Any default risks colliding with
    /// whatever launcher the user already runs.
    @Test func aFreshInstallHasNoHotkeyAndRegistersNothing() {
        let controller = makeController()
        controller.start()

        #expect(controller.status == .unset)
        #expect(controller.isRegistered == false)
        #expect(HotKeyCenter.shared.registrationCount == 0)
    }

    // MARK: - Choosing one

    /// Registration succeeding is NOT the feature. Until the user presses the
    /// key, nothing has demonstrated that it delivers -- a system hotkey
    /// registers with noErr and then never fires.
    @Test func choosingACombinationRegistersItButDoesNotClaimItWorks() {
        let controller = makeController()

        let status = controller.setCombo(combo)

        #expect(status == .awaitingConfirmation)
        #expect(controller.isRegistered)
        #expect(controller.combo == combo)
        controller.stop()
    }

    /// **The only thing that can confirm it.** Neither OSStatus nor
    /// CopySymbolicHotKeys proves delivery.
    @Test func pressingItOnceConfirmsIt() {
        let controller = makeController()
        controller.setCombo(combo)
        #expect(controller.status == .awaitingConfirmation)

        controller.didFire()

        #expect(controller.status == .confirmed)
        controller.stop()
    }

    /// And the proof is persisted, so a combination proven once is not
    /// re-interrogated on every launch.
    @Test func aConfirmedHotkeyStaysConfirmedAcrossARelaunch() {
        HotKeyCenter.shared.unregisterAll()
        let store = isolatedStore()
        let first = HotKeyController(store: store)
        first.setCombo(combo)
        first.didFire()
        first.stop()

        let second = HotKeyController(store: store)

        #expect(second.status == .confirmed)
    }

    /// The proof was about the OLD combination. A tick beside a key nobody
    /// has pressed is worse than no tick.
    @Test func changingTheCombinationRequiresProvingTheNewOne() {
        let controller = makeController()
        controller.setCombo(combo)
        controller.didFire()
        #expect(controller.status == .confirmed)

        controller.setCombo(other)

        #expect(controller.status == .awaitingConfirmation)
        controller.stop()
    }

    /// **Registering the new one without dropping the old leaves both live**,
    /// and the old one keeps opening the panel -- a bug nobody would think to
    /// look for.
    @Test func changingTheCombinationDropsTheOldRegistration() {
        let controller = makeController()
        controller.setCombo(combo)

        controller.setCombo(other)

        #expect(HotKeyCenter.shared.registrationCount == 1, "the old registration is still live")
        controller.stop()
    }

    @Test func clearingTheCombinationUnregistersIt() {
        let controller = makeController()
        controller.setCombo(combo)
        #expect(controller.isRegistered)

        controller.setCombo(nil)

        #expect(controller.status == .unset)
        #expect(controller.isRegistered == false)
        #expect(HotKeyCenter.shared.registrationCount == 0)
    }

    // MARK: - Firing

    @Test func firingCallsTheAction() {
        let controller = makeController()
        var fired = 0
        controller.onTrigger = { fired += 1 }
        controller.setCombo(combo)

        controller.didFire()
        controller.didFire()

        #expect(fired == 2)
        controller.stop()
    }

    // MARK: - The Preferences leg

    /// Switching the module off must DROP the registration, not ignore the
    /// callback. A registration alive while the switch reads off is exactly
    /// the failure the preferences module exists to prevent.
    @Test func disablingDropsTheRegistrationRatherThanIgnoringIt() {
        let controller = makeController()
        controller.setCombo(combo)
        #expect(HotKeyCenter.shared.registrationCount == 1)

        controller.setEnabled(false)

        #expect(controller.isRegistered == false)
        #expect(HotKeyCenter.shared.registrationCount == 0)
        #expect(HotKeyCenter.shared.isHandlerInstalled == false, "the handler outlived the module")
    }

    /// And re-enabling brings it back, or the toggle only works once.
    @Test func reEnablingRegistersItAgain() {
        let controller = makeController()
        controller.setCombo(combo)
        controller.setEnabled(false)

        controller.setEnabled(true)

        #expect(controller.isRegistered)
        #expect(HotKeyCenter.shared.registrationCount == 1)
        controller.stop()
    }

    /// A combination chosen while the module is off is stored but not
    /// registered -- otherwise the switch reading "off" would be a lie.
    @Test func choosingACombinationWhileDisabledDoesNotRegisterIt() {
        let controller = makeController()
        controller.setEnabled(false)

        controller.setCombo(combo)

        #expect(controller.combo == combo)
        #expect(controller.isRegistered == false)
        #expect(HotKeyCenter.shared.registrationCount == 0)
    }

    /// `start()` is idempotent, so a switchboard leg that runs twice does not
    /// stack registrations.
    ///
    /// **Counting registrations is not enough here**, and that gap was found
    /// by mutation. Without the `registrationID == nil` guard, the second
    /// `start()` re-registers the same combination, gets -9878 back, and
    /// leaves `registrationID` nil while the FIRST registration is still live
    /// -- a leak `stop()` can no longer reach, with the count still reading 1.
    /// So the state is asserted too.
    @Test func startingTwiceRegistersOnce() {
        let controller = makeController()
        controller.setCombo(combo)

        controller.start()
        controller.start()

        #expect(HotKeyCenter.shared.registrationCount == 1)
        #expect(controller.status == .awaitingConfirmation, "the second start failed and corrupted the status")
        #expect(controller.isRegistered, "the second start orphaned the live registration")

        controller.stop()
        #expect(HotKeyCenter.shared.registrationCount == 0, "stop() could not reach the registration")
    }

    /// And `start()` respects the latch, or a switchboard that starts
    /// everything at launch would register a hotkey the user switched off.
    @Test func startingWhileDisabledRegistersNothing() {
        let controller = makeController()
        controller.setCombo(combo)
        controller.setEnabled(false)

        controller.start()

        #expect(controller.isRegistered == false)
        #expect(HotKeyCenter.shared.registrationCount == 0)
    }

    // MARK: - Copy

    /// Three refusals needing three different things said. Collapsing them
    /// into one generic message is the trap.
    @Test func eachRefusalGetsItsOwnMessage() {
        let messages = [
            HotKeyController.message(for: .exclusiveConflict),
            HotKeyController.message(for: .rejectedBySystem(-9868)),
            HotKeyController.message(for: .handlerInstallFailed(-1)),
            HotKeyController.message(for: .other(-1)),
        ]
        #expect(Set(messages).count == messages.count, "two refusals share one message")
        #expect(messages[0].contains("exclusively"))
        #expect(messages[1].contains("another modifier"))
    }

    /// **The pane must never claim a combination is taken**, because an
    /// ordinary conflict returns noErr and is undetectable. Pinned by literal,
    /// the way the Preferences honesty notes are.
    @Test func noMessageClaimsAConflictTheSystemCannotReport() {
        let messages = [
            HotKeyController.message(for: .exclusiveConflict),
            HotKeyController.message(for: .rejectedBySystem(-9868)),
            HotKeyController.message(for: .handlerInstallFailed(-1)),
            HotKeyController.message(for: .other(-1)),
        ]
        for message in messages {
            #expect(message.contains("already in use") == false)
            #expect(message.contains("already taken") == false)
        }
    }
}
