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

    /// The login-item toggle. Handed in rather than built here, so the window
    /// and the app agree about one controller -- and so a test can supply one
    /// pinned to a path of its choosing.
    let launchAtLogin: LaunchAtLoginController

    init(
        switchboard: ModuleSwitchboard,
        state: AppState,
        launchAtLogin: LaunchAtLoginController
    ) {
        self.switchboard = switchboard
        self.state = state
        self.launchAtLogin = launchAtLogin
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
        launchAtLogin: LaunchAtLoginController,
        presenter: @escaping (PreferencesController) -> Void
    ) {
        self.switchboard = switchboard
        self.state = state
        self.launchAtLogin = launchAtLogin
        self.presenter = presenter
    }

    /// **Refreshing here rather than in the view is load-bearing.**
    ///
    /// `presentRealWindow()` caches the window and sets
    /// `isReleasedWhenClosed = false`, so closing Settings and reopening it
    /// reuses the same `NSHostingView` — and SwiftUI's `.onAppear` fires
    /// exactly once per process. Measured, not assumed: after close and
    /// reopen, `onAppear` does not fire again and `onDisappear` never fires
    /// at all.
    ///
    /// With the read living only in `.onAppear`, a login item switched off
    /// in System Settings would go on reading `on` here for the life of the
    /// process, which is precisely the lie this module exists to prevent.
    /// The presentation boundary fires every time; the view's `.onAppear`
    /// stays as well, for the first show and for any future presentation
    /// path that does not come through here.
    ///
    /// `refresh()` is eligibility-guarded, so this still touches nothing
    /// from an uninstalled copy.
    func show() {
        launchAtLogin.refresh()
        presenter(self)
    }

    /// The one write path. Persists and applies in the same call, because two
    /// calls are two chances to do one without the other.
    func setEnabled(_ enabled: Bool, for module: ModuleID) {
        switchboard.setEnabled(enabled, for: module, persist: true)
    }

    func isEnabled(_ module: ModuleID) -> Bool { state.preferences[module] }

    /// The hotkey controller, for the recorder row. Reached through the
    /// switchboard's delegate rather than stored twice.
    var hotKeyController: HotKeyController? { switchboard.hotKeyController }

    /// Whether a countdown is running, which is what makes the timer row's
    /// warning conditional. Shown unconditionally it would train people to
    /// ignore it.
    var hasRunningCountdown: Bool { state.countdown != nil }

    private var recorders: [ObjectIdentifier: HotKeyRecorder] = [:]

    /// One recorder per hotkey controller, built on first use. Held here
    /// rather than in the view, because a SwiftUI body can run many times and
    /// a recorder rebuilt mid-recording would drop its monitor.
    func recorder(for hotKey: HotKeyController) -> HotKeyRecorder {
        let key = ObjectIdentifier(hotKey)
        if let existing = recorders[key] { return existing }
        let recorder = HotKeyRecorder { [weak hotKey] combo in
            hotKey?.setCombo(combo)
        }
        recorders[key] = recorder
        return recorder
    }

    private func presentRealWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
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

/// Which group of the form a module's row sits in (spec §6).
///
/// The longer, honest notes that used to sit under every toggle become the
/// section's footer, so the form reads as a form and the honesty is still
/// there for anyone who reads to the end of a group.
enum PreferencesSection: CaseIterable {
    case notch, music, camera, system, shortcut

    var title: String {
        switch self {
        case .notch:    return "In the notch"
        case .music:    return "Music"
        case .camera:   return "Camera and privacy"
        case .system:   return "System"
        case .shortcut: return "Shortcut"
        }
    }

    var footer: String? {
        switch self {
        case .notch:
            return "The shelf costs nothing when idle: switching it off hides the tab and refuses drops, it does not save battery. Clipboard history is the only repeating timer in the app, and switching it off stops it."
        case .music:
            return "Now playing runs a helper process to read the track; switching it off terminates the helper. Media controls map a framework that has no unload, so switching them off hides the buttons and the framework stays mapped until the next launch."
        case .camera:
            return "The camera is the only module that costs anything while it runs: the light is on whenever the preview is, and a clip keeps recording if you close the notch. The indicator is notification-driven and costs nothing while nothing is capturing."
        case .system:
            return "Volume and brightness feedback where macOS shows none. Releases a global event tap when switched off."
        case .shortcut:
            return "No shortcut is set until you choose one. Any default would risk colliding with a launcher you already use."
        }
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
    let section: PreferencesSection
    let symbolName: String
    let tint: Color
    let title: String
    let detail: String

    var id: ModuleID { module }
}

struct PreferencesView: View {
    let controller: PreferencesController

    static let rows: [PreferencesRow] = [
        PreferencesRow(
            module: .shelf, section: .notch, symbolName: "tray.full", tint: .blue,
            title: "File shelf",
            // Required, not decorative. The shelf owns no timer, observer or
            // process, so this toggle saves no power at all. Saying so beats
            // implying a saving that is not there.
            detail: "Drag files onto the notch to stash them for a week. Off hides the tab; it does not save battery."
        ),
        PreferencesRow(
            module: .clipboard, section: .notch, symbolName: "doc.on.clipboard", tint: .purple,
            title: "Clipboard history",
            detail: "The last 50 things you copied, in memory only."
        ),
        PreferencesRow(
            module: .timer, section: .notch, symbolName: "timer", tint: .orange,
            title: "Timer",
            detail: "A countdown, in the ear of the notch."
        ),
        PreferencesRow(
            module: .power, section: .notch, symbolName: "battery.100percent", tint: .green,
            title: "Battery and power",
            detail: "Level, charging state and Low Power Mode. Costs almost nothing either way."
        ),
        PreferencesRow(
            module: .mediaMetadata, section: .music, symbolName: "music.note", tint: .pink,
            title: "Now playing",
            detail: "Title, artist and artwork, in the panel and beside the closed notch."
        ),
        PreferencesRow(
            module: .mediaControls, section: .music, symbolName: "playpause", tint: .pink,
            title: "Media controls",
            // Required. Only disabled-at-launch means "not loaded": the
            // framework is mapped with `dlopen` and there is no `dlclose`.
            detail: "Play, pause and skip. Off hides the buttons; the framework stays mapped until the next launch."
        ),
        PreferencesRow(
            module: .camera, section: .camera, symbolName: "camera", tint: .gray,
            title: "Camera",
            detail: "A mirror under the lens, with a shutter and a record button."
        ),
        PreferencesRow(
            module: .captureIndicator, section: .camera, symbolName: "record.circle", tint: .red,
            title: "Camera and microphone indicator",
            detail: "Shows in the notch when another app is using the camera or the microphone."
        ),
        PreferencesRow(
            module: .hud, section: .system, symbolName: "speaker.wave.2", tint: .indigo,
            title: "System HUD",
            detail: "Volume and brightness in the notch, where macOS shows you nothing."
        ),
        PreferencesRow(
            module: .hotkey, section: .shortcut, symbolName: "command", tint: .gray,
            title: "Global shortcut",
            detail: "Open the notch from anywhere."
        ),
    ]

    var body: some View {
        Form {
            // First, and outside the `ForEach`: this is about the app rather
            // than about a module, and `PreferencesSection`'s cases are module
            // groups -- adding a case with no module rows would make the
            // "every section has rows" test meaningless.
            Section {
                LaunchAtLoginRow(controller: controller.launchAtLogin)
            } header: {
                Text("Startup")
            } footer: {
                Text("macOS owns this setting, so it is read back from the system rather than remembered here \u{2014} turning it off in System Settings turns it off here too.")
            }

            ForEach(PreferencesSection.allCases, id: \.self) { section in
                Section {
                    ForEach(Self.rows.filter { $0.section == section }) { row in
                        moduleRow(row)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer {
                        Text(footer)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func moduleRow(_ row: PreferencesRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { controller.isEnabled(row.module) },
                set: { controller.setEnabled($0, for: row.module) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.body.weight(.medium))
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: row.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(row.tint)
                        )
                }
            }

            if row.module == .hotkey,
               controller.isEnabled(.hotkey),
               let hotKey = controller.hotKeyController {
                HotKeyRow(
                    controller: hotKey,
                    recorder: controller.recorder(for: hotKey),
                    label: hotKey.combo.map {
                        HotKeyGlyphs.label($0, key: KeyCodeDisplay.character(for: $0.keyCode))
                    }
                )
                .padding(.leading, 36)
            }

            if let warning = Self.warning(for: row.module, controller: controller) {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 36)
            }
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

/// The one row in this window that stores nothing.
///
/// Its switch shows `LaunchAtLoginController.state`, which is read from the
/// system, so a registration removed in System Settings shows up here on the
/// next open without anything having told us.
///
/// Everything with a right answer — whether the switch reads on, whether the
/// row can be operated, what the line underneath says — lives on
/// `LaunchAtLoginState` in Core, because a SwiftUI body is not reachable
/// from a test. What is left here is arrangement.
struct LaunchAtLoginRow: View {
    let controller: LaunchAtLoginController

    /// Built by a function rather than inline so both directions can be
    /// exercised without rendering: a getter reading `!= .on` and a setter
    /// calling `setEnabled(!$0)` are each a one-character bug that shows the
    /// switch backwards or unregisters when asked to register, and neither
    /// is visible to any other kind of test.
    static func binding(for controller: LaunchAtLoginController) -> Binding<Bool> {
        Binding(
            get: { controller.state.isOn },
            set: { controller.setEnabled($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Self.binding(for: controller)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                            .font(.body.weight(.medium))
                        Text(controller.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.teal)
                        )
                }
            }
            .disabled(!controller.state.isOperable)

            // Unconditional, not shown only on failure: no probe in this repo
            // can prove macOS actually starts the app after a logout, and a
            // user for whom it silently does not should not have to deduce
            // that they are in a failure case to find the manual route.
            // (Spec section 5.)
            Button("Open Login Items") {
                LaunchAtLoginController.openLoginItemsSettings()
            }
            .padding(.leading, 36)
        }
        // The first show comes through here; every later one comes through
        // `PreferencesController.show()`, because this fires only once per
        // process. See that method.
        .onAppear { controller.refresh() }
    }
}
