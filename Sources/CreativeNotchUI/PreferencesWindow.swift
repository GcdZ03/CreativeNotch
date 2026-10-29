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

    /// The updater (2026-10-24), handed in for `launchAtLogin`'s reason: the
    /// window, the menu bar and the activity hook must agree about one.
    let updates: UpdateController

    /// What a controller built without one shows: an updater that asks
    /// nobody and can install nothing, over a domain of its own.
    static func detachedUpdates() -> UpdateController {
        UpdateController(
            environment: .sandboxed(in: FileManager.default.temporaryDirectory),
            defaults: UserDefaults(suiteName: "com.gcdz.creativenotch.sandbox.settings-updates") ?? .standard
        )
    }

    init(
        switchboard: ModuleSwitchboard,
        state: AppState,
        launchAtLogin: LaunchAtLoginController,
        updates: UpdateController? = nil
    ) {
        self.switchboard = switchboard
        self.state = state
        self.launchAtLogin = launchAtLogin
        self.updates = updates ?? Self.detachedUpdates()
        // Taking the instance as a parameter rather than `[weak self]`, which
        // would capture `self` before every stored property has a value --
        // the same reason the other window controllers do it this way.
        self.presenter = { $0.presentRealWindow() }
    }

    /// Test-only seam, deliberately not `public`: reached from tests through
    /// `@testable import` so it can never bypass the real presentation path
    /// from production code.
    init(
        switchboard: ModuleSwitchboard,
        state: AppState,
        launchAtLogin: LaunchAtLoginController,
        updates: UpdateController? = nil,
        presenter: @escaping (PreferencesController) -> Void
    ) {
        self.switchboard = switchboard
        self.state = state
        self.launchAtLogin = launchAtLogin
        self.updates = updates ?? Self.detachedUpdates()
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
        show(highlighting: nil)
    }

    /// Which section to scroll to and highlight, read by the view. Held here
    /// rather than in the view for the reason the recorders are: the window
    /// and its hosting view are built once and reused, so a request has to
    /// reach a view that already exists.
    let highlight = PreferencesHighlight()

    /// Presents the window scrolled to `section`, its rows briefly tinted —
    /// the welcome card's "Set Shortcut…". `nil` asks for nothing, leaving
    /// the form where it was.
    func show(highlighting section: PreferencesSection?) {
        if let section { highlight.ask(for: section) }
        launchAtLogin.refresh()
        // At the presentation boundary for the reason `refresh()` is: the
        // reused window's `.onAppear` would read the displays once per
        // process, and a monitor plugged in since would be missing.
        state.onRefreshDisplays?()
        // The same boundary: macOS posts nothing when Accessibility is
        // allowed in System Settings, so coming back here is when to look,
        // for the "Keep clear of app menus" warning. Reading never prompts.
        state.onRefreshAccessibility?()
        // The same boundary, for the same reason: macOS posts nothing when
        // Bluetooth is allowed in System Settings, so coming back here is
        // the moment to look. Reading never prompts.
        state.onRefreshBluetoothAccess?()
        // The calendar's grants, for the same reason: a refusal changed in
        // System Settings since the last look must show in the row's warning.
        state.onRefreshCalendarAccess?()
        // Likewise for notification permission: switched off in System
        // Settings since the last show, the line under the timer's switch
        // has to say so.
        state.onRefreshTimerNotices?()
        // The same boundary, for the same reason: someone refused the
        // Downloads folder, allowed it in System Settings, and came back
        // here to see whether it took. Reads nothing unless the module is on
        // and was refused.
        state.onRecheckDownloadsAccess?()
        // Opening Settings is a moment someone is looking at the version, so
        // it is one the updater may look too — at most once a day, and not
        // at all with automatic checks off.
        updates.check(.settingsOpened)
        presenter(self)
    }

    /// The one write path. Persists and applies in the same call, because two
    /// calls are two chances to do one without the other.
    func setEnabled(_ enabled: Bool, for module: ModuleID) {
        switchboard.setEnabled(enabled, for: module, persist: true)
    }

    func isEnabled(_ module: ModuleID) -> Bool { state.preferences[module] }

    /// Open on hover (2026-10-17). Written through `AppState`'s verb, which
    /// saves and applies together, and read back from what applied.
    var hoverBehaviour: HoverBehaviour { state.hoverBehaviour }

    func setHoverBehaviour(_ behaviour: HoverBehaviour) {
        state.onSetHoverBehaviour?(behaviour)
    }

    /// Show on (2026-10-24). Written through `AppState`'s verb, which saves,
    /// applies and moves the panel together, and read back from what applied.
    var displayChoice: DisplayChoice { state.displayChoice }

    func setDisplayChoice(_ choice: DisplayChoice) {
        state.onSetDisplayChoice?(choice)
    }

    /// Keep clear of app menus (2026-10-26). Written through `AppState`'s
    /// verb, which saves, asks for Accessibility access if it is missing, and
    /// places the pill again; read back from what applied.
    var pillClearsMenus: Bool { state.pillClearsMenus }

    func setPillClearsMenus(_ enabled: Bool) {
        state.onSetPillClearsMenus?(enabled)
    }

    /// Whether the switch is on but macOS has not allowed reading other
    /// apps' menus -- the one state in which it silently does nothing unless
    /// this window says why.
    var isMissingAccessibility: Bool { state.pillClearsMenus && !state.accessibilityTrusted }

    func openAccessibilitySettings() {
        state.onOpenAccessibilitySettings?()
    }

    /// Text size (2026-10-24). Written through `AppState`'s verb, which saves,
    /// applies and resizes the panel together, and read back from what
    /// applied.
    var textSize: TextSize { state.textSize }

    func setTextSize(_ size: TextSize) {
        state.onSetTextSize?(size)
    }

    /// Layout (2026-10-24). Written through `AppState`'s verb, which saves,
    /// applies and re-places the panel together, and read back from what
    /// applied -- the whole value each time, like `limits`.
    var layoutOptions: LayoutOptions { state.layoutOptions }

    func setLayoutOptions(_ options: LayoutOptions) {
        state.onSetLayoutOptions?(options)
    }

    /// Copy as (2026-10-24). Written through `AppState`'s verb, which saves
    /// and applies together, and read back from what applied.
    var colorFormat: ColorFormat { state.colorFormat }

    func setColorFormat(_ format: ColorFormat) {
        state.onSetColorFormat?(format)
    }

    /// The "Show on" menu: the general choices, each connected external
    /// display, and a pinned display that is unplugged
    /// (`DisplayChoice.options`). Derived from `AppState`'s observable
    /// display list, so the open menu follows a cable without a poll.
    var displayOptions: [DisplayChoice.Option] {
        DisplayChoice.options(for: state.connectedDisplays, current: state.displayChoice)
    }

    /// The adjustable limits (2026-10-24), through `AppState`'s verb like the
    /// hover behaviour: saved and applied together, read back from what
    /// applied.
    var limits: Limits { state.limits }

    /// A change that would move shelf files to the Trash, held until the
    /// user answers (2026-10-24). Held here, like `highlight`, because the
    /// window's view is built once and reused.
    let pendingLimits = PendingLimits()

    /// What the rows show: the change being asked about while the question
    /// is up, and what applied otherwise. Cancel then moves the picker from
    /// the held value back to the applied one — a real change of value, so
    /// the menu redraws instead of keeping the choice that was refused.
    var displayedLimits: Limits { pendingLimits.change?.limits ?? state.limits }

    /// Applies at once, unless the change would take something off the
    /// shelf: a lowered capacity or expiry moves real files to the Trash, so
    /// that change is held and Settings asks first. Everything else —
    /// raising a limit, the clipboard, the presets, the chime — applies as
    /// before, because a question asked about nothing is one people learn to
    /// click through.
    ///
    /// "Would take something" means more than the limits in force already
    /// take. The shelf purges only at launch and after an add, and a file
    /// that refuses the Trash stays listed, so the shelf can hold items the
    /// current limits have already condemned. Those are not this change's
    /// doing: counting them would raise the question on every Limits change
    /// — the clipboard's, the chime's, a raised capacity — and, with the
    /// shelf row hidden, hold a change no dialog is there to answer.
    func setLimits(_ limits: Limits) {
        if let removal = addedRemoval(limits) {
            pendingLimits.change = PendingLimits.Change(limits: limits, removal: removal)
        } else {
            pendingLimits.change = nil
            state.onSetLimits?(limits)
        }
    }

    /// What applying `limits` would take off the shelf, when that includes
    /// anything the current limits would not already take; `nil` when the
    /// change can apply without asking. A change that leaves both shelf
    /// limits alone never asks.
    private func addedRemoval(_ limits: Limits) -> ShelfLimitRemoval? {
        let current = state.limits
        guard limits.shelfCapacity != current.shelfCapacity || limits.shelfExpiry != current.shelfExpiry,
              let preview = state.onPreviewLimits else { return nil }
        let removal = preview(limits)
        let alreadyDue = Set(preview(current).items.map(\.id))
        return removal.items.allSatisfy { alreadyDue.contains($0.id) } ? nil : removal
    }

    /// "Move to Trash": applies the held change. Takes the change rather
    /// than reading `pendingLimits`, so it applies what the dialog showed
    /// even if SwiftUI dismissed the dialog — clearing the hold — before
    /// running the button's action.
    ///
    /// Measured again first: drops, finished copies and the clock all move
    /// while the dialog is up, and applying re-runs eviction and the purge
    /// on the list as it is now. If that would now take a file the dialog
    /// never counted (and the current limits would not take anyway), the
    /// change is held again with the new count instead of applied, so what
    /// was confirmed is never less than what goes.
    func confirmLimits(_ change: PendingLimits.Change) {
        let shown = Set(change.removal.items.map(\.id))
        if let fresh = addedRemoval(change.limits),
           !fresh.items.allSatisfy({ shown.contains($0.id) }) {
            pendingLimits.change = PendingLimits.Change(limits: change.limits, removal: fresh)
            return
        }
        pendingLimits.change = nil
        state.onSetLimits?(change.limits)
    }

    /// "Cancel", or the dialog dismissed: nothing was applied, so dropping
    /// the hold is the whole of it.
    func cancelLimits() {
        pendingLimits.change = nil
    }

    /// "Notify when hidden by a full-screen app" (2026-10-24), through
    /// `AppState`'s verb like the hover behaviour.
    var timerNotifyWhenHidden: Bool { state.timerNotifyWhenHidden }

    func setTimerNotifyWhenHidden(_ enabled: Bool) {
        state.onSetTimerNotifyWhenHidden?(enabled)
    }

    /// The line under that switch -- why it may do nothing -- or `nil`.
    var timerNoticeNote: String? {
        TimerDoneNotice.settingsNote(for: state.timerNoticeAuthorization, enabled: state.timerNotifyWhenHidden)
    }

    /// Whether that line is a warning -- notifications refused, or allowed
    /// with banners off -- which is when the row turns it orange and offers a
    /// way to System Settings.
    var timerNoticeWarning: TimerNoticeSettingsWarning? {
        TimerDoneNotice.settingsWarning(for: state.timerNoticeAuthorization, enabled: state.timerNotifyWhenHidden)
    }

    /// Clipboard history's excluded apps (2026-10-24), as bundle identifiers.
    var clipboardExcludedApps: [String] { state.clipboardExcludedApps }

    /// What "+" asks for: the apps chosen in an open panel, or none when it
    /// is cancelled. A seam so no test opens a real `NSOpenPanel`.
    var chooseApps: () -> [String] = { ExcludedApp.chooseWithOpenPanel() }

    /// "+": appends what was chosen, skipping anything already listed.
    func addExcludedApps() {
        let chosen = chooseApps()
        guard !chosen.isEmpty else { return }
        let updated = ClipboardExclusions.adding(chosen, to: state.clipboardExcludedApps)
        guard updated != state.clipboardExcludedApps else { return }
        state.onSetClipboardExcludedApps?(updated)
    }

    /// "−" on one row.
    func removeExcludedApp(_ bundleID: String) {
        state.onSetClipboardExcludedApps?(ClipboardExclusions.removing(bundleID, from: state.clipboardExcludedApps))
    }

    /// The hotkey controller, for the recorder row. Reached through the
    /// switchboard's delegate rather than stored twice.
    var hotKeyController: HotKeyController? { switchboard.hotKeyController }

    /// Whether Bluetooth alerts are on and macOS has said no — the one state
    /// in which the module silently shows nothing unless this window says
    /// why.
    var isBluetoothDenied: Bool {
        state.preferences.bluetooth && state.bluetoothAccess == .denied
    }

    func openBluetoothSettings() {
        state.onOpenBluetoothSettings?()
    }

    /// Whether a countdown is running, which is what makes the timer row's
    /// warning conditional. Shown unconditionally it would train people to
    /// ignore it.
    var hasRunningCountdown: Bool { state.countdown != nil }

    /// Whether the downloads module is on but cannot read the folder, which
    /// is what makes its row warn rather than read "on" over a module that
    /// sees nothing.
    var downloadsAccess: DownloadsAccess { state.downloadsAccess }

    /// The denied row's button: System Settings at Files & Folders.
    func openDownloadsPrivacy() {
        state.onOpenDownloadsPrivacy?()
    }

    /// Whether the calendar is switched on over grants that let it read
    /// nothing -- the case a switch reading "on" would lie about. Refused
    /// by the user, which Privacy & Security can undo.
    var calendarAccessRefused: Bool {
        guard state.preferences.calendar else { return false }
        return state.calendar?.pane == .denied
    }

    /// The same, but restricted by a profile or Screen Time: nothing in
    /// Privacy & Security can change it, so the warning must not send
    /// anyone there (the pane says the same, with no button).
    var calendarAccessRestricted: Bool {
        guard state.preferences.calendar else { return false }
        return state.calendar?.pane == .restricted
    }

    private var recorders: [ObjectIdentifier: HotKeyRecorder] = [:]

    /// One recorder per hotkey controller, built on first use. Held here
    /// rather than in the view, because a SwiftUI body can run many times and
    /// a recorder rebuilt mid-recording would drop its monitor.
    func recorder(for hotKey: HotKeyController) -> HotKeyRecorder {
        let key = ObjectIdentifier(hotKey)
        if let existing = recorders[key] { return existing }
        // `record`, not `setCombo`: what the user presses is validated
        // before it is registered, or a bare Space or ⌘C would become an
        // exclusive system-wide hotkey.
        let recorder = HotKeyRecorder { [weak hotKey] combo in
            hotKey?.record(combo)
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
        window.title = String(localized: "CreativeNotch Settings", bundle: .creativeNotch)
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreferencesView(controller: self))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

/// A limit change waiting on "Move N files to the Trash?" (2026-10-24).
///
/// Observable so the dialog appears when a change is held and goes when it
/// is answered. Nothing here applies anything; the controller does, on
/// confirm, through the same `onSetLimits` every other change takes.
@MainActor
@Observable
final class PendingLimits {
    struct Change: Equatable {
        let limits: Limits
        let removal: ShelfLimitRemoval
    }

    var change: Change?
}

/// A request to land on one section of the form (2026-10-24).
///
/// `request` changes on every ask, so asking for the same section twice —
/// the card dismissed, the window closed, "Set Shortcut…" never pressed
/// again, but Settings reopened on it some other way — still scrolls. The
/// view clears `section` once the tint has faded; nothing here runs on its
/// own.
///
/// **The scroll waits for the form's first layout.** On the very first open
/// the request arrives before the window's form has laid out, and a
/// `scrollTo` issued then has no rows to scroll between — the window landed
/// at the top, the Shortcut row tinted out of sight at the bottom. The view
/// reports its first layout through `formDidLayOut()`, and `scrollKey`
/// changes with it, so the view's one-shot runs again once there is
/// something to scroll. The window is built once and reused, so after that
/// first report every later ask scrolls straight away.
@MainActor
@Observable
final class PreferencesHighlight {
    private(set) var section: PreferencesSection?
    private(set) var request = 0
    private(set) var formLaidOut = false

    func ask(for section: PreferencesSection) {
        self.section = section
        request &+= 1
    }

    /// Called by the view once its form has a size. Idempotent: a later
    /// layout pass is not a new request and must not re-run the scroll.
    func formDidLayOut() {
        guard !formLaidOut else { return }
        formLaidOut = true
    }

    /// The section to scroll to now — `nil` until the form can be scrolled.
    var scrollTarget: PreferencesSection? { formLaidOut ? section : nil }

    /// What the view's scroll task is keyed on: a new request, or the first
    /// layout that makes a waiting request actionable.
    struct ScrollKey: Hashable {
        let request: Int
        let formLaidOut: Bool
    }

    var scrollKey: ScrollKey { ScrollKey(request: request, formLaidOut: formLaidOut) }

    /// Clears the tint, unless a newer request arrived while it was showing.
    func fade(request finished: Int) {
        guard finished == request else { return }
        section = nil
    }
}

/// Which group of the form a module's row sits in (spec §6).
///
/// The longer, honest notes that used to sit under every toggle become the
/// section's footer, so the form reads as a form and the honesty is still
/// there for anyone who reads to the end of a group.
enum PreferencesSection: CaseIterable {
    case notch, music, camera, shortcut
    /// The updater's section (2026-10-24): about the app, not a module, so
    /// it has no rows in `PreferencesView.rows` and is drawn with the
    /// app-wide sections. A case here only so "Check for Updates…" can land
    /// on it through the same highlight as "Set Shortcut…".
    case updates

    /// The sections that hold module rows, in the order they are drawn.
    static let moduleGroups: [PreferencesSection] = [.notch, .music, .camera, .shortcut]

    var title: String {
        switch self {
        case .notch:    return String(localized: "In the notch", bundle: .creativeNotch)
        case .music:    return String(localized: "Music", bundle: .creativeNotch)
        case .camera:   return String(localized: "Camera and privacy", bundle: .creativeNotch)
        case .shortcut: return String(localized: "Shortcut", bundle: .creativeNotch)
        case .updates:  return String(localized: "Updates", bundle: .creativeNotch)
        }
    }

    var footer: String? {
        switch self {
        case .notch:
            return String(localized: "The shelf costs nothing when idle: switching it off hides the tab and refuses drops, it does not save battery. Lowering its limits moves the files that no longer fit to the Trash straight away. Clipboard history is the only repeating timer in the app, and switching it off stops it. The colour picker runs nothing until you click it: macOS draws the loupe and hands back only the colour you click, so it needs no Screen Recording permission. The calendar is off until you switch it on, asks for access then, and reads nothing while its pane is closed. Bluetooth alerts are off until you switch them on, which is when macOS asks for Bluetooth access; they listen for connections rather than checking, and switching them off stops listening. Downloads starts off because it asks to read your Downloads folder; it listens for the progress browsers publish, the way Finder does, and switching it off stops listening.", bundle: .creativeNotch)
        case .music:
            return String(localized: "Now playing runs a helper process to read the track; switching it off terminates the helper. Media controls map a framework that has no unload, so switching them off hides the buttons and the framework stays mapped until the next launch. Synced lyrics start off: they ask LRCLIB once per track, wake once per line while music plays, and keep answers in memory only.", bundle: .creativeNotch)
        case .camera:
            return String(localized: "The camera is the only module that costs anything while it runs: the light is on whenever the preview is, and a clip keeps recording if you close the notch. The indicator is notification-driven and costs nothing while nothing is capturing.", bundle: .creativeNotch)
        case .shortcut:
            return String(localized: "No shortcut is set until you choose one. Any default would risk colliding with a launcher you already use.", bundle: .creativeNotch)
        case .updates:
            return String(localized: "CreativeNotch looks for a new release when it opens, when you come back to your Mac and when you open Settings \u{2014} the last two at most once a day \u{2014} and never on a timer. Update Now downloads the release, checks its checksum, signature and version, and replaces this copy; if anything fails, the current copy stays. Each release is signed ad hoc, so macOS may ask again for permissions you had already granted.", bundle: .creativeNotch)
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

    /// Which module rows to show; `nil`, the window's own value, shows the
    /// whole form. A subset drops the app-wide sections and every module
    /// outside it, so the feature renders (`SettingsFeatureRenders`) show the
    /// real rows at a legible size instead of a 2,000-point-tall form.
    var only: Set<ModuleID>? = nil

    /// The highlight's fade becomes a cut under Reduce Motion, like every
    /// spring in the panel.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long a requested section stays tinted: long enough to find after
    /// the window lands, short enough not to read as a state of the row.
    static let highlightDuration: Duration = .seconds(2)

    static let rows: [PreferencesRow] = [
        PreferencesRow(
            module: .shelf, section: .notch, symbolName: "tray.full", tint: .blue,
            title: String(localized: "File shelf", bundle: .creativeNotch),
            // Required, not decorative. The shelf owns no timer, observer or
            // process, so this toggle saves no power at all. Saying so beats
            // implying a saving that is not there.
            detail: String(localized: "Drag files onto the notch to stash them. Off hides the tab; it does not save battery.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .clipboard, section: .notch, symbolName: "doc.on.clipboard", tint: .purple,
            title: String(localized: "Clipboard history", bundle: .creativeNotch),
            detail: String(localized: "The last things you copied, in memory only.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .timer, section: .notch, symbolName: "timer", tint: .orange,
            title: String(localized: "Timer", bundle: .creativeNotch),
            detail: String(localized: "Up to three countdowns in the ear of the notch, and a stopwatch.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .power, section: .notch, symbolName: "battery.100percent", tint: .green,
            title: String(localized: "Battery and power", bundle: .creativeNotch),
            detail: String(localized: "Level, charging state and Low Power Mode. Costs almost nothing either way.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .bluetooth, section: .notch, symbolName: "airpods", tint: .blue,
            title: String(localized: "Bluetooth alerts", bundle: .creativeNotch),
            // Says what it asks for, because switching it on is what shows
            // macOS's Bluetooth prompt.
            detail: String(localized: "A glance when AirPods, headphones or a speaker connect or disconnect. Needs Bluetooth access.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .calendar, section: .notch, symbolName: "calendar", tint: .red,
            title: String(localized: "Calendar and reminders", bundle: .creativeNotch),
            // Required: the switch asks for two permissions, and the row says
            // so before it is pressed rather than after.
            detail: String(localized: "Your next events and today's reminders, as the last tab. Asks for Calendars and Reminders access when you switch it on.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .colorPicker, section: .notch, symbolName: "eyedropper", tint: .teal,
            title: String(localized: "Colour picker", bundle: .creativeNotch),
            // On by default, and the detail says why: no permission, and
            // nothing runs until the dropper is clicked.
            detail: String(localized: "Pick a colour from anywhere on screen and copy it. Needs no permission; nothing runs until you click the dropper.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .downloads, section: .notch, symbolName: "arrow.down.circle", tint: .teal,
            title: String(localized: "Downloads", bundle: .creativeNotch),
            // Says what the switch will ask for before it asks: the read
            // is a macOS prompt, and this is the "why" that prompt lacks.
            detail: String(localized: "Progress of Safari and other downloads, beside the closed notch. Asks to read your Downloads folder.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .mediaMetadata, section: .music, symbolName: "music.note", tint: .pink,
            title: String(localized: "Now playing", bundle: .creativeNotch),
            detail: String(localized: "Title, artist and artwork, in the panel and beside the closed notch.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .mediaControls, section: .music, symbolName: "playpause", tint: .pink,
            title: String(localized: "Media controls", bundle: .creativeNotch),
            // Required. Only disabled-at-launch means "not loaded": the
            // framework is mapped with `dlopen` and there is no `dlclose`.
            detail: String(localized: "Play, pause and skip. Off hides the buttons; the framework stays mapped until the next launch.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .lyrics, section: .music, symbolName: "quote.bubble", tint: .pink,
            title: String(localized: "Synced lyrics", bundle: .creativeNotch),
            // Required: switching it on is what starts sending each track to
            // a third party, so the row names the service and what goes to
            // it before the switch is pressed.
            detail: String(localized: "The line being sung, under the notch and in the panel; swipe up on the notch with two fingers to hide or show it. Looks each track up on LRCLIB (lrclib.net), sending its title, artist and length.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .camera, section: .camera, symbolName: "camera", tint: .gray,
            title: String(localized: "Camera", bundle: .creativeNotch),
            detail: String(localized: "A mirror under the lens, with a shutter and a record button.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .captureIndicator, section: .camera, symbolName: "record.circle", tint: .red,
            title: String(localized: "Camera and microphone indicator", bundle: .creativeNotch),
            detail: String(localized: "Shows in the notch when another app is using the camera or the microphone.", bundle: .creativeNotch)
        ),
        PreferencesRow(
            module: .hotkey, section: .shortcut, symbolName: "command", tint: .gray,
            title: String(localized: "Global shortcut", bundle: .creativeNotch),
            detail: String(localized: "Open the notch from anywhere.", bundle: .creativeNotch)
        ),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            form
                // A one-shot per request, not a loop: scroll, wait out the
                // tint, clear it. Keyed on the request so a second ask for
                // the same section restarts it, and on the form's first
                // layout so an ask that arrived before it is acted on once
                // there is something to scroll. Cancelled with the view.
                .task(id: controller.highlight.scrollKey) {
                    let request = controller.highlight.request
                    guard let section = controller.highlight.scrollTarget else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(section, anchor: .center)
                    }
                    try? await Task.sleep(for: Self.highlightDuration)
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) {
                        controller.highlight.fade(request: request)
                    }
                }
        }
    }

    private var form: some View {
        Form {
            if only == nil { appSections }

            ForEach(PreferencesSection.moduleGroups.filter { section in
                Self.rows.contains { $0.section == section && only?.contains($0.module) != false }
            }, id: \.self) { section in
                Section {
                    ForEach(Self.rows.filter { $0.section == section && only?.contains($0.module) != false }) { row in
                        moduleRow(row)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer {
                        Text(footer)
                    }
                }
                .id(section)
            }
        }
        .formStyle(.grouped)
        // Reported after layout, with the size layout produced: the moment
        // a `scrollTo` has rows to land on. See `PreferencesHighlight`.
        .onGeometryChange(for: Bool.self) { $0.size.height > 0 } action: { hasSize in
            if hasSize { controller.highlight.formDidLayOut() }
        }
    }

    @ViewBuilder
    private var appSections: some View {
        // First, and outside the `ForEach`: this is about the app rather
        // than about a module, and `PreferencesSection`'s cases are module
        // groups -- adding a case with no module rows would make the
        // "every section has rows" test meaningless.
        Section {
            LaunchAtLoginRow(controller: controller.launchAtLogin)
        } header: {
            Text("Startup", bundle: .creativeNotch)
        } footer: {
            Text("macOS owns this setting, so it is read back from the system rather than remembered here \u{2014} turning it off in System Settings turns it off here too.", bundle: .creativeNotch)
        }

        UpdatesSection(controller: controller.updates, highlighted: controller.highlight.section == .updates)
            .id(PreferencesSection.updates)

        Section {
            HoverRow(controller: controller)
        } header: {
            Text("Hover", bundle: .creativeNotch)
        } footer: {
            Text("Off, resting on the notch shows what is playing or what just changed, and a click or a two-finger swipe opens the panel. On, resting for the delay opens the panel directly.", bundle: .creativeNotch)
        }

        Section {
            DisplayRow(controller: controller)
            ClearOfMenusRow(controller: controller)
            TextSizeRow(controller: controller)
        } header: {
            Text("Display", bundle: .creativeNotch)
        } footer: {
            Text("With more than one display, following the focused window moves the notch to whichever display you are working on. Built-in keeps it on the laptop screen, and uses the main display when the lid is closed. A named display keeps it there; while that display is unplugged the notch waits on the built-in display and returns when it is connected again. Larger text makes the open panel larger to fit it; the closed notch and its glances stay their size, fitted to the camera housing.", bundle: .creativeNotch)
        }

        Section {
            LayoutRows(controller: controller)
        } header: {
            Text("Layout", bundle: .creativeNotch)
        } footer: {
            Text("Compact goes no narrower than leaves room for every tab, and for the eyedropper, battery and gear, beside the camera. With the calendar on, six tabs need more than Default's width there, so Default widens to fit them. Hiding a badge only clears it from beside the closed notch: the timer still chimes and shows when it ends. The recording dot always shows; the camera and microphone indicator has its own switch below.", bundle: .creativeNotch)
        }
    }

    /// Internal rather than private so the feature renders can draw one
    /// row in its real form, warning and all, without the whole window.
    @ViewBuilder
    func moduleRow(_ row: PreferencesRow) -> some View {
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
                    recorder: controller.recorder(for: hotKey)
                )
                .padding(.leading, 36)
            }

            if row.module == .colorPicker, controller.isEnabled(.colorPicker) {
                ColorFormatRow(controller: controller)
                    .padding(.leading, 36)
            }

            if Self.hasLimits(row.module), controller.isEnabled(row.module) {
                LimitsRows(module: row.module, controller: controller)
                    .padding(.leading, 36)
            }

            if row.module == .bluetooth, controller.isBluetoothDenied {
                BluetoothDeniedRow(controller: controller)
                    .padding(.leading, 36)
            }

            if let warning = Self.warning(for: row.module, controller: controller) {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 36)
            }

            if Self.offersPrivacySettings(row.module, controller: controller) {
                Button(String(localized: "Open Privacy Settings\u{2026}", bundle: .creativeNotch)) { controller.openDownloadsPrivacy() }
                    .controlSize(.small)
                    .padding(.leading, 36)
            }
        }
        // The row a "Set Shortcut…" was pressed for, tinted with the
        // accent until it fades, so the eye lands on it in a long form.
        .background {
            if controller.highlight.section == row.section {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .padding(-6)
            }
        }
    }

    /// Which modules have limits to adjust, shown under their switch while
    /// it is on — the shape the shortcut's recorder already has. Static so
    /// a test can pin the list against `LimitsRows`.
    static func hasLimits(_ module: ModuleID) -> Bool {
        switch module {
        case .shelf, .clipboard, .timer: return true
        default: return false
        }
    }

    /// Conditional warnings. Shown unconditionally they would be ignored.
    static func warning(for module: ModuleID, controller: PreferencesController) -> String? {
        switch module {
        case .timer where controller.hasRunningCountdown:
            // Required by the spec: the tab you would cancel it from is what
            // disappears, so say what happens to the countdown.
            return String(localized: "A countdown is running. Switching the timer off removes the tab you would cancel it from — it will finish and chime.", bundle: .creativeNotch)
        case .downloads where controller.isEnabled(.downloads):
            // Switched on and seeing nothing is possible here too: the
            // switch must not read "on" over a refusal without saying so.
            return controller.downloadsAccess.warning
        case .calendar where controller.calendarAccessRefused:
            // A switch must not read "on" over a module that can read
            // nothing (ARCHITECTURE.md, "Why the settings surface is a
            // window").
            return String(localized: "Calendars and Reminders access is off in System Settings, so the glance has nothing to show. Turn it on in Privacy & Security.", bundle: .creativeNotch)
        case .calendar where controller.calendarAccessRestricted:
            return String(localized: "Calendars and Reminders access is restricted on this Mac by a profile or Screen Time, so the glance has nothing to show.", bundle: .creativeNotch)
        default:
            return nil
        }
    }

    /// Whether the row offers the way to fix its warning: only downloads,
    /// only while on and refused.
    static func offersPrivacySettings(_ module: ModuleID, controller: PreferencesController) -> Bool {
        module == .downloads && controller.isEnabled(.downloads) && controller.downloadsAccess == .denied
    }
}

/// What Bluetooth alerts say when macOS has refused them (2026-10-24).
///
/// A denied grant is not an error, it is a choice the person made — the
/// camera's rule — but left unsaid it reads as a broken module: switched
/// on, never shows anything. So it says what happened and offers the one
/// place it can be undone.
struct BluetoothDeniedRow: View {
    let controller: PreferencesController

    static let message = String(localized: "Bluetooth access is off for CreativeNotch, so no alerts can show. Allow it in System Settings › Privacy & Security › Bluetooth.", bundle: .creativeNotch)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.message)
                .font(.caption)
                .foregroundStyle(.orange)
            Button(String(localized: "Open Bluetooth Settings", bundle: .creativeNotch)) {
                controller.openBluetoothSettings()
            }
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
                        Text("Open at login", bundle: .creativeNotch)
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
            Button(String(localized: "Open Login Items", bundle: .creativeNotch)) {
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

/// "Open on hover" and its delay (2026-10-17).
///
/// Holds a local copy so the slider moves smoothly, and writes every change
/// through the controller, which saves and applies it.
struct HoverRow: View {
    let controller: PreferencesController
    @State private var behaviour: HoverBehaviour

    init(controller: PreferencesController) {
        self.controller = controller
        _behaviour = State(initialValue: controller.hoverBehaviour)
    }

    /// The delay beside its slider: "0.5 s". The number is formatted for the
    /// region, the unit comes from the catalog. That is a deliberate change
    /// from the old `String(format: "%.1f s")`, which printed "0.5 s" even
    /// where every other number on the Mac reads "0,5"; in a point-decimal
    /// region the text is unchanged.
    static func delayLabel(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let number = seconds.formatted(.number.precision(.fractionLength(1)).locale(locale))
        return String(localized: "\(number) s", bundle: .creativeNotch, comment: "Hover delay in seconds")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { behaviour.opensOnHover },
                set: { behaviour.opensOnHover = $0; controller.setHoverBehaviour(behaviour) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open on hover", bundle: .creativeNotch)
                            .font(.body.weight(.medium))
                        Text("Open the panel by resting the pointer on the notch.", bundle: .creativeNotch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.indigo)
                        )
                }
            }

            if behaviour.opensOnHover {
                HStack(spacing: 10) {
                    Text("Delay", bundle: .creativeNotch)
                    Slider(
                        value: Binding(
                            get: { behaviour.openDelay },
                            set: { behaviour.openDelay = $0; controller.setHoverBehaviour(behaviour) }
                        ),
                        in: HoverBehaviour.delayRange,
                        step: 0.1
                    )
                    Text(Self.delayLabel(behaviour.openDelay))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.leading, 36)
            }
        }
    }
}

/// "Show on" (2026-10-24): which display the notch lives on.
///
/// Reads the controller rather than holding a copy, unlike `HoverRow`: a
/// menu has no in-between values to keep smooth, and reading what applied
/// means the row cannot show a choice that was not saved.
struct DisplayRow: View {
    let controller: PreferencesController

    /// What each choice is called in the menu. Here rather than on the Core
    /// enum, which stores the choice and knows nothing of how it is worded.
    /// A specific display goes by the name macOS gives it, the one System
    /// Settings → Displays shows, and says so when it is unplugged -- the
    /// pin is kept, and the panel is waiting for it.
    static func title(for option: DisplayChoice.Option) -> String {
        switch option.choice {
        case .focusedWindow: return String(localized: "Display with the focused window", bundle: .creativeNotch)
        case .builtIn:       return String(localized: "Built-in display", bundle: .creativeNotch)
        case .display:
            let name = option.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "External display", bundle: .creativeNotch)
            return option.isConnected ? name : String(localized: "\(name) (not connected)", bundle: .creativeNotch)
        }
    }

    var body: some View {
        Picker(selection: Binding(
            get: { controller.displayChoice },
            set: { controller.setDisplayChoice($0) }
        )) {
            ForEach(controller.displayOptions, id: \.choice) { option in
                Text(Self.title(for: option)).tag(option.choice)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show on", bundle: .creativeNotch)
                        .font(.body.weight(.medium))
                    Text("Which display the notch lives on.", bundle: .creativeNotch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "display")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.cyan)
                    )
            }
        }
    }
}

/// "Keep clear of app menus" (2026-10-26): on a display with no notch, the
/// pill moves right of the frontmost app's menus when they reach under it.
///
/// Reading another app's menus needs Accessibility access, which switching
/// this on asks for. Left unsaid, a refusal would read as a switch that does
/// nothing -- the Bluetooth row's rule -- so it says so and offers the one
/// place it can be changed.
struct ClearOfMenusRow: View {
    let controller: PreferencesController

    static let missingAccessMessage = String(localized: "Accessibility access is off for CreativeNotch, so the pill stays centred. Allow it in System Settings › Privacy & Security › Accessibility; it applies from the next app you switch to.", bundle: .creativeNotch)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { controller.pillClearsMenus },
                set: { controller.setPillClearsMenus($0) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep clear of app menus", bundle: .creativeNotch)
                            .font(.body.weight(.medium))
                        Text("On a display without a notch, moves the pill right of the menus of the app in front when they reach under it. Needs Accessibility access.", bundle: .creativeNotch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.indigo)
                        )
                }
            }
            if controller.isMissingAccessibility {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.missingAccessMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Open Accessibility Settings", bundle: .creativeNotch)) {
                        controller.openAccessibilitySettings()
                    }
                }
                .padding(.leading, 36)
            }
        }
    }
}

/// "Text size" (2026-10-24): how large the open panel's text is.
///
/// Reads the controller rather than holding a copy, for the reason
/// `DisplayRow` gives.
struct TextSizeRow: View {
    let controller: PreferencesController

    /// What each size is called in the menu. Here rather than on the Core
    /// enum, which stores the size and knows nothing of how it is worded.
    static func title(for size: TextSize) -> String {
        switch size {
        case .standard: return String(localized: "Default", bundle: .creativeNotch, comment: "Text size")
        case .large:    return String(localized: "Large", bundle: .creativeNotch, comment: "Text size")
        case .larger:   return String(localized: "Larger", bundle: .creativeNotch, comment: "Text size")
        }
    }

    var body: some View {
        Picker(selection: Binding(
            get: { controller.textSize },
            set: { controller.setTextSize($0) }
        )) {
            ForEach(TextSize.allCases, id: \.self) { size in
                Text(Self.title(for: size)).tag(size)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text size", bundle: .creativeNotch)
                        .font(.body.weight(.medium))
                    Text("How large the open panel's text is.", bundle: .creativeNotch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.blue)
                    )
            }
        }
    }
}

/// "Copy as" under the colour picker's switch (2026-10-24): which text a
/// picked colour becomes on the pasteboard.
///
/// Reads the controller rather than holding a copy, for the reason
/// `DisplayRow` gives. Each choice shows a sample of itself, so the menu
/// answers "what will I get" without a trip to the panel.
struct ColorFormatRow: View {
    let controller: PreferencesController

    /// The menu's wording: the name, then what the format looks like. Here
    /// rather than on the Core enum, which knows nothing of how it is worded.
    static func title(for format: ColorFormat) -> String {
        let name: String
        switch format {
        case .hex:     name = String(localized: "Hex", bundle: .creativeNotch)
        case .rgb:     name = String(localized: "RGB", bundle: .creativeNotch)
        case .hsl:     name = String(localized: "HSL", bundle: .creativeNotch)
        // The framework's name, the same in every language.
        case .swiftUI: name = "SwiftUI"
        }
        let example = format.string(for: sample)
        return String(localized: "\(name) \u{2014} \(example)", bundle: .creativeNotch, comment: "A colour format's name, then a sample of it: Hex — #3A7BD5")
    }

    /// The colour every sample is printed in.
    static let sample = SampledColor(red8: 58, green8: 123, blue8: 213)

    var body: some View {
        Picker(String(localized: "Copy as", bundle: .creativeNotch), selection: Binding(
            get: { controller.colorFormat },
            set: { controller.setColorFormat($0) }
        )) {
            ForEach(ColorFormat.allCases, id: \.self) { format in
                Text(Self.title(for: format)).tag(format)
            }
        }
        .pickerStyle(.menu)
    }
}

/// The adjustable limits under the shelf, clipboard and timer switches
/// (2026-10-24).
///
/// Holds no copy of its own, unlike `HoverRow`: every control reads
/// `controller.limits` — `AppState`'s, which is observable — and writes the
/// whole value back through `setLimits`, so what the row shows is always what
/// applied, normalisation included. A preset typed as 500 reads back as 99.
///
/// The one exception is a shelf change that would trash files: the row shows
/// it (`displayedLimits`) while "Move N files to the Trash?" asks, and goes
/// back to what applied if the answer is Cancel. One dialog serves both shelf
/// pickers, since only one change can be held at a time.
struct LimitsRows: View {
    let module: ModuleID
    let controller: PreferencesController

    /// A chime's name in the menu. The sounds keep the names macOS gives
    /// them — they are the files in `/System/Library/Sounds`, and the raw
    /// value is what `NSSound(named:)` is handed — so only "None", which is
    /// this app's word, is translated.
    static func title(for chime: ChimeSound) -> String {
        chime == .none
            ? String(localized: "None", bundle: .creativeNotch, comment: "Timer chime: no sound")
            : chime.rawValue
    }

    /// One field of `Limits`, both directions. Static and built from a key
    /// path, like `LaunchAtLoginRow.binding`, so a test can drive the exact
    /// binding a control is given without rendering it.
    static func binding<Value>(
        _ keyPath: WritableKeyPath<Limits, Value>,
        on controller: PreferencesController
    ) -> Binding<Value> {
        Binding(
            get: { controller.displayedLimits[keyPath: keyPath] },
            set: { value in
                var limits = controller.limits
                limits[keyPath: keyPath] = value
                controller.setLimits(limits)
            }
        )
    }

    /// Whether the shelf's "Move N files to the Trash?" is up. Dismissing it
    /// any way other than the destructive button — Cancel, Escape — is a
    /// cancel, so the held change is dropped and the picker reverts. Static,
    /// like `binding`, so a test can drive it without rendering.
    ///
    /// A dismissal cancels only the change the dialog was showing. When
    /// "Move to Trash" finds the count has grown, `confirmLimits` holds the
    /// change again with the new count; if SwiftUI reports the dismissal
    /// after that action, it must not drop the new question unasked.
    static func confirming(_ controller: PreferencesController) -> Binding<Bool> {
        let shown = ShownChange()
        return Binding(
            get: {
                shown.change = controller.pendingLimits.change
                return shown.change != nil
            },
            set: { presented in
                guard !presented else { return }
                let held = controller.pendingLimits.change
                if shown.change == nil || held == shown.change { controller.cancelLimits() }
            }
        )
    }

    /// The change the presentation binding last reported as up.
    private final class ShownChange {
        var change: PendingLimits.Change?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch module {
            case .shelf:
                Picker(String(localized: "Holds", bundle: .creativeNotch, comment: "Shelf capacity"), selection: Self.binding(\.shelfCapacity, on: controller)) {
                    ForEach(Limits.shelfCapacityChoices, id: \.self) { Text(String(localized: "\($0) items", bundle: .creativeNotch)).tag($0) }
                }
                Picker(String(localized: "Keeps files for", bundle: .creativeNotch), selection: Self.binding(\.shelfExpiry, on: controller)) {
                    ForEach(ShelfExpiry.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .confirmationDialog(
                    controller.pendingLimits.change?.removal.title ?? "",
                    isPresented: Self.confirming(controller),
                    titleVisibility: .visible,
                    presenting: controller.pendingLimits.change
                ) { change in
                    Button(change.removal.confirmLabel, role: .destructive) {
                        controller.confirmLimits(change)
                    }
                    Button(String(localized: "Cancel", bundle: .creativeNotch), role: .cancel) { controller.cancelLimits() }
                } message: { change in
                    Text(change.removal.message)
                }
            case .clipboard:
                Picker(String(localized: "Remembers", bundle: .creativeNotch, comment: "Clipboard capacity"), selection: Self.binding(\.clipboardCapacity, on: controller)) {
                    ForEach(Limits.clipboardCapacityChoices, id: \.self) { Text(String(localized: "\($0) items", bundle: .creativeNotch)).tag($0) }
                }
                ExcludedAppsRows(controller: controller)
            case .timer:
                presets
                Picker(String(localized: "Chime", bundle: .creativeNotch), selection: Self.binding(\.chime, on: controller)) {
                    ForEach(ChimeSound.allCases, id: \.self) { Text(Self.title(for: $0)).tag($0) }
                }
                .help(String(localized: "With None, a timer that finishes while the panel is open shows no peek and makes no sound.", bundle: .creativeNotch))
                TimerNoticeRow(controller: controller)
            default:
                EmptyView()
            }
        }
        .pickerStyle(.menu)
    }

    /// Three number fields, one per preset button in the timer tab. Typed
    /// rather than stepped: going from 25 to 90 by clicks is a chore, and
    /// unlike the panel this window holds the keyboard. Out-of-range values
    /// are clamped by `Limits` and read back clamped.
    private var presets: some View {
        HStack(spacing: 8) {
            Text("Presets", bundle: .creativeNotch)
            Spacer()
            ForEach(0..<Limits.defaultTimerPresets.count, id: \.self) { index in
                // No title: the accessibility label names it. `String()`, not
                // `""`, which would be a lookup of an empty catalog key.
                TextField(String(), value: Self.binding(\.timerPresets[index], on: controller), format: .number)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)
                    .accessibilityLabel(String(localized: "Preset \(index + 1), in minutes", bundle: .creativeNotch))
            }
            Text("min", bundle: .creativeNotch)
                .foregroundStyle(.secondary)
        }
        .help(String(localized: "\(Limits.presetRange.lowerBound)\u{2013}\(Limits.presetRange.upperBound) minutes each", bundle: .creativeNotch))
    }
}

/// "Notify when hidden by a full-screen app" (2026-10-24), under the timer's
/// chime.
///
/// Reads the controller rather than holding a copy, for the reason
/// `DisplayRow` gives. The line underneath is `TimerDoneNotice.settingsNote`:
/// nothing while notifications are allowed, when macOS will ask while it has
/// not, and -- denied, or allowed with the alert style at None -- that the
/// switch cannot do what it says until System Settings says otherwise, with
/// the way there (`TimerDoneNotice.settingsWarning`).
struct TimerNoticeRow: View {
    let controller: PreferencesController

    /// System Settings → Notifications. The pane, not this app's row in it:
    /// there is no documented URL for one app's entry.
    static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!

    static func binding(for controller: PreferencesController) -> Binding<Bool> {
        Binding(
            get: { controller.timerNotifyWhenHidden },
            set: { controller.setTimerNotifyWhenHidden($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(String(localized: "Notify when hidden by a full-screen app", bundle: .creativeNotch), isOn: Self.binding(for: controller))
                .toggleStyle(.checkbox)
                .help(String(localized: "The notch is hidden over full-screen apps, so a timer that finishes there also posts a notification.", bundle: .creativeNotch))
            if let note = controller.timerNoticeNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(controller.timerNoticeWarning != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.timerNoticeWarning != nil {
                Button(String(localized: "Open Notification Settings", bundle: .creativeNotch)) {
                    NSWorkspace.shared.open(Self.notificationSettingsURL)
                }
            }
        }
    }
}

/// "Ignore copies from" (2026-10-24): clipboard history's excluded apps,
/// under its capacity.
///
/// "+" chooses apps in an open panel on `/Applications`; "−" on a row removes
/// that one. Empty by default, and says what that means: password-manager
/// entries marked concealed are skipped whatever this list holds.
struct ExcludedAppsRows: View {
    let controller: PreferencesController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ignore copies from", bundle: .creativeNotch)
            let apps = controller.clipboardExcludedApps.map(ExcludedApp.init(bundleID:))
            if apps.isEmpty {
                Text("No apps. Everything you copy is remembered, except entries password managers mark as concealed.", bundle: .creativeNotch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(apps) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            Text(app.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(app.bundleID)
                            Spacer()
                            Button {
                                controller.removeExcludedApp(app.bundleID)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Stop ignoring \(app.name)", bundle: .creativeNotch))
                            .accessibilityLabel(String(localized: "Remove \(app.name)", bundle: .creativeNotch))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Button {
                controller.addExcludedApps()
            } label: {
                Label(String(localized: "Add App\u{2026}", bundle: .creativeNotch), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Add an app to ignore", bundle: .creativeNotch))
        }
    }
}
