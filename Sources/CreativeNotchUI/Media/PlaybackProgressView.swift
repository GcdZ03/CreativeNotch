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
    /// Where the fill starts and how long it takes to reach the end, set
    /// each time the bar restarts. `run` bumps `epoch`, which gives the fill
    /// a new identity: it is rebuilt at `start` and slides on from there.
    ///
    /// Not one long-lived animated value, as it was: setting the start and
    /// animating to the end in the same instant let SwiftUI merge the two,
    /// and after a seek the fill slid — or jumped — from the wrong place,
    /// once straight to full with 3 minutes left (2026-10-18).
    @State private var start: Double
    @State private var remaining: TimeInterval = 0
    @State private var epoch = 0
    /// The bar's own reading after a seek, until the player's arrives.
    @State private var seekedTo: PlaybackPosition?
    /// Where a drag in progress points, as a time.
    @State private var scrubbing: TimeInterval?
    @State private var hovering = false

    init(position: PlaybackPosition, isPlaying: Bool, onSeek: ((TimeInterval) -> Void)? = nil) {
        self.position = position
        self.isPlaying = isPlaying
        self.onSeek = onSeek
        _start = State(initialValue: position.fraction(at: Date(), isPlaying: isPlaying))
    }

    /// What the bar and the times show: a fresh seek's reading, or the
    /// player's.
    private var current: PlaybackPosition { seekedTo ?? position }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.hairline(0.15))
                    if let scrubbing {
                        // Under the finger: exactly where it points, no motion.
                        Capsule()
                            .fill(.ink(0.85))
                            .frame(width: g.size.width * scrubbing / position.duration)
                    } else {
                        Fill(
                            start: start,
                            remaining: remaining,
                            moves: isPlaying && motionAllowed,
                            width: g.size.width
                        )
                        .id(epoch)
                    }
                }
                // Drawn at a fixed thickness and *stretched* thicker under
                // the pointer, with that animation scoped to the stretch.
                //
                // The thickness used to be the frame's height, animated on
                // hover. The fill's frame is mid-way through a minutes-long
                // slide to full width, and re-animating its size for the
                // thickness re-animated the width too: the bar ran to full
                // in 0.12s on hover, or at the end of a drag (2026-10-18).
                .frame(height: Self.drawnHeight)
                .animation(.easeOut(duration: 0.12)) { bar in
                    bar.scaleEffect(y: barHeight / Self.drawnHeight)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(seekGesture(width: g.size.width), including: onSeek == nil ? .none : .all)
                .onHover { hovering = $0 && onSeek != nil }
            }
            // Taller than the bar, so it can be grabbed without aiming for 4pt.
            .frame(height: onSeek == nil ? 4 : 14)

            HStack {
                elapsedText
                Spacer()
                remainingText
            }
            // At the panel's text size in the music column, and at one in
            // the peek, which sets no scale (`notchTextScale`).
            .notchFont(10, weight: .medium, design: .rounded)
            .monospacedDigit()
            .foregroundStyle(.ink(0.5))
        }
        .onAppear(perform: run)
        .onChange(of: position) {
            // The player has spoken; its reading wins over the bar's guess.
            seekedTo = nil
            run()
        }
        .onChange(of: isPlaying) { run() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Playback position", bundle: .creativeNotch))
        .accessibilityValue(
            String(localized: "\(Self.clock(current.elapsed(at: Date(), isPlaying: isPlaying))) of \(Self.clock(current.duration))", bundle: .creativeNotch, comment: "Playback position: 1:02 of 3:45")
        )
    }

    private var barHeight: CGFloat { hovering || scrubbing != nil ? 6 : 4 }

    /// The thickness the bar is drawn at; `barHeight` is reached by scaling.
    private static let drawnHeight: CGFloat = 6

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                scrubbing = PlaybackPosition.seekTime(atX: value.location.x, width: width,
                                                      duration: position.duration)
            }
            .onEnded { value in
                // Cleared *before* restarting the bar. It used to be cleared
                // after, so the restart saw a drag still in progress and
                // skipped itself.
                scrubbing = nil
                guard let t = PlaybackPosition.seekTime(atX: value.location.x, width: width,
                                                        duration: position.duration) else { return }
                seekedTo = position.seeked(to: t, at: Date())
                onSeek?(t)
                run()
            }
    }

    /// Restarts the fill at where playback is now: a fresh fill, at the
    /// right place, sliding to the end over the time left.
    private func run() {
        let now = Date()
        start = current.fraction(at: now, isPlaying: isPlaying)
        remaining = current.remaining(at: now, isPlaying: true)
        epoch += 1
    }

    /// The moving part of the bar. Built at `start`; on appearing it slides
    /// to the end over `remaining`, in one linear animation — no clock, no
    /// loop. A restart replaces it rather than re-animating it.
    private struct Fill: View {
        let start: Double
        let remaining: TimeInterval
        let moves: Bool
        let width: CGFloat
        @State private var fraction: Double

        init(start: Double, remaining: TimeInterval, moves: Bool, width: CGFloat) {
            self.start = start
            self.remaining = remaining
            self.moves = moves
            self.width = width
            _fraction = State(initialValue: start)
        }

        var body: some View {
            Capsule()
                .fill(.ink(0.85))
                .frame(width: width * fraction)
                .onAppear {
                    guard moves, remaining > 0 else { return }
                    withAnimation(.linear(duration: remaining)) { fraction = 1 }
                }
        }
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
                Text(verbatim: "-")
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
