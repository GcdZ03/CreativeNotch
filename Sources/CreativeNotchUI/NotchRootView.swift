import SwiftUI
import CreativeNotchCore

/// The single funnel every derived value hangs off.
///
/// `state`, `anchor` and `panelFrame` are all `private(set)`: the hover
/// tracking rect, the hit-test region and the drawn shape are *derived*
/// from them, so every change has to be followed by a re-sync. Assigning
/// them directly left the tracking rect describing the previous
/// presentation — harmless for a hover-driven peek, fatal for a
/// programmatic state like `.receiving`, where a stale rect turns a drag
/// moving below the notch into a `mouseExited` that tears the drop target
/// down mid-drag.
@Observable
public final class AppState {

    public private(set) var state: NotchState = .closed

    /// Where the panel attaches on the current screen.
    public private(set) var anchor: CreativeNotchCore.Anchor = .pill(.zero)

    /// The window's frame. Needed alongside the anchor because the drawn
    /// rect and the hit-test rect are both panel-*local*.
    public private(set) var panelFrame: CGRect = .zero

    /// The tab the panel was last opened on.
    ///
    /// Reopening returns here rather than always to the shelf. Only
    /// `.open` touches it: HUD peeks fire constantly, and letting one
    /// reset the tab would move the panel out from under the user for
    /// reasons they never see.
    ///
    /// Qualified because SwiftUI has a `Tab` of its own, the same reason
    /// `anchor` spells out `CreativeNotchCore.Anchor`.
    public private(set) var lastOpenTab: CreativeNotchCore.Tab = .shelf

    /// What an observer is told about.
    public enum Change: Equatable, Sendable {
        case state(NotchState)
        case geometry(anchor: CreativeNotchCore.Anchor, panelFrame: CGRect)
    }

    public struct ObserverToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Set once at install.
    ///
    /// `@ObservationIgnored` because the store publishes its own changes —
    /// it is `@Observable`, so the view redraws from the store rather than
    /// from this reference, and re-assigning it must not invalidate a
    /// view.
    @ObservationIgnored
    public var shelf: ShelfStore?

    /// Set once at install, like `shelf`. `@ObservationIgnored` because
    /// the store publishes its own changes — it is `@Observable`, so the
    /// view redraws from the store rather than from this reference.
    @ObservationIgnored
    public var clipboard: ClipboardStore?

    /// How the view asks for an entry to be put back on the pasteboard.
    ///
    /// A closure rather than a `ClipboardController` reference, so the
    /// view layer never gains a way to start or stop the poller.
    @ObservationIgnored
    public var onPasteClipboard: ((ClipboardEntry) -> Void)?

    /// How the media buttons reach `MediaRemoteBridge`.
    ///
    /// A closure rather than calling the bridge from the view, for the
    /// same reason `onPasteClipboard` is one: it keeps a real transport
    /// command — which changes playback on the machine — out of anything
    /// a test constructs.
    @ObservationIgnored
    public var onMediaCommand: ((MediaCommand) -> Void)?

    /// How the timer tab reaches `TimerController`.
    ///
    /// Closures rather than a controller reference, for the same reason
    /// `onMediaCommand` is one: it keeps the scheduler — a thing that
    /// wakes the machine — out of anything a test or a preview
    /// constructs, and leaves the view layer no way to start or stop it
    /// beyond the four verbs below.
    @ObservationIgnored
    public var onStartTimer: ((TimeInterval) -> Void)?

    @ObservationIgnored
    public var onPauseTimer: (() -> Void)?

    @ObservationIgnored
    public var onResumeTimer: (() -> Void)?

    @ObservationIgnored
    public var onCancelTimer: (() -> Void)?

    /// Whether to show the media row at all.
    ///
    /// Set once at install from `MediaRemoteBridge.isAvailable`. Buttons
    /// that resolve to nothing would look identical to working ones and
    /// silently do nothing, which is worse than not offering them.
    ///
    /// Not `@ObservationIgnored`: unlike `shelf` / `clipboard`, which
    /// publish their own changes, this is a plain `Bool` that `body` reads
    /// directly — it needs Observation's tracking to invalidate the view
    /// if it is ever written again after install.
    public var showsMediaControls: Bool = false

    /// Whether this Mac has an internal battery.
    ///
    /// Set once at install from `PowerObserver.hasBattery`. Defaults to
    /// `false` so anything constructing a bare `AppState` — every test
    /// that does not care about power — gets the shape that shows less,
    /// rather than the one that promises a tab with nothing behind it.
    ///
    /// Not `@ObservationIgnored`: like `showsMediaControls`, it is a
    /// plain `Bool` that `body` reads directly and needs Observation's
    /// tracking if it is ever written after install.
    public var hasBattery: Bool = false

    /// Current power state, set by `PowerController`. Observable, like
    /// `nowPlaying`: a plain value the panel reads directly.
    public internal(set) var power: PowerSnapshot?


    /// Set by `MediaController`. Observable — unlike `shelf` and
    /// `clipboard`, which are `@Observable` stores that publish their own
    /// changes, this is a plain value the header reads directly.
    public internal(set) var nowPlaying: TrackSnapshot?
    public internal(set) var nowPlayingArtwork: Data?

    /// The observed storage behind `countdown`, whose entire job is to
    /// **not** be `Equatable`.
    ///
    /// Do not conform it, and do not collapse it back into a plain stored
    /// `Countdown?`. Swift's `@Observable` macro emits an equality guard in
    /// the generated setter of every `Equatable` stored property, so
    /// assigning a value equal to the one already there notifies nobody.
    /// For `nowPlaying` that is right and free: a `TrackSnapshot` renders
    /// identically whenever it compares equal, so a skipped redraw is a
    /// redraw that would have changed nothing.
    ///
    /// A countdown is the one value in this file where that reasoning
    /// fails. `TimerSchedule` wakes the controller at the exact instant
    /// `TimerDisplay.text` starts reading differently, and republishes a
    /// `Countdown` whose `target`, `duration` and `pausedRemaining` are all
    /// unchanged — because what changed is the wall clock, and the wall
    /// clock is not part of the value. `remaining(at:)` takes `now` as a
    /// parameter precisely so it is not. Under the compiler's guard, every
    /// one of those wakes is dropped: the timer keeps running, still fires
    /// on time, still chimes, still peeks — and the number in the ear stays
    /// frozen at whatever it read when the countdown started. No crash, no
    /// log line, and no failing test that asserts values rather than
    /// notifications.
    ///
    /// Routing the assignment through a non-`Equatable` box is what makes
    /// the mutation unconditional again.
    /// `TimerWiringTests.aDisplayChangeWakeStillReachesTheView` is what
    /// bites a change to any of this.
    private struct CountdownPublication {
        var countdown: Countdown?
    }

    private var countdownPublication = CountdownPublication(countdown: nil)

    /// Set by `TimerController`. Observable for the same reason
    /// `nowPlaying` is: a plain value that `body` reads directly, rather
    /// than an `@Observable` store that publishes its own changes.
    ///
    /// Computed over `countdownPublication` rather than stored — see that
    /// property for why the indirection is load-bearing and not
    /// ceremony. Reading here tracks the box, and writing replaces it, so
    /// callers and `body` see an ordinary property either way.
    public internal(set) var countdown: Countdown? {
        get { countdownPublication.countdown }
        set { countdownPublication = CountdownPublication(countdown: newValue) }
    }

    /// A list, not a single closure.
    ///
    /// It was one closure, which meant the second registration silently
    /// replaced the first. `AppDelegate` registers the tracking-rect
    /// re-sync and the outside-click monitor here, and every planned
    /// module will want its own — under the old shape the first of them to
    /// arrive would have taken both of those with it, at runtime, with no
    /// compiler help. (Follow-up F2.)
    ///
    /// `@ObservationIgnored` because it is wiring, not observable state:
    /// registering must never invalidate a SwiftUI view.
    @ObservationIgnored
    private var observers: [(token: ObserverToken, handler: (Change) -> Void)] = []

    public init() {}

    /// Registers `handler`, returning a token that removes it.
    @discardableResult
    public func observe(_ handler: @escaping (Change) -> Void) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        observers.append((token, handler))
        return token
    }

    /// How many handlers are registered. Exposed so a caller that
    /// re-registers (`AppDelegate.install`) can be shown not to stack.
    var observerCount: Int { observers.count }

    public func removeObserver(_ token: ObserverToken) {
        observers.removeAll { $0.token == token }
    }

    /// The only way `state` ever changes.
    ///
    /// Equal transitions are dropped: `@Observable` does not dedupe, and a
    /// redundant assignment would force a redraw for no visible difference.
    /// The derived rects are functions of the state, so skipping the
    /// callback for an unchanged state cannot leave them stale.
    public func transition(to next: NotchState) {
        guard next != state else { return }
        if case .open(let tab) = next { lastOpenTab = tab }
        state = next
        notify(.state(next))
    }

    /// The only way the geometry ever changes. Returns whether anything
    /// actually moved, so callers can skip the work that follows.
    @discardableResult
    public func setGeometry(
        anchor newAnchor: CreativeNotchCore.Anchor,
        panelFrame newFrame: CGRect
    ) -> Bool {
        guard newAnchor != anchor || newFrame != panelFrame else { return false }
        anchor = newAnchor
        panelFrame = newFrame
        notify(.geometry(anchor: newAnchor, panelFrame: newFrame))
        return true
    }

    private func notify(_ change: Change) {
        for observer in observers { observer.handler(change) }
    }
}

public struct NotchRootView: View {
    @Bindable var app: AppState

    /// The instant the badge slot is decided at, or `nil` to read the wall
    /// clock once per `body` evaluation.
    ///
    /// Threaded rather than read inside the view, the way every function in
    /// `CreativeNotchCore` takes its `now`: it is what lets a test pin the
    /// instant and prove the reserved width and the drawn content come from
    /// *one* reading of it. A second, unpinned read anywhere in `body` then
    /// shows up as a disagreement rather than as a race nobody can
    /// reproduce.
    ///
    /// Optional, and defaulted to `nil` rather than to `Date()`: a stored
    /// `Date` defaulted at initialisation would freeze the slot for the
    /// app's lifetime, because `AppDelegate` builds this view exactly once,
    /// at install. A countdown started an hour later would then never stop
    /// showing. `nil` keeps the live per-evaluation read.
    let now: Date?

    public init(app: AppState, now: Date? = nil) {
        self.app = app
        self.now = now
    }

    /// The drawn region, in the top-left-origin space SwiftUI lays out in.
    ///
    /// Derived from `NotchShape.visibleRect` — the same tested function the
    /// hit test uses — rather than from a second `switch` over the
    /// presentation. Two independent derivations of one rectangle is the
    /// exact shape of this project's only Critical bug. (Follow-up F5.)
    ///
    /// `badgeWidth` is handed straight to `visibleRect` rather than
    /// widening the result here: the badge grows the shape in exactly one
    /// place, which is the same place the hit test and the tracking rect
    /// read.
    static func drawnRect(
        state: NotchState,
        anchor: CreativeNotchCore.Anchor,
        panelFrame: CGRect,
        badgeWidth: CGFloat = 0
    ) -> CGRect {
        let visible = NotchShape.visibleRect(
            presentation: state.presentation,
            anchor: anchor,
            panelFrame: panelFrame,
            badgeWidth: badgeWidth
        )
        return CGRect(
            x: visible.minX,
            y: panelFrame.height - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    /// The drawn rect for a whole `AppState` — the derivation `body` uses,
    /// badge width and all, with the slot read here rather than handed in.
    ///
    /// Static and internal rather than a private computed property so a
    /// test can compare *this* against the region `AppDelegate` accepts
    /// clicks and hover in, without rendering a view. Comparing against a
    /// rect the test derives itself would only prove the test agrees with
    /// itself.
    ///
    /// `now` is defaulted rather than stored, so every call reads the clock
    /// afresh unless a caller pins it.
    static func drawnRect(for app: AppState, now: Date = Date()) -> CGRect {
        drawnRect(for: app, badge: badgeSlot(for: app, at: now))
    }

    /// The same derivation for a slot that has already been decided.
    ///
    /// `body` calls this one, passing the slot it also draws the content
    /// from, so the width the shape grows by and the badge that lands in
    /// it cannot come from two different readings of the clock.
    static func drawnRect(for app: AppState, badge slot: BadgeSlot) -> CGRect {
        drawnRect(
            state: app.state,
            anchor: app.anchor,
            panelFrame: app.panelFrame,
            badgeWidth: slot.width
        )
    }

    /// Which badge owns the trailing slot.
    ///
    /// `NotchShape.badgeSlot` rather than a second `isPlaying == true`
    /// here: `AppDelegate` asks the same function for the hit-test and
    /// hover rects, so the shape that is drawn and the shape that accepts
    /// clicks cannot disagree about whether the badge exists.
    ///
    /// An identity, not a width. The width alone cannot say *which* badge
    /// is showing without being compared against a constant — `> 0` would
    /// put the album cover inside the countdown's slot, and comparing
    /// against `nowPlayingBadgeWidth` would make two independent constants
    /// load-bearing as distinct values.
    ///
    /// Takes `now` rather than reading it. The same decision is read from
    /// three places — here, `AppDelegate.currentBadgeWidth`, and whatever
    /// `now` `drawnRect(for:now:)` is handed — so this view cannot claim to
    /// hold the only clock read, and an earlier version of this comment
    /// that said so was wrong. What it *can* guarantee is that `body` reads
    /// the clock at most once and hands that single value to everything
    /// below it: at the instant a timer finishes, two reads microseconds
    /// apart disagree, and the slot's width and its content would come from
    /// different answers.
    static func badgeSlot(for app: AppState, at now: Date) -> BadgeSlot {
        NotchShape.badgeSlot(
            countdown: app.countdown, nowPlaying: app.nowPlaying, at: now
        )
    }

    /// The horizontal band a centred peek has to leave empty, because on a
    /// notched Mac that band is the camera housing.
    ///
    /// One name for one value. `HUDView` and `NowPlayingPeekView` each
    /// spelled `anchor.isNotch ? anchor.rect.width : 0` out for
    /// themselves, two lines apart — and two independent derivations of a
    /// single value is the exact shape of this project's only Critical
    /// bug. (Follow-up F3.)
    ///
    /// Zero on a pill Mac and on external displays, where the middle of
    /// the band is ordinary screen and one centred line is correct.
    static func notchGap(for anchor: CreativeNotchCore.Anchor) -> CGFloat {
        anchor.isNotch ? anchor.rect.width : 0
    }

    /// The now-playing peek exactly as `body` builds it, arguments and all.
    ///
    /// `body` calls this instead of constructing the view inline so the
    /// arguments it passes can be read without rendering anything — the
    /// same reason `drawnRect(for:)` above is a static function.
    ///
    /// The gap it closes: `PeekRenderingTests` prove `NowPlayingPeekView`
    /// *honours* `notchGap`, but nothing proved this view *supplies* the
    /// right one — replacing the argument with `notchGap: 0` left the whole
    /// suite green. Proving it through a render is a trap, and a documented
    /// one (`PeekRenderingTests.peekViewPixels`, lines 51-58): switching
    /// the anchor to `.notch` changes the drawn panel shape as well as the
    /// content, so the two images differ whether or not the gap was
    /// honoured. Building the view here moves the argument somewhere a
    /// plain `#expect` can read it. (Follow-up F2.)
    ///
    /// Note what this does and does not bind. It pins the arguments; it
    /// does not pin that `body`'s `.peek(.nowPlaying)` case calls it. That
    /// a now-playing peek draws the peek at all is what the rendering
    /// tests cover, and they are the tests that caught C2.
    static func nowPlayingPeek(
        for app: AppState,
        track: TrackSnapshot
    ) -> NowPlayingPeekView {
        NowPlayingPeekView(
            track: track,
            artwork: app.nowPlayingArtwork,
            notchGap: notchGap(for: app.anchor)
        )
    }

    /// The power peek exactly as `body` builds it, arguments and all.
    ///
    /// Static for the same reason `nowPlayingPeek(for:track:)` is: it lets
    /// a test read the `notchGap` this view *supplies* without rendering.
    /// Proving the gap through a render is a documented trap — switching
    /// the anchor changes the drawn panel shape as well as the content, so
    /// the images differ whether or not the gap was honoured.
    static func powerPeek(for app: AppState, event: PowerEvent) -> PowerPeekView {
        PowerPeekView(event: event, notchGap: notchGap(for: app.anchor))
    }

    public var body: some View {
        // At most one clock read per evaluation, and none at all when the
        // instant was pinned. Everything below derives from this single
        // value: asking `badgeSlot` again for the content, or calling
        // `drawnRect(for:)` for the width, would read the clock again with
        // it.
        let instant = now ?? Date()
        let slot = Self.badgeSlot(for: app, at: instant)
        let drawn = Self.drawnRect(for: app, badge: slot)
        ZStack(alignment: .topLeading) {
            Color.clear
            shape(badge: slot, at: instant)
                .frame(width: drawn.width, height: drawn.height)
                .offset(x: drawn.minX, y: drawn.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: app.state)
    }

    /// Derived from `NotchShape.cornerRadii` — the same tested function
    /// that decides the drawn rect — rather than from a second `switch`
    /// here. Two independent derivations of one shape is the exact shape
    /// of this project's only Critical bug.
    private var backgroundShape: AnyShape {
        let r = NotchShape.cornerRadii(
            presentation: app.state.presentation,
            anchor: app.anchor
        )
        return AnyShape(UnevenRoundedRectangle(
            topLeadingRadius: r.topLeading,
            bottomLeadingRadius: r.bottomLeading,
            bottomTrailingRadius: r.bottomTrailing,
            topTrailingRadius: r.topTrailing
        ))
    }

    /// Takes the slot rather than reading it, so the content it draws and
    /// the width `body` grew the frame by are the same answer. Takes `now`
    /// for the same reason: the timer's text is `countdown.remaining(at:)`
    /// of *this* instant, not a fresh `Date()` — a second read here is
    /// exactly the divergence `theReservedWidthAndTheDrawnContentComeFrom
    /// OneClockRead` exists to catch.
    private func shape(badge slot: BadgeSlot, at now: Date) -> some View {
        backgroundShape
            .fill(.black)
            .overlay {
                switch app.state {
                case .closed:
                    // Trailing-aligned, so it lands exactly in the region
                    // `visibleRect` grew for it on a notch — and inside
                    // the pill's own trailing edge on a notchless Mac,
                    // where nothing grew because nothing had to.
                    //
                    // The timer outranks media here for the same reason it
                    // outranks it in `NotchShape.badgeSlot`: one rule,
                    // spelled once. If these two disagreed, the slot would
                    // be sized for one badge and filled with the other —
                    // `aRunningTimerKeepsTheAlbumCoverOutOfTheSlot` is the
                    // test that bites that mistake.
                    switch slot {
                    case .timer:
                        if let countdown = app.countdown {
                            TimerBadgeView(
                                text: TimerDisplay.text(remaining: countdown.remaining(at: now)),
                                isPaused: countdown.isPaused
                            )
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .trailing
                            )
                        } else {
                            EmptyView()
                        }
                    case .nowPlaying:
                        NowPlayingBadgeView(artwork: app.nowPlayingArtwork)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .trailing
                            )
                    case .none:
                        EmptyView()
                    }

                case .open(let tab):
                    VStack(spacing: 0) {
                        mediaBar
                        PanelTabBar(
                            selected: tab,
                            hasBattery: app.hasBattery
                        ) { app.transition(to: .open($0)) }
                        // `at: now` keeps the tab on the single instant
                        // `body` already bound, rather than taking a
                        // second clock read for the countdown.
                        openContent(for: tab, at: now)
                    }
                    // Top-aligned, but *below the anchor* — not at the
                    // panel's absolute top. `panelFrame` puts the panel's
                    // top edge at `anchor.rect.maxY`, so its first band is
                    // the hardware notch (or, on a pill Mac, the menu bar
                    // it sits under). Pinning to the true top hid the media
                    // row behind the notch entirely while leaving the tab
                    // bar just low enough to still show — the panel looked
                    // like the module had not shipped.
                    .padding(.top, app.anchor.rect.height)
                    .frame(maxHeight: .infinity, alignment: .top)

                case .receiving:
                    Text("Drop here")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))

                case .peek(.hud(let event)):
                    HUDView(
                        kind: event.kind,
                        notchGap: Self.notchGap(for: app.anchor)
                    )

                // A peek is a glance, not a panel: one truncating line,
                // plus a 16pt cover when there is one to show.
                //
                // Artwork here was a stated non-goal in section 10 of the
                // spec, reversed on the user's request after they saw the
                // shipped panel. The spec is amended rather than silently
                // contradicted: see "Reversed after the fact" there. Its
                // stated reason — that the cache can legitimately be empty
                // when a peek fires — is answered by
                // `NowPlayingPeekView.cover`, which in that case draws
                // nothing at all rather than a placeholder tile.
                //
                // Without this case the state fell through to `default`
                // and drew the literal string "CreativeNotch" over playing
                // music — the ambient peek this whole module exists for
                // was never once drawn. Text comes from
                // `NowPlayingLabel.text(for:)`, the same function the
                // panel header uses, so the two cannot drift apart.
                // A real case rather than a fall-through to `default`.
                // That fall-through is bug C2: `.peek(.nowPlaying)` hit
                // `default` and drew the literal string "CreativeNotch"
                // over playing music for a whole module's development.
                case .peek(.power(let event)):
                    Self.powerPeek(for: app, event: event)

                case .peek(.nowPlaying(let track)):
                    // Same notch-gap treatment `HUDView` gets above, from
                    // the same named function: on a notched Mac the middle
                    // of this band is the camera housing, and a centred
                    // line renders straight behind it. Built by
                    // `nowPlayingPeek(for:track:)` rather than inline so a
                    // test can read the arguments without rendering — see
                    // its doc comment.
                    Self.nowPlayingPeek(for: app, track: track)

                // Same notch-gap treatment the other peeks get: a finished
                // timer's text must not be drawn behind the camera housing
                // either. Named explicitly rather than left to `default`
                // below, for the same reason `.peek(.nowPlaying)` above is:
                // an unhandled `PeekContent` case falling through `default`
                // is exactly how this project's only Critical bug shipped.
                case .peek(.timerDone(let completion)):
                    TimerDonePeekView(
                        completion: completion,
                        notchGap: app.anchor.isNotch ? app.anchor.rect.width : 0
                    )

                default:
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .onTapGesture {
                // Through the funnel, like every other mutation.
                switch app.state {
                case .open:  app.transition(to: .closed)
                default:     app.transition(to: .open(app.lastOpenTab))
                }
            }
    }

    /// What is playing, and the controls for it, as ONE full-width bar.
    ///
    /// They were previously two rows: a left-aligned header above centred
    /// buttons. That put two alignment systems in one panel, left the whole
    /// right half of the header empty, and floated the transport controls
    /// away from the track they operate on. A bar that spans the panel does
    /// not read as "left-aligned" at all, so the centred tab bar below it
    /// sits in a different register rather than in conflict.
    ///
    /// The divider is structure, not decoration: above it is what is
    /// playing now, below it is what you have stored. Two different
    /// concerns, and the panel is small enough that the seam has to be
    /// stated rather than implied by space.
    @ViewBuilder
    private var mediaBar: some View {
        let hasMedia = app.nowPlaying != nil || app.showsMediaControls

        if hasMedia {
            HStack(spacing: 12) {
                if let nowPlaying = app.nowPlaying {
                    NowPlayingView(snapshot: nowPlaying, artwork: app.nowPlayingArtwork)
                }

                // Keeps the controls hard right when a track is showing,
                // and lets them sit centred on their own when nothing is
                // playing — the helper may be starting, degraded, or the
                // machine simply silent, and transport still works in all
                // three.
                Spacer(minLength: 12)

                if app.showsMediaControls {
                    MediaControlsView { app.onMediaCommand?($0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()
                .overlay(.white.opacity(0.10))
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func openContent(for tab: CreativeNotchCore.Tab, at now: Date) -> some View {
        switch tab {
        case .shelf:
            if let shelf = app.shelf { ShelfView(store: shelf) }
        case .clipboard:
            if let clipboard = app.clipboard {
                ClipboardView(store: clipboard) { entry in
                    app.onPasteClipboard?(entry)
                }
            }
        case .hud:
            // Not built. `PanelTabBar.visible` does not offer this tab, so
            // it is unreachable — but `Tab` is exhaustive and the compiler
            // wants a case.
            EmptyView()
        case .timer:
            // Through `AppState`, never to a controller this view holds —
            // the same routing `onPasteClipboard` and `onMediaCommand`
            // use. Optional-chained, so a state nobody wired (a preview,
            // a test) renders the tab and does nothing rather than
            // trapping.
            TimerTabView(
                countdown: app.countdown,
                now: now,
                onStart: { app.onStartTimer?($0) },
                onPause: { app.onPauseTimer?() },
                onResume: { app.onResumeTimer?() },
                onCancel: { app.onCancelTimer?() }
            )

        case .power:
            PowerView(snapshot: app.power)
        }
    }

    private var label: String {
        switch app.state {
        case .closed:          return ""
        case .peek:            return "CreativeNotch"
        case .open(let tab):   return tab.rawValue.capitalized
        case .receiving:       return "Drop here"
        }
    }
}
