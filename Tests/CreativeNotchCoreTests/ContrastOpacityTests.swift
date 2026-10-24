import Testing
@testable import CreativeNotchCore

/// Increase Contrast lifts the panel's dimmed whites, and touches nothing
/// else.
struct ContrastOpacityTests {

    /// Every nominal value used in the panel, and then some.
    private let nominals: [Double] = [0, 0.04, 0.08, 0.12, 0.2, 0.4, 0.45, 0.5, 0.55, 0.7, 0.92, 1]

    /// The default look is the design. Without the setting, the value is
    /// returned untouched for both roles.
    @Test func withoutIncreaseContrastNothingChanges() {
        for role in [ContrastOpacity.Role.text, .hairline] {
            for nominal in nominals {
                #expect(ContrastOpacity.opacity(nominal, role: role, increased: false) == nominal)
            }
        }
    }

    /// The floors are the point: under the setting, no secondary text can
    /// read fainter than `textFloor`, no hairline fainter than
    /// `hairlineFloor`.
    @Test func increasedTextNeverFallsBelowItsFloor() {
        for nominal in nominals where nominal > 0 {
            #expect(ContrastOpacity.opacity(nominal, role: .text, increased: true)
                    >= ContrastOpacity.textFloor)
            #expect(ContrastOpacity.opacity(nominal, role: .hairline, increased: true)
                    >= ContrastOpacity.hairlineFloor)
        }
    }

    /// The clipboard's time label is the faintest text in the panel.
    @Test func theClipboardTimeLabelIsLiftedWellClearOfItsDefault() {
        let lifted = ContrastOpacity.opacity(0.4, role: .text, increased: true)
        #expect(lifted >= 0.8)
        #expect(lifted < 1)
    }

    /// Lifted, not flattened: a title still reads above its count, a
    /// selected tab above an unselected one.
    @Test func theHierarchySurvivesTheLift() {
        for role in [ContrastOpacity.Role.text, .hairline] {
            let lifted = nominals.map { ContrastOpacity.opacity($0, role: role, increased: true) }
            for (a, b) in zip(lifted, lifted.dropFirst()) {
                #expect(a < b, "\(role) lift is not strictly increasing")
            }
        }
    }

    /// A zero is a switched-off state -- an unhovered row's highlight, an
    /// unselected tab's background -- and the setting must not switch it on.
    @Test func zeroStaysZeroAndOneStaysOne() {
        for role in [ContrastOpacity.Role.text, .hairline] {
            #expect(ContrastOpacity.opacity(0, role: role, increased: true) == 0)
            #expect(ContrastOpacity.opacity(1, role: role, increased: true) == 1)
        }
    }

    @Test func outOfRangeInputIsClamped() {
        #expect(ContrastOpacity.opacity(1.5, role: .text, increased: true) == 1)
        #expect(ContrastOpacity.opacity(-0.2, role: .text, increased: true) == 0)
        #expect(ContrastOpacity.opacity(1.5, role: .text, increased: false) == 1)
        #expect(ContrastOpacity.opacity(-0.2, role: .text, increased: false) == 0)
    }
}
