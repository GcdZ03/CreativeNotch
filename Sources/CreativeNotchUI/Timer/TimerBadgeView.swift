import SwiftUI
import CreativeNotchCore

/// The countdown, in the trailing ear of the closed notch.
///
/// Monospaced digits are not cosmetic here: proportional digits change
/// width as they change value, so `18m` and `11m` would render at different
/// widths and the text would shuffle sideways every minute inside a fixed
/// badge. `monospacedDigit` pins each glyph to the same advance.
///
/// Static, like the now-playing badge. Nothing here animates: the view
/// redraws only when `text` or `isPaused` changes, and the scheduler that
/// owns `AppState.countdown` decides when that is — this view has no clock
/// of its own.
struct TimerBadgeView: View {
    let text: String
    let isPaused: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            // Dimming is the paused signal. A pause glyph would compete
            // with three digits in a 44pt slot, and dimming has a property
            // worth having: a paused timer redraws zero times, because
            // nothing about it changes until it is resumed.
            .foregroundStyle(.white.opacity(isPaused ? 0.4 : 0.95))
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(isPaused ? "Timer paused, \(text) remaining"
                                         : "\(text) remaining")
    }
}
