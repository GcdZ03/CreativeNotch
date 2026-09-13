import AppKit
import Carbon.HIToolbox
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Registration against the real window server.
///
/// These drive `HotKeyCenter.shared`, because the C callback has to reach a
/// fixed place and a per-test instance would never fire. Every test therefore
/// clears up after itself; a leaked registration is system-wide for the life
/// of the process and would make the next test lie.
///
/// **What is asserted is the registration, not the delivery.** Whether the
/// combination actually reaches the handler needs a keypress and a human --
/// see `docs/research/2026-09-13-hotkey-probe.md` -- which is exactly why the
/// settings row asks the user to press it once rather than trusting any API.
@MainActor
struct HotKeyCenterTests {

    /// F13 with three modifiers: about as unlikely to collide with anything
    /// the developer has bound as a combination gets.
    private let combo = HotKeyCombo(
        keyCode: UInt32(kVK_F13),
        carbonModifiers: HotKeyModifier.control | HotKeyModifier.option | HotKeyModifier.shift
    )

    @Test func registeringInstallsTheHandlerAndCountsTheEntry() throws {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        #expect(center.registrationCount == 0)
        #expect(center.isHandlerInstalled == false)

        let id = try center.register(combo) {}

        #expect(center.registrationCount == 1)
        #expect(center.isHandlerInstalled)

        center.unregister(id)
    }

    /// **The subsystem is the registration plus the process-wide handler**, so
    /// stopping means dropping both. Leaving the handler installed would be
    /// cheap and would violate this module's own rule.
    @Test func unregisteringTheLastHotkeyRemovesTheHandlerToo() throws {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let id = try center.register(combo) {}
        #expect(center.isHandlerInstalled)

        center.unregister(id)

        #expect(center.registrationCount == 0)
        #expect(center.isHandlerInstalled == false)
    }

    /// But not while another is still live, or switching one hotkey off would
    /// silently break the others.
    @Test func unregisteringOneOfTwoKeepsTheHandler() throws {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let first = try center.register(combo) {}
        let second = try center.register(
            HotKeyCombo(keyCode: UInt32(kVK_F14), carbonModifiers: combo.carbonModifiers)
        ) {}

        center.unregister(first)

        #expect(center.registrationCount == 1)
        #expect(center.isHandlerInstalled, "the surviving hotkey lost its handler")

        center.unregister(second)
    }

    /// Re-registering the same combination inside this process is the one
    /// conflict the API genuinely reports: -9878, mapped to `exclusiveConflict`.
    /// It is what lets the pane honestly say "you already used that shortcut".
    @Test func registeringTheSameCombinationTwiceIsRefused() throws {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let id = try center.register(combo) {}

        #expect(throws: HotKeyError.exclusiveConflict) {
            _ = try center.register(combo) {}
        }

        // And the failure left nothing behind.
        #expect(center.registrationCount == 1)
        center.unregister(id)
    }

    @Test func unregisterAllClearsEverything() throws {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        _ = try center.register(combo) {}
        _ = try center.register(
            HotKeyCombo(keyCode: UInt32(kVK_F14), carbonModifiers: combo.carbonModifiers)
        ) {}
        #expect(center.registrationCount == 2)

        center.unregisterAll()

        #expect(center.registrationCount == 0)
        #expect(center.isHandlerInstalled == false)
    }

    /// Unregistering something already gone is a no-op, so a switchboard leg
    /// that runs twice does not have to ask first.
    @Test func unregisteringAnUnknownIdIsHarmless() throws {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let id = try center.register(combo) {}
        center.unregister(id)

        center.unregister(id)
        center.unregister(9999)

        #expect(center.registrationCount == 0)
    }

    /// The handler is installed on the application event target and sees every
    /// `kEventHotKeyPressed` in the process, including any a dependency
    /// registers. The signature is what separates ours from theirs.
    @Test func theSignatureIsTheFourCharacterCodeTheHandlerChecks() {
        #expect(HotKeyCenter.signature == 0x434E4B59)
        #expect(HotKeyCenter.signatureForCallback == HotKeyCenter.signature)

        // 'CNKY', spelled out so a change to either constant is visible as a
        // change of meaning rather than of digits.
        let expected = (UInt32(UInt8(ascii: "C")) << 24)
            | (UInt32(UInt8(ascii: "N")) << 16)
            | (UInt32(UInt8(ascii: "K")) << 8)
            | UInt32(UInt8(ascii: "Y"))
        #expect(HotKeyCenter.signature == expected)
    }
}
