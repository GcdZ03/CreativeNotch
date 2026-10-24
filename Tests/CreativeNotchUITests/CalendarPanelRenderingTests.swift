import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the panel draws the calendar: its tab, last in the one bar with the
/// others (so it moves with them when the tabs go to the right ear), and each
/// state of its pane.
///
/// Rendered offscreen in the shape `PanelRenderingTests` set, with the
/// calendar, locale and instant pinned through the environment and
/// `NotchRootView(now:)`, so a render reads the same on any machine at any
/// hour.
@MainActor
struct CalendarPanelRenderingTests {

    /// 09:12 on Wednesday 21 October 2026, Berlin.
    static let now = CalendarDates.date(9, 12)
    static let locale = Locale(identifier: "en_GB")

    /// A morning with something under way, something soon, something later,
    /// and more than three rows' worth, so the limit is exercised.
    static let busyDay: CalendarSnapshot = {
        let d = CalendarDates.self
        return CalendarSnapshot(
            eventsAccess: .granted,
            remindersAccess: .granted,
            events: [
                d.event("Product sync", start: d.date(9), end: d.date(9, 30),
                        color: CalendarColor(red: 1.0, green: 0.62, blue: 0.04)),
                d.event("Design review", start: d.date(9, 40), end: d.date(10, 30),
                        color: CalendarColor(red: 0.27, green: 0.55, blue: 1.0)),
                d.event("Lunch with Sam", start: d.date(12, 30), end: d.date(13, 30),
                        color: CalendarColor(red: 0.2, green: 0.82, blue: 0.35), calendarTitle: "Home"),
                d.event("Release week", start: d.date(0), end: d.date(0, dayOffset: 1), allDay: true,
                        color: CalendarColor(red: 0.75, green: 0.35, blue: 0.95)),
                d.event("1:1 with Priya", start: d.date(10, dayOffset: 1), end: d.date(10, 30, dayOffset: 1)),
            ],
            reminders: [
                d.reminder(d.date(8)),                      // overdue
                d.reminder(d.date(17)),                     // due today
                d.reminder(d.date(0), hasTime: false),      // due today, no time
            ],
            refreshedAt: now
        )
    }()

    static func snapshot(events: CalendarAccess, reminders: CalendarAccess) -> CalendarSnapshot {
        CalendarSnapshot(eventsAccess: events, remindersAccess: reminders, refreshedAt: now)
    }

    /// The 14-inch panel `PanelRenderingTests` uses, with the calendar on --
    /// sized as the app sizes it for the tabs that show (`fit`), which with
    /// the calendar's sixth tab is wider than 620.
    static func state(_ snapshot: CalendarSnapshot?, tab: CreativeNotchCore.Tab = .calendar,
                      calendarOn: Bool = true, tabsSide: EarSide = .left) -> AppState {
        let s = PanelRenderingTests.state()
        s.preferences.calendar = calendarOn
        s.layoutOptions.tabsSide = tabsSide
        s.calendar = snapshot
        fit(s)
        s.transition(to: .open(tab))
        return s
    }

    /// Re-sizes `s`'s panel for the tabs it shows, at its text size, on the
    /// 14" screen -- the frame `AppDelegate.panelFrame(on:)` would give it.
    static func fit(_ s: AppState) {
        let screen = TextSizeRenderingTests.screen
        let anchor = NotchGeometry.anchor(for: screen)
        s.setGeometry(anchor: anchor, panelFrame: NotchGeometry.panelFrame(
            for: anchor, in: screen, textScale: s.textSize.scale, width: s.layoutOptions.width,
            tabCount: TabVisibility.visible(enabled: s.preferences, hasBattery: s.hasBattery).count
        ))
    }

    static func panel(_ s: AppState) -> some View {
        NotchRootView(app: s, now: now)
            .frame(width: s.panelFrame.width, height: s.panelFrame.height)
            .environment(\.calendar, CalendarDates.calendar)
            .environment(\.locale, locale)
            .environment(\.timeZone, CalendarDates.calendar.timeZone)
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: panel(s))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    static func png(_ s: AppState) -> Data? {
        bitmap(s)?.representation(using: .png, properties: [:])
    }

    /// The bar's sixth slot, where the calendar's icon sits at the standard
    /// size: in from the edge of the ear that holds the tabs by the inset and
    /// five buttons with their gaps.
    static func calendarSlot(_ s: AppState) -> CGRect {
        let step = PanelLayout.tabButtonWidth + PanelLayout.tabSpacing
        let x = s.layoutOptions.tabsSide == .left
            ? PanelLayout.earInset + 5 * step
            : s.panelFrame.width - PanelLayout.earInset - PanelLayout.tabButtonWidth
        return CGRect(x: x, y: 4, width: PanelLayout.tabButtonWidth, height: 24)
    }

    /// The module pane, right of the music column, under the title row.
    static let paneRect = CGRect(x: 230, y: 70, width: 370, height: 170)

    // MARK: - The tab

    /// On, the calendar's icon is the bar's sixth; off, the bar ends at five
    /// and the panel is the 620 it always was.
    @Test func theBarShowsTheCalendarOnlyWhileItIsOn() throws {
        let onState = Self.state(Self.busyDay, tab: .shelf)
        let offState = Self.state(nil, tab: .shelf, calendarOn: false)
        #expect(onState.panelFrame.width == 678)
        #expect(offState.panelFrame.size == NotchGeometry.expandedSize)
        let on = try #require(Self.bitmap(onState))
        let off = try #require(Self.bitmap(offState))
        #expect(PanelRenderingTests.ink(on, in: Self.calendarSlot(onState)) > 0.02)
        #expect(PanelRenderingTests.ink(off, in: Self.calendarSlot(onState)) == 0)
    }

    /// Selected, the icon gets the tab bar's highlight, like any tab -- in
    /// the left ear or, with the tabs moved, the right.
    @Test(arguments: EarSide.allCases)
    func theCalendarIconHighlightsWhenSelected(side: EarSide) throws {
        let selectedState = Self.state(Self.busyDay, tabsSide: side)
        let selected = try #require(Self.bitmap(selectedState))
        let unselected = try #require(Self.bitmap(Self.state(Self.busyDay, tab: .shelf, tabsSide: side)))
        let slot = Self.calendarSlot(selectedState)
        #expect(PanelRenderingTests.ink(selected, in: slot) > PanelRenderingTests.ink(unselected, in: slot),
                "no highlight in the \(side) ear's last slot")
    }

    /// The status ear -- dropper, battery and gear -- is untouched by the
    /// calendar: it sits against the panel's outer edge, and the calendar is
    /// in the other ear's bar. Compared from the right edge, since the panel
    /// is wider with the calendar on.
    @Test func theStatusEarIsUntouched() throws {
        let on = try #require(Self.bitmap(Self.state(Self.busyDay, tab: .shelf)))
        let off = try #require(Self.bitmap(Self.state(nil, tab: .shelf, calendarOn: false)))
        let crop: (NSBitmapImageRep) -> Data? = { rep in
            let width: CGFloat = 200
            guard let cg = rep.cgImage?.cropping(
                to: CGRect(x: CGFloat(rep.pixelsWide) - width, y: 0, width: width, height: 32)
            ) else { return nil }
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        #expect(Render.same(try #require(crop(on)), try #require(crop(off))))
    }

    /// At every text size, with the tabs in either ear, six tabs in one and
    /// the dropper, battery and gear in the other stay clear of the camera
    /// housing.
    @Test(arguments: TextSize.allCases, EarSide.allCases)
    func theHeaderStaysOutOfTheHousing(size: TextSize, side: EarSide) throws {
        let s = TextSizeRenderingTests.state(size)
        s.preferences.calendar = true
        s.layoutOptions.tabsSide = side
        s.calendar = Self.busyDay
        Self.fit(s)
        s.transition(to: .open(.calendar))
        let b = try #require(Self.bitmap(s))
        #expect(PanelRenderingTests.ink(b, in: TextSizeRenderingTests.housing(s)) == 0,
                "the header reaches the housing at \(size) with the tabs on the \(side)")
    }

    // MARK: - The pane

    @Test func thePaneDrawsItsRows() throws {
        let busy = try #require(Self.png(Self.state(Self.busyDay)))
        var empty = Self.busyDay
        empty.events = []
        let quiet = try #require(Self.png(Self.state(empty)))
        #expect(Render.differs(busy, quiet))
    }

    /// The rows are the three Core picks: timed events today first, the
    /// all-day one and tomorrow's held back by the limit.
    @Test func thePanePicksTheNextThree() {
        let rows = CalendarView.rows(for: Self.busyDay, now: Self.now, calendar: CalendarDates.calendar)
        #expect(rows.map(\.title) == ["Product sync", "Design review", "Lunch with Sam"])
    }

    @Test func everyAccessStateDrawsDifferently() throws {
        let renders = try [
            Self.busyDay,
            Self.snapshot(events: .notDetermined, reminders: .notDetermined),
            Self.snapshot(events: .denied, reminders: .denied),
            Self.snapshot(events: .restricted, reminders: .restricted),
        ].map { try #require(Self.png(Self.state($0))) }
        for i in renders.indices {
            for j in renders.indices where j > i {
                #expect(Render.differs(renders[i], renders[j]), "states \(i) and \(j) render the same")
            }
        }
    }

    /// Nothing in any calendar state runs off the bottom, at any text size.
    @Test(arguments: TextSize.allCases)
    func nothingRunsOffTheBottom(size: TextSize) throws {
        let states = [
            Self.busyDay,
            Self.snapshot(events: .notDetermined, reminders: .notDetermined),
            Self.snapshot(events: .denied, reminders: .denied),
            Self.snapshot(events: .granted, reminders: .notDetermined),
        ]
        for snapshot in states {
            let s = TextSizeRenderingTests.state(size)
            s.preferences.calendar = true
            s.calendar = snapshot
            Self.fit(s)
            s.transition(to: .open(.calendar))
            let renderer = ImageRenderer(content: Self.panel(s))
            renderer.scale = 1
            let b = try #require(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            #expect(TextSizeRenderingTests.stripInk(b, s) == 0,
                    "\(snapshot.pane) at \(size) runs off a \(s.panelFrame.size) panel")
        }
    }

    // MARK: - Screenshots for the README and the pull request

    /// Writes `docs/assets/features/calendar-*.png`: the panel at 2x on a
    /// stand-in wallpaper, as README's own render is. Opt-in, so the normal
    /// suite never rewrites files:
    ///
    ///     CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter CalendarPanelRenderingTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] == "1"))
    func writeTheFeatureScreenshots() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var quiet = Self.busyDay
        quiet.events = []
        quiet.reminders = []
        let shots: [(String, CalendarSnapshot)] = [
            ("calendar-glance", Self.busyDay),
            ("calendar-empty", quiet),
            ("calendar-access", Self.snapshot(events: .notDetermined, reminders: .notDetermined)),
            ("calendar-denied", Self.snapshot(events: .denied, reminders: .denied)),
        ]
        for (name, snapshot) in shots {
            let data = try #require(Self.screenshot(Self.state(snapshot)))
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        }

        // The largest text size, in the larger panel the app gives it, with
        // a track in the music column -- the fullest the pane gets.
        let larger = TextSizeRenderingTests.state(.larger)
        larger.preferences.calendar = true
        larger.calendar = Self.busyDay
        Self.fit(larger)
        larger.transition(to: .open(.calendar))
        let data = try #require(Self.screenshot(larger))
        try data.write(to: directory.appendingPathComponent("calendar-larger-text.png"))
    }

    /// The panel hanging from the top of a stand-in wallpaper, 40pt of
    /// desktop either side and below, at 2x. The wallpaper runs top to bottom
    /// so each row is one colour, which keeps the PNGs small.
    static func screenshot(_ s: AppState) -> Data? {
        let margin: CGFloat = 40
        let content = ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.24, green: 0.20, blue: 0.52),
                    Color(red: 0.55, green: 0.33, blue: 0.70),
                    Color(red: 0.93, green: 0.55, blue: 0.62),
                ],
                startPoint: .top, endPoint: .bottom
            )
            panel(s)
        }
        .frame(width: s.panelFrame.width + margin * 2, height: s.panelFrame.height + margin)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
