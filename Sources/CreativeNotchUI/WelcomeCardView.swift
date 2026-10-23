import SwiftUI
import CreativeNotchCore

/// The first-run welcome card, over the open panel's body (2026-10-24).
///
/// In the panel rather than a window of its own: the panel is what the user
/// just opened, so that is where they are looking, and a welcome window
/// would be one more thing to close before the notch can be used. It covers
/// the body only — the header stays live, so the tabs it describes are right
/// there to try, and switching between them keeps the card
/// (`WelcomeCard.isDismissed`).
///
/// Arrangement only. Whether it shows, what dismisses it and what it says
/// are all `WelcomeCard`, in Core, where they are tested; the two buttons
/// are verbs handed in, like every pane's.
struct WelcomeCardView: View {
    let onSetShortcut: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        // `ModulePane` for the title row, so the card reads as one more pane
        // rather than as a dialog that arrived from somewhere else.
        ModulePane(title: "Welcome to CreativeNotch") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(WelcomeCard.tips, id: \.symbolName) { tip in
                        HStack(spacing: 10) {
                            Image(systemName: tip.symbolName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 18)
                                // The sentence says it; the glyph would only
                                // make VoiceOver read a symbol name first.
                                .accessibilityHidden(true)
                            Text(tip.text)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Spacer(minLength: 10)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Set Shortcut\u{2026}", action: onSetShortcut)
                        .buttonStyle(NotchButtonStyle(.quiet))
                        .accessibilityHint("Opens Settings at the global shortcut. No shortcut is set until you choose one.")
                    Button("Got it", action: onDismiss)
                        .buttonStyle(NotchButtonStyle(.prominent))
                        .accessibilityHint("Hides this welcome. Show it again from the menu bar icon.")
                }
            }
        }
        // Opaque, so the pane underneath does not show through and its
        // controls cannot be reached around the card.
        .background(Color.black)
        .contentShape(.rect)
        // A stray click on the card's blank space would otherwise reach the
        // shape's tap, which closes an open panel — and closing counts as
        // having read it. Only the buttons, and the header, act.
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to CreativeNotch")
    }
}
