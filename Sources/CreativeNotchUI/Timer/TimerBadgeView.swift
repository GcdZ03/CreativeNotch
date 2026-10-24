import SwiftUI
import CreativeNotchCore

/// The countdown, in the trailing ear of the closed notch.
///
/// Monospaced digits are not cosmetic here: proportional digits change
/// width as they change value, so `18m` and `11m` would render at different
/// widths and the text would shuffle sideways every minute inside a fixed
/// badge. `monospacedDigit` pins each glyph to the same advance.
///
/// Static, like the now-playing badge. The view redraws only when `text`
/// or `isPaused` changes, and the scheduler that owns `AppState.countdown`
/// decides when that is — this view has no clock of its own. When the
/// digits do change they roll to the new value (`rollingDigits`), a
/// fraction of a second once a minute, never a loop.
///
/// **Paused shows a glyph as well as dimming.** Dimming alone was the
/// signal for a long time, on the reasoning that a glyph would not fit
/// beside three digits in the 44pt slot. Rendered, it does: the widest
/// digits, `0:00`, are about 28pt at 12pt rounded, and a 7pt `pause.fill`
/// with 2pt of spacing brings that to about 37pt, still clear of the camera
/// housing at both notch heights (`TimerBadgeRenderingTests`). Two greys are
/// no signal under Differentiate Without Color, and Increase Contrast lifts
/// the dim one most of the way to the bright, so the shape is what says
/// paused to everyone. Both are free: a paused timer still redraws zero
/// times, since nothing about it changes until it is resumed. VoiceOver
/// hears "Timer paused, …" from `accessibilityText`.
struct TimerBadgeView: View {
    let text: String
    let isPaused: Bool
    /// The seconds `text` was formatted from, for VoiceOver's words —
    /// `25m` read aloud is "25 m". Optional only so the rendering tests can
    /// still draw a literal string such as `TimerDisplay.widestText`; the
    /// one production call site always passes it.
    var remaining: TimeInterval? = nil

    /// What VoiceOver reads: the time in words, at the digits' own
    /// granularity (`TimerSpokenText`), and whether it is paused.
    var accessibilityText: String {
        if let remaining { return TimerSpokenText.remaining(remaining, isPaused: isPaused) }
        return isPaused
            ? String(localized: "Timer paused, \(text) remaining", bundle: .creativeNotch)
            : String(localized: "\(text) remaining", bundle: .creativeNotch)
    }

    var body: some View {
        HStack(spacing: 2) {
            // Ahead of the digits, so they keep their place at the
            // trailing edge whether or not it shows.
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 7, weight: .bold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .rollingDigits(text, countsDown: true)
        }
        // Dimmed while paused, through `NotchInk` so Increase Contrast
        // lifts both shades -- which is why the glyph carries the signal.
        .foregroundStyle(.ink(isPaused ? 0.4 : 0.95))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
