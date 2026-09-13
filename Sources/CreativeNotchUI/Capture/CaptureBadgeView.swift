import SwiftUI
import CreativeNotchCore

/// The privacy tell: something is using the microphone or the camera.
///
/// It sits in the notch's trailing ear, next to the hardware it is about — the
/// camera is directly above it, which is the whole reason this module belongs
/// in a notch rather than a menu bar item.
///
/// Both glyphs can show at once, because both devices can be in use at once
/// and collapsing that to one icon would hide half of what the user most wants
/// to know. The slot is the two-glyph width whichever is showing, so the
/// closed notch never resizes mid-call.
struct CaptureBadgeView: View {
    let use: CaptureUse

    var body: some View {
        HStack(spacing: 3) {
            if use.microphone {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Microphone in use")
            }
            if use.camera {
                Image(systemName: "video.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Camera in use")
            }
        }
        .padding(.trailing, 8)
    }
}
