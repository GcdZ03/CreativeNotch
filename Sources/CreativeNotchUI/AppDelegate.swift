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

    /// Exposed so tests can await the real re-evaluation instead of
    /// sleeping and hoping, exactly like `graceTask`.
    private(set) var peekTTLTask: Task<Void, Never>?

    // MARK: - Preferences

    /// Overridable so tests never read or write the real
    /// `com.gcdz.creativenotch` domain.
    ///
    /// **Required, not a convenience.** Once the activity fan-out routes
    /// through the switchboard, a wiring suite reading the developer's real
    /// defaults means a developer who switched media off in the actual app
    /// makes `lockingStopsTheMediaHelper` fail on their machine and nowhere
    /// else. Set it before `install(metrics:)`, exactly as `shelfDirectory`
    /// and `growthDelay` are.
    var preferencesDefaults: UserDefaults = .standard

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

    /// The global hotkey. Internal rather than private so the switchboard and
    /// the tests can reach its lifecycle, like every other controller.
    private(set) var hotkey: HotKeyController?

    /// The settings window's controller, built on first use by
    /// `showPreferences()`.
    private(set) var preferences: PreferencesController?

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
    var shelfDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CreativeNotch/Shelf")

    private(set) var shelf: ShelfStore?

    /// How the shelf copies a dropped file. Overridable, like
    /// `shelfDirectory`, so a test can decide when -- and whether -- a copy
    /// finishes. Set it before `install(metrics:)`.
    var shelfCopier: ShelfCopier = .system

    /// How long "Couldn't add …" stays under the shelf after a background
    /// copy fails. Long enough to read a file name; it is a report, not an
    /// offer, so nothing waits on it.
    static let defaultShelfNoticeDuration: Duration = .seconds(4)

    /// Overridable for the reason `shelfUndoWindow` is.
    var shelfNoticeDuration: Duration = AppDelegate.defaultShelfNoticeDuration

    /// The one-shot that withdraws the notice. Scheduled only by a failed
    /// copy, sleeps once, and is gone: `nil` whenever no notice is shown.
    private(set) var shelfNoticeTask: Task<Void, Never>?

    /// How long "Undo" stays on offer after the shelf is cleared.
    ///
    /// Long enough to notice a mistake and reach the button, short enough
    /// that the offer does not outlive the user's memory of what it undoes.
    static let defaultShelfUndoWindow: Duration = .seconds(6)

    /// Overridable so a test can watch the offer lapse without waiting six
    /// seconds, the same reason `growthDelay` is.
    var shelfUndoWindow: Duration = AppDelegate.defaultShelfUndoWindow

    /// What the last clear took, while it can still be undone.
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
    /// rules an add already follows, and a smaller clipboard forgets its
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
        shelf?.setLimits(
            capacity: limits.shelfCapacity,
            maxAge: limits.shelfExpiry.maxAge,
            now: Date(timeIntervalSince1970: now())
        )
        clipboard?.store.setCapacity(limits.clipboardCapacity)
        if limits.chime != previous.chime, limits.chime != .none {
            playChime(limits.chime)
        }
    }

    /// Clears the shelf and offers the clear back for `shelfUndoWindow`.
    ///
    /// The one path both the pane's Clear and the menu bar's Clear Shelf
    /// take, so either can be undone from the pane. Clear moves real files
    /// to the Trash; before the undo, getting one back meant finding it in
    /// Finder. A clear that fails partway still offers back what it did
    /// take. A new clear replaces the previous offer rather than merging
    /// with it: Undo undoes the clear just made.
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

    /// Puts back what the last clear took, if the offer has not lapsed.
    /// Items that cannot come back -- emptied from the Trash in the
    /// meantime -- are skipped by the store; the rest still return.
    func undoClearShelf() {
        guard let clearance = pendingShelfClearance else { return }
        withdrawShelfUndo()
        guard let restoration = shelf?.restore(clearance) else { return }
        if !restoration.skipped.isEmpty {
            NSLog("CreativeNotch: could not restore \(restoration.skipped.count) shelf item(s)")
        }
    }

    private func offerShelfUndo(_ clearance: ShelfClearance) {
        shelfUndoTask?.cancel()
        pendingShelfClearance = clearance
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

    /// A dropped file's background copy failed after the drop was accepted.
    ///
    /// Logged, and said under the shelf for `shelfNoticeDuration`. A second
    /// failure replaces the first line rather than queueing behind it.
    func reportShelfCopyFailure(_ item: ShelfItem, _ error: any Error) {
        NSLog("CreativeNotch: shelf could not copy \(item.displayName): \(error)")
        shelfNoticeTask?.cancel()
        state.shelfNotice = "Couldn't add \(item.displayName)"
        shelfNoticeTask = Task { @MainActor [weak self] in
            guard let duration = self?.shelfNoticeDuration else { return }
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.state.shelfNotice = nil
            self?.shelfNoticeTask = nil
        }
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

    public override init() { super.init() }

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
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
            shelfCount: { [weak self] in self?.shelf?.items.count ?? 0 },
            onClearClipboard: { [weak self] in self?.clipboard?.store.clear() },
            clipboardCount: { [weak self] in self?.clipboard?.store.entries.count ?? 0 },
            onUndoClearShelf: { [weak self] in self?.undoClearShelf() },
            canUndoClearShelf: { [weak self] in self?.state.canUndoShelfClear ?? false },
            onShowWelcome: { [weak self] in self?.showWelcomeAgain() }
        )
        menuBar.install()
        self.menuBar = menuBar

        // Observing is a lifecycle concern, not part of building the
        // panel: registering it from inside `install` meant it could be
        // registered more than once and never at a point where the tokens
        // had an owner.
        observeScreenChanges()

        startSubsystems()
    }

    /// The metrics of the screen "Show on" picks, or `nil` with no screen.
    ///
    /// The launch, a screen change, an activation and the preference itself
    /// all ask here, so the choice is made in one place. `NSScreen.main` is
    /// the screen holding the key window, and an accessory app launching may
    /// have none -- the panel was once never built, for the whole session --
    /// so the rule falls back to any screen (`DisplayChoice.screen(in:)`).
    /// Injected so a test can answer it without a real display.
    var screenMetrics: (DisplayChoice) -> ScreenMetrics? = { choice in
        NSScreen.chosen(by: choice)?.metrics
    }

    /// The metrics of the screen an app activation moves the panel to, or
    /// `nil` to leave it where it is (`DisplayChoice.screenOnActivation`).
    /// Separate from `screenMetrics` because an activation with no main
    /// screen is no news about focus and must not fall back to the first
    /// screen the way the launch does. Injected for the same reason.
    var activationScreenMetrics: (DisplayChoice) -> ScreenMetrics? = { choice in
        NSScreen.chosenOnActivation(by: choice)?.metrics
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

    /// The four actions the timer tab can take.
    ///
    /// Extracted so the switchboard can nil them when the timer is switched
    /// off and restore them when it comes back. `onChange` and `onFinished`
    /// are deliberately not among them: they are the publish and finish paths
    /// of a countdown that is allowed to outlive the toggle.
    func wireTimerActions() {
        state.onStartTimer = { [weak timer] duration in timer?.start(duration: duration) }
        state.onPauseTimer = { [weak timer] in timer?.pause() }
        state.onResumeTimer = { [weak timer] in timer?.resume() }
        state.onCancelTimer = { [weak timer] in timer?.cancel() }
    }

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

    public func applicationWillTerminate(_ notification: Notification) {
        fullScreenWatcher?.stop()
        fullScreenWatcher = nil
        fixedSpace?.tearDown()
        fixedSpace = nil
        removeScreenObservers()
        switchboard.stopAll()
        activity.stop()
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
                launchAtLogin: launchAtLogin
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
        let size = NotchGeometry
            .panelFrame(for: NotchGeometry.anchor(for: metrics), in: metrics)
            .size

        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: size))
        panel.onPanelKey = { [weak self] key in self?.handlePanelKey(key) ?? false }

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
            let screen = self.pointerLocation()
            return CGPoint(x: screen.x - self.currentFrame.minX, y: screen.y - self.currentFrame.minY)
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
        // not register a system-wide hotkey.
        let hotkey = HotKeyController(store: HotKeyStore(defaults: preferencesDefaults))
        hotkey.onTrigger = { [weak self] in self?.toggleFromHotKey() }
        self.hotkey = hotkey

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
            copier: shelfCopier
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

        state.onSetLimits = { [weak self] limits in self?.applyLimits(limits) }
        state.onClearClipboard = { [weak self] in self?.clipboard?.store.clear() }
        state.onRemoveClipboardEntry = { [weak self] id in self?.clipboard?.store.remove(id) }
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

        // Publishes into `AppState` for the power tab, and into the
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
            self.syncTrackingRect()
            if case .state(let newState) = change {
                self.syncDismissAffordances(for: newState)
                self.syncKeyWindow(for: newState)
                self.syncCameraVisibility(for: newState)
                self.tapIfOpening(newState)
            }
        }

        // Seeding is unconditional on purpose. `reposition` dedupes on the
        // geometry being unchanged, which is right for a screen change and
        // wrong here: a second `install` builds a *fresh* panel and hover
        // tracker whose frame and tracking rect are still zero, so
        // delegating to the deduping path left the new panel unpositioned
        // and the tracking rect empty -- no tracking area at all, and hover
        // silently dead. (Follow-up F1.)
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)
        state.setGeometry(anchor: anchor, panelFrame: frame)
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
        NotchShape.visibleRect(
            presentation: state.state.presentation,
            anchor: currentAnchor,
            panelFrame: currentFrame,
            badgeWidth: currentBadgeSlot.width,
            leadingBadgeWidth: currentBadgeSlot.leadingWidth
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
            at: Date()
        )
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
    func countdownDidChange(_ countdown: Countdown?) {
        state.countdown = countdown
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
        let screen = pointerLocation()
        let local = CGPoint(x: screen.x - currentFrame.minX, y: screen.y - currentFrame.minY)
        guard rect.contains(local) else { return }
        cancelDismissGrace()
        state.isHovering = true
        hoverView?.acknowledgePointerInside()
    }

    private func area(of rect: CGRect) -> CGFloat { rect.width * rect.height }

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
        state.hasBattery = true
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
        timerDone: Duration
    ) -> Duration {
        switch content {
        case .power:     return power
        case .timerDone: return timerDone
        // `.nowPlaying` and `.dragTarget` have no expiry of their own —
        // they end when the track stops or the drag does. The delay is
        // irrelevant for them; `reevaluatePeek` does not reschedule.
        case .nowPlaying, .dragTarget:
            return power
        }
    }

    private func schedulePeekReevaluation(for content: PeekContent) {
        let delay = Self.reevaluationDelay(
            for: content,
            power: powerTTLDelay,
            timerDone: timerDoneTTLDelay
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
            case .power, .timerDone: schedulePeekReevaluation(for: content)
            case .nowPlaying, .dragTarget: break
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
        guard let action = PanelKeyboard.action(for: key, in: state.state, visible: visible) else {
            return false
        }
        switch action {
        case .close:            state.transition(to: .closed)
        case .select(let tab):  state.transition(to: .open(tab))
        }
        return true
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
                self.activeApplicationDidChange()
            }
        }, NSWorkspace.shared.notificationCenter))
    }

    /// Another app came forward, so the focused window may be on another
    /// display. Following focus, the panel goes with it; pinned, it stays
    /// and the screen list is not even read -- an app switch is not a
    /// reason to look.
    func activeApplicationDidChange() {
        guard state.displayChoice.followsActivation,
              let metrics = activationScreenMetrics(state.displayChoice)
        else { return }
        reposition(metrics: metrics)
    }

    /// A display was connected, disconnected or rearranged: place the panel
    /// on whatever the choice picks from the screens there are now.
    func screenParametersDidChange() {
        guard let metrics = screenMetrics(state.displayChoice) else { return }
        screenParametersDidChange(metrics: metrics)
    }

    /// Saves and applies a new "Show on", then places the panel by it at
    /// once. `reposition` re-checks full screen when the panel moves, which
    /// is the only time the display it is on can have changed.
    func setDisplayChoice(_ choice: DisplayChoice) {
        preferencesStore.setDisplayChoice(choice)
        state.displayChoice = choice
        guard panel != nil, let metrics = screenMetrics(choice) else { return }
        reposition(metrics: metrics)
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
    /// Returns whether anything actually moved. `didActivateApplication`
    /// fires on every Cmd-Tab and `@Observable` does not dedupe equal
    /// assignments, so without the guard every app switch pushed a new
    /// frame and a new anchor and forced a redraw -- contradicting the
    /// rule that state transitions are the only thing that triggers one.
    @discardableResult
    func reposition(metrics: ScreenMetrics) -> Bool {
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)
        // The dedupe lives in the funnel now, and the tracking rect
        // re-syncs from the geometry observer.
        guard state.setGeometry(anchor: anchor, panelFrame: frame) else { return false }
        panel?.setFrame(frame, display: true)
        // A different display has its own current Space, which the watcher
        // only looks at when the active Space changes. Moved onto a display
        // showing a full-screen app, the panel sat on top of it; moved off
        // one, it stayed hidden on a normal desktop.
        fullScreenWatcher?.evaluate()
        return true
    }
}
