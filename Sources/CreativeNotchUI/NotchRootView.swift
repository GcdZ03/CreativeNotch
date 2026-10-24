import SwiftUI
@preconcurrency import AVFoundation
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
    /// `.open` touches it: peeks fire unprompted, and letting one reset the
    /// tab would move the panel out from under the user for reasons they
    /// never see.
    ///
    /// Qualified because SwiftUI has a `Tab` of its own, the same reason
    /// `anchor` spells out `CreativeNotchCore.Anchor`.
    public private(set) var lastOpenTab: CreativeNotchCore.Tab = .shelf

    /// Why the panel is open, or `nil` when it is not.
    ///
    /// Written by `transition(to:openedBy:)` alongside `state`, so the two
    /// cannot disagree: recorded on the change *into* `.open`, kept across a
    /// tab switch (still the same open), cleared the moment the panel leaves.
    /// A later hover-open therefore cannot inherit an earlier tap's right to
    /// the keyboard. Read by `AppDelegate.syncKeyWindow` through
    /// `PanelFocus`, from inside the funnel's own notification.
    ///
    /// Also decides whether the welcome card shows (`showsWelcome`).
    /// `@ObservationIgnored` all the same: an open's reason changing only
    /// ever coincides with `state` changing, which already redraws.
    @ObservationIgnored
    public private(set) var openReason: PanelOpenReason?

    /// Whether the last state change grew the panel, so the view can pick
    /// a bouncy spring for growing and a snappy one for shrinking (spec
    /// 2026-10-15). Set by `transition(to:)` alongside `state`, so the two
    /// cannot describe different changes.
    ///
    /// One peek replacing another counts as growing: it is a swap, not a
    /// collapse.
    public private(set) var lastChangeGrew: Bool = true

    /// Whether the cursor is over the notch, for the drawn-only hover
    /// reaction (`NotchRootView.hoverInflated`).
    ///
    /// Visual only, and deliberately outside the funnel: nothing derived
    /// from it reaches the hit test or the tracking rect, which is what
    /// lets it change without a re-sync.
    public internal(set) var isHovering: Bool = false

    /// How far a two-finger swipe has pulled the shape: positive toward
    /// opening, negative toward closing, 1 at the commit threshold
    /// (`NotchSwipe.pull`). Visual only, like `isHovering`: the accepted
    /// region does not follow it.
    public internal(set) var pullProgress: CGFloat = 0

    /// What resting on the notch does: peek (the default), or open the
    /// panel after a delay (2026-10-17). Applied by `onSetHoverBehaviour`.
    public internal(set) var hoverBehaviour = HoverBehaviour()

    /// Saves and applies a new hover behaviour in one call, so Settings
    /// cannot do one without the other. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onSetHoverBehaviour: ((HoverBehaviour) -> Void)?

    /// Which display the notch lives on (2026-10-24). Applied by
    /// `onSetDisplayChoice`; read by the activation and screen-change paths
    /// each time they fire, so a change needs nothing re-registered.
    public internal(set) var displayChoice: DisplayChoice = .default

    /// Saves the choice, applies it and moves the panel in one call, so
    /// Settings cannot do one without the others. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onSetDisplayChoice: ((DisplayChoice) -> Void)?

    /// How large the open panel's text is (2026-10-24). Applied by
    /// `onSetTextSize`, which also resizes the panel to fit it; the view reads
    /// it on every draw, so a change needs nothing re-registered.
    public internal(set) var textSize: TextSize = .default

    /// The scale the open panel actually draws at: `textSize.scale`, brought
    /// down to what the panel's frame holds on a screen too small for the
    /// full factor (`NotchGeometry.fittedTextScale`), fitted against the
    /// nominal width the frame was built from ("Panel width",
    /// `NotchGeometry.nominalPanelWidth`) -- the default's would read a
    /// Compact frame as too small and shrink its text.
    ///
    /// Read from the frame rather than stored beside it, so the two cannot
    /// disagree: `panelFrame` was built from the same fitted scale, and the
    /// fit is a fixed point, so asking it of the frame gives that scale
    /// back. Before any geometry arrives there is no frame to fit, and the
    /// setting is used as it is.
    public var textScale: CGFloat {
        guard !panelFrame.isEmpty else { return textSize.scale }
        let nominalWidth = NotchGeometry.nominalPanelWidth(
            for: anchor,
            width: layoutOptions.width,
            tabCount: TabVisibility.visible(enabled: preferences, hasBattery: hasBattery).count
        )
        return NotchGeometry.fittedTextScale(textSize.scale, within: panelFrame.size, nominalWidth: nominalWidth)
    }

    /// Saves the size, applies it and resizes the panel in one call, so
    /// Settings cannot do one without the others. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onSetTextSize: ((TextSize) -> Void)?

    /// The panel's width, corners, tab side, header battery and closed-notch
    /// badges (2026-10-24). Applied by `onSetLayoutOptions`, which also
    /// resizes the panel for a new width and re-syncs the accepted region for
    /// a badge shown or hidden; the view reads it on every draw, so a change
    /// needs nothing re-registered.
    public internal(set) var layoutOptions: LayoutOptions = .default

    /// Saves the options, applies them and re-places the panel in one call,
    /// so Settings cannot do one without the others. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onSetLayoutOptions: ((LayoutOptions) -> Void)?

    /// The displays connected when last asked, for the "Show on" menu's
    /// per-display entries. Refreshed by `onRefreshDisplays` when Settings is
    /// shown and on every screen-parameter change -- never polled, and never
    /// read by the placement rule, which asks `NSScreen` afresh each time.
    public internal(set) var connectedDisplays: [ScreenDescriptor] = []

    /// Re-reads `connectedDisplays`. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onRefreshDisplays: (() -> Void)?

    /// The shelf's, clipboard's and timer's adjustable numbers (2026-10-24).
    /// Applied by `onSetLimits`; the timer tab draws its presets from here.
    public internal(set) var limits = Limits()

    /// Saves and applies new limits in one call — to the stores as well as
    /// here — for the reason `onSetHoverBehaviour` does both. Wired by
    /// `AppDelegate`.
    @ObservationIgnored
    public var onSetLimits: ((Limits) -> Void)?

    /// What `onSetLimits` would take off the shelf, without applying
    /// anything — so Settings can ask before a lowered limit trashes files.
    /// Wired by `AppDelegate`; unwired, nothing would be taken.
    @ObservationIgnored
    public var onPreviewLimits: ((Limits) -> ShelfLimitRemoval)?

    /// Whether a timer finishing behind a full-screen app also posts a
    /// notification (2026-10-24). Applied by `onSetTimerNotifyWhenHidden`;
    /// read by `AppDelegate.timerDidFinish` at the moment it fires.
    public internal(set) var timerNotifyWhenHidden = true

    /// Saves and applies the switch in one call, for the reason
    /// `onSetHoverBehaviour` does both. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onSetTimerNotifyWhenHidden: ((Bool) -> Void)?

    /// What macOS allows the timer's notification, as last asked. Read when
    /// Settings is shown (`onRefreshTimerNotices`), never polled, so the line
    /// under the switch can say when notifications are off.
    public internal(set) var timerNoticeAuthorization: TimerNoticeAuthorization = .allowed

    /// Re-reads `timerNoticeAuthorization`. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onRefreshTimerNotices: (() -> Void)?

    /// Bundle identifiers whose copies clipboard history ignores
    /// (2026-10-24). Applied by `onSetClipboardExcludedApps`; the poller asks
    /// for it at each detected change, so an edit applies to the next copy.
    public internal(set) var clipboardExcludedApps: [String] = []

    /// Saves and applies the list in one call. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onSetClipboardExcludedApps: (([String]) -> Void)?

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
    public var onCopyClipboard: ((ClipboardEntry) -> Void)?

    /// The pane's title-row verbs. Closures, like `onCopyClipboard`, so the
    /// view gets a verb and never a store or a controller. Wired in
    /// `AppDelegate.install(metrics:)` to the same `clear()` the menu bar
    /// calls — `ShelfStore.clear()` moves real files to the Trash, which is
    /// exactly why the verb is not duplicated (spec §5.3).
    @ObservationIgnored
    public var onClearShelf: (() -> Void)?

    @ObservationIgnored
    public var onRemoveShelfItem: ((UUID) -> Void)?

    /// Whether the last Clear can still be undone, which puts "Undo" in the
    /// shelf's title row. Observable, unlike the verbs: the offer lapses on
    /// its own after a few seconds, and the button has to go with it.
    /// Set by `AppDelegate`, which holds what the clear took.
    public internal(set) var canUndoShelfClear = false

    /// A short line under the shelf -- "Couldn't add Holiday.mov" -- when a
    /// dropped file's background copy fails, or `nil`.
    ///
    /// The drop had already been accepted by then, so the pane is the only
    /// place left to say so. Observable, like `canUndoShelfClear`, because
    /// it lapses on its own; set and withdrawn by `AppDelegate`.
    public internal(set) var shelfNotice: String?

    /// Puts back what the last Clear moved to the Trash. Wired, like
    /// `onClearShelf`, to the delegate that holds the record.
    @ObservationIgnored
    public var onUndoClearShelf: (() -> Void)?

    /// Sends shelf files over AirDrop. A verb, like the others, so the view
    /// never holds a sharing service (spec 2026-10-17).
    @ObservationIgnored
    public var onAirDropShelfItems: (([URL]) -> Void)?

    /// Shows a shelf file selected in Finder, from a tile's context menu or
    /// accessibility actions. A verb, like AirDrop, so the view never
    /// reaches for `NSWorkspace`.
    @ObservationIgnored
    public var onRevealShelfItem: ((URL) -> Void)?

    /// Opens a shelf file with its default app — a double-click on the tile,
    /// or Open in its menu. By id rather than URL so the delegate, which
    /// holds the store, decides whether there is a file to open yet.
    @ObservationIgnored
    public var onOpenShelfItem: ((UUID) -> Void)?

    /// Shows a shelf file in Quick Look — Quick Look in the tile's menu.
    /// Space reaches the same preview through `AppDelegate.handlePanelKey`.
    @ObservationIgnored
    public var onQuickLookShelfItem: ((UUID) -> Void)?

    /// The tile Space previews and ← → move: set by a click on a tile, an
    /// arrow key, or a preview. Observable, because the tile draws a ring
    /// round it. A selection whose item has gone is no selection — every
    /// reader goes through `ShelfPreview` / `ShelfSelection`, which treat it
    /// so — and switching the shelf off clears it.
    public internal(set) var shelfSelection: UUID?

    @ObservationIgnored
    public var onClearClipboard: (() -> Void)?

    /// A row's Delete: forgets one entry, by id, like `onRemoveShelfItem`.
    @ObservationIgnored
    public var onRemoveClipboardEntry: ((UUID) -> Void)?

    /// A row's Pin or Unpin, by id, like `onRemoveClipboardEntry`.
    @ObservationIgnored
    public var onTogglePinClipboardEntry: ((UUID) -> Void)?

    /// What is typed in the clipboard pane's search field (2026-10-24).
    ///
    /// Here rather than in the view's `@State` because Esc has to see it:
    /// `AppDelegate.handlePanelKey` asks `PanelKeyboard` whether Esc clears
    /// the search or closes the panel, and a value private to a view is one
    /// the key path cannot read. Observed — the pane filters by it.
    ///
    /// It lasts for one look at the history: a tab switch keeps it, and
    /// leaving `.open` empties it (`transition(to:)`), so the next open shows
    /// the whole list rather than a filter nobody remembers typing. Never
    /// written down, like the history it searches.
    public var clipboardQuery: String = ""

    /// The colour picker's last few picks, newest first (2026-10-24), for the
    /// strip's swatches and the dropper's menu. Published by
    /// `ColorPickerController` through `AppDelegate`; empty while the module
    /// is off. Observable: a pick changes it while the panel is on screen.
    public internal(set) var recentColors: [SampledColor] = []

    /// The colour just copied, which puts the result strip over the body --
    /// or `nil`, which takes it away. Set by a pick or a swatch; cleared by
    /// the strip's close button and whenever the panel leaves `.open`, so the
    /// result belongs to the opening it was shown in. Nothing times it out.
    public internal(set) var pickedColor: SampledColor?

    /// How a pick is copied: "Copy as" in Settings. Applied by
    /// `onSetColorFormat`; the strip prints the value in it.
    public internal(set) var colorFormat: ColorFormat = .default

    /// The header's dropper: closes the panel, shows the system loupe, and
    /// brings the panel back with the result. A verb, like the pane's, so the
    /// view never holds a sampler. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onPickColor: (() -> Void)?

    /// A swatch's click: copies that colour again in the current format.
    @ObservationIgnored
    public var onCopyColor: ((SampledColor) -> Void)?

    /// Saves and applies a new copy format in one call, for the reason
    /// `onSetTextSize` does both. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onSetColorFormat: ((ColorFormat) -> Void)?

    /// The strip's close button. The history stays; only the strip goes.
    public func dismissColorStrip() {
        pickedColor = nil
    }

    /// The header's gear. Closes the panel, then opens Settings — Settings
    /// is an activating window, and the panel should not sit open under it.
    @ObservationIgnored
    public var onOpenSettings: (() -> Void)?

    /// Whether the first-run welcome card has been dismissed (2026-10-24).
    ///
    /// Defaults to `true`, the opposite of a fresh install, so a bare
    /// `AppState` — every rendering test's — draws the panel it always drew.
    /// `AppDelegate.install(metrics:)` loads the real value from the store.
    /// Observed: `body` reads it, and a dismissal must take the card away.
    public internal(set) var welcomeSeen: Bool = true

    /// Persists the flag. A closure, like the pane verbs, so the view never
    /// holds a store. `false` is "Show Welcome Again".
    @ObservationIgnored
    public var onPersistWelcomeSeen: ((Bool) -> Void)?

    /// The card's "Set Shortcut…": dismisses it, closes the panel and opens
    /// Settings on the shortcut row. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onWelcomeSetShortcut: (() -> Void)?

    /// Whether the card is on screen right now. `WelcomeCard.isShown`, read
    /// in one place so the view and the tests ask the same question.
    public var showsWelcome: Bool {
        WelcomeCard.isShown(seen: welcomeSeen, in: state, openedBy: openReason)
    }

    /// The one writer of `welcomeSeen` after install: applies and persists
    /// in the same call, for the reason `onSetHoverBehaviour` does both.
    public func setWelcomeSeen(_ seen: Bool) {
        guard seen != welcomeSeen else { return }
        welcomeSeen = seen
        onPersistWelcomeSeen?(seen)
    }

    /// The notch tap's way into the panel: the delegate's
    /// `openPanel(openedBy: .tap)`, which picks a visible tab or declines when
    /// there is none. Only the tap calls it, which is what lets the delegate
    /// record the open as explicit and give it the keyboard.
    @ObservationIgnored
    public var onOpenPanel: (() -> Void)?

    /// How the media buttons reach `MediaRemoteBridge`.
    ///
    /// A closure rather than calling the bridge from the view, for the
    /// same reason `onCopyClipboard` is one: it keeps a real transport
    /// command — which changes playback on the machine — out of anything
    /// a test constructs.
    @ObservationIgnored
    public var onMediaCommand: ((MediaCommand) -> Void)?

    /// Moves playback to a time in the track, from the progress bar
    /// (2026-10-18). Wired only where the transport controls work, like
    /// `onMediaCommand`; `nil` leaves the bar display-only.
    @ObservationIgnored
    public var onSeek: ((TimeInterval) -> Void)?

    /// How the timer tab reaches `TimerController`.
    ///
    /// Closures rather than a controller reference, for the same reason
    /// `onMediaCommand` is one: it keeps the scheduler — a thing that
    /// wakes the machine — out of anything a test or a preview
    /// constructs, and leaves the view layer no way to start or stop it
    /// beyond the four verbs below.
    @ObservationIgnored
    public var onStartTimer: ((TimeInterval) -> Void)?

    /// Pause, resume and cancel take the row's `RunningTimer.id`: with
    /// several countdowns (2026-10-24) a bare verb would have to guess
    /// which one was meant.
    @ObservationIgnored
    public var onPauseTimer: ((Int) -> Void)?

    @ObservationIgnored
    public var onResumeTimer: ((Int) -> Void)?

    @ObservationIgnored
    public var onCancelTimer: ((Int) -> Void)?

    /// The stopwatch's one verb, applied by the delegate at its clock.
    @ObservationIgnored
    public var onStopwatch: ((StopwatchCommand) -> Void)?

    /// The stopwatch, as a value: a start date and what it banked, never a
    /// tick. Nothing republishes it while it runs — the digits are a
    /// `Text(timerInterval:)` the system keeps current, and only while the
    /// tab is on screen — so it is an ordinary `Equatable` property whose
    /// dedupe is right: an equal stopwatch draws identically.
    public internal(set) var stopwatch = Stopwatch()

    /// Which half of the timer tab is showing. In `AppState` rather than
    /// the view's `@State`, so reopening the panel finds the stopwatch
    /// still in front if that is where it was left; not persisted, because
    /// neither is anything it shows.
    public var timerMode: TimerTabMode = .timer

    /// Whether the timer tab is showing the picker for one more countdown
    /// beside those running. Cleared when one starts and when the last
    /// one goes, so the next countdown starts from the plain view.
    public var isAddingTimer = false

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

    /// The capture session the preview draws, or `nil` when the camera module
    /// is off or has no camera. Published rather than reached through the
    /// delegate so the view keeps its one dependency.
    @ObservationIgnored public var cameraSession: AVCaptureSession?

    /// What the camera tab shows. Observed, unlike the session itself, which
    /// is an object identity that never changes.
    var cameraState: CameraController.State?

    public var onCameraShutter: (() -> Void)?
    public var onCameraToggleRecording: (() -> Void)?

    /// What is currently capturing, from the capture indicator module. Read by
    /// the badge slot, so an indicator the user cannot otherwise get is the
    /// first thing the closed notch gives up its ear for.
    public var captureUse: CaptureUse = .none

    /// Whether a clip is being written. Read by the badge slot, and the reason
    /// the camera's activity-gate exemption is honest rather than silent.
    public var isRecordingClip: Bool = false

    /// Which modules are switched on.
    ///
    /// **The single read surface for preferences.** `ModuleSwitchboard` writes
    /// it; everything else reads it from here -- `PanelTabBar` the way it
    /// takes `hasBattery`, the shelf drop closures through their existing
    /// `[weak self]`, the timer's finish path to decide whether to peek.
    /// Nothing reads `PreferencesStore` or the switchboard directly, which is
    /// what makes a preference snapshotted into a `let` structurally
    /// impossible for the app-lifetime closures built in `install(metrics:)`.
    ///
    /// Defaults to the shipped state -- everything on but the calendar --
    /// matching what an empty defaults domain resolves to, so a bare
    /// `AppState` in a test behaves like a fresh install rather than like a
    /// user who switched everything off.
    ///
    /// Not `@ObservationIgnored`: like `hasBattery`, `body` reads it directly
    /// and needs Observation's tracking when it is written at runtime -- which
    /// unlike `hasBattery` is the normal case here.
    public var preferences: Preferences = .shipped

    /// Whether this Mac has an internal battery.
    ///
    /// Set by the first power snapshot, in `AppDelegate.powerDidChange` —
    /// not at install. An install-time read of `PowerObserver.hasBattery`
    /// used to exist and was dead, because that flag is false until the
    /// observer starts, which happens later. Defaults to `false` so anything
    /// constructing a bare `AppState` — every test that does not care about
    /// power — gets the shape that shows less, rather than the one that
    /// promises a tab with nothing behind it.
    ///
    /// A capability, not a preference: it answers "can this machine do it",
    /// which is never overwritten by whether the user wants it.
    ///
    /// Not `@ObservationIgnored`: like `showsMediaControls`, it is a
    /// plain `Bool` that `body` reads directly and needs Observation's
    /// tracking if it is ever written after install.
    public var hasBattery: Bool = false

    /// Current power state, set by `PowerController`. Observable, like
    /// `nowPlaying`: a plain value the panel reads directly.
    public internal(set) var power: PowerSnapshot?

    /// What the calendar pane draws, set by `CalendarController`, or `nil`
    /// while the module is off. Observable, like `power`. Each refresh carries
    /// its own `refreshedAt`, so a boundary refresh that read the same events
    /// is still a new value and still redraws -- the trap `countdown`'s box
    /// guards against, avoided in the value instead.
    public internal(set) var calendar: CalendarSnapshot?

    /// The calendar pane's verbs: ask for access, and open Privacy & Security
    /// after a refusal. Closures, like every pane's, so the view never holds
    /// the controller or reaches for `NSWorkspace`. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onRequestCalendarAccess: (() -> Void)?

    @ObservationIgnored
    public var onOpenCalendarPrivacySettings: (() -> Void)?

    /// Opens Calendar, from the pane's title row.
    @ObservationIgnored
    public var onOpenCalendarApp: (() -> Void)?

    /// Re-reads the calendar grants when Settings is shown, so its warning
    /// follows a change made in System Settings. Wired by `AppDelegate`.
    @ObservationIgnored
    public var onRefreshCalendarAccess: (() -> Void)?


    /// Set by `MediaController`. Observable — unlike `shelf` and
    /// `clipboard`, which are `@Observable` stores that publish their own
    /// changes, this is a plain value the header reads directly.
    public internal(set) var nowPlaying: TrackSnapshot?
    public internal(set) var nowPlayingArtwork: Data? {
        didSet {
            guard nowPlayingArtwork != oldValue else { return }
            nowPlayingBarTint = nowPlayingArtwork.flatMap(ArtworkTint.barColor(for:))
            nowPlayingArtworkAspect = nowPlayingArtwork
                .flatMap { NSImage(data: $0) }
                .map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 }
        }
    }

    /// The artwork's width over its height, read once per artwork change, so
    /// a video thumbnail gets a wider tile than an album cover
    /// (`NotchGeometry.coverWidth`).
    public private(set) var nowPlayingArtworkAspect: CGFloat?

    /// The equalizer's colour, sampled from the artwork once per artwork
    /// change (spec 2026-10-15).
    ///
    /// Here rather than in a `.task(id:)` in each view that draws bars, so
    /// the closed notch and the peek share one sample, and a render — in
    /// the app or in a test — never races an asynchronous one.
    public private(set) var nowPlayingBarTint: Color?

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
    ///
    /// The list of every countdown (2026-10-24) rides in the same box for
    /// the same reason: a display-change wake republishes a list equal to
    /// the one already there.
    private struct CountdownPublication {
        var countdown: Countdown?
        var timers: [RunningTimer] = []
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
        set {
            countdownPublication = CountdownPublication(
                countdown: newValue, timers: countdownPublication.timers
            )
        }
    }

    /// Every running or paused countdown, in start order, for the tab's
    /// list. `countdown` is the soonest of these, for the ear.
    public internal(set) var timers: [RunningTimer] {
        get { countdownPublication.timers }
        set {
            countdownPublication = CountdownPublication(
                countdown: countdownPublication.countdown, timers: newValue
            )
        }
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
    ///
    /// `reason` says who asked, and counts only on the change into `.open`
    /// from somewhere else: a tab switch keeps the open's original reason.
    /// It defaults to `.unspecified` — ambient, never key — so a route that
    /// forgets to say is the safe one, not the one that steals keystrokes.
    public func transition(to next: NotchState, openedBy reason: PanelOpenReason = .unspecified) {
        guard next != state else { return }
        // Leaving a panel that showed the welcome card, or switching its tab,
        // counts as reading it (`WelcomeCard.isDismissed`). Decided from the
        // state and reason being left, so it is computed before either moves.
        let dismissesWelcome = WelcomeCard.isDismissed(
            seen: welcomeSeen, from: state, openedBy: openReason, to: next)
        if case .open(let tab) = next {
            lastOpenTab = tab
            if case .open = state {} else { openReason = reason }
        } else {
            openReason = nil
            if !clipboardQuery.isEmpty { clipboardQuery = "" }
        }
        // One peek replacing another is a swap, not a collapse, even when the
        // new one is smaller — a battery peek giving way to a drag target.
        lastChangeGrew = next.presentation.rank >= state.presentation.rank
            || (next.presentation.isPeek && state.presentation.isPeek)
        state = next
        notify(.state(next))
        if dismissesWelcome { setWelcomeSeen(true) }
    }

    /// Corrects which tab a later reopen would target, without moving the
    /// panel.
    ///
    /// **The second and last writer of `lastOpenTab`, and there will not be a
    /// third.** `transition(to:)` is the only writer of `state` and remains
    /// so; this exists because `lastOpenTab` is assigned only on the `.open`
    /// branch, and a preference usually changes while the panel is CLOSED.
    /// Correcting it through the funnel would mean opening a window on screen
    /// in order to change a setting.
    ///
    /// It notifies nobody on purpose: nothing moved, and an observer told the
    /// panel changed when it did not is a redraw for nothing.
    ///
    /// Not optional. Fix only the live state when a module is switched off
    /// and the notch-tap reopen fires later from `.open(lastOpenTab)`, long
    /// after the toggle -- the hardest version of that bug to reproduce and
    /// the easiest to dismiss as a glitch.
    public func retarget(lastOpenTab tab: CreativeNotchCore.Tab) {
        lastOpenTab = tab
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

    /// The one now-playing cover the badge, the music peek and the panel
    /// share, so it slides between them (spec 2026-10-15).
    @Namespace private var coverSpace

    /// For the calendar pane's title row: the system's calendar and locale in
    /// the app, pinned ones in a render.
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    /// The system's Reduce Motion setting (spec 2026-10-17). With it on,
    /// springs become one short ease, content fades rather than blurs in,
    /// the cover cross-fades rather than slides, hover does not grow the
    /// notch, and the peek's bars stand still.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whatever the surroundings allow for the bars — off in a render that
    /// must be repeatable. Reduce Motion can only take motion away from it,
    /// never grant it back: setting `!reduceMotion` outright overrode a
    /// test's `false` and made two renders of a playing peek differ.
    @Environment(\.animatesEqualizer) private var equalizerAllowed

    /// The shared cover's namespace, or none under Reduce Motion.
    private var sharedCover: Namespace.ID? {
        NotchMotion.slidesCover(reduceMotion: reduceMotion) ? coverSpace : nil
    }

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
        badgeWidth: CGFloat = 0,
        leadingBadgeWidth: CGFloat = 0
    ) -> CGRect {
        let visible = NotchShape.visibleRect(
            presentation: state.presentation,
            anchor: anchor,
            panelFrame: panelFrame,
            badgeWidth: badgeWidth,
            leadingBadgeWidth: leadingBadgeWidth
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
            badgeWidth: slot.width,
            leadingBadgeWidth: slot.leadingWidth
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
            countdown: app.countdown,
            nowPlaying: app.nowPlaying,
            isRecording: app.isRecordingClip,
            capture: app.captureUse,
            hiding: app.layoutOptions.hiddenBadges,
            at: now
        )
    }

    /// The horizontal band a centred peek has to leave empty, because on a
    /// notched Mac that band is the camera housing.
    ///
    /// One name for one value. Two peek views each spelled
    /// `anchor.isNotch ? anchor.rect.width : 0` out for themselves, two lines
    /// apart — and two independent derivations of a single value is the
    /// exact shape of this project's only Critical
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
        track: TrackSnapshot,
        coverNamespace: Namespace.ID? = nil
    ) -> NowPlayingPeekView {
        NowPlayingPeekView(
            track: track,
            artwork: app.nowPlayingArtwork,
            notchGap: notchGap(for: app.anchor),
            bandHeight: app.anchor.rect.height,
            barTint: app.nowPlayingBarTint,
            artworkAspect: app.nowPlayingArtworkAspect,
            coverNamespace: coverNamespace,
            onCommand: { app.onMediaCommand?($0) },
            onSeek: app.onSeek.map { seek in { seek($0) } }
        )
    }

    /// The drawn rect, grown a few points while the cursor rests on the
    /// closed notch (spec 2026-10-15).
    ///
    /// The notch reacts the moment the cursor arrives, rather than doing
    /// nothing until the 300ms dwell decides whether there is anything to
    /// peek. **Drawn only.** The accepted hit/hover region is not grown,
    /// so it stays no larger than what is drawn — the invariant the growth
    /// lag exists for. The few points it does not cover are a margin, not
    /// a target.
    ///
    /// Closed only: a peek or a panel is already larger, and a few more
    /// points on top would make the next change jump.
    static func hoverInflated(
        _ drawn: CGRect, isHovering: Bool, state: NotchState, reduceMotion: Bool = false
    ) -> CGRect {
        guard isHovering, state == .closed, !reduceMotion else { return drawn }
        let g = NotchMotion.hoverGrowth
        return CGRect(
            x: drawn.minX - g.width / 2,
            y: drawn.minY,
            width: drawn.width + g.width,
            height: drawn.height + g.height
        )
    }

    /// The power peek exactly as `body` builds it, arguments and all.
    ///
    /// Static for the same reason `nowPlayingPeek(for:track:)` is: it lets
    /// a test read the band height this view *supplies* without rendering.
    /// The row hangs below the notch's own band, so the band must be the
    /// anchor's real height.
    static func powerPeek(for app: AppState, event: PowerEvent) -> PowerPeekView {
        PowerPeekView(event: event, bandHeight: app.anchor.rect.height)
    }

    public var body: some View {
        // At most one clock read per evaluation, and none at all when the
        // instant was pinned. Everything below derives from this single
        // value: asking `badgeSlot` again for the content, or calling
        // `drawnRect(for:)` for the width, would read the clock again with
        // it.
        let instant = now ?? Date()
        let slot = Self.badgeSlot(for: app, at: instant)
        let resting = Self.drawnRect(for: app, badge: slot)
        let drawn = Self.pulled(
            Self.hoverInflated(
                resting,
                isHovering: app.isHovering,
                state: app.state,
                reduceMotion: reduceMotion
            ),
            opening: Self.drawnRect(state: .open(app.lastOpenTab), anchor: app.anchor, panelFrame: app.panelFrame),
            closing: Self.drawnRect(
                state: .closed, anchor: app.anchor, panelFrame: app.panelFrame,
                badgeWidth: slot.width, leadingBadgeWidth: slot.leadingWidth
            ),
            pull: app.pullProgress,
            state: app.state
        )
        ZStack(alignment: .topLeading) {
            Color.clear
            shape(badge: slot, at: instant)
                .frame(width: drawn.width, height: drawn.height)
                .offset(x: drawn.minX, y: drawn.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(NotchMotion.hover, value: app.isHovering)
        // Keyed on the state, with the spring chosen by which way it moved:
        // bouncy growing, snappy shrinking.
        .animation(
            NotchMotion.animation(growing: app.lastChangeGrew, reduceMotion: reduceMotion),
            value: app.state
        )
        // Outermost, so a commit — which changes the state *and* zeroes the
        // pull — springs with the state's animation above; on its own the
        // pull tracks the fingers closely and snaps back the same way.
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.82), value: app.pullProgress)
        .environment(\.animatesEqualizer, equalizerAllowed && !reduceMotion)
    }

    /// The shape, stretched by a swipe in progress (spec 2026-10-17).
    ///
    /// A pull toward opening grows it a quarter of the way to the panel at
    /// the threshold — a promise of what letting go will do, not the panel
    /// itself. A pull toward closing shrinks the open panel a little toward
    /// the notch. Drawn only: the accepted region stays where it is.
    static func pulled(
        _ drawn: CGRect, opening: CGRect, closing: CGRect, pull: CGFloat, state: NotchState
    ) -> CGRect {
        if pull > 0, state.presentation != .expanded {
            return lerp(drawn, opening, min(pull, 1.6) * 0.25)
        }
        if pull < 0, case .open = state {
            return lerp(drawn, closing, min(-pull, 1.6) * 0.12)
        }
        return drawn
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    /// Derived from `NotchShape.cornerRadii` — the same tested function
    /// that decides the drawn rect — rather than from a second `switch`
    /// here. Two independent derivations of one shape is the exact shape
    /// of this project's only Critical bug.
    private var backgroundShape: UnevenRoundedRectangle {
        let r = NotchShape.cornerRadii(
            presentation: app.state.presentation,
            anchor: app.anchor,
            corners: app.layoutOptions.corners
        )
        return UnevenRoundedRectangle(
            topLeadingRadius: r.topLeading,
            bottomLeadingRadius: r.bottomLeading,
            bottomTrailingRadius: r.bottomTrailing,
            topTrailingRadius: r.topTrailing,
            style: .continuous
        )
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
            // The edge, since there is no shadow (spec §4): a window exactly
            // the size of its shape has nowhere to cast one. Expanded only —
            // the closed notch must vanish into the housing, and a peek is a
            // glance.
            .overlay {
                if app.state.presentation == .expanded {
                    backgroundShape.strokeBorder(.hairline(0.08), lineWidth: 1)
                }
            }
            .overlay {
                Group { switch app.state {
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
                    case .capture:
                        CaptureBadgeView(use: app.captureUse)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .trailing
                            )
                    case .recording:
                        RecordingBadgeView()
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .trailing
                            )
                    case .timer:
                        if let countdown = app.countdown {
                            TimerBadgeView(
                                text: TimerDisplay.text(remaining: countdown.remaining(at: now)),
                                isPaused: countdown.isPaused,
                                remaining: countdown.remaining(at: now)
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
                        // Cover then bars, together in the trailing ear that
                        // `visibleRect` grew, starting just past the housing;
                        // a square cover leaves its slack at the far end.
                        HStack(spacing: 5) {
                            NowPlayingBadgeView(
                                artwork: app.nowPlayingArtwork,
                                aspect: app.nowPlayingArtworkAspect,
                                coverNamespace: sharedCover,
                                track: app.nowPlaying
                            )
                            EqualizerBarsView(
                                isPlaying: true,
                                animates: false,
                                color: app.nowPlayingBarTint ?? .white
                            )
                        }
                        .padding(.leading, 6)
                        .frame(width: NotchGeometry.nowPlayingBadgeWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    case .none:
                        EmptyView()
                    }

                case .open(let tab):
                    // The header sits in the band the content used to be
                    // padded past — the hardware notch on a notched Mac, the
                    // pill's own band otherwise — with the camera housing
                    // left black between its two ears. Below it, a fixed
                    // media column beside the module pane. The camera takes
                    // the whole body: a preview wants width, and with no
                    // column beside it its height no longer depends on
                    // whether a track is playing (spec §5.9).
                    let layout = PanelLayout.resolve(
                        anchor: app.anchor,
                        panelFrame: app.panelFrame,
                        showsMedia: tab != .camera && app.showsMediaControls,
                        textScale: app.textScale,
                        tabsSide: app.layoutOptions.tabsSide
                    )
                    VStack(spacing: 0) {
                        PanelHeader(
                            layout: layout,
                            selected: tab,
                            enabled: app.preferences,
                            hasBattery: app.hasBattery,
                            power: app.power,
                            showsBattery: app.layoutOptions.showsBattery,
                            onSelect: { app.transition(to: .open($0)) },
                            onSettings: { app.onOpenSettings?() },
                            colorPicker: Self.colorPickerHeader(for: app)
                        )
                        // The first-run card stacks over the body, under the
                        // live header (`WelcomeCardView`). A `ZStack` rather
                        // than an overlay: an overlay is offered the body's
                        // size, and a body that hugs its content — an empty
                        // shelf — would squeeze the card into a column.
                        ZStack {
                            HStack(spacing: 0) {
                                if layout.mediaColumnWidth > 0 {
                                    MediaColumn(
                                        width: layout.mediaColumnWidth,
                                        snapshot: app.nowPlaying,
                                        artwork: app.nowPlayingArtwork,
                                        showsControls: app.showsMediaControls,
                                        coverNamespace: sharedCover,
                                        onSeek: app.onSeek
                                    ) { app.onMediaCommand?($0) }
                                }
                                // `at: now` keeps the pane on the single instant
                                // `body` already bound.
                                openContent(for: tab, at: now)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            // A pick's result, over the bottom of the body
                            // (`ColorStripView`). Under the welcome card, which
                            // is the one thing that should cover it.
                            if let picked = app.pickedColor {
                                ColorStripView(
                                    picked: picked,
                                    recent: app.recentColors,
                                    format: app.colorFormat,
                                    onCopy: { app.onCopyColor?($0) },
                                    onDismiss: { app.dismissColorStrip() }
                                )
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .transition(NotchMotion.content(reduceMotion: reduceMotion))
                            }
                            // Read from `showsWelcome`, the one question the
                            // tests ask too.
                            if app.showsWelcome {
                                WelcomeCardView(
                                    onSetShortcut: { app.onWelcomeSetShortcut?() },
                                    onDismiss: { app.setWelcomeSeen(true) }
                                )
                                .transition(NotchMotion.content(reduceMotion: reduceMotion))
                            }
                        }
                        // A one-shot on the button press, the snappy spring
                        // the panel shrinks with — or a short ease under
                        // Reduce Motion.
                        .animation(
                            NotchMotion.animation(growing: false, reduceMotion: reduceMotion),
                            value: app.welcomeSeen
                        )
                        // The strip arrives with the panel's own grow spring
                        // and leaves with the snappy one, a one-shot per pick.
                        .animation(
                            NotchMotion.animation(growing: app.pickedColor != nil, reduceMotion: reduceMotion),
                            value: app.pickedColor
                        )
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    // Text size (2026-10-24): every `.notchFont` and text-
                    // holding length below reads it. Here and on the drop
                    // target only, so the badges and the peeks above stay
                    // the size the hardware band allows (`NotchType`).
                    .environment(\.notchTextScale, app.textScale)

                case .receiving:
                    // The same target the empty shelf shows, brighter, under
                    // an empty header band (spec §5.5). The state, the
                    // transition and the hit region are unchanged.
                    VStack(spacing: 0) {
                        Color.clear.frame(height: app.anchor.rect.height)
                        DropTargetView(prominent: true)
                            .padding(.horizontal, 22)
                            .padding(.top, 10)
                            .padding(.bottom, 20)
                    }
                    .environment(\.notchTextScale, app.textScale)

                // The music peek is a mini player that grows down from the
                // notch (spec 2026-10-15); power and timer peeks stay one
                // line in the ears.
                //
                // Without the now-playing case the state fell through to
                // `default` and drew the literal string "CreativeNotch"
                // over playing music — bug C2, for a whole module's
                // development. Every `PeekContent` case is named rather
                // than left to `default` for that reason.
                case .peek(.power(let event)):
                    Self.powerPeek(for: app, event: event)

                case .peek(.nowPlaying(let track)):
                    // The same notch gap the power peek gets, from the same
                    // named function: the bars in its top band must start
                    // clear of the camera housing. Built by
                    // `nowPlayingPeek(for:track:coverNamespace:)` rather than
                    // inline so a test can read the arguments without
                    // rendering — see its doc comment.
                    Self.nowPlayingPeek(for: app, track: track, coverNamespace: sharedCover)

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
                        .foregroundStyle(.ink(0.9))
                } }
                // Every state's content blurs in as the shape grows and
                // fades fast as it shrinks (spec 2026-10-15). Replaces the
                // panel's own opacity-and-scale, so all states move alike.
                .transition(NotchMotion.content(reduceMotion: reduceMotion))
            }
            // Content never spills past the shape, including a cover in
            // flight between two states.
            .clipShape(backgroundShape)
            .onTapGesture { Self.handleTap(app: app) }
    }

    /// What a tap on the notch does. Static so a test can drive it without
    /// a rendered view, like `nowPlayingPeek`.
    ///
    /// Opening goes through `onOpenPanel` — `AppDelegate.openPanel()`, the
    /// path the shortcut and the swipe take — rather than straight to
    /// `.open(lastOpenTab)`. That transition knew nothing about which tabs
    /// are switched on, so with every tab off a tap opened an empty panel.
    /// The direct transition remains only for a view with no delegate
    /// behind it, a preview.
    static func handleTap(app: AppState) {
        // Through the funnel, like every other mutation.
        switch app.state {
        case .open:
            app.transition(to: .closed)
        default:
            if let open = app.onOpenPanel {
                open()
            } else {
                app.transition(to: .open(app.lastOpenTab), openedBy: .tap)
            }
        }
    }

    /// The camera tab's content: the preview across the whole body.
    @ViewBuilder
    private var cameraContent: some View {
        if let camera = app.cameraSession, let state = app.cameraState {
            CameraTabView(
                state: state,
                session: camera,
                onShutter: { app.onCameraShutter?() },
                onToggleRecording: { app.onCameraToggleRecording?() },
                onClose: { app.transition(to: .closed) }
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func openContent(for tab: CreativeNotchCore.Tab, at now: Date) -> some View {
        switch tab {
        case .camera:
            cameraContent

        case .shelf:
            if let shelf = app.shelf {
                ModulePane(
                    title: tab.title,
                    count: Self.shelfCount(shelf.items.count),
                    actions: Self.shelfActions(for: shelf, app: app)
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ShelfView(
                            store: shelf,
                            selection: app.shelfSelection,
                            onSelect: { app.shelfSelection = $0 },
                            onRemove: { app.onRemoveShelfItem?($0) },
                            onAirDrop: { app.onAirDropShelfItems?([$0]) },
                            onReveal: { app.onRevealShelfItem?($0) },
                            onOpen: { app.onOpenShelfItem?($0) },
                            onQuickLook: { app.onQuickLookShelfItem?($0) }
                        )
                        // A background copy that failed after its drop was
                        // accepted, or an Undo that could not bring every
                        // file back — gone again once it has been on screen
                        // for a while — else how to preview the selected
                        // tile. Under the tiles rather than in the title
                        // row, which is for verbs.
                        if let notice = Self.shelfFooter(
                            notice: app.shelfNotice, selection: app.shelfSelection, in: shelf.items
                        ) {
                            Text(notice)
                                .notchFont(11, weight: .medium, design: .rounded)
                                .foregroundStyle(.ink(0.6))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

        case .clipboard:
            if let clipboard = app.clipboard {
                ModulePane(
                    title: tab.title,
                    count: Self.clipboardCount(for: clipboard, query: app.clipboardQuery),
                    actions: Self.clipboardActions(for: clipboard, app: app)
                ) {
                    ClipboardView(
                        store: clipboard,
                        now: now,
                        query: Binding(
                            get: { app.clipboardQuery },
                            set: { app.clipboardQuery = $0 }
                        ),
                        onCopy: { app.onCopyClipboard?($0) },
                        onTogglePin: { app.onTogglePinClipboardEntry?($0) },
                        onRemove: { app.onRemoveClipboardEntry?($0) }
                    )
                }
            }

        case .timer:
            // Through `AppState`, never to a controller this view holds —
            // the same routing `onCopyClipboard` and `onMediaCommand`
            // use. Optional-chained, so a state nobody wired (a preview,
            // a test) renders the tab and does nothing rather than
            // trapping.
            //
            // The stopwatch and several countdowns (2026-10-24) live here,
            // behind a Timer | Stopwatch switch in the title row, rather
            // than in a tab of their own: the ear's icon row has no room to
            // spare, and a stopwatch is a timer counting the other way.
            let timers = Self.timerRows(app)
            ModulePane(
                title: tab.title,
                count: Self.timerCount(app, rows: timers),
                actions: Self.timerActions(app, rows: timers),
                accessory: AnyView(
                    NotchSegmentedControl(
                        options: TimerTabMode.allCases.map { ($0, $0.title) },
                        selection: app.timerMode,
                        onSelect: { app.timerMode = $0 }
                    )
                )
            ) {
                switch app.timerMode {
                case .timer:
                    TimerTabView(
                        timers: timers,
                        now: now,
                        presets: Self.timerPresets(app),
                        isAdding: app.isAddingTimer,
                        onStart: { app.onStartTimer?($0) },
                        onPause: { app.onPauseTimer?($0) },
                        onResume: { app.onResumeTimer?($0) },
                        onCancel: { app.onCancelTimer?($0) }
                    )
                case .stopwatch:
                    StopwatchView(
                        stopwatch: app.stopwatch,
                        now: now,
                        onCommand: { app.onStopwatch?($0) }
                    )
                }
            }

        case .power:
            ModulePane(title: tab.title) {
                PowerView(snapshot: app.power)
            }

        case .calendar:
            ModulePane(
                title: tab.title,
                count: CalendarText.day(now, calendar: calendar, locale: locale),
                actions: Self.calendarActions(app)
            ) {
                CalendarView(
                    snapshot: app.calendar,
                    now: now,
                    onRequestAccess: { app.onRequestCalendarAccess?() },
                    onOpenPrivacySettings: { app.onOpenCalendarPrivacySettings?() }
                )
            }
        }
    }

    /// The calendar's title-row verb: "Open Calendar", once there is a glance
    /// to open it from. Not offered while the pane is asking for access or
    /// explaining a refusal, where the pane's own button is the next step.
    static func calendarActions(_ app: AppState) -> [(label: String, perform: () -> Void)] {
        guard case .glance = app.calendar?.pane else { return [] }
        return [("Open Calendar", { app.onOpenCalendarApp?() })]
    }

    /// The header's dropper, or `nil` while the colour picker is switched
    /// off. Static so a test can read what the header is handed without
    /// rendering it, like `timerPresets`.
    static func colorPickerHeader(for app: AppState) -> ColorPickerHeaderModel? {
        guard app.preferences.colorPicker else { return nil }
        return ColorPickerHeaderModel(
            recent: app.recentColors,
            format: app.colorFormat,
            onPick: { app.onPickColor?() },
            onCopy: { app.onCopyColor?($0) }
        )
    }

    /// The countdowns the timer tab lists: `AppState.timers`, or — when only
    /// `countdown` was set, as a render or a test does directly — that one
    /// as a list of one, so the tab draws what the ear draws.
    static func timerRows(_ app: AppState) -> [RunningTimer] {
        if !app.timers.isEmpty { return app.timers }
        return app.countdown.map { [RunningTimer(id: -1, countdown: $0)] } ?? []
    }

    /// The timer title row's count: the set duration for one countdown, as
    /// it always was, and how many for several. On the stopwatch, the laps.
    static func timerCount(_ app: AppState, rows: [RunningTimer]) -> String? {
        switch app.timerMode {
        case .stopwatch:
            let laps = app.stopwatch.laps.count
            return laps == 0 ? nil : "\(laps) lap\(laps == 1 ? "" : "s")"
        case .timer:
            switch rows.count {
            case 0: return nil
            case 1: return durationLabel(rows[0].countdown)
            default: return "\(rows.count) running"
            }
        }
    }

    /// The timer title row's verbs: "Add" beside one or two running
    /// countdowns, "Back" while the add picker is up, and nothing on the
    /// stopwatch, with none running, or at `TimerSet.capacity`.
    static func timerActions(
        _ app: AppState, rows: [RunningTimer]
    ) -> [(label: String, perform: () -> Void)] {
        guard app.timerMode == .timer, !rows.isEmpty else { return [] }
        if app.isAddingTimer { return [("Back", { app.isAddingTimer = false })] }
        guard rows.count < TimerSet.capacity, app.onStartTimer != nil else { return [] }
        return [("Add", { app.isAddingTimer = true })]
    }

    /// The timer tab's presets: the ones chosen in Settings, read from
    /// `AppState` so a change draws on the next frame. Static so a test can
    /// check where the tab gets them without rendering it.
    static func timerPresets(_ app: AppState) -> [Int] {
        app.limits.timerPresets
    }

    /// The shelf's title-row verbs: "AirDrop All" then "Clear", or none
    /// when it is empty -- with "Undo" before Clear for the few seconds a
    /// clear can still be taken back.
    ///
    /// Both act on `readyItems`: a file still copying in has nothing to
    /// AirDrop, and Clear would pass it by, so a shelf holding only copies
    /// in progress offers neither.
    ///
    /// AirDrop All hands every file to AirDrop in one go — one picker, not
    /// one per file — through the same `onAirDropShelfItems` verb the
    /// tiles use. Clear stays last, at the edge, where the destructive verb
    /// already was. Undo lands where Clear was a moment ago on the shelf it
    /// just emptied, so the hand that cleared can take it back without
    /// moving.
    static func shelfActions(
        for shelf: ShelfStore, app: AppState
    ) -> [(label: String, perform: () -> Void)] {
        var actions: [(label: String, perform: () -> Void)] = []
        if !shelf.readyItems.isEmpty {
            actions.append(("AirDrop All", { app.onAirDropShelfItems?(shelf.readyItems.map(\.url)) }))
        }
        if app.canUndoShelfClear {
            actions.append(("Undo", { app.onUndoClearShelf?() }))
        }
        if !shelf.readyItems.isEmpty {
            actions.append(("Clear", { app.onClearShelf?() }))
        }
        return actions
    }

    /// The line under the shelf's tiles: a notice (a failed copy, or an Undo
    /// that could not bring every file back), which is news and wins; else,
    /// while a tile is selected, how to preview and open it — the only place
    /// Space and the double-click are written down in the panel; else
    /// nothing.
    static func shelfFooter(notice: String?, selection: UUID?, in items: [ShelfItem]) -> String? {
        if let notice { return notice }
        guard let selection, let item = items.first(where: { $0.id == selection }),
              ShelfSelection.isSelectable(item) else { return nil }
        return "Space to Quick Look · double-click to open"
    }

    /// The clipboard's title-row verb: "Clear", while there is something for
    /// it to take. Pins stay through a Clear (`ClipboardStore.clear`), so a
    /// history of pins alone offers none — a button that changed nothing
    /// would read as broken.
    static func clipboardActions(
        for clipboard: ClipboardStore, app: AppState
    ) -> [(label: String, perform: () -> Void)] {
        clipboard.clearableCount == 0 ? [] : [("Clear", { app.onClearClipboard?() })]
    }

    /// "12 of 50" — the history against its size — or, while a search is
    /// typed, "3 of 12": what the search kept of what there is. Without the
    /// second form an empty filtered list reads as an empty history.
    static func clipboardCount(for clipboard: ClipboardStore, query: String) -> String? {
        guard !clipboard.entries.isEmpty else { return nil }
        guard ClipboardSearch.isActive(query) else {
            return "\(clipboard.entries.count) of \(clipboard.capacity)"
        }
        let kept = ClipboardSearch.filter(clipboard.entries, query: query).count
        return "\(kept) of \(clipboard.entries.count)"
    }

    /// "4 items", "1 item", or "empty" — the shelf's title-row count.
    static func shelfCount(_ count: Int) -> String {
        switch count {
        case 0:  return "empty"
        case 1:  return "1 item"
        default: return "\(count) items"
        }
    }

    /// The duration a running countdown was set to, for the timer's title
    /// row. Whole minutes: presets and the field are both in minutes.
    static func durationLabel(_ countdown: Countdown) -> String {
        "\(Int(countdown.duration / 60)) min"
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

