import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The panel's dimmed whites go through one style, and that style reads
/// Increase Contrast from the environment it is drawn in.
struct NotchInkTests {

    private func opacity(_ color: Color) -> Double {
        Double(color.resolve(in: EnvironmentValues()).opacity)
    }

    /// The default environment is standard contrast, and the panel must
    /// look exactly as it did before the style existed.
    @Test func theDefaultEnvironmentDrawsTheNominalOpacity() {
        let resolved = NotchInk.ink(0.4).resolve(in: EnvironmentValues())
        #expect(abs(opacity(resolved) - 0.4) < 0.001)
        let hairline = NotchInk.hairline(0.08).resolve(in: EnvironmentValues())
        #expect(abs(opacity(hairline) - 0.08) < 0.001)
    }

    /// Under Increase Contrast the colour is Core's lifted value, for each
    /// role -- the style decides nothing of its own.
    @Test func increasedContrastDrawsCoresLiftedValue() {
        for (nominal, role) in [(0.4, ContrastOpacity.Role.text), (0.08, .hairline)] {
            let color = NotchInk.color(nominal, role: role, contrast: .increased)
            let expected = ContrastOpacity.opacity(nominal, role: role, increased: true)
            #expect(abs(opacity(color) - expected) < 0.001)
            #expect(expected > nominal)
        }
    }

    @Test func standardContrastIsUntouched() {
        let color = NotchInk.color(0.55, role: .text, contrast: .standard)
        #expect(abs(opacity(color) - 0.55) < 0.001)
    }
}
