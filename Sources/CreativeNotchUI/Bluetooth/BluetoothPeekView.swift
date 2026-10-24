import SwiftUI
import CreativeNotchCore

/// What the notch shows for a moment when AirPods, headphones or a speaker
/// connect or disconnect.
///
/// The battery peek's shape (`PowerPeekView`): one row hanging below the
/// notch's band, read left to right — the device's glyph, its name, and
/// what happened. Nothing is split around the camera housing, because
/// nothing is drawn in the band.
///
/// The word "Connected" or "Disconnected" is always there: the state never
/// rests on the glyph or on dimming alone. And no battery level, because
/// there is no public API that gives one without polling (see
/// `BluetoothAudioEvent`).
///
/// Plain `.system(size:)` fonts, not `.notchFont`: peeks keep their fixed
/// heights whatever the text size, as `NotchType` explains.
struct BluetoothPeekView: View {

    let event: BluetoothAudioEvent

    /// The notch's own band, left empty; the row hangs below it.
    var bandHeight: CGFloat = 32

    /// The same words VoiceOver is sent when this peek appears
    /// (`PeekAnnouncement`), so a cursor landing on it agrees.
    var accessibilityText: String { BluetoothLabel.spoken(for: event) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: bandHeight)
            HStack(spacing: 8) {
                Image(systemName: event.kind.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink(0.9))
                    .frame(width: 18)
                Text(BluetoothLabel.title(for: event))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.ink(0.95))
                    .lineLimit(1)
                    // A long name loses its middle, not the end that says
                    // which pair it is ("Gerald's AirPods Pro").
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(BluetoothLabel.status(for: event))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.ink(0.6))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
