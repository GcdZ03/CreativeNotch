import AppKit
import ServiceManagement
import CreativeNotchCore

/// The login-item toggle: one read, two writes, and a rule about which copy
/// is allowed to make them.
///
/// **Nothing here runs.** A registration is a row in the system's Background
/// Task Management database, not a process, so this module joins no
/// lifecycle hook and no activity gate — there is nothing to start, nothing
/// to stop, and the app is not running when the record matters. It is the
/// first module in this project whose honest answer to "what does the toggle
/// stop?" is *nothing*, and `docs/specs/2026-09-19-launch-at-login-design.md`
/// §2 is why that is stated rather than quietly true.
///
/// The three seams are injected because **a real call changes the machine
/// running the tests**: `register()` writes a record that outlives the
/// process, so a suite that made one would pass or fail depending on whether
/// it had ever been run before. Same discipline as never spawning a real
/// media helper.
@MainActor
@Observable
public final class LaunchAtLoginController {

    /// What the row shows.
    ///
    /// `init` seeds it — `.unread` for a copy that may ask, `.unavailable`
    /// for one that may not — and after that `refresh()` is the only writer.
    /// Both seeds are the *absence* of an answer rather than a guess at one:
    /// nothing here ever renders a value that was not read from the system.
    public private(set) var state: LaunchAtLoginState

    private let bundlePath: String
    private let eligibility: LaunchAtLoginEligibility

    @ObservationIgnored
    var readStatus: () -> Int

    @ObservationIgnored
    var register: () throws -> Void

    @ObservationIgnored
    var unregister: () throws -> Void

    /// The app's own controller: this bundle, the real service.
    ///
    /// **The only initialiser that binds the real service, and it takes no
    /// path.** That pairing is deliberate. Review found that the seams alone
    /// did not close the hazard: a test could construct a controller with an
    /// *installed* path, leave the defaults bound, and call `refresh()` —
    /// performing a real read, and therefore a real repoint of the
    /// developer's own login item — with nothing in the source for a scan to
    /// notice. Requiring every caller who names a path to supply all three
    /// seams makes that unconstructible rather than merely documented.
    public convenience init() {
        self.init(
            bundlePath: Bundle.main.bundlePath,
            installDirectories: LaunchAtLoginEligibility.defaultInstallDirectories,
            readStatus: { SMAppService.mainApp.status.rawValue },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() }
        )
    }

    /// Every other caller: say which bundle, and bring your own seams.
    init(
        bundlePath: String,
        installDirectories: [String],
        readStatus: @escaping () -> Int,
        register: @escaping () throws -> Void,
        unregister: @escaping () throws -> Void
    ) {
        self.bundlePath = bundlePath
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.eligibility = LaunchAtLoginEligibility.resolve(
            bundlePath: bundlePath, installDirectories: installDirectories
        )
        // Resolved once, at construction, and never asked again: the answer
        // is a property of where this bundle is, and a running app does not
        // move. Note the initial value is NOT a status read — construction
        // must touch nothing, or building a controller would be the very
        // repoint the eligibility rule exists to prevent.
        //
        // `.unread` rather than `.off`, so "nobody has asked yet" is not
        // spelled the same as "the system said no". See `LaunchAtLoginState`.
        self.state = eligibility == .eligible
            ? .unread
            : .unavailable(bundlePath: bundlePath)
    }

    /// The only writer of `state`.
    ///
    /// The guard is the whole mitigation for the probe's Q3, and it guards
    /// the **call**, not the result: reading `.status` from an uninstalled
    /// copy repoints the system's record at it, so discarding the answer
    /// afterwards would be too late.
    public func refresh() {
        guard eligibility == .eligible else {
            state = .unavailable(bundlePath: bundlePath)
            return
        }
        state = LaunchAtLoginState.from(rawStatus: readStatus())
    }

    /// Register or unregister, then read back what actually happened.
    ///
    /// A throw is caught rather than propagated: the row has no way to show
    /// an error that the re-read does not already show better. A refused
    /// registration leaves the switch off, which is true — where a stored
    /// `Bool` would leave it on over nothing at all.
    public func setEnabled(_ enabled: Bool) {
        guard eligibility == .eligible else { return }
        do {
            try enabled ? register() : unregister()
        } catch {
            NSLog("CreativeNotch: login item \(enabled ? "registration" : "removal") failed: \(error)")
        }
        refresh()
    }

    /// System Settings → General → Login Items.
    ///
    /// Split out from the call below so a test can check the deep link at
    /// all: `NSWorkspace.shared.open` is not seamed, so the only part of
    /// this with a right answer is the URL itself.
    public static let loginItemsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )

    /// The manual route, and the fallback for the one thing no probe in this
    /// repo can prove: that macOS actually starts the app after a logout.
    public static func openLoginItemsSettings() {
        guard let url = loginItemsSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
