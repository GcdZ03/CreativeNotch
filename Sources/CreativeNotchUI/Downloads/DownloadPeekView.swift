import SwiftUI
import CreativeNotchCore

/// The downloads peek: one row hanging below the notch, the battery peek's
/// shape (`.statusPeek`).
///
/// Two contents. While downloading — shown on hover over the badge — the
/// ring, the file name (or "3 downloads"), a bar and the percentage. When a
/// download finishes — shown unasked for a few seconds — a tick, "Downloaded
/// report.pdf" and a magnifying glass, because clicking the peek is how to
/// get to the file in Finder.
///
/// The name truncates in the middle, where a long download's name is least
/// informative: "Quarterly-rep…final.pdf" keeps both the start and the
/// extension.
struct DownloadPeekView: View {
    let content: Content

    /// The notch's own band, left empty; the row hangs below it.
    var bandHeight: CGFloat = 32

    /// What VoiceOver's activate does on a completion. A pointer click is the
    /// root view's tap (`NotchRootView.handleTap`), which an element that
    /// ignores its children does not pass on, so the same verb is offered
    /// here as the element's default action.
    var onReveal: (() -> Void)? = nil

    enum Content: Equatable {
        case progress(DownloadSummary)
        case done(DownloadCompletion)
    }

    /// The same words the announcement uses (`PeekAnnouncement`), so the
    /// VoiceOver cursor and the announcement agree.
    var accessibilityText: String {
        switch content {
        case .progress(let summary): return summary.spoken
        case .done(let completion):  return completion.text
        }
    }

    /// Whether clicking the peek does something of its own: revealing the
    /// finished file. A completion with no file offers nothing to reveal.
    var reveals: Bool {
        if case .done(let completion) = content { return completion.url != nil }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: bandHeight)
            HStack(spacing: 8) {
                switch content {
                case .progress(let summary):
                    DownloadRing(fraction: summary.fraction, diameter: 15, lineWidth: 2)
                        .frame(width: 18)
                    title(summary.title)
                    Spacer(minLength: 8)
                    if let fraction = summary.fraction, let text = summary.percentText {
                        bar(fraction).frame(width: 56)
                        Text(text)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.ink(0.9))
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                    }

                case .done(let completion):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.ink(0.95))
                        .frame(width: 18)
                    // The verb never truncates; the name gives way, in the
                    // middle, so its start and its extension both survive.
                    Text("Downloaded")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.ink(0.6))
                        .fixedSize()
                    title(completion.name)
                    Spacer(minLength: 8)
                    // Safari's own "show in Finder" glyph, rather than the
                    // words, which would take the name's room. The hint
                    // says it for VoiceOver.
                    if completion.url != nil {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.ink(0.6))
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(reveals ? .isButton : [])
        .accessibilityHint(reveals ? "Shows the file in Finder" : "")
        .accessibilityAction { if reveals { onReveal?() } }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.ink(0.95))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.hairline(0.18))
                Capsule()
                    .fill(.ink(0.9))
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 4)
    }
}
