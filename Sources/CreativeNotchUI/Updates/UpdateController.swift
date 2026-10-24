import AppKit
import CreativeNotchCore

/// Everything the updater touches outside itself, in one value
/// (2026-10-24).
///
/// `sandboxed` is what every `AppDelegate()` starts with: nobody to ask, a
/// bundle path in a temporary folder that is in no install folder — so even
/// an install forced past the button would be refused as a dev build — and
/// relaunch, terminate, open and copy that do nothing.
/// `AppDelegate.configureForRealLaunch()` swaps in `system()`, and nothing
/// else does.
struct UpdateEnvironment {
    var fetcher: any ReleaseFetching
    var installer: any UpdateInstalling
    /// The running copy, which "Update Now" replaces.
    var bundleURL: URL
    /// Where a copy counts as installed (`LaunchAtLoginEligibility`'s list).
    var installDirectories: [String]
    /// Whether this user can replace the bundle at that URL.
    var isWritable: @MainActor (URL) -> Bool
    var relaunch: @MainActor (URL) -> Void
    var terminate: @MainActor () -> Void
    var openURL: @MainActor (URL) -> Void
    var copy: @MainActor (String) -> Void
    var now: @MainActor () -> Date
    var currentVersion: String

    static func sandboxed(in folder: URL) -> UpdateEnvironment {
        UpdateEnvironment(
            fetcher: InertReleaseFetcher(),
            installer: InertUpdateInstaller(),
            bundleURL: folder.appendingPathComponent("CreativeNotch.app", isDirectory: true),
            installDirectories: [],
            isWritable: { _ in false },
            relaunch: { _ in },
            terminate: {},
            openURL: { _ in },
            copy: { _ in },
            now: { Date() },
            currentVersion: CoreInfo.version
        )
    }

    /// The real thing. Building it fetches, moves and launches nothing.
    static func system() -> UpdateEnvironment {
        UpdateEnvironment(
            fetcher: GitHubReleaseFetcher(),
            installer: UpdateInstaller.system(),
            bundleURL: Bundle.main.bundleURL,
            installDirectories: LaunchAtLoginEligibility.defaultInstallDirectories,
            isWritable: UpdateEnvironment.canReplace,
            relaunch: { UpdateRelaunch.spawn(bundle: $0) },
            terminate: { NSApp.terminate(nil) },
            openURL: { NSWorkspace.shared.open($0) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            now: { Date() },
            currentVersion: CoreInfo.version
        )
    }

    /// The swap renames the bundle within its folder and deletes the old
    /// copy, so it needs to write both the folder and the bundle. A copy
    /// `install.sh` put there with `sudo` is root's, and fails the second.
    static func canReplace(_ bundle: URL) -> Bool {
        let manager = FileManager.default
        return manager.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && manager.isWritableFile(atPath: bundle.path)
    }
}

/// The in-app updater (2026-10-24): asks GitHub whether there is a newer
/// release, says so in the menu bar and Settings, and on "Update Now"
/// downloads, verifies and swaps it in, then relaunches.
///
/// **It owns no timer.** It checks when the app launches, when the Mac
/// comes back to `.active` (through the one `SystemActivityObserver` the
/// app already has), when Settings opens, and when asked — the last always,
/// the middle two at most once a day (`UpdateCheckPolicy`). Between those
/// moments it costs nothing, which is the one rule's whole demand.
///
/// Not a module, so not on the switchboard: there is nothing running for a
/// switch to stop. "Automatically check for updates" stops the checks
/// nobody asked for; the menu's check always works.
@MainActor
@Observable
final class UpdateController {
    private(set) var status: UpdateStatus = .notChecked
    private(set) var automatic = true

    @ObservationIgnored var environment: UpdateEnvironment

    /// The preferences domain. Setting it re-reads what was remembered, so
    /// `configureForRealLaunch()` moving the delegate off its sandbox suite
    /// brings the real record with it.
    @ObservationIgnored var defaults: UserDefaults {
        didSet { restore() }
    }

    /// The check in flight, if any. Internal so a test can await it.
    @ObservationIgnored private(set) var checkTask: Task<Void, Never>?
    /// The install in flight, if any. Internal so a test can await it.
    @ObservationIgnored private(set) var installTask: Task<Void, Never>?
    /// Whether anyone asked for the check in flight. Only then is a failure
    /// reported; otherwise nobody is told, because nobody asked.
    @ObservationIgnored private var reportsFailure = false

    init(environment: UpdateEnvironment, defaults: UserDefaults) {
        self.environment = environment
        self.defaults = defaults
        restore()
    }

    private var store: PreferencesStore { PreferencesStore(defaults: defaults) }

    /// The resting status and the toggle, from the domain.
    private func restore() {
        automatic = store.checksForUpdatesAutomatically
        guard !status.isBusy else { return }
        status = .settled(record: store.loadUpdateRecord(), currentVersion: environment.currentVersion)
    }

    var currentVersion: String { environment.currentVersion }

    /// Whether "Update Now" can replace this copy. Asked when Settings
    /// draws, so a permission changed since launch shows.
    var eligibility: UpdateInstallEligibility {
        UpdateInstallEligibility.resolve(
            bundlePath: environment.bundleURL.path,
            installDirectories: environment.installDirectories,
            isWritable: environment.isWritable(environment.bundleURL)
        )
    }

    // MARK: - Checking

    /// Asks GitHub, if `trigger` should now (`UpdateCheckPolicy`). Returns
    /// whether a request started.
    @discardableResult
    func check(_ trigger: UpdateCheckTrigger) -> Bool {
        let record = store.loadUpdateRecord()
        guard UpdateCheckPolicy.shouldCheck(
            trigger, lastCheck: record.lastCheck, automatic: automatic, now: environment.now()
        ) else { return false }
        // A manual check arriving while an automatic one is out joins it,
        // and is owed an answer either way.
        guard checkTask == nil else {
            if trigger == .manual { reportsFailure = true }
            return false
        }
        guard !status.isBusy else { return false }

        reportsFailure = trigger == .manual
        status = .checking
        let headers = UpdateEndpoint.headers(version: environment.currentVersion, etag: record.conditionalETag)
        let fetcher = environment.fetcher
        checkTask = Task { [weak self] in
            let reply = await fetcher.fetch(headers: headers)
            self?.finishCheck(UpdateCheckResult.classify(reply))
        }
        return true
    }

    private func finishCheck(_ result: UpdateCheckResult) {
        checkTask = nil
        let reports = reportsFailure
        reportsFailure = false
        let record = store.loadUpdateRecord().applying(result, at: environment.now())
        store.saveUpdateRecord(record)
        if case .failed(let failure) = result, reports {
            status = .checkFailed(failure)
        } else {
            status = .settled(record: record, currentVersion: environment.currentVersion)
        }
    }

    /// Cancels a check in flight, at quit. An install is not cancelled: it
    /// ends by quitting the app itself.
    func stop() {
        checkTask?.cancel()
    }

    func setAutomatic(_ enabled: Bool) {
        store.setChecksForUpdatesAutomatically(enabled)
        automatic = enabled
    }

    // MARK: - Installing

    /// "Update Now": only with an installable release on offer, from a copy
    /// that may replace itself, and with nothing else under way. Ends by
    /// relaunching and quitting; a failure says why and leaves the offer.
    func installUpdate() {
        guard installTask == nil, checkTask == nil,
              let release = status.installableRelease,
              eligibility.canInstall else { return }
        status = .installing(release, .downloading)
        let installer = environment.installer
        let bundle = environment.bundleURL
        let progress: @Sendable (UpdatePhase) async -> Void = { [weak self] phase in
            await self?.advance(release, to: phase)
        }
        installTask = Task { [weak self] in
            do throws(UpdateInstallFailure) {
                try await installer.install(release, over: bundle, progress: progress)
                self?.finishInstall(release, bundle: bundle)
            } catch {
                self?.failInstall(release, error)
            }
        }
    }

    private func advance(_ release: Release, to phase: UpdatePhase) {
        status = .installing(release, phase)
    }

    private func finishInstall(_ release: Release, bundle: URL) {
        installTask = nil
        status = .relaunching(release)
        environment.relaunch(bundle)
        environment.terminate()
    }

    private func failInstall(_ release: Release, _ failure: UpdateInstallFailure) {
        installTask = nil
        status = .installFailed(release, failure)
    }

    // MARK: - Links

    /// The release page, in the browser.
    func openReleaseNotes() {
        guard let release = status.release else { return }
        environment.openURL(release.notesURL)
    }

    /// The one-line install command, for a copy that cannot replace itself.
    func copyInstallCommand() {
        environment.copy(UpdateInstallEligibility.installCommand)
    }
}
