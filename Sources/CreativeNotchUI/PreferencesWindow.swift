import AppKit
import SwiftUI
import CreativeNotchCore

/// The settings surface: one switch per module.
///
/// **A window, not a notch tab.** The panel disqualifies itself on its own
/// construction — a `.nonactivatingPanel`, dismissed on a 400ms grace when the
/// cursor leaves, taking key focus for exactly one tab. A form that closes
/// 400ms after your cursor strays and does not hold the keyboard is the wrong
/// container. A menu of seven checkboxes was considered and declined: it does
/// not scale past the toggles, and it has nowhere to put the three notes below
/// that are required rather than decorative.
///
/// **Reached from the menu bar, not the panel.** With every tab-bearing module
/// switched off the visible tab list is empty and the panel has nowhere to
/// open, so the menu bar is the escape hatch — and the reason an empty tab list
/// is a legal state rather than a trap.
///
/// It calls `ModuleSwitchboard.setEnabled` and nothing else. It never touches
/// `PreferencesStore`, a controller, or `AppState` directly: one direction, one
/// source of truth, and no second path that could apply a change without
/// persisting it or persist one without applying it.
@MainActor
final class PreferencesController {

    private let switchboard: ModuleSwitchboard
    private let state: AppState
    private let presenter: (PreferencesController) -> Void
    private var window: NSWindow?

    init(switchboard: ModuleSwitchboard, state: AppState) {
        self.switchboard = switchboard
        self.state = state
        // Taking the instance as a parameter rather than `[weak self]`, which
        // would capture `self` before every stored property has a value --
        // the same reason `OnboardingController` does it this way.
        self.presenter = { $0.presentRealWindow() }
    }

    /// Test-only seam, deliberately not `public`: reached from tests through
    /// `@testable import` so it can never bypass the real presentation path
    /// from production code.
    init(
        switchboard: ModuleSwitchboard,
        state: AppState,
        presenter: @escaping (PreferencesController) -> Void
    ) {
        self.switchboard = switchboard
        self.state = state
        self.presenter = presenter
    }

    func show() { presenter(self) }

    /// The one write path. Persists and applies in the same call, because two
    /// calls are two chances to do one without the other.
    func setEnabled(_ enabled: Bool, for module: ModuleID) {
        switchboard.setEnabled(enabled, for: module, persist: true)
    }

    func isEnabled(_ module: ModuleID) -> Bool { state.preferences[module] }

    /// Whether a countdown is running, which is what makes the timer row's
    /// warning conditional. Shown unconditionally it would train people to
    /// ignore it.
    var hasRunningCountdown: Bool { state.countdown != nil }

    private func presentRealWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "CreativeNotch Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreferencesView(controller: self))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

/// One row per module.
///
/// `rows` is the single source of which modules are offered, in the same sense
/// `TabVisibility.visible` is for tabs. A module missing from it ships
/// unreachable, which is the failure a test pins by comparing against
/// `ModuleID.allCases`.
struct PreferencesRow: Identifiable {
    let module: ModuleID
    let title: String
    let detail: String

    var id: ModuleID { module }
}

struct PreferencesView: View {
    let controller: PreferencesController

    static let rows: [PreferencesRow] = [
        PreferencesRow(
            module: .shelf,
            title: "File shelf",
            // Required, not decorative. The shelf owns no timer, observer or
            // process, so this toggle saves no power at all. Saying so beats
            // implying a saving that is not there.
            detail: "Drag files onto the notch to stash them. This one costs nothing when idle — switching it off hides the tab and refuses drops, it does not save battery."
        ),
        PreferencesRow(
            module: .hud,
            title: "System HUD",
            detail: "Volume and brightness in the notch, where macOS shows you nothing. Releases a global event tap when switched off."
        ),
        PreferencesRow(
            module: .clipboard,
            title: "Clipboard history",
            detail: "The last things you copied. Switching it off stops the only repeating timer in the app."
        ),
        PreferencesRow(
            module: .mediaMetadata,
            title: "Now playing",
            detail: "Title, artist and artwork. Switching it off terminates the helper process that reads them."
        ),
        PreferencesRow(
            module: .mediaControls,
            title: "Media controls",
            // Required. Only disabled-at-launch means "not loaded": the
            // framework is mapped with `dlopen` and there is no `dlclose`.
            detail: "Play, pause and skip buttons. Switching this off now hides the buttons; the framework stays mapped until the next launch."
        ),
        PreferencesRow(
            module: .power,
            title: "Battery and power",
            detail: "Level, charging state and Low Power Mode. Notification-driven, so it costs almost nothing either way."
        ),
        PreferencesRow(
            module: .timer,
            title: "Timer",
            detail: "A countdown in the notch."
        ),
        PreferencesRow(
            module: .hotkey,
            title: "Global shortcut",
            // No default, and the note says why rather than leaving an empty
            // field looking broken.
            detail: "Open the notch from anywhere. No shortcut is set until you choose one — any default would risk colliding with a launcher you already use."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Modules")
                    .font(.title2.weight(.semibold))

                Text("Switching a module off stops what it runs, rather than hiding it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(Self.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(row.title, isOn: Binding(
                            get: { controller.isEnabled(row.module) },
                            set: { controller.setEnabled($0, for: row.module) }
                        ))
                        .font(.body.weight(.medium))

                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let warning = Self.warning(for: row.module, controller: controller) {
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    /// Conditional warnings. Shown unconditionally they would be ignored.
    static func warning(for module: ModuleID, controller: PreferencesController) -> String? {
        switch module {
        case .timer where controller.hasRunningCountdown:
            // Required by the spec: the tab you would cancel it from is what
            // disappears, so say what happens to the countdown.
            return "A countdown is running. Switching the timer off removes the tab you would cancel it from — it will finish and chime."
        case .hud where !Permissions.isAccessibilityTrusted:
            // The honesty rule with teeth. `CGEventTapCreate` genuinely fails
            // without Accessibility and `MediaKeyMonitor.start()` records that
            // as `isRunning = token != nil` with no retry, so a switch reading
            // "on" over a dead subsystem is the exact inversion of the failure
            // this module exists to prevent.
            return "Accessibility is not granted, so the HUD cannot tell a keypress from any other cause. It will show both overlays at once when you use the keys."
        default:
            return nil
        }
    }
}
