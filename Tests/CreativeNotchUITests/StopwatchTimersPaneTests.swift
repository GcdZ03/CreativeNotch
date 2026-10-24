import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The timer tab's stopwatch and several countdowns (2026-10-24), as drawn:
/// which layout, which title-row verbs, what VoiceOver hears — through the
/// views' pure statics where they exist, and offscreen renders where the
/// claim is about pixels.
@MainActor
struct StopwatchTimersPaneTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func rows(_ durations: [TimeInterval], pausing: Set<Int> = []) -> [RunningTimer] {
        durations.enumerated().map { index, duration in
            var c = Countdown(duration: duration, startingAt: t0.addingTimeInterval(-90))!
            if pausing.contains(index) { c = c.paused(at: t0) }
            return RunningTimer(id: index, countdown: c)
        }
    }

    // MARK: - Layout

    /// One running looks exactly as it did when one was the whole model;
    /// two or more are a list; the picker comes back only when asked for.
    @Test func theLayoutFollowsTheCountAndTheAddFlag() {
        #expect(TimerTabView.layout(count: 0, isAdding: false) == .picker)
        #expect(TimerTabView.layout(count: 1, isAdding: false) == .single)
        #expect(TimerTabView.layout(count: 2, isAdding: false) == .list)
        #expect(TimerTabView.layout(count: 3, isAdding: false) == .list)
        #expect(TimerTabView.layout(count: 1, isAdding: true) == .picker)
    }

    // MARK: - The title row

    @Test func addIsOfferedBesideOneOrTwoAndNotAtTheCap() {
        let app = AppState()
        app.onStartTimer = { _ in }
        #expect(NotchRootView.timerActions(app, rows: []).isEmpty)
        #expect(NotchRootView.timerActions(app, rows: Self.rows([600])).map(\.label) == ["Add"])
        #expect(NotchRootView.timerActions(app, rows: Self.rows([600, 300])).map(\.label) == ["Add"])
        #expect(NotchRootView.timerActions(app, rows: Self.rows([600, 300, 60])).isEmpty)
    }

    @Test func addOpensThePickerAndBackClosesIt() throws {
        let app = AppState()
        app.onStartTimer = { _ in }
        let rows = Self.rows([600])
        try #require(NotchRootView.timerActions(app, rows: rows).first).perform()
        #expect(app.isAddingTimer)
        let back = try #require(NotchRootView.timerActions(app, rows: rows).first)
        #expect(back.label == "Back")
        back.perform()
        #expect(!app.isAddingTimer)
    }

    /// With the timer switched off there is no start verb, so no Add that
    /// would open a picker whose buttons do nothing.
    @Test func addIsNotOfferedWithNoStartVerb() {
        let app = AppState()
        #expect(NotchRootView.timerActions(app, rows: Self.rows([600])).isEmpty)
    }

    @Test func theStopwatchHasNoTimerVerbs() {
        let app = AppState()
        app.onStartTimer = { _ in }
        app.timerMode = .stopwatch
        #expect(NotchRootView.timerActions(app, rows: Self.rows([600])).isEmpty)
    }

    @Test func theCountReadsTheDurationForOneAndTheNumberForSeveral() {
        let app = AppState()
        #expect(NotchRootView.timerCount(app, rows: []) == nil)
        #expect(NotchRootView.timerCount(app, rows: Self.rows([1500])) == "25 min")
        #expect(NotchRootView.timerCount(app, rows: Self.rows([1500, 300])) == "2 running")

        app.timerMode = .stopwatch
        #expect(NotchRootView.timerCount(app, rows: []) == nil)
        app.stopwatch = Stopwatch().started(at: Self.t0).lapped(at: Self.t0.addingTimeInterval(5))
        #expect(NotchRootView.timerCount(app, rows: []) == "1 lap")
    }

    /// A countdown set on its own — as renders and older tests do — still
    /// draws in the tab, as a list of one.
    @Test func aBareCountdownIsAListOfOne() {
        let app = AppState()
        app.countdown = Countdown(duration: 600, startingAt: Self.t0)
        #expect(NotchRootView.timerRows(app).count == 1)
        app.timers = Self.rows([600, 300])
        #expect(NotchRootView.timerRows(app).count == 2)
    }

    // MARK: - What VoiceOver hears

    @Test func eachRowIsNamedByItsDuration() throws {
        let c = try #require(Countdown(duration: 1500, startingAt: Self.t0))
        #expect(TimerTabView.rowName(c) == "25-minute timer")
    }

    @Test func aStoppedStopwatchIsSpokenInWords() {
        #expect(StopwatchView.accessibilityValue(Stopwatch(), at: Self.t0) == "0 seconds")
        let paused = Stopwatch().started(at: Self.t0).paused(at: Self.t0.addingTimeInterval(65))
        #expect(StopwatchView.accessibilityValue(paused, at: Self.t0) == "Paused, 1 minute 5 seconds")
    }

    /// Paused is said in a word, not only by dimming; a reset or running
    /// stopwatch has nothing to add.
    @Test func onlyAPausedStopwatchCarriesTheWord() {
        #expect(StopwatchView.caption(Stopwatch()) == nil)
        let running = Stopwatch().started(at: Self.t0)
        #expect(StopwatchView.caption(running) == nil)
        #expect(StopwatchView.caption(running.paused(at: Self.t0.addingTimeInterval(1))) == "paused")
    }

    // MARK: - Pixels

    /// The list draws one row per countdown: three rows put ink lower in
    /// the pane than two do. Guards against a list that silently drops
    /// rows past the first.
    @Test func everyCountdownGetsARow() throws {
        func lowestInk(_ count: Int) throws -> Int {
            let s = PanelRenderingTests.state()
            s.timers = Self.rows(Array([1500, 300, 600].prefix(count)))
            s.countdown = s.timers.first?.countdown
            s.transition(to: .open(.timer))
            let b = try #require(PanelRenderingTests.bitmap(s))
            // The pane, right of the music column, below the title row.
            var lowest = 0
            for y in 80..<250 where PanelRenderingTests.ink(b, in: CGRect(x: 260, y: y, width: 330, height: 1)) > 0 {
                lowest = y
            }
            return lowest
        }
        #expect(try lowestInk(3) > lowestInk(2))
    }

    /// The stopwatch half draws in the pane where the countdown would.
    @Test func theStopwatchDrawsInThePane() throws {
        let s = PanelRenderingTests.state()
        s.timerMode = .stopwatch
        s.transition(to: .open(.timer))
        let b = try #require(PanelRenderingTests.bitmap(s))
        #expect(PanelRenderingTests.ink(b, in: CGRect(x: 260, y: 90, width: 330, height: 120)) > 0.01)
    }

    // MARK: - Screenshots (opt-in)

    /// Renders the feature's key states into `docs/assets/features/` for the
    /// README and the pull request. Opt-in, so the normal suite never
    /// rewrites tracked files:
    ///
    ///     RENDER_FEATURE_SCREENSHOTS=1 swift test --filter StopwatchTimersPaneTests
    ///
    /// The same offscreen renderer the pixel tests use, at 2x, on a
    /// stand-in wallpaper — the layout is exact, the desktop is not. A
    /// running stopwatch is drawn with its live count switched off, so the
    /// digits are the fixed reading at the render's `now`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RENDER_FEATURE_SCREENSHOTS"] == "1"))
    func renderFeatureScreenshots() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = Self.t0
        func base() -> AppState {
            let s = PanelRenderingTests.state()
            s.onStartTimer = { _ in }
            return s
        }
        let states: [(String, AppState, CGFloat)] = [
            ("empty", {
                let s = base()
                s.transition(to: .open(.timer))
                return s
            }(), 260),
            ("single", {
                let s = base()
                s.timers = Self.rows([1500])
                s.countdown = s.timers[0].countdown
                s.transition(to: .open(.timer))
                return s
            }(), 260),
            ("adding", {
                let s = base()
                s.timers = Self.rows([1500])
                s.countdown = s.timers[0].countdown
                s.isAddingTimer = true
                s.transition(to: .open(.timer))
                return s
            }(), 260),
            ("multiple", {
                let s = base()
                s.timers = Self.rows([1500, 300, 600], pausing: [2])
                s.countdown = s.timers[1].countdown
                s.transition(to: .open(.timer))
                return s
            }(), 260),
            ("ear-soonest", {
                let s = base()
                s.timers = Self.rows([1500, 300, 600], pausing: [2])
                s.countdown = s.timers[1].countdown
                return s
            }(), 70),
            ("stopwatch-reset", {
                let s = base()
                s.timerMode = .stopwatch
                s.transition(to: .open(.timer))
                return s
            }(), 260),
            ("stopwatch-running", {
                let s = base()
                let start = now.addingTimeInterval(-252)
                s.stopwatch = Stopwatch().started(at: start)
                    .lapped(at: start.addingTimeInterval(62))
                    .lapped(at: start.addingTimeInterval(130))
                    .lapped(at: start.addingTimeInterval(191))
                s.timerMode = .stopwatch
                s.transition(to: .open(.timer))
                return s
            }(), 260),
            ("stopwatch-paused", {
                let s = base()
                let start = now.addingTimeInterval(-300)
                s.stopwatch = Stopwatch().started(at: start)
                    .lapped(at: start.addingTimeInterval(62))
                    .paused(at: start.addingTimeInterval(97))
                s.timerMode = .stopwatch
                s.transition(to: .open(.timer))
                return s
            }(), 260),
        ]

        for (name, s, height) in states {
            let view = ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(red: 0.36, green: 0.42, blue: 0.78), Color(red: 0.78, green: 0.45, blue: 0.70)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                NotchRootView(app: s, now: now)
                    .frame(width: 620, height: 260)
                    .environment(\.stopwatchCountsLive, false)
                    .environment(\.notchDrawsFieldsAsText, true)
            }
            .frame(width: 620, height: height, alignment: .top)
            .clipped()
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("stopwatch-timers-\(name).png"))
        }
    }
}
