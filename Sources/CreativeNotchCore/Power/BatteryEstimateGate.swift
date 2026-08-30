import Foundation

/// Decides whether IOKit's time-remaining estimate is worth showing.
///
/// The roadmap names this as the module's real problem. IOKit's estimate
/// swings for minutes after a plug or unplug and while the system
/// recalibrates, and a number that jumps from 1:20 to 4:55 and back reads
/// as a broken app rather than an honest estimate.
///
/// Filtering the documented `-1` "Still Calculating" sentinel is not
/// enough on its own: the swinging values are reported *confidently*, as
/// ordinary integers. So two further rules apply, both measured rather
/// than guessed (`docs/research/2026-08-30-battery-estimate-noise.md`):
///
/// - **A settling window.** For `settlingWindow` after any power-source
///   transition, nothing is shown at all.
/// - **Agreement.** Outside the window, a value is shown only once two
///   consecutive readings agree within `agreementTolerance`.
///
/// This is the shape `HUDSignificanceGate` uses for the ambient light
/// sensor, and it is the same answer to the same question: decide what
/// counts as signal, document the threshold, and stay silent below it.
///
/// Pure and time-injected, so every rule here is arithmetic and the whole
/// type is tested without a clock, a timer, or a battery.
public struct BatteryEstimateGate: Equatable, Sendable {

    /// How long after a power-source transition nothing is shown.
    ///
    /// MEASURED — see the research note. Do not adjust without repeating
    /// the measurement; this is the number that decides whether the panel
    /// is honest in the minutes when someone is most likely to be looking
    /// at it.
    public static let settlingWindow: TimeInterval = 90

    /// How far two consecutive readings may differ and still be believed,
    /// as a fraction of the larger of the two.
    ///
    /// Relative rather than absolute, because five minutes of disagreement
    /// on a two-hour estimate is noise and the same five minutes on an
    /// eight-minute estimate is not.
    ///
    /// MEASURED. Over 39 minutes of steady discharge, consecutive
    /// notification-driven readings moved by a median of 3.1% and never by
    /// more than 4.7%, even while a build pushed the estimate from 7.6
    /// hours down to 3.4. 10% is a little over double the observed
    /// worst case, and still rejects the swing the roadmap complains about
    /// — 1:20 to 4:55 is a 73% disagreement. See
    /// `docs/research/2026-08-30-battery-estimate-noise.md`.
    public static let agreementTolerance: Double = 0.10

    /// The smallest disagreement that is always forgiven, in minutes.
    ///
    /// IOKit does not report a continuous estimate. It quantises, and the
    /// probe measured the steps: of 36 distinct values seen, 27 were
    /// exactly 5 or 10 minutes apart. A single step is therefore the
    /// smallest change the estimator can express, and it is not evidence
    /// of anything.
    ///
    /// This matters because a purely relative tolerance is *too strict* at
    /// the bottom of the range, which is the opposite of the usual worry.
    /// One 10-minute step is 4% of four hours and 50% of twenty minutes,
    /// so a 10% relative rule alone would reject every ordinary step below
    /// roughly an hour remaining — leaving the panel stuck on
    /// "Estimating…" from an hour of battery down to empty, exactly where
    /// the number is worth having.
    public static let quantisationFloor: Int = 10

    /// The last reading, waiting for a second one to agree with it.
    private var candidate: Int?

    /// When the power source last changed. `nil` means it has not changed
    /// since launch, which is the ordinary case for a machine that has
    /// been sitting on the desk.
    private var lastTransition: TimeInterval?

    public init() {}

    /// Records a power-source transition, restarting the settling window
    /// and discarding any agreement collected before it.
    ///
    /// Discarding the candidate is not housekeeping. The machine is now
    /// doing something different, so agreement reached about the old
    /// regime says nothing about the new one.
    public mutating func noteTransition(at time: TimeInterval) {
        lastTransition = time
        candidate = nil
    }

    /// Returns the estimate if it should be shown, or `nil` to stay silent.
    ///
    /// - Parameter estimateMinutes: IOKit's estimate, already converted
    ///   from the `-1` sentinel to `nil` by `PowerObserver`.
    public mutating func accept(estimateMinutes: Int?, now: TimeInterval) -> Int? {
        // "Still calculating" is a statement that the previous number no
        // longer stands, so it breaks the run rather than being skipped
        // over — otherwise the readings either side of it would count as
        // consecutive across a gap the system itself flagged.
        guard let estimate = estimateMinutes else {
            candidate = nil
            return nil
        }

        if isSettling(now: now) {
            // The candidate is still recorded, so the first reading after
            // the window can be agreed with rather than starting from
            // nothing — but nothing is shown while the window is open,
            // however stable the readings are. A steady wrong number is
            // exactly what a recalibrating estimator produces.
            candidate = estimate
            return nil
        }

        defer { candidate = estimate }

        guard let candidate, agree(candidate, estimate) else { return nil }
        return estimate
    }

    /// Whether the settling window is still open.
    ///
    /// A negative elapsed time counts as settling. Clocks from different
    /// sources are not guaranteed to agree, and the failure mode of
    /// reading a backward clock as "long ago" is a gate that opens at the
    /// exact instant the charger moves — the one moment it must not.
    private func isSettling(now: TimeInterval) -> Bool {
        guard let lastTransition else { return false }
        return now - lastTransition < Self.settlingWindow
    }

    /// Whether two readings agree: proportionally to the larger of them,
    /// or within one quantisation step, whichever is more forgiving.
    ///
    /// The floor is what keeps the low end usable — see
    /// `quantisationFloor`. It does mean a 10-to-20-minute disagreement is
    /// accepted, which sounds careless until you notice that one
    /// quantisation step is genuinely all IOKit can express there, and the
    /// alternative is saying nothing at all for the last hour.
    private func agree(_ a: Int, _ b: Int) -> Bool {
        let difference = abs(a - b)
        if difference <= Self.quantisationFloor { return true }

        let larger = Double(max(a, b))
        guard larger > 0 else { return a == b }
        return Double(difference) / larger <= Self.agreementTolerance
    }
}
