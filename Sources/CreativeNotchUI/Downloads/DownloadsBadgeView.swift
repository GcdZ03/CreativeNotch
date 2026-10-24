import SwiftUI
import CreativeNotchCore

/// Downloads in progress, in the trailing ear of the closed notch: a ring
/// filling with the aggregate percent, and a count beside it when there is
/// more than one.
///
/// No clock. The ring moves only when `AppState.downloads` changes, which is
/// at most once per whole percent (`DownloadSummary` is quantised), and each
/// move is one short ease to the new value — never a loop. An unknown length
/// draws the arrow in an empty track rather than a spinner: a spinner is a
/// repeating animation, and "downloading, size unknown" is said completely
/// by the arrow.
struct DownloadsBadgeView: View {
    let summary: DownloadSummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What VoiceOver reads: "Downloading report.pdf, 42 percent".
    var accessibilityText: String { summary.spoken }

    var body: some View {
        HStack(spacing: 3) {
            DownloadRing(fraction: summary.fraction, diameter: 14, lineWidth: 2)
            if let count = summary.countText {
                Text(count)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.ink(0.9))
                    .fixedSize()
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(width: NotchGeometry.downloadsBadgeWidth, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: summary.percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

/// The ring itself, shared by the badge and the peek: a faint track, the
/// filled arc from twelve o'clock, and a down arrow inside.
struct DownloadRing: View {
    /// 0...1, or `nil` for a download of unknown length.
    let fraction: Double?
    var diameter: CGFloat = 14
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(.hairline(0.25), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(.ink(0.95), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "arrow.down")
                .font(.system(size: diameter * 0.5, weight: .bold))
                .foregroundStyle(.ink(0.95))
        }
        .frame(width: diameter, height: diameter)
    }
}
