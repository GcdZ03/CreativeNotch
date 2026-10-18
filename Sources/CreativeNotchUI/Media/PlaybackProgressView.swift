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
///
/// **Seeking (2026-10-18).** Handed an `onSeek`, the bar takes a click or a
/// drag: the bar and the times follow the finger, and letting go sends the
/// seek. The bar jumps there at once (`PlaybackPosition.seeked`) rather than
/// waiting for the player to republish, and gives way to the player's own
/// reading as soon as one arrives. The touch target is taller than the 4pt
/// bar, which thickens under the pointer to say it can be grabbed.
struct PlaybackProgressView: View {
    let position: PlaybackPosition
    let isPlaying: Bool
    var onSeek: ((TimeInterval) -> Void)? = nil

    @Environment(\.animatesPlaybackProgress) private var motionAllowed
    @State private var shown: Double
    /// The bar's own reading after a seek, until the player's arrives.
    @State private var seekedTo: PlaybackPosition?
    /// Where a drag in progress points, as a time.
    @State private var scrubbing: TimeInterval?
    @State private var hovering = false

    init(position: PlaybackPosition, isPlaying: Bool, onSeek: ((TimeInterval) -> Void)? = nil) {
        self.position = position
        self.isPlaying = isPlaying
        self.onSeek = onSeek
        _shown = State(initialValue: position.fraction(at: Date(), isPlaying: isPlaying))
    }

    /// What the bar and the times show: a fresh seek's reading, or the
    /// player's.
    private var current: PlaybackPosition { seekedTo ?? position }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: g.size.width * shown)
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(seekGesture(width: g.size.width), including: onSeek == nil ? .none : .all)
                .onHover { hovering = $0 && onSeek != nil }
            }
            // Taller than the bar, so it can be grabbed without aiming for 4pt.
            .frame(height: onSeek == nil ? 4 : 14)
            .animation(.easeOut(duration: 0.12), value: hovering)

            HStack {
                elapsedText
                Spacer()
                remainingText
            }
            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
        .onAppear(perform: run)
        .onChange(of: position) {
            // The player has spoken; its reading wins over the bar's guess.
            seekedTo = nil
            run()
        }
        .onChange(of: isPlaying) { run() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(Self.clock(current.elapsed(at: Date(), isPlaying: isPlaying))) of \(Self.clock(current.duration))"
        )
    }

    private var barHeight: CGFloat { hovering || scrubbing != nil ? 6 : 4 }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let t = PlaybackPosition.seekTime(atX: value.location.x, width: width,
                                                        duration: position.duration) else { return }
                scrubbing = t
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { shown = t / position.duration }
            }
            .onEnded { value in
                defer { scrubbing = nil }
                guard let t = PlaybackPosition.seekTime(atX: value.location.x, width: width,
                                                        duration: position.duration) else { return }
                seekedTo = position.seeked(to: t, at: Date())
                onSeek?(t)
                run()
            }
    }

    /// Snaps the bar to now, then — while playing — runs it to the end of
    /// the track in one linear animation.
    private func run() {
        guard scrubbing == nil else { return }
        let now = Date()
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { shown = current.fraction(at: now, isPlaying: isPlaying) }

        guard isPlaying, motionAllowed else { return }
        let remaining = current.remaining(at: now, isPlaying: true)
        guard remaining > 0 else { return }
        withAnimation(.linear(duration: remaining)) { shown = 1 }
    }

    /// The track's span on the wall clock, so `Text(timerInterval:)` can
    /// count through it: it started `elapsed` ago and lasts `duration`.
    private var span: ClosedRange<Date> {
        let now = Date()
        let start = now.addingTimeInterval(-current.elapsed(at: now, isPlaying: true))
        return start...start.addingTimeInterval(current.duration)
    }

    /// While dragging, the times show where the finger is, not the clock.
    @ViewBuilder
    private var elapsedText: some View {
        if let scrubbing {
            Text(Self.clock(scrubbing))
        } else if isPlaying && motionAllowed {
            Text(timerInterval: span, countsDown: false, showsHours: false)
        } else {
            Text(Self.clock(current.elapsed(at: Date(), isPlaying: isPlaying)))
        }
    }

    @ViewBuilder
    private var remainingText: some View {
        if let scrubbing {
            Text("-" + Self.clock(current.duration - scrubbing))
        } else if isPlaying && motionAllowed {
            HStack(spacing: 0) {
                Text("-")
                Text(timerInterval: span, countsDown: true, showsHours: false)
            }
        } else {
            Text("-" + Self.clock(current.remaining(at: Date(), isPlaying: isPlaying)))
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
