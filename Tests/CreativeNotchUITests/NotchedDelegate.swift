import AppKit
import Foundation
import CreativeNotchCore
@testable import CreativeNotchUI

/// The synthetic notched screen the badge and wiring suites measure
/// against, and the delegate built on it.
///
/// Extracted rather than copied a third time. `NowPlayingBadgeTests`,
/// `TimerBadgeTests` and `TimerWiringTests` all assert about the *same*
/// three rectangles derived from the *same* geometry, and the numbers they
/// pin (230, 264, 274) are only comparable across the three suites because
/// the screen underneath them is identical. A private copy per suite makes
/// that comparability an accident a one-character edit can end silently.
///
/// What is deliberately **not** shared: the expected rects. Those stay
/// written out as literals in each suite, for the reason each suite's own
/// comment gives — a constant imported from production code would be the
/// code handing the test the number it is checked against.
///
/// Anchor (2090, 1118, 230, 38) inside panel (1895, 896, 620, 260), i.e.
/// panel-local closed rect (195, 222, 230, 38).
enum NotchedDelegate {

    static let metrics = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    /// A delegate installed on `metrics`, with everything that would
    /// otherwise reach the real machine switched off.
    ///
    /// - `growthDelay` is zero: the lag has its own suite, and these
    ///   suites are about the shape, so every sync is synchronous.
    /// - `shelfDirectory` is a fresh temporary one, so no test writes into
    ///   the user's real Application Support.
    /// - `playChime` is silenced. No test may make the machine audible;
    ///   the suite that cares about the chime replaces this with a
    ///   counter.
    ///
    /// `countdown` is applied *before* `install`, which seeds the accepted
    /// region from `visibleRect()` directly — that is how a test reaches
    /// the badged state without a scheduler running.
    @MainActor
    static func make(countdown: Countdown? = nil) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchNotched-\(UUID().uuidString)")
        delegate.playChime = {}
        delegate.state.countdown = countdown
        delegate.install(metrics: metrics)
        return delegate
    }
}
