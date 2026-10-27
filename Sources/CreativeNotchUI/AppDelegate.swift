import AppKit
import CreativeNotchCore

/// Owns the panel, its views, and the app-lifetime observers.
///
/// Lives in `CreativeNotchUI` rather than the executable target because
/// SwiftPM cannot link an executable into a test target: while this class
/// sat in `Sources/CreativeNotch` it -- and therefore the whole
/// state/tracking-rect/repositioning core of the app -- was unreachable
/// by any test. The executable is now a five-line launcher.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var panel: NotchPanel?
    private(set) var hostView: HitTestingHostingView<NotchRootView>?
    private(set) var hoverView: HoverTracker?
    private var menuBar: MenuBarController?

    /// Views onto the funnel rather than a second copy. They used to be
    /// stored here *and* on `AppState`, which is two places one value can
    /// drift apart. (Follow-up F4.)
    var currentAnchor: Anchor { state.anchor }
    var currentFrame: CGRect { state.panelFrame }

    /// Each token paired with the centre that issued it. Passing every
    /// token to both centres worked only because the mismatched calls are
    /// no-ops. (Follow-up F3.)
    private var observers: [(token: NSObjectProtocol, center: NotificationCenter)] = []

    /// Removed and re-registered by `install`, so building the panel twice
    /// cannot stack duplicate observers on the state.
    private var stateObserver: AppState.ObserverToken?

    /// The centre each screen observer was registered with, so the pairing
    /// that F3 fixed is assertable. Removing a token from the wrong centre
    /// is a silent no-op, which is exactly why it went unnoticed.
    var screenObserverCenters: [NotificationCenter] { observers.map(\.center) }

    var stateObserverCount: Int { state.observerCount }

    public let state = AppState()

    /// Internal rather than private so the peek wiring is provable — the
    /// same reason `clipboard` and `activity` are internal.
    var arbiter = PeekArbiter()

    /// Internal rather than private so the wiring is provable.
    private(set) var clipboard: ClipboardController?

    /// Internal rather than private so the lifecycle is provable, like
    /// `clipboard`.
    private(set) var media: MediaController?

    /// Internal rather than private for the same reason `media` is: the
    /// module is only "wired" if a test can reach the controller the app
    /// actually built and drive it.
    private(set) var timer: TimerController?

    /// The finish alert, behind an injection point.
    ///
    /// Not called directly for one reason only: a test that drives the
    /// finish path would otherwise make the machine audibly chime, and the
    /// suite must stay silent. The default *is* the real chime, so
    /// production wiring is this line and nothing else.
    ///
    /// Takes the sound to play (2026-10-24), so the same seam carries both
    /// the finish alert and Settings' preview, and a test can see which
    /// sound was asked for without hearing it.
    var playChime: (ChimeSound) -> Void = TimerChime.play

    /// Speaks a peek to VoiceOver, behind an injection point like
    /// `playChime`, so a test can count what would be said.
    ///
    /// Gated on VoiceOver being on. An announcement with no screen reader
    /// listening is harmless, but `isVoiceOverEnabled` is a cached property
    /// AppKit keeps current by notification — reading it costs nothing —
    /// and skipping the post keeps an accessibility message from being
    /// built and sent on every peek for the people who will never hear it.
    ///
    /// AppKit's announcement rather than SwiftUI's
    /// `AccessibilityNotification.Announcement` (which `ClipboardRow` posts
    /// from inside a view): this file is AppKit-only, and the announcement
    /// has to name an element — `NSApp`, since a peek can appear while the
    /// panel is not key and no window of this agent app is focused.
    var announce: (String) -> Void = { text in
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Where a finished timer's notification goes (2026-10-24), when the
    /// notch is hidden and cannot show the peek.
    ///
    /// Sandboxed by default like `shelfDirectory`: a fresh delegate records
    /// into `SilentTimerNotices` and reaches no notification center, so no
    /// test can post a real banner or raise a permission prompt. Only
    /// `configureForRealLaunch()` installs `SystemTimerNotices`.
    var timerNotices: any TimerNoticeCenter = SilentTimerNotices()

    /// Whether MediaRemote is loadable, behind a seam.
    ///
    /// In the shape of `playChime` and `now`, and for a sharper reason than
    /// either: reading `MediaRemoteBridge.isAvailable` is what performs the
    /// `dlopen`, and there is no `dlclose` — `handle` is a `static let`.
    ///
    /// Once the transport toggle exists, this read has to sit on the RIGHT of
    /// a lazy `&&` with the preference on its left. Written the other way
    /// round it compiles, behaves identically in every visible respect, and
    /// loads a private framework the user just declined — exactly the line a
    /// later tidy-up reverses with nothing failing. `handle` is already
    /// forced open by `MediaRemoteBridgeTests` in the same process, so
    /// counting calls to this seam is the only way that order is provable.
    var mediaRemoteAvailable: () -> Bool = { MediaRemoteBridge.isAvailable }

    /// Internal rather than private so the lifecycle and the fan-out are
    /// provable, like `clipboard` and `media`.
    private(set) var power: PowerController?

    /// Bluetooth alerts (2026-10-24). Internal rather than private so the
    /// switchboard and the tests can reach its lifecycle, like `power`.
    private(set) var bluetooth: BluetoothController?

    /// Where Bluetooth connect and disconnect callbacks come from, and the
    /// grant behind them. Sandboxed by default like `shelfTrash`: a fresh
    /// delegate registers nothing with IOBluetooth and can never show the
    /// Bluetooth prompt. Only `configureForRealLaunch()` hands them the real
    /// thing. Set them before `install(metrics:)`, which builds the
    /// controller from them.
    var bluetoothSource: BluetoothSource = SandboxBluetoothSource()
    var bluetoothAccess: BluetoothAccess = SandboxBluetoothAccess()

    /// Reads the frontmost app's menus for "Keep clear of app menus"
    /// (2026-10-26). A sandbox that is never trusted and reads nothing, so no
    /// test can show the Accessibility prompt; `configureForRealLaunch()`
    /// hands it the real one.
    var appMenuReader: AppMenuReader = SandboxAppMenuReader()

    /// How far from its display's left edge the frontmost app's menus reach,
    /// as last read (`AppMenus.end`); 0 while the setting is off. Every
    /// placement reads it through `anchor(for:)`.
    private(set) var appMenusEnd: CGFloat = 0

    /// The last other app to come forward, so switching the setting on --
    /// with Settings, this app, in front -- measures the app the user was
    /// in rather than waiting for the next switch.
    private var lastActivePID: pid_t?

    /// Opens Privacy & Security › Bluetooth, for the Settings row's denied
    /// state. A seam because opening System Settings from a test would put
    /// an app in front of the person running the suite; it does nothing
    /// until `configureForRealLaunch()`.
    var openBluetoothSettings: () -> Void = {}

    /// One observer for the whole app. Internal rather than private so the
    /// fan-out is provable — `SystemActivityFanOutTests` asserts there is
    /// exactly one registration set.
    let activity = SystemActivityObserver()

    /// Overridable so the peek slot's timing is testable without a real
    /// clock or real sleeps -- a test advances this instead of waiting out
    /// the TTL, the same reason `dismissGrace` and `growthDelay` exist.
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

    /// How long a power peek occupies the slot before this re-checks the
    /// arbiter. Mirrors `PeekArbiter.powerTTL`.
    public static let defaultPowerTTLDelay: Duration = .milliseconds(3000)

    /// Overridable so tests need not wait out the real 3 seconds.
    var powerTTLDelay: Duration = AppDelegate.defaultPowerTTLDelay

    /// How long a Bluetooth peek occupies the slot before this re-checks the
    /// arbiter. Mirrors `PeekArbiter.bluetoothTTL`.
    public static let defaultBluetoothTTLDelay: Duration = .milliseconds(2500)

    /// Overridable for the reason `powerTTLDelay` is.
    var bluetoothTTLDelay: Duration = AppDelegate.defaultBluetoothTTLDelay

    /// How long a finished-timer peek occupies the slot before this
    /// re-checks the arbiter. Mirrors `PeekArbiter.timerDoneTTL`.
    ///
    /// Two orders of magnitude longer than the power peek, and deliberately:
    /// a power peek expires so the slot returns to ambient content, while
    /// this one is only a backstop for a completion nobody acknowledged.
    /// Dismissing it is what normally clears it.
    public static let defaultTimerDoneTTLDelay: Duration = .seconds(600)

    /// Overridable for the same reason `powerTTLDelay` is — a test must not
    /// wait out ten minutes.
    var timerDoneTTLDelay: Duration = AppDelegate.defaultTimerDoneTTLDelay

    /// How long a finished-timer peek occupies the slot once shown, when a
    /// banner already announced it. Mirrors
    /// `PeekArbiter.notifiedTimerDoneTTL`, and starts when the peek is put
    /// on screen -- the notch back from a full-screen app -- not when the
    /// timer finished.
    public static let defaultNotifiedTimerDoneTTLDelay: Duration = .milliseconds(5000)

    /// Overridable for the reason `powerTTLDelay` is.
    var notifiedTimerDoneTTLDelay: Duration = AppDelegate.defaultNotifiedTimerDoneTTLDelay

    /// Exposed so tests can await the real re-evaluation instead of
    /// sleeping and hoping, exactly like `graceTask`.
    private(set) var peekTTLTask: Task<Void, Never>?

    // MARK: - Preferences

    /// Overridable so tests never read or write the real
    /// `com.gcdz.creativenotch` domain.
    ///
    /// **Defaults to a private, uniquely named suite, not `.standard`** --
    /// see `configureForRealLaunch()`. A suite that forgets to set it gets an
    /// empty domain of its own, never the developer's real one.
    ///
    /// **Setting it is still required, not a convenience.** Once the activity fan-out routes
    /// through the switchboard, a wiring suite reading the developer's real
    /// defaults means a developer who switched media off in the actual app
    /// makes `lockingStopsTheMediaHelper` fail on their machine and nowhere
    /// else. Set it before `install(metrics:)`, exactly as `shelfDirectory`
    /// and `growthDelay` are.
    var preferencesDefaults: UserDefaults

    /// Reads and writes the module toggles. Built in `install(metrics:)` from
    /// `preferencesDefaults`, so the seam above is the only thing a test has
    /// to set.
    private(set) var preferencesStore = PreferencesStore()

    /// The one place that knows how to start and stop every module.
    ///
    /// Constructed lazily because it holds an `unowned` reference back here,
    /// and `self` is not available in a property initialiser.
    private(set) lazy var switchboard = ModuleSwitchboard(delegate: self)

    /// The capture indicator. Internal rather than private so the switchboard
    /// and the tests can reach its lifecycle, like every other controller.
    private(set) var capture: CaptureController?

    /// The camera. Internal rather than private so the switchboard and the
    /// tests can reach its lifecycle, like every other controller.
    private(set) var camera: CameraController?

    /// The calendar glance. Internal rather than private so the switchboard
    /// and the tests can reach its lifecycle, like every other controller.
    private(set) var calendar: CalendarController?

    /// Where the calendar glance reads from, handed to the controller in
    /// `install(metrics:)`.
    ///
    /// **Sandboxed by default, like the shelf's Trash:** a stand-in that
    /// reads nothing and prompts for nothing. Only `configureForRealLaunch()`
    /// hands it EventKit, so no test can put a Calendars prompt on screen or
    /// read the developer's diary by forgetting to set it.
    var calendarSource: CalendarSource = InertCalendarSource()

    /// How the app opens something outside itself -- Calendar, or a pane of
    /// System Settings. Sandboxed by default to do nothing, so a test that
    /// presses "Open Calendar" opens no app; `configureForRealLaunch()` hands
    /// it `NSWorkspace`.
    var openExternalURL: (URL) -> Void = { _ in }

    /// Privacy & Security's Calendars list, where a refused grant is changed.
    static let calendarPrivacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )!

    /// Calendar itself, for the pane's "Open Calendar".
    static let calendarAppURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")

    /// Where the camera saves captures, handed to it in `install(metrics:)`.
    /// Sandboxed by default like `shelfDirectory`; the real
    /// `~/Pictures/CreativeNotch/` is set by `configureForRealLaunch()`.
    var capturesDirectory: URL

    /// The global hotkey. Internal rather than private so the switchboard and
    /// the tests can reach its lifecycle, like every other controller.
    private(set) var hotkey: HotKeyController?

    /// The colour picker (2026-10-24). Internal rather than private so the
    /// switchboard and the tests can reach it, like every other controller.
    private(set) var colorPicker: ColorPickerController?

    /// What shows the loupe. Sandboxed by default like `shelfTrash`: a bare
    /// delegate finishes every pick at once with nothing, and only
    /// `configureForRealLaunch()` hands it the system's `NSColorSampler`.
    /// Set it before `install(metrics:)`, which builds the controller.
    var colorSampler: ColorSampling = InertColorSampler()

    /// Where a picked colour is written. A uniquely named pasteboard of this
    /// delegate's own until `configureForRealLaunch()` points it at the
    /// general one, so no test overwrites what the developer last copied.
    /// Lazy, because a test run builds hundreds of delegates and only a few
    /// ever copy a colour.
    lazy var colorPasteboard: NSPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.gcdz.creativenotch.sandbox.\(UUID().uuidString)")
    )

    // MARK: - Downloads

    /// The downloads module. Internal rather than private so the switchboard
    /// and the tests can reach its lifecycle, like every other controller.
    private(set) var downloads: DownloadsController?

    /// The folder whose file progress the downloads module watches.
    /// Sandboxed by default like `shelfDirectory` -- a folder that does not
    /// exist, so even a real access probe finds nothing and asks nobody --
    /// and pointed at `~/Downloads` only by `configureForRealLaunch()`.
    var downloadsDirectory: URL

    /// Where download progress comes from. The real subscriber by default;
    /// a test hands in a fake that plays events. Set it before
    /// `install(metrics:)`, which builds the controller with it.
    var makeDownloadSource: () -> DownloadProgressSource = { FileProgressSource() }

    /// Whether the Downloads folder can be read, behind a seam: the real
    /// read is what makes macOS ask, and no test may make macOS ask.
    var probeDownloadsAccess: DownloadsController.AccessProbe = DownloadsController.readsFolder

    /// Shows a finished download in Finder. **Inert until
    /// `configureForRealLaunch()`**, like the real Trash: a test that clicks
    /// a completion peek on a bare delegate opens no Finder window.
    var revealInFinder: (URL) -> Void = { _ in }

    /// Opens System Settings at Files & Folders, from the denied row. Inert
    /// until `configureForRealLaunch()`, for `revealInFinder`'s reason.
    var openDownloadsPrivacySettings: () -> Void = {}

    /// How long a finished-download peek occupies the slot before this
    /// re-checks the arbiter. Mirrors `PeekArbiter.downloadDoneTTL`.
    public static let defaultDownloadDoneTTLDelay: Duration = .seconds(5)

    /// Overridable for the reason `powerTTLDelay` is.
    var downloadDoneTTLDelay: Duration = AppDelegate.defaultDownloadDoneTTLDelay

    /// The settings window's controller, built on first use by
    /// `showPreferences()`.
    private(set) var preferences: PreferencesController?

    // MARK: - Updates

    /// The in-app updater (2026-10-24). **Sandboxed until
    /// `configureForRealLaunch()`**, like the shelf's folder: a fresh
    /// delegate's asks nobody, and its bundle is a path in this delegate's
    /// temporary folder that is in no install folder, so nothing a test does
    /// can download, replace, relaunch or quit anything.
    ///
    /// Lazy so it is built from `preferencesDefaults` as it stands when
    /// first used — after a suite has pointed that at its own suite.
    private(set) lazy var updates = UpdateController(
        environment: .sandboxed(in: updatesSandbox),
        defaults: preferencesDefaults
    )

    /// Where the sandboxed updater's pretend bundle would be.
    private let updatesSandbox: URL

    /// The login-item toggle.
    ///
    /// Lazy, and it reads nothing until the Settings window asks it to: a
    /// status read repoints the system's record at this bundle, so building
    /// one must not be enough to do that. See `LaunchAtLoginController`.
    private(set) lazy var launchAtLogin = LaunchAtLoginController()

    /// Test seam for the header's gear and the welcome card's "Set
    /// Shortcut…": what they present after closing the panel, with the
    /// section to highlight. `nil` means the real window via
    /// `showPreferences(highlighting:)`. Exists so a wiring test can prove the
    /// panel closes without putting a Settings window on screen.
    var presentPreferences: ((PreferencesSection?) -> Void)?

    // MARK: - Shelf

    /// Overridable so tests do not write into the real Application Support.
    ///
    /// Defaults to a folder under this delegate's own temporary sandbox; the
    /// real one is `realShelfDirectory`, set by `configureForRealLaunch()`.
    var shelfDirectory: URL

    private(set) var shelf: ShelfStore?

    /// How the shelf copies a dropped file. Overridable, like
    /// `shelfDirectory`, so a test can decide when -- and whether -- a copy
    /// finishes. Set it before `install(metrics:)`.
    var shelfCopier: ShelfCopier = .system

    /// Where the shelf sends what it clears, evicts and purges. Overridable
    /// so tests never move files into the user's real Trash. Set it before
    /// `install(metrics:)`, whose launch purge already uses it.
    ///
    /// Defaults to a stand-in folder in this delegate's temporary sandbox;
    /// only `configureForRealLaunch()` hands it `.system`.
    var shelfTrash: ShelfTrash

    /// Opens a shelf file with its default app. Overridable, and sandboxed
    /// by default (`ShelfOpener.inert`, which opens nothing) like
    /// `shelfTrash`: only `configureForRealLaunch()` hands in `NSWorkspace`,
    /// so no test can launch an app on the machine running it.
    var shelfOpener: ShelfOpener = .inert

    /// Previews shelf files. Sandboxed by default like `shelfOpener`; only
    /// `configureForRealLaunch()` hands in Quick Look, so no test can put a
    /// preview panel on screen.
    var shelfPreview: ShelfPreviewing = InertShelfPreview() {
        didSet { shelfPreview.onClose = { [weak self] in self?.shelfPreviewDidClose() } }
    }

    /// How long "Couldn't add …" stays under the shelf after a background
    /// copy fails. Long enough to read a file name; it is a report, not an
    /// offer, so nothing waits on it.
    static let defaultShelfNoticeDuration: Duration = .seconds(4)

    /// Overridable for the reason `shelfUndoWindow` is.
    var shelfNoticeDuration: Duration = AppDelegate.defaultShelfNoticeDuration

    /// The one-shot that withdraws the notice. Scheduled only while a notice
    /// is up and the shelf pane is on screen, sleeps once, and is gone:
    /// `nil` whenever no notice is shown or nobody can see it.
    private(set) var shelfNoticeTask: Task<Void, Never>?

    /// How long "Undo" stays on offer after the shelf is cleared.
    ///
    /// Long enough to notice a mistake and reach the button, short enough
    /// that the offer does not outlive the user's memory of what it undoes.
    static let defaultShelfUndoWindow: Duration = .seconds(6)

    /// Overridable so a test can watch the offer lapse without waiting six
    /// seconds, the same reason `growthDelay` is.
    var shelfUndoWindow: Duration = AppDelegate.defaultShelfUndoWindow

    /// What the clears made while the offer stood took, merged newest
    /// first, while they can still be undone.
    private var pendingShelfClearance: ShelfClearance?

    /// The one-shot that withdraws the offer. Not a repeating timer: it is
    /// scheduled only by a clear, sleeps once, and is gone. `nil` whenever
    /// no undo is on offer, so nothing is scheduled while the shelf is idle.
    private(set) var shelfUndoTask: Task<Void, Never>?

    /// Saves and applies new limits from Settings (2026-10-24) — the one path
    /// `AppState.onSetLimits` takes, so nothing can be persisted without
    /// being applied or applied without being persisted.
    ///
    /// Applied to the live stores, not left for a relaunch: a lowered shelf
    /// capacity or expiry trashes what no longer fits straight away, by the
    /// rules an add already follows. Settings asks first, through
    /// `previewLimits`, so by the time a change that trashes files reaches
    /// here the user has confirmed it. A smaller clipboard forgets its
    /// oldest entries. The timer's presets need nothing here — the tab draws
    /// them from `AppState`.
    ///
    /// A newly chosen chime is played once, through the same `playChime`
    /// seam the finish uses, so the menu can be auditioned without running a
    /// timer to the end — and so no test hears it. "None" has nothing to
    /// preview.
    func applyLimits(_ limits: Limits) {
        let previous = state.limits
        preferencesStore.saveLimits(limits)
        state.limits = limits
        // Only a change to the shelf's own limits reaches the shelf: setting
        // them re-runs eviction and the purge, and a clipboard or chime
        // change has no business trashing a file — not even one already
        // past the expiry and waiting for the next add's purge.
        if limits.shelfCapacity != previous.shelfCapacity || limits.shelfExpiry != previous.shelfExpiry {
            shelf?.setLimits(
                capacity: limits.shelfCapacity,
                maxAge: limits.shelfExpiry.maxAge,
                now: Date(timeIntervalSince1970: now())
            )
        }
        clipboard?.store.setCapacity(limits.clipboardCapacity)
        if limits.chime != previous.chime, limits.chime != .none {
            playChime(limits.chime)
        }
    }

    /// What `applyLimits` would take off the shelf, without taking it —
    /// asked by Settings before a change, so one that would trash files can
    /// be confirmed first. Measured at the same `now` the apply uses.
    func previewLimits(_ limits: Limits) -> ShelfLimitRemoval {
        shelf?.previewLimits(
            capacity: limits.shelfCapacity,
            maxAge: limits.shelfExpiry.maxAge,
            now: Date(timeIntervalSince1970: now())
        ) ?? ShelfLimitRemoval(items: [])
    }

    /// Clears the shelf and offers the clear back for `shelfUndoWindow`.
    ///
    /// The one path both the pane's Clear and the menu bar's Clear Shelf
    /// take, so either can be undone from the pane. Clear moves real files
    /// to the Trash; before the undo, getting one back meant finding it in
    /// Finder. A clear that fails partway still offers back what it did
    /// take. A new clear made while an offer still stands is merged into it
    /// and restarts the window: replacing the record instead left the first
    /// batch in the Trash with no button pointing at it, so one Undo puts
    /// back everything cleared since the offer appeared.
    func clearShelf() {
        guard let shelf else { return }
        let clearance: ShelfClearance
        do {
            clearance = try shelf.clear()
        } catch let partial as ShelfStore.PartialClear {
            NSLog("CreativeNotch: shelf could not trash every item: \(partial.underlying)")
            clearance = partial.clearance
        } catch {
            return
        }
        guard !clearance.isEmpty else { return }
        offerShelfUndo(clearance)
    }

    /// Puts back what the clears on offer took, if the offer has not
    /// lapsed. Items that cannot come back -- emptied from the Trash in the
    /// meantime -- are skipped by the store; the rest still return, and the
    /// shelf pane says how many did not, through the same notice a failed
    /// copy uses. A count that was only logged left a user wondering why
    /// fewer tiles came back than went.
    func undoClearShelf() {
        guard let clearance = pendingShelfClearance else { return }
        withdrawShelfUndo()
        guard let restoration = shelf?.restore(clearance) else { return }
        if let notice = restoration.notice {
            NSLog("CreativeNotch: could not restore \(restoration.skipped.count) shelf item(s)")
            showShelfNotice(notice)
        }
    }

    private func offerShelfUndo(_ clearance: ShelfClearance) {
        shelfUndoTask?.cancel()
        pendingShelfClearance = pendingShelfClearance.map(clearance.merging) ?? clearance
        state.canUndoShelfClear = true
        shelfUndoTask = Task { @MainActor [weak self] in
            guard let window = self?.shelfUndoWindow else { return }
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.withdrawShelfUndo()
        }
    }

    private func withdrawShelfUndo() {
        shelfUndoTask?.cancel()
        shelfUndoTask = nil
        pendingShelfClearance = nil
        state.canUndoShelfClear = false
    }

    /// How many shelf items the menu bar's Clear Shelf counts and acts on.
    ///
    /// Ready items only, as the pane's Clear verb: `clear()` never touches a
    /// copy in progress, so counting one would offer a Clear that does
    /// nothing.
    var menuShelfCount: Int { shelf?.readyItems.count ?? 0 }

    /// How many clipboard entries the menu bar's Clear Clipboard counts.
    ///
    /// What Clear would take — pins stay — for the reason `menuShelfCount`
    /// leaves out copies in progress: a history of pins alone would
    /// otherwise offer a Clear that does nothing.
    var menuClipboardCount: Int { clipboard?.store.clearableCount ?? 0 }

    /// The version the menu's "Update to v…" names, or `nil` to hide it.
    var menuAvailableUpdate: String? {
        updates.status.release.map { $0.version?.description ?? $0.tag }
    }

    /// A row's Pin or Unpin, whichever the entry is not. An id the poller
    /// has evicted since the menu was built is a no-op in the store; the
    /// limit is a disabled menu item before it is ever a refusal here.
    private func togglePin(_ id: UUID) {
        guard let store = clipboard?.store,
              let entry = store.entries.first(where: { $0.id == id }) else { return }
        if entry.isPinned { store.unpin(id) } else { store.pin(id) }
    }

    /// A dropped file's background copy failed after the drop was accepted.
    ///
    /// Logged, announced to VoiceOver, and said under the shelf. The
    /// announcement reaches someone who cannot see the line; the line is
    /// what reaches everyone else, so it stays until it has been on screen
    /// for `shelfNoticeDuration`. A big copy is exactly the one the panel
    /// closes or the tab changes during, and a line withdrawn on a timer
    /// nobody saw would leave a pending tile that simply vanished. A second
    /// failure replaces the first line rather than queueing behind it.
    func reportShelfCopyFailure(_ item: ShelfItem, _ error: any Error) {
        NSLog("CreativeNotch: shelf could not copy \(item.displayName): \(error)")
        showShelfNotice(String(localized: "Couldn't add \(item.displayName)", bundle: .creativeNotch))
    }

    /// Announces `notice` and puts it under the shelf until the pane has
    /// shown it -- the one path every shelf report takes, so a failed copy
    /// and an undo that came back short read and behave the same.
    private func showShelfNotice(_ notice: String) {
        announce(notice)
        shelfNoticeTask?.cancel()
        shelfNoticeTask = nil
        state.shelfNotice = notice
        syncShelfNotice(for: state.state)
    }

    /// Runs the notice's withdrawal only while the shelf pane is showing it.
    ///
    /// Called from the state funnel and after a failure. Leaving the pane
    /// before the time is up stops the clock and keeps the line for the next
    /// visit, with the full duration again: a glance on the way past is not
    /// a reading.
    func syncShelfNotice(for next: NotchState) {
        guard state.shelfNotice != nil else { return }
        guard next == .open(.shelf) else {
            shelfNoticeTask?.cancel()
            shelfNoticeTask = nil
            return
        }
        guard shelfNoticeTask == nil else { return }
        shelfNoticeTask = Task { @MainActor [weak self] in
            guard let duration = self?.shelfNoticeDuration else { return }
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.state.shelfNotice = nil
            self?.shelfNoticeTask = nil
        }
    }

    // MARK: - Colour picker

    /// The header's dropper (2026-10-24): close the panel, show the loupe,
    /// and bring the panel back on the tab it was on.
    ///
    /// **Closed first** so the whole screen can be sampled, the band under
    /// the open panel included -- and so the cursor leaving for the loupe
    /// does not race the 400ms dismiss grace into closing it anyway.
    ///
    /// **Reopened as ambient** (`.unspecified`, which `PanelFocus` never makes
    /// key): the person has just clicked in another app's window, and the
    /// confirmation must not take their keystrokes. A cancelled pick reopens
    /// too, so Esc puts things back as they were. A pick dropped by switching
    /// the module off mid-loupe reopens nothing (`ColorPickerController`).
    func pickColor() {
        guard state.preferences.colorPicker, let colorPicker else { return }
        let returnTab: CreativeNotchCore.Tab? = {
            if case .open(let tab) = state.state { return tab }
            return nil
        }()
        let started = colorPicker.pick { [weak self] color in
            guard let self else { return }
            if let returnTab, !self.isHiddenForFullScreen {
                let visible = TabVisibility.visible(enabled: self.state.preferences, hasBattery: self.state.hasBattery)
                if visible.contains(returnTab) {
                    self.state.transition(to: .open(returnTab))
                } else {
                    self.openPanel(openedBy: .unspecified)
                }
            }
            guard let color else { return }
            self.showPickedColor(color)
        }
        // After asking: an inert or instant sampler finishes inside `pick`,
        // and closing then would undo the reopen it just made.
        if started, colorPicker.isSampling { state.transition(to: .closed) }
    }

    /// A swatch's click: the same copy a pick ends with, shown the same way.
    func copyColor(_ color: SampledColor) {
        guard state.preferences.colorPicker, let colorPicker else { return }
        colorPicker.copy(color)
        showPickedColor(color)
    }

    /// Puts the strip up -- only on an open panel, since leaving `.open`
    /// clears it -- and says what was copied, for someone who cannot see it.
    private func showPickedColor(_ color: SampledColor) {
        if case .open = state.state { state.pickedColor = color }
        announce(String(localized: "Copied \(ColorName.spoken(color, as: state.colorFormat))", bundle: .creativeNotch))
    }

    /// "Copy as" in Settings: saved, then applied to the next copy and the
    /// strip's text. What is already on the pasteboard is left alone.
    func setColorFormat(_ format: ColorFormat) {
        preferencesStore.setColorFormat(format)
        colorPicker?.format = format
        state.colorFormat = format
    }

    /// The strip belongs to the opening it was shown in: a tab switch keeps
    /// it, anything that leaves `.open` takes it away. No timer.
    func syncColorStrip(for next: NotchState) {
        if case .open = next { return }
        state.pickedColor = nil
    }

    // MARK: - Dismissal

    /// How long an open panel survives the cursor leaving it.
    ///
    /// Without a grace period, brushing a pixel past the edge snaps the
    /// panel shut, which reads as a glitch rather than as intent. The
    /// mirror image of the 300ms hover dwell.
    public static let defaultDismissGrace: Duration = .milliseconds(400)

    /// Overridable so tests can await it instead of waiting 400ms each.
    var dismissGrace: Duration = AppDelegate.defaultDismissGrace

    /// Exposed so tests can await the real work instead of sleeping and
    /// hoping. Sleeping raced the scheduler: the tests passed locally and
    /// failed on a loaded CI runner, which is the worst kind of test.
    private(set) var graceTask: Task<Void, Never>?

    /// Installs a monitor calling `handler` when a mouse-down lands in
    /// another application; returns a token for removal.
    ///
    /// Injected rather than called directly so the install/remove
    /// lifecycle is assertable without a real global monitor -- and so a
    /// test can fire a synthetic outside click.
    var installOutsideClickMonitor: (@escaping () -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in handler() }
    }

    var removeOutsideClickMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    private var outsideClickToken: Any?

    // MARK: - Growth lag (F6)

    /// How long the drawn shape takes to expand.
    ///
    /// The panel animates open over roughly this long while the derived
    /// rects used to snap to full size instantly, so for that window the
    /// app accepted clicks on a region that was not visibly there yet --
    /// the same "swallows clicks you cannot see" failure the hit test
    /// exists to prevent, just briefly.
    ///
    /// Follows `NotchMotion.openResponse`, the spring that grows the shape.
    public static let defaultGrowthDelay: Duration = .milliseconds(Int(NotchMotion.openResponse * 1000))

    /// Overridable so tests need not wait out a real animation.
    var growthDelay: Duration = AppDelegate.defaultGrowthDelay

    private(set) var growthTask: Task<Void, Never>?

    /// The region currently *accepted* for hit testing and hover, which
    /// lags `visibleRect()` while the shape is growing and matches it
    /// immediately when shrinking.
    ///
    /// The invariant: the accepted region is never larger than what is
    /// drawn. Shrinking early is safe -- clicks fall through a panel that
    /// is still visibly collapsing, which is harmless. Growing early is
    /// not.
    private(set) var acceptedRect: CGRect = .zero

    /// Whether the outside-click monitor is currently installed. Nothing
    /// should be running while the notch is idle.
    var isWatchingForOutsideClicks: Bool { outsideClickToken != nil }

    public override init() {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotch-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "com.gcdz.creativenotch.sandbox.\(UUID().uuidString)"
        sandboxSuiteName = suiteName
        preferencesDefaults = UserDefaults(suiteName: suiteName)!
        shelfDirectory = sandbox.appendingPathComponent("Shelf", isDirectory: true)
        shelfTrash = .folder(sandbox.appendingPathComponent("Trash", isDirectory: true))
        capturesDirectory = sandbox.appendingPathComponent("Captures", isDirectory: true)
        downloadsDirectory = sandbox.appendingPathComponent("Downloads", isDirectory: true)
        updatesSandbox = sandbox.appendingPathComponent("Updates", isDirectory: true)
        super.init()
    }

    /// The sandbox suite `preferencesDefaults` starts as, dropped again when
    /// the delegate goes: a test run builds hundreds of delegates, and each
    /// would otherwise leave an empty domain behind. Harmless after
    /// `configureForRealLaunch()`, which never wrote to it.
    private let sandboxSuiteName: String

    deinit {
        UserDefaults().removePersistentDomain(forName: sandboxSuiteName)
    }

    // MARK: - Real-world locations

    /// The shelf's real storage, `~/Library/Application Support/CreativeNotch/Shelf`.
    static let realShelfDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CreativeNotch/Shelf")

    /// Points every seam that reaches the user's own data at the real thing:
    /// the preferences domain, the shelf's folder, the Trash, and the
    /// captures folder.
    ///
    /// **Why the defaults are sandboxed instead.** Each of these seams once
    /// defaulted to the real location, and staying off it was something every
    /// test had to remember: a suite that built an `AppDelegate()` and forgot
    /// one opened the user's real shelf at `install(metrics:)` and ran its
    /// launch purge into the user's real Trash. Now a fresh delegate reaches
    /// nothing outside a temporary folder and a private defaults suite, and
    /// the real app opts in here, once, before anything is built --
    /// `applicationDidFinishLaunching` calls this first, and nothing else
    /// does. A new seam of this kind belongs in this method, with a sandboxed
    /// default.
    func configureForRealLaunch() {
        preferencesDefaults = .standard
        shelfDirectory = Self.realShelfDirectory
        shelfTrash = .system
        capturesDirectory = CameraController.picturesCapturesDirectory
        calendarSource = EventKitCalendarSource()
        openExternalURL = { url in NSWorkspace.shared.open(url) }
        shelfOpener = .system
        shelfPreview = ShelfQuickLook()
        timerNotices = SystemTimerNotices()
        colorSampler = SystemColorSampler()
        colorPasteboard = .general
        // Building these registers nothing and asks for nothing: the source
        // registers on `start()`, the access prompts on `request`, and both
        // happen only once Bluetooth alerts are switched on.
        bluetoothSource = IOBluetoothSource()
        bluetoothAccess = SystemBluetoothAccess()
        // Building it asks for nothing: the prompt is `requestTrust()`, and
        // only switching "Keep clear of app menus" on calls it.
        appMenuReader = SystemAppMenuReader()
        // Asks for nothing: it watches only once Accessibility is allowed,
        // which "Keep clear of app menus" is what asks for.
        windowFocusWatcher = SystemWindowFocusWatcher()
        // Puts nothing on screen of its own: it animates the panel window,
        // and only when the panel moves to another display.
        panelFader = AnimatedPanelFader()
        // Likewise: it moves the panel window, only while the pill moves
        // along its menu bar.
        panelSlider = AnimatedPanelSlider()
        // One block on the main queue when the anchor changes on its
        // display, and nothing otherwise.
        panelMorpher = AnimatedPanelMorpher()
        openBluetoothSettings = { NSWorkspace.shared.open(SystemBluetoothAccess.settingsURL) }
        downloadsDirectory = Self.realDownloadsDirectory
        revealInFinder = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        openDownloadsPrivacySettings = {
            guard let url = AppDelegate.filesAndFoldersSettings else { return }
            NSWorkspace.shared.open(url)
        }
        // Building these fetches nothing: the first request is the launch
        // check, after the subsystems start. The domain is set second, so
        // the real record is read against the real version.
        updates.environment = .system()
        updates.defaults = .standard
    }

    /// The user's Downloads folder, resolved by `FileManager` rather than
    /// spelled as a path, so a relocated home folder is followed.
    static var realDownloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// System Settings, Privacy & Security, Files & Folders.
    static let filesAndFoldersSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads a preference or builds the shelf: every
        // real-world seam defaults to a sandbox until this runs.
        configureForRealLaunch()

        // With no screen at all, the screen-parameter observer builds the
        // panel when one appears (`screenParametersDidChange`). The choice is
        // read before `install` exists to load it, because it decides which
        // screen `install` is handed.
        state.displayChoice = PreferencesStore(defaults: preferencesDefaults).displayChoice
        if let metrics = screenMetrics(state.displayChoice) {
            showPanel(on: metrics)
        }

        let menuBar = MenuBarController(
            onShowPreferences: { [weak self] in self?.showPreferences() },
            onClearShelf: { [weak self] in self?.clearShelf() },
            shelfCount: { [weak self] in self?.menuShelfCount ?? 0 },
            onClearClipboard: { [weak self] in self?.clipboard?.store.clear() },
            clipboardCount: { [weak self] in self?.menuClipboardCount ?? 0 },
            onUndoClearShelf: { [weak self] in self?.undoClearShelf() },
            canUndoClearShelf: { [weak self] in self?.state.canUndoShelfClear ?? false },
            onShowWelcome: { [weak self] in self?.showWelcomeAgain() },
            onCheckForUpdates: { [weak self] in self?.checkForUpdatesFromMenu() },
            availableUpdate: { [weak self] in self?.menuAvailableUpdate },
            onUpdate: { [weak self] in self?.showUpdatesInSettings() }
        )
        menuBar.install()
        self.menuBar = menuBar

        // Observing is a lifecycle concern, not part of building the
        // panel: registering it from inside `install` meant it could be
        // registered more than once and never at a point where the tokens
        // had an owner.
        observeScreenChanges()

        startSubsystems()
        checkForUpdatesAtLaunch()
    }

    /// The metrics of the screen "Show on" picks, or `nil` with no screen.
    ///
    /// The launch, a screen change and the preference itself all ask here, so the choice is made in one place. `NSScreen.main` is
    /// the screen holding the key window, and an accessory app launching may
    /// have none -- the panel was once never built, for the whole session --
    /// so the rule falls back to any screen (`DisplayChoice.screen(in:)`).
    /// Injected so a test can answer it without a real display.
    var screenMetrics: (DisplayChoice) -> ScreenMetrics? = { choice in
        NSScreen.chosen(by: choice)?.metrics
    }

    /// The metrics of the screen a change of focus moves the panel to, or
    /// `nil` to leave it where it is (`DisplayChoice.screenOnFocusChange`).
    /// Separate from `screenMetrics` because an app with no window is no
    /// news about focus and must not fall back to the first screen the way
    /// the launch does. Injected for the same reason.
    var focusScreenMetrics: (DisplayChoice) -> ScreenMetrics? = { choice in
        NSScreen.chosenOnFocusChange(by: choice)?.metrics
    }

    /// Hears focus move inside the frontmost app -- between two of its
    /// windows, or a window moved -- where no app switch says so
    /// (2026-10-27). A sandbox that never watches until
    /// `configureForRealLaunch()`, so no test registers with a real app.
    var windowFocusWatcher: WindowFocusWatcher = SandboxWindowFocusWatcher()

    /// The frontmost app at launch, before any switch has said which it is.
    /// Injected so a test can name one.
    var frontmostApplicationPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// The app whose windows focus is followed through: the last to come
    /// forward, or `nil` while this app is in front -- its own Settings
    /// window is not one to follow.
    private var focusedAppPID: pid_t?

    /// How long after a change of focus it is looked at once more.
    ///
    /// An app brought forward by a click on one of its windows can be
    /// announced before that window is raised: once, on a three-display desk,
    /// the window list still had the app's previous window in front when
    /// `didActivateApplication` arrived, and the clicked one half a second
    /// later (2026-10-26). The second look catches that. It also gathers a
    /// drag: `AXWindowMoved` arrives many times a second while a window is
    /// dragged, and is read once now and once more when this has passed.
    public static let defaultFocusSettleDelay: Duration = .milliseconds(300)

    /// Overridable so tests can await it instead of waiting.
    var focusSettleDelay: Duration = AppDelegate.defaultFocusSettleDelay

    /// The second look, while one is due. Exposed so tests can await it, as
    /// `graceTask` is. A one-shot after a change the user made, like the
    /// dismiss grace: nothing is scheduled while focus stays where it is.
    private(set) var focusSettleTask: Task<Void, Never>?

    /// The connected displays, for the "Show on" menu. Injected so a test
    /// can plug and unplug displays without a real one.
    var screenDescriptors: () -> [ScreenDescriptor] = { NSScreen.descriptors }

    /// Re-reads the displays the "Show on" menu offers. Asked when Settings
    /// is shown and on every screen-parameter change -- the two moments the
    /// list can be stale while someone is looking at it -- so nothing polls.
    ///
    /// A pinned display connected under a new name has the stored name
    /// updated and saved here too (`DisplayChoice.refreshingName`), so the
    /// next time it is unplugged Settings names it by what it is called
    /// now. Saved without placing the panel again: the UUID is unchanged,
    /// so the display it picks is the same one.
    func refreshConnectedDisplays() {
        let screens = screenDescriptors()
        state.connectedDisplays = screens
        let refreshed = state.displayChoice.refreshingName(from: screens)
        if refreshed != state.displayChoice {
            preferencesStore.setDisplayChoice(refreshed)
            state.displayChoice = refreshed
        }
    }

    /// Builds and presents the panel. `nil` means the real thing,
    /// `buildAndPresentPanel(metrics:)`; a test hands in a spy, because the
    /// real one puts a window on screen and hosts it in a Space.
    var presentPanel: ((ScreenMetrics) -> Void)?

    private func showPanel(on metrics: ScreenMetrics) {
        if let presentPanel { presentPanel(metrics) } else { buildAndPresentPanel(metrics: metrics) }
    }

    private func buildAndPresentPanel(metrics: ScreenMetrics) {
        install(metrics: metrics)
        // Presentation is deliberately *not* part of `install` -- that
        // keeps the wiring path testable without putting a window on
        // screen.
        panel?.orderFrontRegardless()
        // After ordering front, so the panel has a window number. Only
        // here, never in `install`: tests build the delegate through
        // `install`, and must not create Spaces in the session running
        // them.
        hostPanelInFixedSpace()
        watchForFullScreen()
    }

    /// The actions the timer tab can take: the four countdown verbs and the
    /// stopwatch's one.
    ///
    /// Extracted so the switchboard can nil them when the timer is switched
    /// off and restore them when it comes back. `onChange` and `onFinished`
    /// are deliberately not among them: they are the publish and finish paths
    /// of a countdown that is allowed to outlive the toggle.
    ///
    /// Starting one closes the add picker: it exists to start one, and left
    /// up it would offer another the cap may refuse.
    func wireTimerActions() {
        state.onStartTimer = { [weak self, weak timer, weak state] duration in
            timer?.start(duration: duration)
            state?.isAddingTimer = false
            self?.prepareTimerNotices()
        }
        state.onPauseTimer = { [weak timer] id in timer?.pause(id: id) }
        state.onResumeTimer = { [weak timer] id in timer?.resume(id: id) }
        state.onCancelTimer = { [weak timer] id in timer?.cancel(id: id) }
        state.onStopwatch = { [weak self] command in self?.applyStopwatch(command) }
    }

    /// The stopwatch is a value in `AppState`, moved at the delegate's
    /// injected clock. Nothing is scheduled here, ever: the running digits
    /// are a `Text(timerInterval:)` counting from `Stopwatch.anchor`.
    func applyStopwatch(_ command: StopwatchCommand) {
        state.stopwatch = state.stopwatch.applying(command, at: Date(timeIntervalSince1970: now()))
    }

    /// A countdown just started: the moment to ask for notification
    /// permission, if the setting wants it and macOS has never been asked.
    /// The seam decides "never asked"; see `TimerDoneNotice
    /// .shouldRequestAuthorization` for why here and not at launch or at the
    /// finish.
    private func prepareTimerNotices() {
        guard state.timerNotifyWhenHidden else { return }
        timerNotices.prepare()
    }

    /// Reads what macOS allows the timer's notification into `AppState`, for
    /// the line under the Settings switch. Asked when Settings is shown.
    func refreshTimerNoticeAuthorization() async {
        state.timerNoticeAuthorization = await timerNotices.authorization()
    }

    /// Whether a peek put in the slot now would be seen: there is a panel,
    /// and it is not ordered out for a full-screen app.
    var isNotchOnScreen: Bool { panel != nil && !isHiddenForFullScreen }

    /// Tells the camera whether its tab is on screen.
    ///
    /// The one input the controller cannot work out for itself, and the reason
    /// it goes through the funnel rather than being read by the view: a view
    /// that started the camera on appear would also have to stop it on
    /// disappear, and SwiftUI gives no guarantee about when that runs. `pkill`
    /// -- which this repo's own dev.sh and install.sh both use -- runs no
    /// AppKit handler at all.
    ///
    /// Note what this does NOT do: stop a recording. `CameraRunReason` decides
    /// that, and a clip in progress keeps the session alive with the badge
    /// showing. Leaving the tab is not a request to discard a take.
    func syncCameraVisibility(for next: NotchState) {
        camera?.setTabVisible(next == .open(.camera))
    }

    /// Tells the calendar whether its pane is on screen, from the funnel for
    /// the camera's reason: the view is not told when it disappears. Opening
    /// the pane is what reads the calendar, and leaving it cancels the
    /// one-shot that would have read it again -- so nothing about the
    /// calendar runs while the pane is closed.
    func syncCalendarVisibility(for next: NotchState) {
        calendar?.setPaneVisible(next == .open(.calendar))
    }

    /// Re-derives everything that depends on which modules are on.
    ///
    /// The switchboard reaches AppKit through the per-module verbs and this
    /// one method, and nothing else. It pairs the two verbs that
    /// `nowPlayingDidChange` already pairs — which is why that method is the
    /// only disable path in the tree that has ever worked correctly.
    ///
    /// Both are needed. Stopping a subsystem does not by itself remove what it
    /// put on screen: without `syncTrackingRect()` a badge that has just gone
    /// leaves the closed notch's hit-test region widened for the rest of the
    /// session, and without `reevaluatePeek()` a peek withdrawn from the
    /// arbiter stays on screen until something else happens to ask.
    func modulesDidChange() {
        syncTrackingRect()
        reevaluatePeek()
    }

    /// Everything that starts a subsystem, in one place.
    ///
    /// Split out of `applicationDidFinishLaunching` because that method is not
    /// drivable from a test: it reads `NSScreen.main`, installs a real status
    /// item.
    /// `grep applicationDidFinishLaunching Tests/` returns nothing, and never
    /// did. Behaviour that only ever ran there was behaviour nothing could
    /// assert — which is precisely where a preference that applies on change
    /// but not at launch would hide.
    ///
    /// The launch path must reach subsystems only through here. Nothing in the
    /// suite can prove that behaviourally, so a source scan does it instead:
    /// `theLaunchPathStartsSubsystemsOnlyThroughTheOneMethod`.
    func startSubsystems() {
        activity.start()
        switchboard.apply()
    }

    /// The launch's update check, after the subsystems are up so a slow
    /// reply never holds the notch back. Not in `startSubsystems()`: the
    /// updater is not a subsystem, owns nothing that runs, and is not the
    /// switchboard's to start or stop.
    func checkForUpdatesAtLaunch() {
        updates.check(.launch)
    }

    /// The menu's "Check for Updates…": now, past the toggle and the daily
    /// throttle, with Settings opened on the Updates section — the one place
    /// that says what the check found, failure included.
    func checkForUpdatesFromMenu() {
        updates.check(.manual)
        showUpdatesInSettings()
    }

    /// The menu's "Update to v…": Settings, on the Updates section, where
    /// "Update Now" and the release notes are. Not the install itself — an
    /// update that quits the app deserves the one more click.
    func showUpdatesInSettings() {
        if let presentPreferences { presentPreferences(.updates) } else { showPreferences(highlighting: .updates) }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        fullScreenWatcher?.stop()
        fullScreenWatcher = nil
        fixedSpace?.tearDown()
        fixedSpace = nil
        removeScreenObservers()
        windowFocusWatcher.stop()
        focusSettleTask?.cancel()
        focusSettleTask = nil
        switchboard.stopAll()
        activity.stop()
        updates.stop()
    }

    /// What the hotkey does: open the panel, or close it if it is already
    /// open.
    ///
    /// A toggle rather than open-only, because the combination is the one way
    /// to reach the panel from another app -- and a key that opens but cannot
    /// close is a key you press and then reach for the mouse.
    func toggleFromHotKey() {
        if case .open = state.state {
            state.transition(to: .closed)
            return
        }
        openPanel(openedBy: .hotKey)
    }

    /// Opens the panel on the last tab, or the first visible one if that tab
    /// has been switched off. Returns `false`, and changes nothing, when no
    /// tab is visible: there is no empty panel to open.
    ///
    /// The one way the delegate opens the panel — the shortcut, a swipe,
    /// open-on-hover and the notch tap all come through here.
    ///
    /// Also `false` while the panel is hidden for a full-screen app: there
    /// is no window on screen to open.
    ///
    /// `reason` is required, not defaulted, so every route has to say whether
    /// it was asked for. The answer decides whether the open takes the
    /// keyboard (`PanelFocus`), and a default would quietly decide it for a
    /// route added later.
    ///
    /// `avoided` is a tab to open on only when it is the sole visible one —
    /// "Show Welcome Again" passes `.camera`, where the card never shows.
    @discardableResult
    func openPanel(openedBy reason: PanelOpenReason, avoiding avoided: CreativeNotchCore.Tab? = nil) -> Bool {
        guard !isHiddenForFullScreen else { return false }
        let visible = TabVisibility.visible(
            enabled: state.preferences,
            hasBattery: state.hasBattery
        )
        guard !visible.isEmpty else { return false }
        let preferred = visible.filter { $0 != avoided }
        let pool = preferred.isEmpty ? visible : preferred
        state.transition(to: .open(pool.contains(state.lastOpenTab)
                                  ? state.lastOpenTab
                                  : pool[0]),
                         openedBy: reason)
        return true
    }

    /// The settings surface, built on first use.
    ///
    /// Lazily rather than in `install(metrics:)` because building a panel must
    /// not build a window, and because the fourteen suites that call `install`
    /// have no use for one.
    public func showPreferences() {
        showPreferences(highlighting: nil)
    }

    /// The same, scrolled to `section` with its rows briefly highlighted —
    /// how the welcome card's "Set Shortcut…" lands on the recorder.
    func showPreferences(highlighting section: PreferencesSection?) {
        if preferences == nil {
            preferences = PreferencesController(
                switchboard: switchboard,
                state: state,
                launchAtLogin: launchAtLogin,
                updates: updates
            )
        }
        preferences?.show(highlighting: section)
    }

    /// The menu's "Show Welcome Again": clears the flag and opens the panel,
    /// so the card is there to read rather than waiting for the next open.
    /// Through `openPanel(openedBy:)`, so it declines like every other opener
    /// when no tab is visible — the flag stays cleared for when one is. A
    /// menu click is asked for, so it opens as `.tap` does and takes the
    /// keyboard: Esc dismisses the card like any explicit open.
    ///
    /// Not onto the camera tab, where the card never shows
    /// (`WelcomeCard.isShown`): opening there would start the camera and show
    /// no welcome. Only when the camera is the one tab left does it open
    /// there, card-less, with the flag still cleared.
    func showWelcomeAgain() {
        state.setWelcomeSeen(false)
        openPanel(openedBy: .tap, avoiding: .camera)
    }

    /// Closes the panel, then opens Settings. Settings is an activating
    /// window, and the panel should not sit open under it.
    private func openSettingsFromPanel(highlighting section: PreferencesSection?) {
        state.transition(to: .closed)
        if let presentPreferences { presentPreferences(section) } else { showPreferences(highlighting: section) }
    }

    // MARK: - Installation

    /// Builds the panel, the SwiftUI host, and the hover tracker, wires
    /// the state funnel, and positions everything for `metrics`.
    ///
    /// Takes `ScreenMetrics` rather than an `NSScreen` so the whole path
    /// is drivable from a test with no real display attached.
    func install(metrics: ScreenMetrics) {
        // Text size (2026-10-24) is read first, because it decides how large
        // the window is built: built at the default and grown afterwards, the
        // first frame would be the wrong size.
        state.textSize = PreferencesStore(defaults: preferencesDefaults).textSize
        // The layout options (2026-10-24) likewise: the width decides the
        // window's size, and the badges the closed shape the accepted region
        // is seeded from below.
        state.layoutOptions = PreferencesStore(defaults: preferencesDefaults).loadLayout()
        let size = panelFrame(on: metrics).size

        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: size))
        panel.onPanelKey = { [weak self] key in self?.handlePanelKey(key) ?? false }
        panel.quickLook = shelfPreview as? ShelfQuickLook

        let host = HitTestingHostingView(rootView: NotchRootView(app: state))
        host.visibleRectProvider = { [weak self] in self?.acceptedRect ?? .zero }
        host.onScroll = { [weak self] event in
            self?.handleScroll(ScrollSample(event)) ?? false
        }

        let hover = HoverTracker(frame: CGRect(origin: .zero, size: size))
        hover.autoresizingMask = [.width, .height]
        hover.onEnter = { [weak self] in
            self?.state.isHovering = true
            self?.cancelDismissGrace()
        }
        hover.onDwell = { [weak self] in self?.peek() }
        hover.dwellDuration = { [weak self] in
            self?.state.hoverBehaviour.dwell ?? HoverBehaviour.peekDwell
        }
        hover.onExit  = { [weak self] in
            self?.state.isHovering = false
            self?.collapse()
        }
        // The tracker re-reads the pointer when its rect is replaced, and
        // reads it from here — panel-local, as `keepOpenIfPointerInside`
        // computes it — so there is one pointer source and a test that
        // places it places it for both.
        hover.pointerLocation = { [weak self] in
            guard let self else { return nil }
            return self.panelLocal(self.pointerLocation())
        }

        let container = PassthroughContainer(frame: CGRect(origin: .zero, size: size))

        // Purged on launch and after each add — never on a timer.
        preferencesStore = PreferencesStore(defaults: preferencesDefaults)

        // Constructed here, started by the switchboard. Building a panel must
        // not register system-wide property listeners.
        let capture = CaptureController()
        capture.onChange = { [weak self] use in
            self?.state.captureUse = use
            self?.syncTrackingRect()
        }
        self.capture = capture

        // Constructed here, started by the switchboard. Building a panel must
        // not open a camera -- and `install(metrics:)` runs in fourteen test
        // suites, none of which has an Info.plist usage description.
        // The shelf is read through `self`, not passed: it is not built until
        // further down, and handing over the `nil` it is here meant every
        // capture was saved and never listed. Reading late also follows a
        // shelf rebuilt later, the same as the title-row verbs below.
        let camera = CameraController(shelf: { [weak self] in self?.shelf })
        camera.capturesDirectory = capturesDirectory
        camera.onStateChange = { [weak self] next in
            self?.state.cameraState = next
            if case .recording = next {
                self?.state.isRecordingClip = true
            } else {
                self?.state.isRecordingClip = false
            }
            self?.syncTrackingRect()
        }
        // Our own preview must not light the indicator that reports somebody
        // else's capture.
        camera.onHeldCameraChange = { [weak capture] uid in capture?.setOwnCamera(uid) }
        self.camera = camera
        state.cameraState = camera.state
        state.onCameraShutter = { [weak camera] in camera?.takePhoto() }
        state.onCameraToggleRecording = { [weak camera] in camera?.toggleRecording() }

        // Constructed here, started by the switchboard. Building a panel must
        // not open the calendar database, and a bare delegate's source is the
        // inert stand-in anyway (`calendarSource`).
        let calendar = CalendarController(source: calendarSource)
        calendar.onChange = { [weak self] snapshot in self?.state.calendar = snapshot }
        self.calendar = calendar
        state.onRequestCalendarAccess = { [weak calendar] in calendar?.requestAccess() }
        state.onRefreshCalendarAccess = { [weak calendar] in calendar?.refreshAccess() }
        state.onOpenCalendarPrivacySettings = { [weak self] in
            self?.openExternalURL(Self.calendarPrivacyURL)
        }
        state.onOpenCalendarApp = { [weak self] in
            self?.openExternalURL(Self.calendarAppURL)
        }

        // Constructed here, started by the switchboard. Building a panel must
        // not register a system-wide hotkey.
        let hotkey = HotKeyController(store: HotKeyStore(defaults: preferencesDefaults))
        hotkey.onTrigger = { [weak self] in self?.toggleFromHotKey() }
        self.hotkey = hotkey

        // Constructed here, started by the switchboard -- and only when the
        // module is switched on, since it ships off. Building a panel must
        // not read the Downloads folder: that read is a privacy prompt.
        let downloads = DownloadsController(
            folder: downloadsDirectory,
            source: makeDownloadSource(),
            probeAccess: probeDownloadsAccess
        )
        downloads.onSummary = { [weak self] summary in self?.downloadsDidChange(summary) }
        downloads.onCompleted = { [weak self] completion in self?.downloadDidComplete(completion) }
        downloads.onAccess = { [weak self] access in self?.state.downloadsAccess = access }
        self.downloads = downloads
        state.onRevealDownload = { [weak self] completion in self?.revealDownload(completion) }
        state.onRecheckDownloadsAccess = { [weak self] in self?.downloads?.recheckAccess() }
        state.onOpenDownloadsPrivacy = { [weak self] in self?.openDownloadsPrivacySettings() }

        // The limits chosen in Settings (2026-10-24), loaded before the
        // stores are built so the launch purge runs against the chosen age:
        // purging against the default would trash files a "30 days" shelf
        // was promised to keep.
        let limits = preferencesStore.loadLimits()
        state.limits = limits

        shelf = try? ShelfStore(
            directory: shelfDirectory,
            capacity: limits.shelfCapacity,
            maxAge: limits.shelfExpiry.maxAge,
            copier: shelfCopier,
            trash: shelfTrash
        )
        shelf?.onCopyFailed = { [weak self] item, error in
            self?.reportShelfCopyFailure(item, error)
        }
        _ = try? shelf?.purge(now: Date())
        state.shelf = shelf

        // The ring is created here rather than at launch so the wiring
        // path is testable without putting a window on screen, exactly as
        // the shelf is. Starting the poller stays in
        // `applicationDidFinishLaunching` — building a panel must not
        // install a timer.
        let clipboardStore = ClipboardStore(capacity: limits.clipboardCapacity)
        let clipboard = ClipboardController(store: clipboardStore)
        state.clipboard = clipboardStore
        state.onCopyClipboard = { [weak clipboard] entry in clipboard?.copy(entry) }
        self.clipboard = clipboard

        // The pane's title-row verbs reach the verbs that already exist —
        // the same `clear()` the menu bar items call. Read through `self`
        // rather than captured, so a shelf rebuilt later is the one cleared.
        state.onClearShelf = { [weak self] in self?.clearShelf() }
        state.onUndoClearShelf = { [weak self] in self?.undoClearShelf() }
        state.onRemoveShelfItem = { [weak self] id in try? self?.shelf?.remove(id) }
        state.onAirDropShelfItems = { urls in ShelfAirDrop.send(urls, via: ShelfAirDrop.airDrop) }
        state.onRevealShelfItem = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        state.onOpenShelfItem = { [weak self] id in self?.openShelfItem(id) }
        state.onQuickLookShelfItem = { [weak self] id in self?.quickLookShelfItem(id) }

        // Open on hover (2026-10-17). Loaded here, saved and applied together
        // by the verb, like the shortcut's store.
        let hoverStore = HoverBehaviourStore(defaults: preferencesDefaults)
        state.hoverBehaviour = hoverStore.load()
        state.onSetHoverBehaviour = { [weak self] behaviour in
            hoverStore.save(behaviour)
            self?.state.hoverBehaviour = behaviour
        }

        // Show on (2026-10-24). Loaded like the hover behaviour, and applied
        // at once: waiting for the next activation would never come when
        // pinned, which is the point of pinning.
        state.displayChoice = preferencesStore.displayChoice
        state.onSetDisplayChoice = { [weak self] choice in
            self?.setDisplayChoice(choice)
        }
        state.onRefreshDisplays = { [weak self] in self?.refreshConnectedDisplays() }

        // Keep clear of app menus (2026-10-26). Loaded like "Show on", and
        // applied at once: the pill moves, or comes back to the centre.
        state.pillClearsMenus = preferencesStore.pillClearsMenus
        state.accessibilityTrusted = appMenuReader.isTrusted
        state.onSetPillClearsMenus = { [weak self] enabled in self?.setPillClearsMenus(enabled) }
        state.onRefreshAccessibility = { [weak self] in
            guard let self else { return }
            self.state.accessibilityTrusted = self.appMenuReader.isTrusted
        }
        state.onOpenAccessibilitySettings = { [weak self] in
            self?.openExternalURL(SystemAppMenuReader.settingsURL)
        }

        // Text size (2026-10-24). Loaded at the top of `install`, which sized
        // the window by it; applied at once, like "Show on".
        state.onSetTextSize = { [weak self] size in self?.setTextSize(size) }

        // Layout (2026-10-24). Loaded at the top of `install` with the text
        // size; applied at once, like it.
        state.onSetLayoutOptions = { [weak self] options in self?.setLayoutOptions(options) }

        // The timer's notification switch and clipboard history's excluded
        // apps (2026-10-24). Loaded like the hover behaviour, saved and
        // applied together by the verb. Neither has anything to restart:
        // both are read at the moment they matter -- a timer finishing, a
        // copy detected -- so a change applies to the next one.
        state.timerNotifyWhenHidden = preferencesStore.timerNotifyWhenHidden
        state.onSetTimerNotifyWhenHidden = { [weak self] enabled in
            guard let self else { return }
            self.preferencesStore.setTimerNotifyWhenHidden(enabled)
            self.state.timerNotifyWhenHidden = enabled
            // Switched on mid-countdown: ask now, while the user is at the
            // desktop, rather than leave the finish with no permission.
            if enabled, self.state.countdown != nil { self.timerNotices.prepare() }
        }
        state.onRefreshTimerNotices = { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshTimerNoticeAuthorization() }
        }
        state.clipboardExcludedApps = preferencesStore.clipboardExcludedApps
        state.onSetClipboardExcludedApps = { [weak self] ids in
            guard let self else { return }
            self.preferencesStore.setClipboardExcludedApps(ids)
            self.state.clipboardExcludedApps = ids
        }
        clipboard.poller.excludedApps = { [weak self] in self?.state.clipboardExcludedApps ?? [] }

        state.onSetLimits = { [weak self] limits in self?.applyLimits(limits) }
        state.onPreviewLimits = { [weak self] limits in
            self?.previewLimits(limits) ?? ShelfLimitRemoval(items: [])
        }
        // The colour picker (2026-10-24). Built here, like the clipboard
        // ring, and it starts nothing: the sampler exists only while a pick
        // is in progress. The format is loaded, not cached, like the text
        // size.
        let colorPicker = ColorPickerController(sampler: colorSampler, pasteboard: colorPasteboard)
        colorPicker.format = preferencesStore.colorFormat
        colorPicker.onChange = { [weak self] history in
            self?.state.recentColors = history.colors
            // A colour the history no longer holds -- all of them, when the
            // module is switched off -- is not one the strip may still show.
            if let picked = self?.state.pickedColor, !history.colors.contains(picked) {
                self?.state.pickedColor = nil
            }
        }
        self.colorPicker = colorPicker
        state.colorFormat = colorPicker.format
        state.onPickColor = { [weak self] in self?.pickColor() }
        state.onCopyColor = { [weak self] color in self?.copyColor(color) }
        state.onSetColorFormat = { [weak self] format in self?.setColorFormat(format) }

        state.onClearClipboard = { [weak self] in self?.clipboard?.store.clear() }
        state.onRemoveClipboardEntry = { [weak self] id in self?.clipboard?.store.remove(id) }
        state.onTogglePinClipboardEntry = { [weak self] id in self?.togglePin(id) }
        state.onOpenPanel = { [weak self] in self?.openPanel(openedBy: .tap) }
        state.onOpenSettings = { [weak self] in
            self?.openSettingsFromPanel(highlighting: nil)
        }

        // The welcome card (2026-10-24). Loaded, not cached, like the hover
        // behaviour above: a relaunch reads the flag back from the domain.
        state.welcomeSeen = preferencesStore.hasSeenWelcome
        state.onPersistWelcomeSeen = { [weak self] seen in
            self?.preferencesStore.setHasSeenWelcome(seen)
        }
        state.onWelcomeSetShortcut = { [weak self] in
            self?.state.setWelcomeSeen(true)
            self?.openSettingsFromPanel(highlighting: .shortcut)
        }

        // Spec section 4.7: the sleep/lock gate is enforced once, here, and
        // fanned out to every consumer — never registered a second time
        // inside a module. Adding a second consumer later is a one-line
        // addition to this closure, not a second observer.
        // The promised one-line addition, wearing a name. Still ONE
        // registration: `SystemActivityFanOutTests` asserts exactly four
        // notification tokens and one observer, and the switchboard adds
        // neither.
        //
        // The per-module reasoning — why the timer is never suspended, why
        // power keeps observing, which modules belong on this axis at all —
        // moved with the code, to `ModuleSwitchboard.setActivity`. It does not
        // survive being split from what it explains.
        activity.onChange = { [weak self] state in
            self?.switchboard.setActivity(state)
            // Coming back to the Mac — a wake, an unlock — is a moment the
            // app is awake anyway, so it is when the updater looks, at most
            // once a day (`UpdateCheckPolicy`). Here rather than on the
            // switchboard: the updater is not a module and runs nothing a
            // lock would need to stop.
            if state == .active { self?.updates.check(.wake) }
        }

        // Publishes into `AppState` for the panel header and feeds the
        // peek arbiter so hovering the closed notch shows what is
        // playing. Starting and stopping the controller stays in
        // `applicationDidFinishLaunching` / `applicationWillTerminate` —
        // building the wiring here must not spawn the helper.
        let media = MediaController()
        // `[weak self]` matters: `media` holds this closure, and the work
        // it does reaches back through `self` for the artwork — a strong
        // capture would be a controller keeping its owner alive, the same
        // reason `onCopyClipboard` above captures its controller weakly.
        // The body is a method rather than a closure so a test can drive
        // the real publish path without a running helper.
        media.onChange = { [weak self] snapshot in
            self?.nowPlayingDidChange(snapshot)
        }
        self.media = media

        // Built here rather than at launch, like the shelf, the clipboard
        // ring and the media controller: the wiring path has to be
        // testable without putting a window on screen. Constructing one
        // schedules nothing — `TimerController` spawns its first one-shot
        // only when `start(duration:)` is called from the tab.
        let timer = TimerController()

        // `[weak self]` for the same reason `media.onChange` uses it: the
        // controller holds these closures, so a strong capture would be a
        // controller keeping its owner alive. The bodies are methods
        // rather than inline closures so a test can drive the real publish
        // and finish paths with no scheduler running.
        timer.onChange = { [weak self] countdown in
            self?.countdownDidChange(countdown)
        }
        timer.onFinished = { [weak self] countdown in
            self?.timerDidFinish(countdown)
        }

        // The tab's four verbs, routed through `AppState` in the style of
        // `onCopyClipboard` and `onMediaCommand`. `[weak timer]` rather
        // than `[weak self]`: `AppState` outlives nothing here, but the
        // closures are held by the state which the delegate owns, and the
        // delegate owns the controller — capturing it strongly would close
        // the cycle.
        self.timer = timer
        wireTimerActions()

        // Publishes into `AppState` for the Battery tab, and into the
        // arbiter for the peek. Starting and stopping stays in
        // `applicationDidFinishLaunching` / `applicationWillTerminate`,
        // like the clipboard and media controllers — building the wiring
        // here must not register an IOKit callback.
        let power = PowerController()
        power.onSnapshot = { [weak self] snapshot in
            self?.powerDidChange(snapshot)
        }
        power.onEvent = { [weak self] event in
            self?.showPowerPeek(event)
        }
        self.power = power

        // Bluetooth alerts (2026-10-24). Built from the two seams above and
        // started by the switchboard's `.bluetooth` leg, never here:
        // building it registers nothing with IOBluetooth and asks nothing of
        // macOS, so the wiring stays testable and a launch with the module
        // off never touches Bluetooth. A second `install` stops the one it
        // replaces, so two can never both be registered.
        bluetooth?.stop()
        let bluetooth = BluetoothController(source: bluetoothSource, access: bluetoothAccess)
        bluetooth.onEvent = { [weak self] event in
            self?.showBluetoothPeek(event)
        }
        bluetooth.onAccessChange = { [weak self] access in
            self?.state.bluetoothAccess = access
        }
        self.bluetooth = bluetooth
        state.onRefreshBluetoothAccess = { [weak self] in self?.bluetooth?.refreshAccess() }
        state.onOpenBluetoothSettings = { [weak self] in self?.openBluetoothSettings() }

        // `hasBattery` is deliberately NOT set here. It was, and the line was
        // dead: `PowerObserver.hasBattery` is false until `start()` assigns
        // it, and `start()` runs after `install(metrics:)`. The flag has one
        // writer and it is the first snapshot, in `powerDidChange`.

        // The transport controls are deliberately NOT wired here. Reading
        // availability is what `dlopen`s MediaRemote, there is no
        // `dlclose`, and `install` runs before any preference is loaded —
        // so probing here loaded the private framework at every launch,
        // whatever the user had chosen. The `.mediaControls` leg of
        // `ModuleSwitchboard.setEnabled` is the one place that wires the
        // buttons and the seek, preference first, and `apply()` runs it at
        // launch. `MediaRemoteBridge` is stateless beyond its cached
        // handle, so there is nothing to start or stop either way.

        // The same preference, asked by the container before it answers
        // AppKit, so a disabled shelf shows no copy badge on the cursor.
        container.acceptsDrops = { [weak self] in self?.state.preferences.shelf == true }
        container.onDragEntered = { [weak self] in
            // A drop target that appears and then refuses the file is worse
            // than no drop target: it advertises a feature the user switched
            // off. Read through `state.preferences` rather than captured,
            // so the closure cannot hold a stale answer for the app's life.
            guard self?.state.preferences.shelf == true else { return }
            self?.arbiter.setDragActive(true)
            self?.state.transition(to: .receiving)
        }
        container.onDragExited = { [weak self] in
            // Deliberately NOT guarded on the preference. A drag already in
            // flight when the toggle flipped must still be able to put the
            // notch back; a symmetric guard here is how it gets stuck open.
            self?.arbiter.setDragActive(false)
            self?.state.transition(to: .closed)
        }
        container.onDrop = { [weak self] payloads in
            guard let self, let shelf = self.shelf, self.state.preferences.shelf else {
                self?.arbiter.setDragActive(false)
                self?.state.transition(to: .closed)
                return false
            }
            // The drag is over the moment a drop lands, whether or not it
            // is accepted below.
            defer { self.arbiter.setDragActive(false) }

            // Spec section 9: a write that fails refuses the drop rather
            // than half-completing it. Swallowing the error and opening
            // the shelf anyway would show an empty shelf and no reason why.
            //
            // A file is not copied here: `add` checks what it cheaply can,
            // lists it as pending and copies in the background, so a large
            // drop no longer holds the main thread. A copy that fails after
            // that is reported by `reportShelfCopyFailure`, since this drop
            // has long since been answered.
            var stored = 0
            for payload in payloads {
                do {
                    try shelf.add(payload, now: Date())
                    stored += 1
                } catch {
                    NSLog("CreativeNotch: shelf could not store a drop: \(error)")
                }
            }

            // Also covers an empty drop: nothing stored, nothing opened.
            // An explicit `payloads.isEmpty` check above was redundant
            // with this one — mutation testing found it changed no
            // behaviour, so it went rather than gaining a test that
            // asserted nothing.
            guard stored > 0 else {
                self.state.transition(to: .closed)
                return false
            }
            self.state.transition(to: .open(.shelf), openedBy: .drop)
            return true
        }
        container.addSubview(host)
        container.addSubview(hover)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]

        panel.contentView = container

        self.panel = panel
        self.hostView = host
        self.hoverView = hover

        // The funnel. Every accepted change re-derives the hover tracking
        // rect, so no caller has to remember to. Nothing outside
        // `AppState` can change state or geometry, so nothing bypasses it.
        if let previous = stateObserver { state.removeObserver(previous) }
        stateObserver = state.observe { [weak self] change in
            guard let self else { return }
            if case .state = change, self.isHandingOff { self.handoffSawStateChange = true }
            // A state change takes the shape from wherever a morph has got
            // to, on its own spring, and the region trails that spring as it
            // does any other (2026-10-28).
            if case .state = change, self.state.morph != nil { self.state.endMorph() }
            self.syncTrackingRect()
            if case .state(let newState) = change {
                self.syncDismissAffordances(for: newState)
                self.syncKeyWindow(for: newState)
                self.syncCameraVisibility(for: newState)
                self.syncCalendarVisibility(for: newState)
                self.syncShelfNotice(for: newState)
                self.syncColorStrip(for: newState)
                self.tapIfOpening(newState)
            }
        }

        // Placed where it belongs, not faded there: the launch is no trip,
        // and a trip the last panel was on is over (2026-10-28).
        forgetHandoff()

        // Seeding is unconditional on purpose. `reposition` dedupes on the
        // geometry being unchanged, which is right for a screen change and
        // wrong here: a second `install` builds a *fresh* panel and hover
        // tracker whose frame and tracking rect are still zero, so
        // delegating to the deduping path left the new panel unpositioned
        // and the tracking rect empty -- no tracking area at all, and hover
        // silently dead. (Follow-up F1.)
        let anchor = anchor(for: metrics)
        let frame = panelFrame(on: metrics, anchor: anchor)
        state.setGeometry(anchor: anchor, panelFrame: frame)
        shownDisplay = metrics.frame
        panel.setFrame(frame, display: true)
        // Seeded directly rather than through the lag: at install there is
        // no animation in flight for the accepted region to trail.
        growthTask?.cancel()
        acceptRect(visibleRect())
    }

    // MARK: - Derived geometry

    /// The currently-drawn region, panel-local. Both the hit test and the
    /// hover tracking rect read it, so there is exactly one derivation.
    ///
    /// `badgeWidth:` is passed here rather than added to the result, so the
    /// two consumers of this rect and the view's own `drawnRect` all widen
    /// by the badge through the same tested function.
    private func visibleRect() -> CGRect {
        visibleRect(anchor: currentAnchor, frame: currentFrame)
    }

    /// The same region for another geometry: what the shape would be in the
    /// window at `frame`, which `reposition` asks before it moves there.
    private func visibleRect(anchor: Anchor, frame: CGRect) -> CGRect {
        let slot = currentBadgeSlot
        return NotchShape.visibleRect(
            presentation: state.state.presentation,
            anchor: anchor,
            panelFrame: frame,
            badgeWidth: slot.width,
            leadingBadgeWidth: slot.leadingWidth
        )
    }

    /// How much wider than the anchor the closed notch currently is,
    /// because it is carrying a badge — zero when it is carrying none.
    ///
    /// Reads `NotchShape.badgeSlot` rather than spelling the rule out
    /// again, so this and `NotchRootView` cannot disagree about which
    /// badge is there or how wide it is. A width and not the slot itself
    /// because that is all the three rects need — `visibleRect` grows by
    /// a number and stays ignorant of which badge asked. Internal so a
    /// test can assert the source of the width directly.
    var currentBadgeWidth: CGFloat { currentBadgeSlot.width }

    /// The slot itself, for the one consumer that needs both of its
    /// widths: `visibleRect()`, which grows the leading ear for media's
    /// cover as well as the trailing one (spec 2026-10-15).
    var currentBadgeSlot: BadgeSlot {
        NotchShape.badgeSlot(
            countdown: state.countdown,
            nowPlaying: state.nowPlaying,
            isRecording: state.isRecordingClip,
            capture: state.captureUse,
            downloads: state.downloads,
            hiding: state.layoutOptions.hiddenBadges,
            at: Date()
        )
    }

    /// What is downloading changed -- at most once per whole percent.
    ///
    /// Internal so a test can drive the real publish path without a source.
    /// The re-sync is not optional, for `nowPlayingDidChange`'s reason: the
    /// badge changes the closed notch's width and the funnel does not fire
    /// for it. The re-evaluation keeps a downloads peek on screen following
    /// the percent, and turns it into the completion when the last one ends.
    func downloadsDidChange(_ summary: DownloadSummary?) {
        state.downloads = summary
        arbiter.setDownloads(summary)
        syncTrackingRect()
        reevaluatePeek()
    }

    /// A download finished. Recorded and then *asked* about, like a power
    /// event: whether it shows is the arbiter's call, and a peek that shows
    /// is announced by `applyPeek`.
    func downloadDidComplete(_ completion: DownloadCompletion) {
        arbiter.recordDownloadDone(completion, now: self.now())
        presentPeek()
    }

    /// The completion peek was clicked: acknowledged, closed, and the file
    /// shown in Finder.
    func revealDownload(_ completion: DownloadCompletion) {
        arbiter.dismissDownloadDone()
        if case .peek(.downloadDone) = state.state { state.transition(to: .closed) }
        if let url = completion.url { revealInFinder(url) }
    }

    /// What is playing changed.
    ///
    /// Internal rather than private so a test can drive the real publish
    /// path — including the badge re-sync below — without a running
    /// helper process.
    ///
    /// The re-sync is not optional: `AppState`'s funnel fires on state and
    /// geometry changes only, and starting or stopping playback is
    /// neither, yet it changes the closed shape. Without this the drawn
    /// rect would carry a badge the hit-test region and the tracking rect
    /// knew nothing about — clicks on it falling through to the menu bar
    /// behind, and hover never firing over it.
    func nowPlayingDidChange(_ snapshot: TrackSnapshot?) {
        state.nowPlaying = snapshot
        state.nowPlayingArtwork = snapshot.flatMap { media?.artwork(for: $0) }
        arbiter.setNowPlaying(snapshot)
        syncTrackingRect()
        reevaluatePeek()
    }

    /// The countdown ticked, started, paused or was cancelled.
    ///
    /// Internal rather than private so a test can drive the real publish
    /// path without a running scheduler — the same seam
    /// `nowPlayingDidChange` opens for the helper.
    ///
    /// The re-sync is not optional, and this is the second place in the
    /// file that has to say so. The badge changes the closed notch's
    /// width, and `AppState`'s funnel does not fire for a countdown tick —
    /// it carries state and geometry, and a tick is neither. Without the
    /// call below, the drawn rect carries a badge the hit-test region and
    /// the hover tracking rect know nothing about, and the trailing 44pt
    /// of a *visible* countdown drops clicks straight through to the menu
    /// bar and never registers hover. `TimerBadgeTests` pins the 274 that
    /// results.
    ///
    /// The tab's list of every countdown is read from the controller in the
    /// same breath, so the soonest and the list are one reading. With no
    /// countdown left the add picker goes too, so the next one starts from
    /// the plain single-timer view.
    func countdownDidChange(_ countdown: Countdown?) {
        state.countdown = countdown
        state.timers = timer?.timers.all ?? []
        if countdown == nil { state.isAddingTimer = false }
        syncTrackingRect()
    }

    /// The deadline passed.
    ///
    /// Internal for the same reason `countdownDidChange` is.
    func timerDidFinish(_ countdown: Countdown) {
        // Measured, never assumed zero: the machine may have slept through
        // the deadline, and "finished 2h ago" is only true because this
        // reads the clock. `remaining` is deliberately unclamped for
        // exactly this, so negate it and floor at zero.
        let lateness = -countdown.remaining(at: Date())

        // A countdown that finishes AFTER the timer was switched off still
        // chimes -- the interruption is precisely what the user asked for --
        // but does not take the peek slot.
        //
        // `timerDoneTTL` is 600s and outranks `.power`, so recording here
        // would hold the shared slot for ten minutes on behalf of a
        // switched-off module, swallowing the peeks behind it. And it would
        // be unclearable: `dismissTimerDone()`'s only caller sits behind a
        // transition to `.open`, and there is no tab left to reach.
        let completion = TimerCompletion(duration: countdown.duration, lateness: max(0, lateness))
        if state.preferences.timer {
            arbiter.recordTimerFinished(completion, now: self.now())
        }
        playChime(state.limits.chime)
        // The existing peek path, not a second one: it already declines to
        // interrupt `.open` and `.receiving`, and it is what makes the
        // arbiter — rather than this caller — decide what is shown.
        presentPeek()
        // Behind a full-screen app the peek above lands in an ordered-out
        // window. A notification is the one alert that shows there; it is
        // added to the chime and the announcement, never in place of them,
        // so a denied permission leaves exactly what there was before.
        //
        // A banner macOS accepted is also news for the arbiter: the peek the
        // user meets on the way back is then a reminder, and goes after a
        // glance (`PeekArbiter.notifiedTimerDoneTTL`). Denied, nothing is
        // reported and the peek keeps its full lifetime -- it is the only
        // thing they will see.
        if TimerDoneNotice.shouldPost(notchOnScreen: isNotchOnScreen, enabled: state.timerNotifyWhenHidden) {
            timerNotices.post(TimerDoneNotice(completion: completion)) { [weak self] accepted in
                guard accepted else { return }
                self?.arbiter.timerDoneWasNotified(completion)
            }
        }
        // When no peek carries it -- the panel is open, the module is off, a
        // drag holds the slot -- VoiceOver is told here instead. With the
        // chime set to None nothing else would say the timer finished. A
        // shown peek was already announced by `applyPeek`, so not twice.
        if case .peek(.timerDone(completion)) = state.state { return }
        announce(TimerSpokenText.completion(completion))
    }

    /// Moves the accepted region toward the drawn one.
    ///
    /// Shrink now, grow late: the accepted region must never describe more
    /// than is on screen. (Follow-up F6.)
    private func syncTrackingRect() {
        let target = visibleRect()
        // Cancelling stops pending tasks piling up; re-reading below means
        // a superseded task would settle on the right region anyway. Each
        // alone would be correct, so neither has a test that fails without
        // it -- they are kept as independent defences, not as behaviour.
        growthTask?.cancel()
        growthTask = nil

        // Moving between displays (2026-10-28), the window is fading out of
        // one place or into another, and accepts nothing until it has
        // arrived. Before the drag exemption below: a window on its way to
        // another display is not one to drop on either.
        if isHandingOff {
            acceptRect(.zero)
            return
        }

        // Morphing (2026-10-28), the shape is on its way from the old one to
        // `target` and every step covers what the two share, so that and no
        // more. Before the exemptions below: a badge or a drag does not make
        // a shape still on its way any larger.
        if let morph = state.morph {
            let shared = target.intersection(morph.morph.from)
            acceptRect(shared.isNull ? .zero : shared)
            return
        }

        // `.receiving` widens at once. The lag exists so the app never
        // accepts a click on something not yet drawn; during a drag there
        // is no click to mis-accept, and the drop region is gated by
        // hit-testing — so lagging here would refuse drops for a third of
        // a second exactly as the cursor moves into the panel it just
        // opened.
        if case .receiving = state.state {
            acceptRect(target)
            return
        }

        // The badge widens the *closed* shape, and it does so for the same
        // reason `.receiving` is exempt: what the lag protects against is
        // not there. The grow-late rule exists so the app never accepts a
        // click on something not yet drawn — but unlike a panel expansion,
        // the badge has no spring to wait for. `NotchRootView`'s animation
        // is keyed on `app.state`, which does not change when playback
        // starts, so the extra width snaps into place the moment the
        // snapshot publishes. Lagging here would not buy a safety margin;
        // it would make a badge the user can already see ignore clicks and
        // hover for `growthDelay`.
        //
        // Scoped to the closed shape *with* a badge showing, so a real
        // presentation change — which does spring — keeps its lag.
        if case .closed = state.state, currentBadgeWidth > 0 {
            acceptRect(target)
            return
        }

        // Shrinking, or the lag disabled: apply now and stay synchronous,
        // so callers that do not care about the animation need not await.
        guard area(of: target) > area(of: acceptedRect), growthDelay > .zero else {
            acceptRect(target)
            return
        }

        growthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.growthDelay)
            guard !Task.isCancelled else { return }
            // Re-read: the state may have moved on while we waited.
            self.acceptRect(self.visibleRect())
        }
    }

    private func acceptRect(_ rect: CGRect) {
        acceptedRect = rect
        hoverView?.updateTrackingRect(rect)
        keepOpenIfPointerInside(rect)
    }

    /// Where the pointer is on screen. Injected so a test can place it.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    /// The accepted region grows `growthDelay` after the panel is drawn. A
    /// pointer that moves into the newly drawn part before then has left the
    /// *old* region, which started the close; and a tracking area added
    /// around a pointer already inside it sends no `mouseEntered` to cancel
    /// it. So the panel closed under a user reaching for its controls
    /// (2026-10-18). When the region catches up, a pointer found inside it
    /// cancels that pending close.
    private func keepOpenIfPointerInside(_ rect: CGRect) {
        guard graceTask != nil, case .open = state.state else { return }
        let local = panelLocal(pointerLocation())
        guard rect.contains(local) else { return }
        cancelDismissGrace()
        state.isHovering = true
        hoverView?.acknowledgePointerInside()
    }

    private func area(of rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// `screen`, a point in screen coordinates, in the panel's own, where
    /// the accepted region is.
    ///
    /// From where the window is, not from `currentFrame` (2026-10-28): while
    /// the pill slides along the bar the geometry is already the
    /// destination's and the window is still on its way, carrying the shape
    /// and the region with it. A pointer resting on the pill as it set off
    /// read as having left it at once.
    private func panelLocal(_ screen: CGPoint) -> CGPoint {
        let origin = panel?.frame.origin ?? currentFrame.origin
        return CGPoint(x: screen.x - origin.x, y: screen.y - origin.y)
    }

    // MARK: - A Space of its own

    /// Where the window server functions come from. The real SkyLight ones
    /// by default; a test hands in a fake, and only ever through
    /// `hostPanelInFixedSpace()`, which nothing but the launch calls.
    var makeSpaceServer: () -> SpaceServer? = { SkyLightSpaceServer.load() }

    /// The Space the panel lives in so a desktop swipe does not carry it
    /// (spec 2026-10-17), or `nil` before launch or where macOS lacks the
    /// functions.
    private(set) var fixedSpace: NotchSpace?

    func hostPanelInFixedSpace() {
        guard let panel else { return }
        if fixedSpace == nil { fixedSpace = NotchSpace(server: makeSpaceServer()) }
        fixedSpace?.host(windowNumber: panel.windowNumber)
    }

    // MARK: - Full-screen apps

    /// Shows or hides the panel window. Injected so a test can check the
    /// call without putting a window on screen.
    var setPanelShown: (Bool) -> Void = { _ in }

    /// Settable internally so a test can stand in a watcher fed a fake
    /// Space list; only the launch builds the real one.
    var fullScreenWatcher: FullScreenWatcher?

    /// Hides the notch over full-screen apps again (2026-10-17).
    ///
    /// Only needed because of `fixedSpace`: in a Space of its own above every
    /// other, the panel shows over full-screen apps, where before omitting
    /// `.fullScreenAuxiliary` hid it for free. So it is started only when
    /// that Space exists, and only from the real launch.
    private func watchForFullScreen() {
        guard fixedSpace != nil, let read = FullScreenWatcher.skyLightReader() else { return }
        setPanelShown = { [weak self] shown in
            guard let self, let panel = self.panel else { return }
            if shown {
                panel.orderFrontRegardless()
                self.hostPanelInFixedSpace()
            } else {
                panel.orderOut(nil)
                // So showing it again re-adds it to the Space it may have
                // just left, rather than finding it "already hosted".
                self.fixedSpace?.windowOrderedOut()
            }
        }
        let watcher = FullScreenWatcher(
            readDisplays: read,
            displayUUID: { [weak self] in FullScreenWatcher.uuid(of: self?.panel?.screen ?? NSScreen.main) }
        )
        watcher.onChange = { [weak self] in self?.applyFullScreen($0) }
        fullScreenWatcher = watcher
        watcher.start()
    }

    /// Whether the panel is off screen for a full-screen app. `openPanel`
    /// reads it: opening an ordered-out window armed the outside-click
    /// monitor and made an invisible window key, with nothing to click.
    private(set) var isHiddenForFullScreen = false

    /// Full-screen: close the panel and take the notch off screen. Back to
    /// a desktop: put it back.
    ///
    /// Closing ends a drag in flight too. The window is ordered out, so no
    /// `draggingExited` will ever arrive to clear the arbiter's drag flag,
    /// and every later peek would be answered with a drop target.
    func applyFullScreen(_ isFullScreen: Bool) {
        isHiddenForFullScreen = isFullScreen
        if isFullScreen {
            arbiter.setDragActive(false)
            state.transition(to: .closed)
        }
        setPanelShown(!isFullScreen)
        // A timer that finished while hidden left its peek in the ordered-out
        // window, and this is the moment it is actually seen. If a banner
        // already told the user, that starts its brief window -- so the
        // re-check is rescheduled for it, or it would wait out the long one.
        if !isFullScreen, case .peek(.timerDone(let completion)) = state.state {
            arbiter.timerDoneWasShown(now: now())
            schedulePeekReevaluation(for: .timerDone(completion))
        }
    }

    // MARK: - Haptics

    /// The haptic itself. Injected so a test can count taps without a
    /// trackpad (spec 2026-10-17).
    ///
    /// `.levelChange` is the lightest pattern, and `.drawCompleted` lands it
    /// on the frame the panel is drawn on. It is felt only on a Force Touch
    /// trackpad with a finger resting on it — which is exactly the click
    /// that opened the panel — and macOS drops it if the user has turned
    /// haptic feedback off.
    ///
    /// Inert outside the packaged app, so a test that opens the panel without
    /// stubbing this taps nobody's trackpad (2026-10-17).
    var performHaptic: () -> Void = {
        guard AppDelegate.hapticsReachHardware else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .drawCompleted)
    }

    static var hapticsReachHardware: Bool { HostProcess.isPackagedApp() }

    private var wasOpen = false

    /// Set when a swipe has already tapped at its threshold, so the panel
    /// it then opens does not tap a second time.
    private var swipeTapped = false

    /// One tap as the panel opens, and none for a tab switch, a peek or a
    /// close: the panel opening is the deliberate action, and a peek fires
    /// unasked on hover.
    private func tapIfOpening(_ newState: NotchState) {
        let isOpen: Bool
        if case .open = newState { isOpen = true } else { isOpen = false }
        if isOpen && !wasOpen {
            if swipeTapped { swipeTapped = false } else { performHaptic() }
        }
        wasOpen = isOpen
    }

    // MARK: - Trackpad swipes

    private var swipe = NotchSwipe()
    private var swiping = false

    /// One scroll event from the hosting view, as a swipe step (spec
    /// 2026-10-17). Returns whether it was used; an unused one goes on as
    /// an ordinary scroll.
    ///
    /// Internal so a test can drive it with samples: scroll events with
    /// phases cannot be synthesised headlessly.
    @discardableResult
    func handleScroll(_ sample: ScrollSample) -> Bool {
        // A mouse wheel has no fingers to follow, and momentum is the
        // scroll coasting after the fingers lifted.
        guard sample.isPrecise, !sample.isMomentum else { return false }
        if case .receiving = state.state { return false }
        let presentation = state.state.presentation

        switch sample.phase {
        case .began:
            // On the open panel, a push up closes it only from the top strip
            // — the tab icons, level with the notch (2026-10-18). Anywhere
            // else it is an ordinary scroll: with natural scrolling,
            // scrolling *down* is the fingers moving *up*, the close gesture
            // exactly, and the panel used to vanish under a user scrolling
            // toward its controls. The whole swipe is passed on.
            if presentation == .expanded,
               !Self.isInTopStrip(sample.location, panelHeight: currentFrame.height,
                                  stripHeight: currentAnchor.rect.height) {
                swiping = false
                return false
            }
            swipe.began()
            swiping = true
            return presentation != .expanded
        case .changed:
            guard swiping else { return false }
            let crossed = swipe.changed(fingerDX: sample.finger.dx, fingerDY: sample.finger.dy)
            let pull = swipe.pull(on: presentation)
            state.pullProgress = pull
            if crossed, pull != 0 {
                performHaptic()
                swipeTapped = true
            }
            if presentation == .expanded { return pull != 0 }
            return true
        case .ended, .cancelled:
            guard swiping else { return false }
            swiping = false
            let outcome = sample.phase == .ended ? swipe.ended(on: presentation) : .none
            state.pullProgress = 0
            apply(outcome)
            // A threshold tap that did not end in opening must not swallow
            // the next open's tap.
            if outcome != .open { swipeTapped = false }
            return outcome != .none || presentation != .expanded
        case .other:
            return false
        }
    }

    /// Whether a point in the panel's window coordinates (bottom-left
    /// origin) is in its top strip, level with the notch. Unknown is no.
    static func isInTopStrip(_ point: CGPoint?, panelHeight: CGFloat, stripHeight: CGFloat) -> Bool {
        guard let point else { return false }
        return point.y >= panelHeight - stripHeight
    }

    private func apply(_ outcome: NotchSwipe.Outcome) {
        switch outcome {
        case .none:
            break
        case .open:
            openPanel(openedBy: .swipe)
        case .close:
            state.transition(to: .closed)
        case .nextTrack, .previousTrack:
            // Only with working transport controls, the same gate the
            // panel's buttons sit behind.
            guard state.showsMediaControls else { return }
            state.onMediaCommand?(outcome == .nextTrack ? .nextTrack : .previousTrack)
        }
    }

    // MARK: - Hover

    /// The dwell opened the notch. What it shows is the arbiter's call.
    /// With "open on hover" on, the dwell opens the panel instead — from
    /// the closed notch or a peek, never over a drag or an open panel, and
    /// falling back to the peek when there is no tab to open.
    private func peek() {
        if state.hoverBehaviour.opensOnHover {
            switch state.state {
            case .closed, .peek:
                if openPanel(openedBy: .hover) { return }
            case .open, .receiving:
                return
            }
        }
        presentPeek()
    }

    /// Current power state into the panel.
    ///
    /// A method rather than a closure body so a test can drive the real
    /// publish path without an IOKit callback — the same reason
    /// `nowPlayingDidChange` is one.
    func powerDidChange(_ snapshot: PowerSnapshot) {
        state.power = snapshot
        // The first snapshot is the ONLY thing that sets `hasBattery`. An
        // install-time assignment used to sit beside the controller and was
        // dead -- the observer's flag is false until `start()`, which runs
        // later -- so the tab has always appeared from here. A machine whose
        // battery reads as absent at launch and present a moment later would
        // otherwise
        // never show the tab.
        let gainedTab = !state.hasBattery
        state.hasBattery = true
        // The Battery tab just appeared, which a Compact panel (or a Default
        // one holding the calendar too) makes room for (`tabsDidChange`). Once per process: it is never cleared.
        if gainedTab { tabsDidChange() }
    }

    /// A power event into the peek slot.
    ///
    /// Recorded into the arbiter and then *asked* what to show, never shown
    /// directly — priority against a finished timer or a drag is the
    /// arbiter's call alone, never the caller's.
    func showPowerPeek(_ event: PowerEvent) {
        let now = self.now()
        arbiter.recordPower(event, now: now)
        presentPeek()
    }

    /// A Bluetooth device into the peek slot, by `showPowerPeek`'s rule:
    /// recorded, then the arbiter is asked. Power, a finished timer and a
    /// drag all outrank it, and that is the arbiter's call alone.
    func showBluetoothPeek(_ event: BluetoothAudioEvent) {
        arbiter.recordBluetooth(event, now: now())
        presentPeek()
    }

    /// The only path to a `.peek` state.
    ///
    /// `.open` and `.receiving` are deliberate user states -- a hover dwell
    /// that lands mid-drag must not destroy them. What is shown is whatever
    /// the arbiter decides: priority among drag, power and now-playing is
    /// its call alone, not the caller's.
    private func presentPeek() {
        let now = self.now()

        switch state.state {
        case .open, .receiving:
            return
        case .closed, .peek:
            break
        }

        guard let content = arbiter.content(now: now) else { return }
        applyPeek(content)
        schedulePeekReevaluation(for: content)
    }

    /// Puts `content` in the peek slot and tells VoiceOver, if it is news.
    ///
    /// Both paths into `.peek` — a new peek and a re-check of the showing
    /// one — come through here, so neither can show a peek without it being
    /// heard. Whether it is news is `PeekAnnouncement`'s call: a re-check
    /// re-applies the same peek, and the now-playing peek is re-applied on
    /// every pause and seek, and none of that is spoken.
    private func applyPeek(_ content: PeekContent) {
        let previous: PeekContent?
        if case .peek(let showing) = state.state { previous = showing } else { previous = nil }
        state.transition(to: .peek(content))
        if let text = PeekAnnouncement.announcement(showing: content, replacing: previous) {
            announce(text)
        }
        // Here because every path into `.peek` passes through, and the
        // arbiter's brief window must start when the peek is *seen*. Behind
        // a full-screen app the window is ordered out and nothing is seen;
        // the notch coming back starts it instead (`applyFullScreen`).
        if case .timerDone = content, isNotchOnScreen {
            arbiter.timerDoneWasShown(now: now())
        }
    }

    /// Re-reads the arbiter once the showing content's TTL is expected to
    /// have elapsed, and transitions to whatever it now says -- `.closed`
    /// if nothing. Mirrors `startDismissGrace`: cancel-and-replace, and
    /// exposed as `peekTTLTask` so tests can await it instead of sleeping.
    ///
    /// The delay follows the content, which it did not have to while the app
    /// had a single TTL. A finished-timer peek outlives a power one by two
    /// orders of magnitude, so a fixed re-check would fire while the longer
    /// peek was still live, find the arbiter still returning it, transition
    /// to the state it was already in — and never look again. The notch
    /// would stay open until some unrelated event moved it.
    /// Which TTL a given peek is re-checked on.
    ///
    /// Static and internal so a test can read the choice directly. Proving
    /// it through timing does not work: a test that shrinks both delays to
    /// zero — which is what every test here does, to avoid real sleeps —
    /// cannot tell the two apart, and swapping them leaves the suite
    /// green. This is the same reason `NotchRootView.nowPlayingPeek` is a
    /// static builder rather than an inline expression.
    static func reevaluationDelay(
        for content: PeekContent,
        power: Duration,
        timerDone: Duration,
        bluetooth: Duration = AppDelegate.defaultBluetoothTTLDelay,
        downloadDone: Duration = AppDelegate.defaultDownloadDoneTTLDelay,
        timerDoneIsBrief: Bool = false,
        notifiedTimerDone: Duration = AppDelegate.defaultNotifiedTimerDoneTTLDelay
    ) -> Duration {
        switch content {
        case .power:        return power
        // Brief only once the arbiter says so: notified, and shown.
        case .timerDone:    return timerDoneIsBrief ? notifiedTimerDone : timerDone
        case .bluetooth:    return bluetooth
        case .downloadDone: return downloadDone
        // `.nowPlaying`, `.downloads` and `.dragTarget` have no expiry of
        // their own — they end when the track stops, the downloads finish or
        // the drag does. The delay is irrelevant for them; `reevaluatePeek`
        // does not reschedule.
        case .nowPlaying, .downloads, .dragTarget:
            return power
        }
    }

    private func schedulePeekReevaluation(for content: PeekContent) {
        let delay = Self.reevaluationDelay(
            for: content,
            power: powerTTLDelay,
            timerDone: timerDoneTTLDelay,
            bluetooth: bluetoothTTLDelay,
            downloadDone: downloadDoneTTLDelay,
            timerDoneIsBrief: arbiter.timerDoneIsBrief,
            notifiedTimerDone: notifiedTimerDoneTTLDelay
        )

        peekTTLTask?.cancel()
        peekTTLTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.reevaluatePeek()
        }
    }

    /// Only acts while still `.peek`: if the user has since opened the
    /// panel or started a drag, that is a deliberate state this stale
    /// check must not disturb.
    ///
    /// Asks the arbiter what the peek *on screen* becomes, not what a hover
    /// would show: a paused track is held under the pointer so Play stays
    /// reachable, and the music peek is never fallen back to with nobody
    /// hovering. `isHovering` is the pointer, because the tracker is the
    /// one thing that knows where it is without polling.
    private func reevaluatePeek() {
        guard case .peek(let showing) = state.state else { return }
        if let content = arbiter.content(
            now: self.now(), replacing: showing, pointerInside: state.isHovering
        ) {
            applyPeek(content)
            // Something transient may still be live underneath the one that
            // just lapsed — a power peek recorded while a finished timer held
            // the slot is revealed when that one goes. Without this the
            // revealed peek would never be re-checked. It terminates
            // because every transient source strictly expires; ambient
            // content reached here simply stays until its own source
            // changes.
            switch content {
            case .power, .timerDone, .bluetooth, .downloadDone: schedulePeekReevaluation(for: content)
            case .nowPlaying, .downloads, .dragTarget: break
            }
        } else {
            state.transition(to: .closed)
        }
    }

    /// The cursor left the visible shape.
    ///
    /// Every case is named on purpose. The previous form was a
    /// `guard case .open = state else { close }` with an empty success
    /// body, which meant "close" was the default for every state that was
    /// not `.open` -- including states hover has no business ending. Under
    /// that default a drag that moved below the notch closed the drop
    /// target it was aimed at.
    private func collapse() {
        switch state.state {
        case .closed:
            break                       // nothing to collapse

        case .peek:
            // Hover opened it, so hover closes it.
            state.transition(to: .closed)

        case .open:
            // A click opened it, so a click, an app switch, or the cursor
            // staying away closes it. Leaving starts a grace period rather
            // than dismissing outright.
            startDismissGrace()

        case .receiving:
            // A drag is in flight. The drop target has to outlive the
            // cursor leaving the notch or the drop can never land.
            break
        }
    }

    // MARK: - Dismissing an open panel

    /// Keeps the outside-click monitor's lifetime tied to `.open`.
    ///
    /// Driven from the funnel rather than from call sites: every state
    /// change routes through `AppState.transition(to:)`, so there is no
    /// path that can open the panel without arming this, or close it and
    /// leave a monitor running.
    /// Takes keyboard focus for an open somebody asked for, and for the one
    /// tab that accepts typing.
    ///
    /// The panel *can* become key (see `NotchPanel`), but it should not do
    /// so casually: while it holds focus, whatever you were writing in
    /// loses its insertion point. Peeks are ambient and frequent, so none of
    /// them touch it. An open earns it by being explicit — the notch tap or
    /// the global shortcut, the two routes where the person has turned to
    /// the panel and Esc and ⌘1…⌘N are what they will reach for next. A
    /// hover-open never does: a pointer crossing the notch is not someone who
    /// has stopped typing (`PanelOpenReason`).
    ///
    /// Giving focus back is `relinquishKey`, not `resignKey()`. AppKit sends
    /// `resignKey` as a notification and documents that it must never be
    /// called directly; called anyway, it moves nothing, so the closed panel
    /// stayed key and swallowed every keystroke meant for the app underneath.
    /// Still no stored "previous window": once the panel is not key, the
    /// window server returns focus to the frontmost app, which never stopped
    /// being frontmost (the panel is non-activating), and tracking that
    /// ourselves would be a second derivation of state it already owns.
    ///
    /// Deliberately keyed on the tab and the *reason*, not on `.open`.
    /// Making every open steal the cursor would be a regression for the
    /// hover-open that never asked for it.
    /// Pure, so the rule is testable without a window server — `makeKey`
    /// on an offscreen panel in a headless suite proves nothing. The rule
    /// itself is `PanelFocus`, in Core; this is the delegate's name for it.
    static func shouldTakeKey(for state: NotchState, openedBy reason: PanelOpenReason?) -> Bool {
        PanelFocus.shouldTakeKey(for: state, openedBy: reason)
    }

    /// Takes keyboard focus. `nil` means the real thing, `makeKey()`; a test
    /// hands in a counter, like `relinquishKey`, because a headless suite
    /// cannot make an offscreen panel key and so could not tell a hover-open
    /// that took focus from one that did not.
    var takeKey: (() -> Void)?

    /// Whether the panel holds keyboard focus. Injected because a headless
    /// suite cannot make an offscreen panel key, so the give-back path would
    /// otherwise be unreachable from a test.
    var panelIsKey: (NSWindow) -> Bool = { $0.isKeyWindow }

    /// Gives keyboard focus up. `nil` means the real thing,
    /// `orderPanelOutOfFocus()`; a test hands in a counter, like
    /// `presentPreferences`.
    var relinquishKey: (() -> Void)?

    /// **Focus is given back only once the panel leaves `.open`.** Giving it
    /// up means ordering the window out and back in, which is fine for a
    /// panel on its way to closing but not for one staying on screen: a tab
    /// switch from the timer would pull the visible panel off and re-host it
    /// in the fixed Space under the pointer. Staying key on the shelf or
    /// clipboard tab costs nothing -- the user is in the panel -- and the
    /// close that follows gives focus back.
    func syncKeyWindow(for newState: NotchState) {
        guard let panel else { return }
        if Self.shouldTakeKey(for: newState, openedBy: state.openReason) {
            if let takeKey { takeKey() } else { panel.makeKey() }
        } else if case .open = newState {
            return
        } else if panelIsKey(panel) {
            if let relinquishKey { relinquishKey() } else { orderPanelOutOfFocus(panel) }
        }
    }

    /// Ordering a window out is what actually takes key status from it, and
    /// ordering it straight back with `orderFrontRegardless` does not hand it
    /// back — that call never makes a window key. Both in the same turn of
    /// the run loop, so there is no frame in between to draw. Not ordered
    /// back while hidden for a full-screen app. Re-hosted afterwards,
    /// because a window ordered out may leave the fixed Space (see
    /// `NotchSpace`).
    ///
    /// Re-hosting only where a Space exists, so this can never be the call
    /// that creates one — only the launch does that.
    private func orderPanelOutOfFocus(_ panel: NotchPanel) {
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        fixedSpace?.windowOrderedOut()
        guard wasVisible, !isHiddenForFullScreen else { return }
        panel.orderFrontRegardless()
        if fixedSpace != nil { hostPanelInFixedSpace() }
    }

    /// What a key the panel received does, through the funnel.
    ///
    /// Keys arrive only while the panel is key, which `syncKeyWindow` grants
    /// to an explicit open (or the timer tab, or a click in the panel) — so
    /// nothing here needs a monitor, global or local. Esc is the same
    /// `.closed` transition every other dismissal makes; ⌘N is the same
    /// `.open(tab)` the tab bar's buttons make, numbered over the tabs the
    /// bar actually draws.
    ///
    /// Returns whether the key was used. A declined key — ⌘9 with three
    /// tabs, anything while not open — goes back to AppKit to pass on.
    @discardableResult
    func handlePanelKey(_ key: PanelKey) -> Bool {
        let visible = TabVisibility.visible(
            enabled: state.preferences,
            hasBattery: state.hasBattery
        )
        guard let action = PanelKeyboard.action(
            for: key, in: state.state, visible: visible,
            clipboardQuery: state.clipboardQuery,
            clipboardIsEmpty: state.clipboard?.entries.isEmpty ?? true
        ) else {
            return false
        }
        switch action {
        case .close:            state.transition(to: .closed)
        case .select(let tab):  state.transition(to: .open(tab))
        case .quickLook:        return toggleShelfQuickLook()
        case .moveShelfSelection(let step): return moveShelfSelection(by: step)
        case .clearSearch:      state.clipboardQuery = ""
        }
        return true
    }

    // MARK: - Quick Look and Open (2026-10-24)

    /// The shelf's items, or none while the module is off: `state.shelf` is
    /// what the switchboard clears, so a switched-off shelf previews and
    /// opens nothing even if a stale verb reaches here.
    private var visibleShelfItems: [ShelfItem] { state.shelf?.items ?? [] }

    /// Shows `id` — or, for `nil`, the selection's first ready neighbour —
    /// in Quick Look, paging over every ready item, and selects what it
    /// shows so the ring and the preview agree. Returns whether anything
    /// was shown: a copying item, or a shelf with no file in it, shows
    /// nothing (`ShelfPreview`).
    @discardableResult
    func quickLookShelfItem(_ id: UUID?) -> Bool {
        let items = visibleShelfItems
        guard let request = ShelfPreview.request(for: id, in: items) else { return false }
        state.shelfSelection = items.first { $0.url == request.current }?.id
        shelfPreview.show(request)
        return true
    }

    /// Space on the shelf tab: previews the selection. Once the preview is
    /// up it has the keyboard (`ShelfQuickLook.prepare`) and closes itself
    /// on Space, as in Finder, so this sees Space with a preview up only if
    /// someone clicked back into the panel first — and then closes it.
    ///
    /// Always consumed, even with nothing to show: a declined key goes on to
    /// `NSWindow.keyDown`, which beeps, and Space on the shelf tab is never
    /// anybody else's.
    private func toggleShelfQuickLook() -> Bool {
        if shelfPreview.isVisible {
            shelfPreview.close()
        } else {
            quickLookShelfItem(state.shelfSelection)
        }
        return true
    }

    /// ← →, while the panel has the keyboard. A preview that is up follows
    /// the selection — reached only after a click back into the panel,
    /// since while the preview is key its own arrows page it instead.
    private func moveShelfSelection(by step: Int) -> Bool {
        guard let next = ShelfSelection.moved(from: state.shelfSelection, by: step, in: visibleShelfItems) else {
            return false
        }
        state.shelfSelection = next
        if shelfPreview.isVisible { quickLookShelfItem(next) }
        return true
    }

    /// Quick Look closed itself, taking the keyboard with it: hands it back
    /// to the notch panel while the panel is still open, so Space previews
    /// again and Esc closes the panel. A panel that has closed meanwhile —
    /// the pointer left it for the preview — is left closed and unkeyed.
    func shelfPreviewDidClose() {
        guard case .open = state.state, let panel else { return }
        if let takeKey { takeKey() } else { panel.makeKey() }
    }

    /// Hands the file to its default app — a tile's double-click or Open.
    /// The app that opens it comes forward, and that activation closes the
    /// panel through the usual `applicationDidActivate` path.
    func openShelfItem(_ id: UUID) {
        guard let item = visibleShelfItems.first(where: { $0.id == id }),
              ShelfSelection.isSelectable(item) else { return }
        state.shelfSelection = id
        if !shelfOpener.open(item.url) {
            NSLog("CreativeNotch: could not open shelf item \(item.displayName)")
        }
    }

    private func syncDismissAffordances(for newState: NotchState) {
        guard case .open = newState else {
            cancelDismissGrace()
            if let token = outsideClickToken {
                removeOutsideClickMonitor(token)
                outsideClickToken = nil
            }
            return
        }

        // Opening the panel is acknowledgement. Without this the finished
        // timer sits in the arbiter for the rest of its ten-minute TTL and
        // reappears on the next hover, long after the user has dealt with
        // it — and it outranks power, so the charger peek would be
        // swallowed by it too. Cleared here rather than at the tap site
        // because every route to `.open` — the notch tap, a drop, a
        // restored tab — comes through the funnel and lands right here,
        // which is the same argument that put the outside-click monitor
        // in this method.
        arbiter.dismissTimerDone()
        // A finished download too: opening the panel is having seen it.
        arbiter.dismissDownloadDone()

        // Already armed -- switching tabs must not stack monitors.
        guard outsideClickToken == nil else { return }

        outsideClickToken = installOutsideClickMonitor { [weak self] in
            // Global monitor handlers are delivered on the main thread;
            // the closure's type just cannot express that.
            MainActor.assumeIsolated { self?.dismissIfOpen() }
        }
    }

    /// The grace counts from when the accepted region has caught up with the
    /// drawn one, not from the exit. The shipped grace (400ms) is shorter
    /// than the growth lag (420ms), so counted from the exit it fired before
    /// `keepOpenIfPointerInside` could find the pointer inside the grown
    /// region — and the panel shut under a user who had just tapped it open
    /// and moved toward its controls. Waiting on `growthTask` rather than
    /// lengthening the grace keeps both numbers meaning what they say.
    private func startDismissGrace() {
        graceTask?.cancel()
        let growth = growthTask
        graceTask = Task { @MainActor [weak self] in
            await growth?.value
            guard let self, !Task.isCancelled else { return }
            try? await Task.sleep(for: self.dismissGrace)
            guard !Task.isCancelled else { return }
            self.dismissIfOpen()
        }
    }

    private func cancelDismissGrace() {
        graceTask?.cancel()
        graceTask = nil
    }

    /// Closes the panel only if it is still open, so a pending grace
    /// timer can never reopen or disturb a state the user has since
    /// changed -- a drag in flight above all.
    private func dismissIfOpen() {
        guard case .open = state.state else { return }
        state.transition(to: .closed)
    }

    /// Another application came forward.
    ///
    /// Takes a pid rather than an `NSRunningApplication` so it is drivable
    /// from a test without conjuring a real running app.
    func applicationDidActivate(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        dismissIfOpen()
    }

    // MARK: - Screen changes

    func observeScreenChanges() {
        // `queue: .main` guarantees these closures run on the main thread,
        // but their type is `@Sendable`, so the compiler can't see that --
        // `MainActor.assumeIsolated` asserts the guarantee the API already
        // gives us rather than deferring the call to a fresh `Task`, which
        // would change *when* repositioning happens relative to the
        // notification.
        observers.append((NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersDidChange() }
        }, NotificationCenter.default))

        observers.append((NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            MainActor.assumeIsolated {
                if let pid = app?.processIdentifier {
                    self.applicationDidActivate(pid: pid)
                }
                self.activeApplicationDidChange(pid: app?.processIdentifier)
            }
        }, NSWorkspace.shared.notificationCenter))

        // Another desktop on a display can bring forward another window of
        // the app already in front, which is no app switch.
        observers.append((NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceDidChange() }
        }, NSWorkspace.shared.notificationCenter))

        // The app in front at launch has not come forward, so no switch
        // names it.
        focusedAppPID = frontmostApplicationPID().flatMap {
            $0 == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }
        syncFocusWatch()
    }

    /// Another app came forward, so the focused window may be on another
    /// display. Following focus, the panel goes with it; pinned, it stays
    /// and the screen list is not even read -- an app switch is not a
    /// reason to look.
    ///
    /// With "Keep clear of app menus" on, the app that came forward (`pid`)
    /// has its menus read first, and the pill is placed again for them --
    /// pinned too, since the menus are what changed. Placed again only when
    /// the reach changed, so a pinned switch between apps with the same
    /// menus does no more than before.
    func activeApplicationDidChange(pid: pid_t? = nil) {
        let menusMoved = pid.map(refreshAppMenus(for:)) ?? false
        if let pid {
            focusedAppPID = pid == ProcessInfo.processInfo.processIdentifier ? nil : pid
        }
        syncFocusWatch()
        if state.displayChoice.followsActivation {
            focusMayHaveMoved()
            settleFocus(restarting: true)
        } else if menusMoved, let metrics = screenMetrics(state.displayChoice) {
            reposition(metrics: metrics)
        }
    }

    /// Another Space came forward on some display, perhaps with another
    /// window of the same app in front -- no app switch says so.
    func activeSpaceDidChange() {
        guard state.displayChoice.followsActivation else { return }
        focusMayHaveMoved()
        settleFocus(restarting: true)
    }

    /// The frontmost app said another of its windows took focus or one
    /// moved (`WindowFocusWatcher`). Read at once unless a second look is
    /// already due, which then reads for it: a drag says so many times a
    /// second, and is read about three times a second, not at that rate.
    func focusedAppWindowsDidChange() {
        guard state.displayChoice.followsActivation, focusSettleTask == nil else { return }
        focusMayHaveMoved()
        settleFocus(restarting: false)
    }

    /// Following focus, watches the app in front for focus moving among its
    /// own windows; pinned, or with this app in front, watches nothing.
    /// Asked on every switch, so access allowed in System Settings meanwhile
    /// takes effect at the next one.
    private func syncFocusWatch() {
        guard state.displayChoice.followsActivation, let pid = focusedAppPID else {
            windowFocusWatcher.stop()
            return
        }
        windowFocusWatcher.watch(pid: pid) { [weak self] in self?.focusedAppWindowsDidChange() }
    }

    /// Looks at focus once more after `focusSettleDelay`. An app switch or a
    /// Space change starts the wait again, so the look comes after the last
    /// of them; a window notification leaves a wait already running alone.
    private func settleFocus(restarting: Bool) {
        if restarting {
            focusSettleTask?.cancel()
        } else if focusSettleTask != nil {
            return
        }
        let delay = focusSettleDelay
        focusSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.focusSettleTask = nil
            self.focusMayHaveMoved()
        }
    }

    /// Following focus, places the panel on the focused window's screen. A
    /// change that lands on the screen it is already on moves nothing:
    /// `reposition` drops an equal geometry.
    private func focusMayHaveMoved() {
        guard state.displayChoice.followsActivation,
              let metrics = focusScreenMetrics(state.displayChoice)
        else { return }
        reposition(metrics: metrics)
    }

    /// Reads the menus of `pid`, the app that just came forward, and keeps
    /// how far they reach. Returns whether that changed.
    ///
    /// This app coming forward -- Settings -- is not the app whose menus are
    /// on the bar the user cares about, so it is skipped. Off, or without
    /// Accessibility access, nothing is read. An app with nothing to read (no
    /// menu bar, or no answer in `SystemAppMenuReader.messagingTimeout`)
    /// says nothing about where menus are, so the last reach stands.
    @discardableResult
    func refreshAppMenus(for pid: pid_t) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
        lastActivePID = pid
        guard state.pillClearsMenus else { return false }
        state.accessibilityTrusted = appMenuReader.isTrusted
        guard state.accessibilityTrusted, let end = appMenuReader.menusEnd(of: pid), end != appMenusEnd else {
            return false
        }
        appMenusEnd = end
        return true
    }

    /// Saves and applies "Keep clear of app menus" (2026-10-26), then places
    /// the pill by it at once.
    ///
    /// Switched on, it asks for Accessibility access when macOS has not given
    /// it -- the only place the prompt is shown -- and measures the app that
    /// was in front before Settings. Switched off, the pill goes back to the
    /// centre.
    func setPillClearsMenus(_ enabled: Bool) {
        preferencesStore.setPillClearsMenus(enabled)
        state.pillClearsMenus = enabled
        if enabled {
            if !appMenuReader.isTrusted { appMenuReader.requestTrust() }
            state.accessibilityTrusted = appMenuReader.isTrusted
            if let pid = lastActivePID { refreshAppMenus(for: pid) }
        } else {
            appMenusEnd = 0
        }
        guard panel != nil, let metrics = screenMetrics(state.displayChoice) else { return }
        reposition(metrics: metrics)
    }

    /// The anchor on `metrics`, clear of the frontmost app's menus while
    /// "Keep clear of app menus" is on. Every placement asks here, so the
    /// launch, a screen change, an activation and a setting cannot disagree
    /// about where the pill goes.
    private func anchor(for metrics: ScreenMetrics) -> Anchor {
        NotchGeometry.anchor(for: metrics, menusEnd: state.pillClearsMenus ? appMenusEnd : 0)
    }

    /// A display was connected, disconnected or rearranged: place the panel
    /// on whatever the choice picks from the screens there are now. This is
    /// also how a pinned display that was unplugged gets the panel back --
    /// plugging it in posts this, and the rule finds it again.
    ///
    /// The Settings menu's display list is refreshed first, so an open
    /// Settings window offers what is connected now.
    func screenParametersDidChange() {
        refreshConnectedDisplays()
        guard let metrics = screenMetrics(state.displayChoice) else { return }
        screenParametersDidChange(metrics: metrics)
    }

    /// Saves and applies a new "Show on", then places the panel by it at
    /// once. `reposition` re-checks full screen when the panel moves, which
    /// is the only time the display it is on can have changed.
    func setDisplayChoice(_ choice: DisplayChoice) {
        preferencesStore.setDisplayChoice(choice)
        state.displayChoice = choice
        syncFocusWatch()
        if !choice.followsActivation {
            focusSettleTask?.cancel()
            focusSettleTask = nil
        }
        guard panel != nil, let metrics = screenMetrics(choice) else { return }
        reposition(metrics: metrics)
    }

    /// Saves and applies a new "Text size", then resizes the panel to fit it
    /// at once (2026-10-24). Through `reposition`, the one path that changes
    /// the panel's frame, so the funnel re-syncs the tracking rect and the
    /// hosting view follows the window as it does on a screen change. No
    /// observer: the view reads `state.textSize` on its next draw.
    func setTextSize(_ size: TextSize) {
        preferencesStore.setTextSize(size)
        state.textSize = size
        guard panel != nil, let metrics = screenMetrics(state.displayChoice) else { return }
        reposition(metrics: metrics)
    }

    /// Saves and applies new layout options, then re-places the panel at
    /// once (2026-10-24).
    ///
    /// Two things follow a change, and both are needed. A new width is a new
    /// frame, so it goes through `reposition` like a new text size; that is
    /// a no-op for every other option, because the funnel drops an equal
    /// geometry. A badge shown or hidden changes the *closed* shape without
    /// changing state or geometry, so neither funnel event fires and the
    /// accepted region has to be re-synced here -- the reason
    /// `countdownDidChange` gives for its own call. The corners, the tab
    /// side and the battery are drawn only, and the view reads them on its
    /// next draw.
    func setLayoutOptions(_ options: LayoutOptions) {
        preferencesStore.saveLayout(options)
        state.layoutOptions = options
        if panel != nil, let metrics = screenMetrics(state.displayChoice) {
            reposition(metrics: metrics)
        }
        syncTrackingRect()
    }

    /// The header's tabs changed: a module with a tab was switched on or off,
    /// or the Battery tab arrived with the first power snapshot.
    ///
    /// Re-places the panel only when the tab count changes the width it is
    /// sized from (`NotchGeometry.nominalPanelWidth`): Compact follows the
    /// tabs, Default and Wide only past the five tabs that ship on -- the
    /// calendar's sixth. Any other toggle leaves the panel where it is, which also
    /// keeps the toggle paths that run at launch and in the test suites from
    /// asking the real screens where to go.
    func tabsDidChange() {
        guard panel != nil,
              let placed = placedNominalWidth,
              nominalPanelWidth(for: currentAnchor) != placed,
              let metrics = screenMetrics(state.displayChoice) else { return }
        reposition(metrics: metrics)
    }

    /// The width the panel was last sized from, recorded by `panelFrame(on:)`
    /// so `tabsDidChange` can tell whether a tab coming or going moves it.
    private var placedNominalWidth: CGFloat?

    private var visibleTabCount: Int {
        TabVisibility.visible(enabled: state.preferences, hasBattery: state.hasBattery).count
    }

    private func nominalPanelWidth(for anchor: Anchor) -> CGFloat {
        NotchGeometry.nominalPanelWidth(for: anchor, width: state.layoutOptions.width, tabCount: visibleTabCount)
    }

    /// The window frame for `metrics` at the current text size and layout.
    /// Every place the panel is sized asks here, so a screen change, an
    /// activation and the launch cannot disagree with the settings about how
    /// large it is.
    private func panelFrame(on metrics: ScreenMetrics, anchor: Anchor? = nil) -> CGRect {
        let anchor = anchor ?? self.anchor(for: metrics)
        placedNominalWidth = nominalPanelWidth(for: anchor)
        return NotchGeometry.panelFrame(
            for: anchor,
            in: metrics,
            textScale: state.textSize.scale,
            width: state.layoutOptions.width,
            tabCount: visibleTabCount
        )
    }

    /// The display arrangement changed. Internal so a test can drive it
    /// with metrics instead of a real display.
    ///
    /// Re-checks full screen even when the panel did not move: the
    /// arrangement changed, and what its display shows may have with it.
    /// `reposition` already did when it moved, and `evaluate` reports only
    /// a change, so the second look is free.
    ///
    /// With no panel yet — there was no screen at launch — this is the
    /// launch's second chance: build it now, then start the subsystems again
    /// through the one method that does, because the controllers the
    /// switchboard starts are built by `install` and were still `nil` the
    /// first time. Re-starting is safe: `activity.start()` re-registers
    /// rather than stacking, and `apply()` only reconciles.
    func screenParametersDidChange(metrics: ScreenMetrics) {
        guard panel != nil else {
            showPanel(on: metrics)
            if panel != nil { startSubsystems() }
            return
        }
        if !reposition(metrics: metrics) { fullScreenWatcher?.evaluate() }
    }

    private func removeScreenObservers() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
    }

    /// Moves the panel to wherever the notch or pill is on `metrics`.
    ///
    /// Returns whether anything moved, or is on its way to. `didActivateApplication`
    /// fires on every Cmd-Tab and `@Observable` does not dedupe equal
    /// assignments, so without the guard every app switch pushed a new
    /// frame and a new anchor and forced a redraw -- contradicting the
    /// rule that state transitions are the only thing that triggers one.
    ///
    /// On the display it is on, the panel is placed at once. To another
    /// display it fades across (`PanelMove`, 2026-10-28): the geometry
    /// changes only once the window is invisible, so the shape is never
    /// drawn as the new display's in the old place. A move asked for during
    /// a trip replaces the trip's destination rather than queueing behind
    /// it, and a move back to where the panel still is calls the trip off.
    ///
    /// The pill moving along its own menu bar -- keeping clear of the menus
    /// -- slides there instead of jumping (2026-10-28).
    ///
    /// And the anchor changing on the display it is on -- the notch and the
    /// pill trading places in a mode change, the pill going into or out of
    /// the menu bar -- morphs the drawn shape from where it was, or fades on
    /// the spot where the window cannot show where it was (2026-10-28). The
    /// decision is told what is drawn either side and which display the
    /// shape was placed on, since a mode change moves the display's top.
    @discardableResult
    func reposition(metrics: ScreenMetrics) -> Bool {
        let anchor = anchor(for: metrics)
        let frame = panelFrame(on: metrics, anchor: anchor)
        let move = PanelMove.from(
            currentAnchor, frame: currentFrame,
            to: anchor, frame: frame,
            on: metrics.frame,
            reduceMotion: reduceMotion(),
            drawn: PanelMove.Drawn(
                before: drawnNow().offsetBy(dx: slidLag.dx, dy: slidLag.dy),
                after: visibleRect(anchor: anchor, frame: frame),
                display: shownDisplay ?? metrics.frame
            )
        )
        switch move {
        case .betweenDisplays(let trip) where panel != nil, .fadeInPlace(let trip) where panel != nil:
            let target = (anchor: anchor, frame: frame, display: metrics.frame)
            if handoffTarget != nil {
                handoffTarget = target
            } else {
                startHandoff(to: target, trip: trip)
            }
            return true
        case .stay:
            if handoffTarget != nil { callOffHandoff() }
            shownDisplay = metrics.frame
            return false
        case .slide(let slide) where panel != nil:
            if handoffTarget != nil { callOffHandoff() }
            shownDisplay = metrics.frame
            return self.slide(anchor: anchor, frame: frame, over: slide)
        case .morph(let morph) where panel != nil:
            if handoffTarget != nil { callOffHandoff() }
            shownDisplay = metrics.frame
            return self.morph(anchor: anchor, frame: frame, by: morph)
        case .inPlace, .betweenDisplays, .slide, .morph, .fadeInPlace:
            if handoffTarget != nil { callOffHandoff() }
            shownDisplay = metrics.frame
            return place(anchor: anchor, frame: frame)
        }
    }

    /// Puts the panel at `frame` now. The dedupe lives in the funnel, and
    /// the tracking rect re-syncs from the geometry observer.
    ///
    /// `morph`, when the shape is to morph there from where it was; `nil`
    /// draws it there at once, ending any morph under way.
    @discardableResult
    private func place(anchor: Anchor, frame: CGRect, morph: ShapeMorph? = nil) -> Bool {
        guard state.setGeometry(anchor: anchor, panelFrame: frame, morph: morph) else { return false }
        if isSliding, let panel {
            // A frame set on a window still sliding is undone by the
            // slide's next step; this ends it there.
            endSlide()
            panelSlider.stop(panel, at: frame)
        } else {
            panel?.setFrame(frame, display: true)
        }
        // A different display has its own current Space, which the watcher
        // only looks at when the active Space changes. Moved onto a display
        // showing a full-screen app, the panel sat on top of it; moved off
        // one, it stayed hidden on a normal desktop.
        fullScreenWatcher?.evaluate()
        return true
    }

    // MARK: - Moving between displays (2026-10-28)

    /// Fades the window out and in for a move between displays. Instant
    /// until the real launch swaps in `AnimatedPanelFader`, so a test that
    /// moves the panel need await nothing; a wiring test hands in a fake.
    var panelFader: PanelFader = InstantPanelFader()

    /// The system's Reduce Motion setting, read at each move: the trip then
    /// fades without the drop. A safe read, so the default is the real one;
    /// injected so a suite does not depend on the machine running it.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Where a trip is going while the panel fades out, or `nil`. Replaced,
    /// never queued: the last display asked for is the one it goes to.
    /// `display` is that display's frame, for `shownDisplay` on arrival.
    private var handoffTarget: (anchor: Anchor, frame: CGRect, display: CGRect)?

    /// Whether a trip is under way, fading out or in. While it is, the
    /// accepted region is empty.
    private var isHandingOff = false

    /// Counts trips, so a fade that a later one cut short does nothing when
    /// its completion arrives: never a move to a superseded display, never a
    /// region restored over a window fading out again.
    private var handoffGeneration = 0

    /// Whether the state changed during the trip, or shortly enough before
    /// it that the region was still trailing its spring, in which case that
    /// spring may still be growing the shape when the window has faded in.
    private var handoffSawStateChange = false

    private func startHandoff(to target: (anchor: Anchor, frame: CGRect, display: CGRect), trip: DisplayHandoff) {
        guard let panel else { return }
        handoffGeneration += 1
        let generation = handoffGeneration
        handoffTarget = target
        // A spring started before this trip may still be growing the shape
        // when the window has faded in: one that a trip cut short saw, or
        // one the region was trailing when this trip began. Read before the
        // shrink below empties the region, so arrival keeps the lag rather
        // than accepting a shape not yet drawn (2026-10-28, review of #79).
        handoffSawStateChange = isHandingOff
            ? handoffSawStateChange
            : area(of: visibleRect()) > area(of: acceptedRect)
        isHandingOff = true
        // Shrink now: from here until it has faded in there is nothing to
        // click where the region was, and nothing yet where it is going.
        syncTrackingRect()
        panelFader.fadeOut(panel, over: trip.fadeOut) { [weak self] in
            self?.handoffFadedOut(generation, trip: trip)
        }
    }

    /// Invisible now: move, take the new display's shape, fade in there.
    private func handoffFadedOut(_ generation: Int, trip: DisplayHandoff) {
        guard generation == handoffGeneration, let target = handoffTarget, let panel else { return }
        handoffTarget = nil
        shownDisplay = target.display
        place(anchor: target.anchor, frame: target.frame)
        panelFader.fadeIn(panel, over: trip.fadeIn, droppingFrom: trip.drop) { [weak self] in
            self?.handoffArrived(generation)
        }
    }

    /// Back where it still is before it left: fade in on the spot, without
    /// the drop, since it is not arriving from anywhere.
    private func callOffHandoff() {
        guard let panel else { return }
        handoffGeneration += 1
        let generation = handoffGeneration
        handoffTarget = nil
        let trip: DisplayHandoff = reduceMotion() ? .reduced : .standard
        panelFader.fadeIn(panel, over: trip.fadeIn, droppingFrom: 0) { [weak self] in
            self?.handoffArrived(generation)
        }
    }

    /// Faded in: grow the accepted region to the shape. At once, because the
    /// shape was drawn whole when the window moved -- unless the state
    /// changed meanwhile or just before, whose spring the growth lag waits
    /// for as always.
    ///
    /// Or unless the shape is still morphing (2026-10-28): a morph that
    /// called the trip off fades the window back in on the spot while the
    /// shape goes on its way, and the fade can be over first. The region is
    /// then what the two shapes share until the morph is (`morphEnded`).
    private func handoffArrived(_ generation: Int) {
        guard generation == handoffGeneration else { return }
        isHandingOff = false
        if handoffSawStateChange || state.morph != nil {
            syncTrackingRect()
        } else {
            growthTask?.cancel()
            growthTask = nil
            acceptRect(visibleRect())
        }
    }

    /// A fresh panel is built where it belongs and shown at once: whatever
    /// trip or slide the last one was on is over.
    private func forgetHandoff() {
        handoffGeneration += 1
        handoffTarget = nil
        isHandingOff = false
        endSlide()
        state.endMorph()
    }

    // MARK: - Sliding along the menu bar (2026-10-28)

    /// Slides the window along the menu bar. Instant until the real launch
    /// swaps in `AnimatedPanelSlider`, so a test that moves the pill need
    /// await nothing; a wiring test hands in a fake.
    var panelSlider: PanelSlider = InstantPanelSlider()

    /// Whether the window is on its way to `currentFrame`, so that a frame
    /// set on it now has to end the slide.
    private var isSliding = false

    /// Counts slides, so one that a later move replaced does nothing when
    /// its completion arrives -- AppKit calls it the moment it is replaced.
    private var slideGeneration = 0

    /// Takes the geometry at once and sends the window after it.
    ///
    /// The geometry first, as for any placement: the shape and the accepted
    /// region are panel-local and the same all the way along, so neither
    /// changes, and a second move is decided from where the pill is going.
    /// The window is not put anywhere here: the slider takes it from where
    /// it is, which during a slide already under way is somewhere along it.
    ///
    /// Full screen is checked as for any move: a screen change that slides
    /// the pill -- its display changing width -- counts on `reposition` to
    /// have looked, since it moved something.
    ///
    /// A morph under way goes on inside the window as it slides
    /// (2026-10-28): where the shape is in the window is the same all the
    /// way along, so where it morphs from is too.
    private func slide(anchor: Anchor, frame: CGRect, over slide: PanelSlide) -> Bool {
        guard let panel, state.setGeometry(anchor: anchor, panelFrame: frame, morph: state.morph) else { return false }
        slideGeneration += 1
        let generation = slideGeneration
        isSliding = true
        panelSlider.slide(panel, to: frame, over: slide.duration) { [weak self] in
            self?.slideEnded(generation)
        }
        fullScreenWatcher?.evaluate()
        return true
    }

    /// Arrived: on the frame exactly, whatever the last step rounded to, and
    /// the pointer read again. AppKit says nothing to a tracking area whose
    /// window moved under a still pointer, so a pill that slid out from under
    /// it would otherwise be hovered until the pointer next moved.
    private func slideEnded(_ generation: Int) {
        guard generation == slideGeneration else { return }
        endSlide()
        if let panel, panel.frame != currentFrame {
            panel.setFrame(currentFrame, display: true)
        }
        hoverView?.updateTrackingRect(acceptedRect)
    }

    private func endSlide() {
        slideGeneration += 1
        isSliding = false
    }

    // MARK: - Morphing on the spot (2026-10-28)

    /// Says when a morph is over. Instant until the real launch swaps in
    /// `AnimatedPanelMorpher`, so a test that changes the anchor need await
    /// nothing; a wiring test hands in a fake.
    var panelMorpher: PanelMorpher = InstantPanelMorpher()

    /// The clock a morph is timed on, in seconds: how far one has got when
    /// another change cuts it short. Injected so a test can stop it halfway.
    var mediaTime: () -> Double = { CACurrentMediaTime() }

    /// The frame of the display the shown geometry was placed on. A mode
    /// change moves the display's top under the shape, and where the shape
    /// was is where it was on its display (`PanelMove.Drawn.display`).
    private var shownDisplay: CGRect?

    /// Counts morphs, so that one a later change replaced does nothing when
    /// its time is up.
    private var morphCount = 0

    /// When the morph under way began, on `mediaTime`.
    private var morphStarted: Double = 0

    /// Places the panel and has the shape morph there from `morph.from`.
    ///
    /// The window is put on its new frame at once, as for any placement, and
    /// the geometry and the morph change together, so the first frame drawn
    /// in it is the old shape where it was. The accepted region is what the
    /// two shapes share until the morph is over (`syncTrackingRect`).
    private func morph(anchor: Anchor, frame: CGRect, by morph: AnchorMorph) -> Bool {
        morphCount += 1
        let shape = ShapeMorph(morph: morph, id: morphCount)
        let started = mediaTime()
        guard place(anchor: anchor, frame: frame, morph: shape) else { return false }
        morphStarted = started
        panelMorpher.morph(over: morph.duration) { [weak self] in
            self?.morphEnded(shape.id)
        }
        return true
    }

    /// Drawn whole: the region is the new shape at once, with no growth lag,
    /// since there is no spring left to wait for -- a state change during the
    /// morph ended it already, and left the region to that spring. A trip
    /// begun meanwhile keeps its empty region; it gives one back on arrival.
    private func morphEnded(_ id: Int) {
        guard state.morph?.id == id else { return }
        state.endMorph()
        guard !isHandingOff else { return }
        growthTask?.cancel()
        growthTask = nil
        acceptRect(visibleRect())
    }

    /// The shape as drawn now, panel-local: where a morph under way has got
    /// to by `mediaTime`, on the curve the view draws it on, or the resting
    /// shape. A second change halfway then morphs from where the shape is,
    /// not from where the first was going.
    private func drawnNow() -> CGRect {
        let resting = visibleRect()
        guard let morph = state.morph?.morph, morph.duration > 0 else { return resting }
        let progress = (mediaTime() - morphStarted) / morph.duration
        return AnchorMorph.rect(from: morph.from, to: resting, progress: progress)
    }

    /// How far the window is short of `currentFrame`: nothing, except part
    /// way through a slide, when the geometry is already the destination's
    /// and the window still on its way. What is drawn in it is drawn that
    /// much off where `currentFrame` would put it, and a morph cutting the
    /// slide short starts from there -- where the shape is on screen -- not
    /// from the end of a slide it never finished.
    private var slidLag: CGVector {
        guard isSliding, let panel else { return .zero }
        return CGVector(dx: panel.frame.minX - currentFrame.minX, dy: panel.frame.minY - currentFrame.minY)
    }
}
