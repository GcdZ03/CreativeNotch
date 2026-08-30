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
    private let onboarding = OnboardingController()

    // MARK: - HUD (F8)

    private var hud: HUDController?

    /// Internal rather than private so the peek wiring is provable — the
    /// same reason `hud`, `clipboard` and `activity` are internal.
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
    var playChime: () -> Void = TimerChime.play

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

    /// How long the HUD occupies the peek slot before this re-checks the
    /// arbiter. Mirrors `PeekArbiter.hudTTL`.
    public static let defaultHUDTTLDelay: Duration = .milliseconds(1500)

    /// Overridable so tests need not wait out the real 1.5 seconds.
    var hudTTLDelay: Duration = AppDelegate.defaultHUDTTLDelay

    /// How long a power peek occupies the slot before this re-checks the
    /// arbiter. Mirrors `PeekArbiter.powerTTL`.
    public static let defaultPowerTTLDelay: Duration = .milliseconds(3000)

    /// Overridable for the same reason `hudTTLDelay` is.
    var powerTTLDelay: Duration = AppDelegate.defaultPowerTTLDelay

    /// How long a finished-timer peek occupies the slot before this
    /// re-checks the arbiter. Mirrors `PeekArbiter.timerDoneTTL`.
    ///
    /// Three orders of magnitude longer than the others, and deliberately:
    /// the HUD and power peeks expire so the slot returns to ambient
    /// content, while this one is only a backstop for a completion nobody
    /// acknowledged. Dismissing it is what normally clears it.
    public static let defaultTimerDoneTTLDelay: Duration = .seconds(600)

    /// Overridable for the same reason `hudTTLDelay` is — a test must not
    /// wait out ten minutes.
    var timerDoneTTLDelay: Duration = AppDelegate.defaultTimerDoneTTLDelay

    /// Exposed so tests can await the real re-evaluation instead of
    /// sleeping and hoping, exactly like `graceTask`.
    private(set) var hudTTLTask: Task<Void, Never>?

    // MARK: - Shelf

    /// Overridable so tests do not write into the real Application Support.
    var shelfDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CreativeNotch/Shelf")

    private(set) var shelf: ShelfStore?

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
    public static let defaultGrowthDelay: Duration = .milliseconds(320)

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
        if let screen = NSScreen.main {
            install(metrics: screen.metrics)
            // Presentation is deliberately *not* part of `install` -- that
            // keeps the wiring path testable without putting a window on
            // screen.
            panel?.orderFrontRegardless()
        }

        let menuBar = MenuBarController(
            onShowOnboarding: { [weak self] in self?.showOnboarding() },
            onClearShelf: { [weak self] in try? self?.shelf?.clear() },
            shelfCount: { [weak self] in self?.shelf?.items.count ?? 0 },
            onClearClipboard: { [weak self] in self?.clipboard?.store.clear() },
            clipboardCount: { [weak self] in self?.clipboard?.store.entries.count ?? 0 }
        )
        menuBar.install()
        self.menuBar = menuBar

        // Observing is a lifecycle concern, not part of building the
        // panel: registering it from inside `install` meant it could be
        // registered more than once and never at a point where the tokens
        // had an owner.
        observeScreenChanges()

        onboarding.showIfNeeded()

        let hud = HUDController { [weak self] kind in self?.showHUD(kind) }
        hud.start()
        self.hud = hud

        activity.start()
        clipboard?.start()
        media?.start()
        power?.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        removeScreenObservers()
        hud?.stop()
        clipboard?.stop()
        media?.stop()
        power?.stop()
        activity.stop()
    }

    public func showOnboarding() {
        onboarding.show()
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

        let host = HitTestingHostingView(rootView: NotchRootView(app: state))
        host.visibleRectProvider = { [weak self] in self?.acceptedRect ?? .zero }

        let hover = HoverTracker(frame: CGRect(origin: .zero, size: size))
        hover.autoresizingMask = [.width, .height]
        hover.onEnter = { [weak self] in self?.cancelDismissGrace() }
        hover.onDwell = { [weak self] in self?.peek() }
        hover.onExit  = { [weak self] in self?.collapse() }

        let container = PassthroughContainer(frame: CGRect(origin: .zero, size: size))

        // Purged on launch and after each add — never on a timer.
        shelf = try? ShelfStore(directory: shelfDirectory)
        _ = try? shelf?.purge(now: Date())
        state.shelf = shelf

        // The ring is created here rather than at launch so the wiring
        // path is testable without putting a window on screen, exactly as
        // the shelf is. Starting the poller stays in
        // `applicationDidFinishLaunching` — building a panel must not
        // install a timer.
        let clipboardStore = ClipboardStore()
        let clipboard = ClipboardController(store: clipboardStore)
        state.clipboard = clipboardStore
        state.onPasteClipboard = { [weak clipboard] entry in clipboard?.paste(entry) }
        self.clipboard = clipboard

        // Spec section 4.7: the sleep/lock gate is enforced once, here, and
        // fanned out to every consumer — never registered a second time
        // inside a module. Adding a second consumer later is a one-line
        // addition to this closure, not a second observer.
        activity.onChange = { [weak self] state in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            self.clipboard?.setActivity(state, now: now)
            self.media?.setActivity(state)

            // The timer is deliberately NOT suspended here the way the
            // poller and the helper above are, and the difference is the
            // point rather than an oversight. Their output is only worth
            // producing while somebody can see it, so outside `.active`
            // they stop. A timer's whole purpose is to fire while nobody
            // is watching: `setActive` changes only how often it wakes to
            // *redraw* the ear — see `TimerSchedule.nextWake`, where
            // inactive schedules the deadline itself and nothing before
            // it. It never changes whether the deadline fires. Three
            // subsystems on one fan-out with one deliberately different
            // behaviour is exactly the shape a later "consistency fix"
            // breaks, so: do not make this a `stop()`.
            self.timer?.setActive(state == .active)

            // The promised one-line addition. Note what it does *not* do:
            // `PowerController.setActivity` suppresses peeks and leaves
            // the observer running, because a notification-driven source
            // costs nothing idle and suspending it would mean missing the
            // charger moving while the lid is shut.
            self.power?.setActivity(state)
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
        // reason `onPasteClipboard` above captures its controller weakly.
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
        // `onPasteClipboard` and `onMediaCommand`. `[weak timer]` rather
        // than `[weak self]`: `AppState` outlives nothing here, but the
        // closures are held by the state which the delegate owns, and the
        // delegate owns the controller — capturing it strongly would close
        // the cycle.
        state.onStartTimer = { [weak timer] duration in timer?.start(duration: duration) }
        state.onPauseTimer = { [weak timer] in timer?.pause() }
        state.onResumeTimer = { [weak timer] in timer?.resume() }
        state.onCancelTimer = { [weak timer] in timer?.cancel() }

        self.timer = timer

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
        // Read once: a machine does not grow a battery, and a tab that
        // opens onto three meaningless rows is worse than no tab.
        state.hasBattery = power.hasBattery

        // No object to own: `MediaRemoteBridge` is stateless beyond its
        // cached handle, and there is nothing to start or stop. Unlike the
        // HUD and clipboard controllers it needs no lifecycle hook in
        // `applicationDidFinishLaunching` or `applicationWillTerminate` —
        // a command is sent only because a button was clicked.
        state.showsMediaControls = MediaRemoteBridge.isAvailable
        state.onMediaCommand = { command in MediaRemoteBridge.send(command) }

        container.onDragEntered = { [weak self] in
            self?.arbiter.setDragActive(true)
            self?.state.transition(to: .receiving)
        }
        container.onDragExited = { [weak self] in
            self?.arbiter.setDragActive(false)
            self?.state.transition(to: .closed)
        }
        container.onDrop = { [weak self] payloads in
            guard let self, let shelf = self.shelf else {
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
            self.state.transition(to: .open(.shelf))
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
            badgeWidth: currentBadgeWidth
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
    var currentBadgeWidth: CGFloat {
        NotchShape.badgeSlot(
            countdown: state.countdown, nowPlaying: state.nowPlaying, at: Date()
        ).width
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
        arbiter.recordTimerFinished(
            TimerCompletion(duration: countdown.duration, lateness: max(0, lateness)),
            now: self.now()
        )
        playChime()
        // The existing peek path, not a second one: it already declines to
        // interrupt `.open` and `.receiving`, and it is what makes the
        // arbiter — rather than this caller — decide what is shown.
        presentPeek()
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
    }

    private func area(of rect: CGRect) -> CGFloat { rect.width * rect.height }

    // MARK: - Hover

    /// The dwell opened the notch. What it shows is the arbiter's call.
    private func peek() {
        presentPeek()
    }

    /// A level changed and the HUD decided it is worth showing.
    ///
    /// Internal rather than private: the test target reaches it through
    /// `@testable import` to drive the funnel without a real hardware
    /// change.
    func showHUD(_ kind: HUDKind) {
        presentPeek(recording: kind)
    }

    /// Current power state into the panel.
    ///
    /// A method rather than a closure body so a test can drive the real
    /// publish path without an IOKit callback — the same reason
    /// `nowPlayingDidChange` is one.
    func powerDidChange(_ snapshot: PowerSnapshot) {
        state.power = snapshot
        // `hasBattery` is set at install, but the first snapshot is the
        // first proof there is one. A machine whose battery reads as
        // absent at launch and present a moment later would otherwise
        // never show the tab.
        state.hasBattery = true
    }

    /// A power event into the peek slot.
    ///
    /// Recorded into the arbiter and then *asked* what to show, never
    /// shown directly — priority against a HUD peek or a drag is the
    /// arbiter's call alone, exactly as it is for `showHUD`.
    func showPowerPeek(_ event: PowerEvent) {
        let now = self.now()
        arbiter.recordPower(event, now: now)
        presentPeek()
    }

    /// The only path to a `.peek` state.
    ///
    /// `.open` and `.receiving` are deliberate user states -- a passing
    /// volume change, or a hover dwell that lands mid-drag, must not
    /// destroy them. Whatever `kind` names is recorded into the arbiter
    /// first, but what is actually shown is whatever the arbiter then
    /// decides, never `kind` directly: priority among drag, HUD and
    /// now-playing is the arbiter's call alone, not the caller's.
    private func presentPeek(recording kind: HUDKind? = nil) {
        let now = self.now()
        if let kind {
            arbiter.recordHUD(HUDEvent(kind: kind), now: now)
        }

        switch state.state {
        case .open, .receiving:
            return
        case .closed, .peek:
            break
        }

        guard let content = arbiter.content(now: now) else { return }
        state.transition(to: .peek(content))
        schedulePeekReevaluation(for: content)
    }

    /// Re-reads the arbiter once the showing content's TTL is expected to
    /// have elapsed, and transitions to whatever it now says -- `.closed`
    /// if nothing. Mirrors `startDismissGrace`: cancel-and-replace, and
    /// exposed as `hudTTLTask` so tests can await it instead of sleeping.
    ///
    /// The delay follows the content, which it did not have to before this
    /// module: with one TTL in the app, one constant was the whole story.
    /// A power peek lives twice as long as a HUD one, so a fixed 1.5s
    /// re-check would fire while the power peek was still live, find the
    /// arbiter still returning it, transition to the state it was already
    /// in — and never look again. The notch would stay open until some
    /// unrelated event moved it.
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
        hud: Duration,
        power: Duration,
        timerDone: Duration
    ) -> Duration {
        switch content {
        case .hud:       return hud
        case .power:     return power
        case .timerDone: return timerDone
        // `.nowPlaying` and `.dragTarget` have no expiry of their own —
        // they end when the track stops or the drag does. The delay is
        // irrelevant for them; `reevaluatePeek` does not reschedule.
        case .nowPlaying, .dragTarget:
            return hud
        }
    }

    private func schedulePeekReevaluation(for content: PeekContent) {
        let delay = Self.reevaluationDelay(
            for: content,
            hud: hudTTLDelay,
            power: powerTTLDelay,
            timerDone: timerDoneTTLDelay
        )

        hudTTLTask?.cancel()
        hudTTLTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.reevaluatePeek()
        }
    }

    /// Only acts while still `.peek`: if the user has since opened the
    /// panel or started a drag, that is a deliberate state this stale
    /// check must not disturb.
    private func reevaluatePeek() {
        guard case .peek = state.state else { return }
        if let content = arbiter.content(now: self.now()) {
            state.transition(to: .peek(content))
            // Something transient may still be live underneath the one
            // that just lapsed — a HUD peek fired while a power peek was
            // showing expires first and reveals it. Without this the
            // revealed peek would never be re-checked. It terminates
            // because every transient source strictly expires; ambient
            // content reached here simply stays until its own source
            // changes.
            switch content {
            case .hud, .power, .timerDone: schedulePeekReevaluation(for: content)
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
    /// Takes keyboard focus only for the one tab that accepts typing.
    ///
    /// The panel *can* become key (see `NotchPanel`), but it should not do
    /// so casually: while it holds focus, whatever you were writing in
    /// loses its insertion point. Peeks are ambient and frequent, and the
    /// shelf and clipboard tabs are click-only, so none of them touch it.
    ///
    /// `resignKey` rather than a stored "previous window": AppKit returns
    /// key to whoever had it, and tracking that ourselves would be a second
    /// derivation of state the window server already owns.
    ///
    /// Deliberately keyed on the *tab*, not on `.open`. Making every open
    /// steal the cursor would be a regression for the three surfaces that
    /// never needed it.
    /// Pure, so the rule is testable without a window server — `makeKey`
    /// on an offscreen panel in a headless suite proves nothing.
    static func shouldTakeKey(for state: NotchState) -> Bool {
        if case .open(.timer) = state { return true }
        return false
    }

    func syncKeyWindow(for newState: NotchState) {
        guard let panel else { return }
        if Self.shouldTakeKey(for: newState) {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
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
        // it — and it outranks the HUD, so volume feedback would be
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

    private func startDismissGrace() {
        graceTask?.cancel()
        graceTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
            guard let self, let screen = NSScreen.main else { return }
            MainActor.assumeIsolated { _ = self.reposition(metrics: screen.metrics) }
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
                if let screen = NSScreen.main {
                    _ = self.reposition(metrics: screen.metrics)
                }
            }
        }, NSWorkspace.shared.notificationCenter))
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
        return true
    }
}
