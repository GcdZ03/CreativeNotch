import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The module joined to the app: controller to arbiter to panel state.
///
/// Modelled on `MediaWiringTests`. Every assertion here is about a
/// connection rather than about a decision — the decisions are already
/// pinned in `PowerControllerTests` and `PeekArbiterTests`, and were still
/// all correct on the day the now-playing peek was never once drawn.
@MainActor
struct PowerWiringTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchPower-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    private func snapshot(
        level: Int = 66,
        source: PowerSource = .battery,
        isCharging: Bool = false,
        isLowPowerMode: Bool = false
    ) -> PowerSnapshot {
        PowerSnapshot(
            level: level, source: source, isCharging: isCharging,
            isLowPowerMode: isLowPowerMode
        )
    }

    // MARK: - The controller exists and is owned

    @Test func installBuildsThePowerController() {
        #expect(makeDelegate().power != nil)
    }

    /// `install()` twice must not stack observers on `AppState` — the
    /// failure `observerCount` exists to catch.
    @Test func installingTwiceDoesNotStackObservers() {
        let delegate = makeDelegate()
        let after = delegate.state.observerCount

        delegate.install(metrics: Self.notched)

        #expect(delegate.state.observerCount == after)
    }

    // MARK: - Snapshots reach the panel

    @Test func aSnapshotReachesTheAppState() {
        let delegate = makeDelegate()

        delegate.powerDidChange(snapshot(level: 42, isCharging: true))

        #expect(delegate.state.power?.level == 42)
        #expect(delegate.state.power?.isCharging == true)
    }


    /// The first snapshot is proof of a battery. A machine that reports
    /// none at install and one a moment later would otherwise never show
    /// the tab.
    @Test func aSnapshotProvesThereIsABattery() {
        let delegate = makeDelegate()
        delegate.state.hasBattery = false

        delegate.powerDidChange(snapshot())

        #expect(delegate.state.hasBattery)
    }

    // MARK: - Events reach the peek

    @Test func aPowerEventBecomesAPeek() {
        let delegate = makeDelegate()

        delegate.showPowerPeek(.unplugged(level: 66))

        #expect(delegate.state.state == .peek(.power(.unplugged(level: 66))))
    }

    /// Recorded into the arbiter and then *asked* — not shown directly.
    /// A drag in progress outranks it, and the caller does not get to
    /// decide that.
    @Test func aDragStillOutranksAPowerEvent() {
        let delegate = makeDelegate()
        delegate.arbiter.setDragActive(true)

        delegate.showPowerPeek(.unplugged(level: 66))

        #expect(delegate.state.state == .peek(.dragTarget))
    }

    /// An open panel is a deliberate user state. A passing power change
    /// must not tear it down, exactly as a volume change must not.
    @Test func anOpenPanelIsNotReplacedByAPowerPeek() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))

        delegate.showPowerPeek(.unplugged(level: 66))

        #expect(delegate.state.state == .open(.shelf))
    }

    // MARK: - The peek clears

    /// The re-evaluation has to be scheduled for the *power* TTL. With one
    /// TTL in the app a single constant was the whole story; a 1.5s
    /// re-check against a 3s peek finds the arbiter still returning it,
    /// transitions to the state it is already in, and never looks again —
    /// leaving the notch open until something unrelated moves it.
    @Test func aPowerPeekClearsItself() async {
        let delegate = makeDelegate()
        delegate.powerTTLDelay = .zero
        var clock: TimeInterval = 100
        delegate.now = { clock }

        delegate.showPowerPeek(.unplugged(level: 66))
        #expect(delegate.state.state == .peek(.power(.unplugged(level: 66))))

        clock += PeekArbiter.powerTTL + 1
        await delegate.hudTTLTask?.value

        #expect(delegate.state.state == .closed)
    }

    /// And falls back to what was underneath rather than to nothing.
    @Test func aPowerPeekFallsBackToNowPlaying() async {
        let delegate = makeDelegate()
        delegate.powerTTLDelay = .zero
        var clock: TimeInterval = 100
        delegate.now = { clock }
        let track = TrackSnapshot(title: "T", artist: "A", isPlaying: true)
        delegate.arbiter.setNowPlaying(track)

        delegate.showPowerPeek(.unplugged(level: 66))
        clock += PeekArbiter.powerTTL + 1
        await delegate.hudTTLTask?.value

        #expect(delegate.state.state == .peek(.nowPlaying(track)))
    }

    /// A HUD peek fired over a live power peek expires first and reveals
    /// it — and the revealed peek must still be re-checked, or it stays on
    /// screen indefinitely.
    @Test func aHUDPeekOverAPowerPeekRevealsItAndStillClears() async {
        let delegate = makeDelegate()
        delegate.hudTTLDelay = .zero
        delegate.powerTTLDelay = .zero
        var clock: TimeInterval = 100
        delegate.now = { clock }

        delegate.showPowerPeek(.unplugged(level: 66))
        delegate.showHUD(.volume(0.5))
        #expect(delegate.state.state == .peek(.hud(HUDEvent(kind: .volume(0.5)))))

        // The HUD lapses; the power peek is still live underneath.
        clock += PeekArbiter.hudTTL + 0.1
        await delegate.hudTTLTask?.value
        #expect(delegate.state.state == .peek(.power(.unplugged(level: 66))))

        // And the revealed power peek clears in its turn.
        clock += PeekArbiter.powerTTL
        await delegate.hudTTLTask?.value

        #expect(delegate.state.state == .closed)
    }

    /// Which TTL each peek is re-checked on, read rather than timed.
    ///
    /// Timing cannot prove this. Every test here shrinks both delays to
    /// zero to avoid real sleeps, and at zero the two are
    /// indistinguishable — swapping them left the whole suite green.
    @Test func eachPeekIsRecheckedOnItsOwnTTL() {
        let hud = Duration.milliseconds(11)
        let power = Duration.milliseconds(22)
        let timerDone = Duration.milliseconds(33)

        #expect(AppDelegate.reevaluationDelay(
            for: .hud(HUDEvent(kind: .volume(0.5))),
            hud: hud, power: power, timerDone: timerDone
        ) == hud)

        #expect(AppDelegate.reevaluationDelay(
            for: .power(.unplugged(level: 66)),
            hud: hud, power: power, timerDone: timerDone
        ) == power)

        // Three distinct values, so a case returning the wrong neighbour's
        // delay is caught rather than passing by coincidence.
        #expect(AppDelegate.reevaluationDelay(
            for: .timerDone(TimerCompletion(duration: 1500, lateness: 0)),
            hud: hud, power: power, timerDone: timerDone
        ) == timerDone)
    }

    /// And the two constants match the arbiter they mirror. A TTL delay
    /// shorter than the arbiter's would re-check while the peek was still
    /// live; longer would leave it on screen past its own expiry.
    @Test func theTTLDelaysMirrorTheArbiter() {
        #expect(AppDelegate.defaultHUDTTLDelay
            == .milliseconds(Int(PeekArbiter.hudTTL * 1000)))
        #expect(AppDelegate.defaultPowerTTLDelay
            == .milliseconds(Int(PeekArbiter.powerTTL * 1000)))
    }
}
