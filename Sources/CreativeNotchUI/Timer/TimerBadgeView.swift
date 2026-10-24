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
        return isPaused ? "Timer paused, \(text) remaining" : "\(text) remaining"
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .rollingDigits(text, countsDown: true)
            // Dimming is the paused signal. A pause glyph would compete
            // with three digits in a 44pt slot, and dimming has a property
            // worth having: a paused timer redraws zero times, because
            // nothing about it changes until it is resumed.
            .foregroundStyle(.white.opacity(isPaused ? 0.4 : 0.95))
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(accessibilityText)
    }
}
