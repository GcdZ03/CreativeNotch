import SwiftUI
import CreativeNotchCore

/// The finished-timer peek.
///
/// Follows `NowPlayingPeekView`'s split: on a notched Mac the label hugs
/// the notch's left edge and the detail its right, so the pair reads as one
/// line interrupted by hardware. `notchGap` is zero on a notchless Mac and
/// on external displays, where a single centred line is correct.
struct TimerDonePeekView: View {
    let completion: TimerCompletion
    var notchGap: CGFloat = 0

    private var detail: String { TimerCompletionText.detail(for: completion) }

    /// "Timer done", not "Timer": beside the length alone, "Timer" read as
    /// a timer's name rather than one that had finished — most of all when
    /// the peek appears late, after a full-screen app hid the notch.
    var title: String { String(localized: "Timer done", bundle: .creativeNotch, comment: "Finished-timer peek, beside the notch") }

    /// The one-line form for a notchless display: "Timer done · 25m".
    var singleLine: String {
        String(localized: "Timer done · \(detail)", bundle: .creativeNotch, comment: "Finished-timer peek without a notch: Timer done · 25m")
    }

    /// The spoken completion, the same words VoiceOver is sent when this
    /// peek appears (`PeekAnnouncement`) — "25m · finished 5m ago" read
    /// aloud is letters and a dot.
    var accessibilityText: String { TimerSpokenText.completion(completion) }

    var body: some View {
        if notchGap > 0 {
            HStack(spacing: 0) {
                label(title, weight: .semibold, opacity: 0.95)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)

                Color.clear.frame(width: notchGap)

                label(detail, weight: .regular, opacity: 0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        } else {
            label(singleLine, weight: .medium, opacity: 0.9)
                .padding(.horizontal, 14)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
        }
    }

    private func label(_ s: String, weight: Font.Weight, opacity: Double) -> some View {
        Text(s)
            .font(.system(size: 12, weight: weight, design: .rounded))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
