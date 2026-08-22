import Testing
import CreativeNotchUI

/// `AXIsProcessTrusted()` itself can't be driven from a test — it reflects
/// real Accessibility permission state. What can be tested is the pure
/// formatting `MenuBarController` derives from it once read.
@MainActor
struct MenuBarControllerTests {

    @Test func trustedProducesTheGrantedTitle() {
        #expect(MenuBarController.accessibilityTitle(trusted: true) == "Accessibility: granted")
    }

    @Test func untrustedProducesASetUpPrompt() {
        let title = MenuBarController.accessibilityTitle(trusted: false)
        #expect(title.hasPrefix("Accessibility: not granted"))
        #expect(title != MenuBarController.accessibilityTitle(trusted: true))
    }
}
