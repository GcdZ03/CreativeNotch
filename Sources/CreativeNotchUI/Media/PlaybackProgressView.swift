import SwiftUI
import CreativeNotchCore

/// The music peek's progress bar and its two times (spec 2026-10-15,
/// follow-up).
///
/// **No clock in this view.** The UI bans `TimelineView`, and a bar that
/// redrew itself once a second would be exactly the steady cost the notch
/// is built to avoid. Instead:
///
/// - the bar is set to where playback is *now*, then handed one linear
///   animation to the end of the track over the time remaining. One
///   animation, not a loop; it is restarted only when a play, pause or
///   seek republishes the position.
/// - the times use `Text(timerInterval:)`, which the system keeps current
///   without this view re-evaluating.
///
/// Paused, both are plain values: the bar stands still and the times are
/// ordinary text.
struct PlaybackProgressView: View {
    let position: PlaybackPosition
    let isPlaying: Bool

    @Environment(\.animatesPlaybackProgress) private var motionAllowed
    @State private var shown: Double

    init(position: PlaybackPosition, isPlaying: Bool) {
        self.position = position
        self.isPlaying = isPlaying
        _shown = State(initialValue: position.fraction(at: Date(), isPlaying: isPlaying))
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: g.size.width * shown)
                }
            }
            .frame(height: 4)

            HStack {
                elapsedText
                Spacer()
                remainingText
            }
            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
        .onAppear(perform: run)
        .onChange(of: position) { run() }
        .onChange(of: isPlaying) { run() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(Self.clock(position.elapsed(at: Date(), isPlaying: isPlaying))) of \(Self.clock(position.duration))"
        )
    }

    /// Snaps the bar to now, then — while playing — runs it to the end of
    /// the track in one linear animation.
    private func run() {
        let now = Date()
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { shown = position.fraction(at: now, isPlaying: isPlaying) }

        guard isPlaying, motionAllowed else { return }
        let remaining = position.remaining(at: now, isPlaying: true)
        guard remaining > 0 else { return }
        withAnimation(.linear(duration: remaining)) { shown = 1 }
    }

    /// The track's span on the wall clock, so `Text(timerInterval:)` can
    /// count through it: it started `elapsed` ago and lasts `duration`.
    private var span: ClosedRange<Date> {
        let now = Date()
        let start = now.addingTimeInterval(-position.elapsed(at: now, isPlaying: true))
        return start...start.addingTimeInterval(position.duration)
    }

    @ViewBuilder
    private var elapsedText: some View {
        if isPlaying && motionAllowed {
            Text(timerInterval: span, countsDown: false, showsHours: false)
        } else {
            Text(Self.clock(position.elapsed(at: Date(), isPlaying: isPlaying)))
        }
    }

    @ViewBuilder
    private var remainingText: some View {
        if isPlaying && motionAllowed {
            HStack(spacing: 0) {
                Text("-")
                Text(timerInterval: span, countsDown: true, showsHours: false)
            }
        } else {
            Text("-" + Self.clock(position.remaining(at: Date(), isPlaying: isPlaying)))
        }
    }

    /// `m:ss`, whole seconds, rounded down — the format
    /// `Text(timerInterval:)` uses, so the paused text and the running
    /// timer read alike. Hours run on as minutes; tracks that long are rare
    /// and the peek has no room for a third field.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

extension EnvironmentValues {
    /// Whether the progress bar runs and its times count. On everywhere in
    /// the app, Reduce Motion included — a bar creeping along is the
    /// information itself, not decoration. Off only where a render must be
    /// repeatable.
    @Entry var animatesPlaybackProgress: Bool = true
}
