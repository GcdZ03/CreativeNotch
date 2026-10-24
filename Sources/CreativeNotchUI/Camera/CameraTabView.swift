@preconcurrency import AVFoundation
import SwiftUI
import CreativeNotchCore

/// The camera tab: the preview, a shutter, a record button, and a way out.
///
/// **It takes the full panel height and suppresses the chrome**, which is the
/// one thing that makes the geometry work. The content area left by the media
/// header and the tab bar is roughly 195 points, dropping to about 130 when a
/// track starts playing -- and a preview that resizes when music starts is not
/// acceptable. Taking all 260 leaves `expandedFrame` untouched, so no other tab
/// is affected.
///
/// Because the tab bar is gone, **this view owns the only way back**. A tab you
/// cannot leave is worse than a preview that letterboxes.
struct CameraTabView: View {
    let state: CameraController.State
    let session: AVCaptureSession
    let onShutter: () -> Void
    let onToggleRecording: () -> Void
    let onClose: () -> Void

    /// System Settings → Privacy & Security → Camera. Split out so a test can
    /// check the deep link, as `LaunchAtLoginController` does for its own:
    /// `NSWorkspace.shared.open` is not seamed.
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    )

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var body: some View {
        ZStack {
            switch state {
            case .denied:
                VStack(spacing: 2) {
                    message(
                        "CreativeNotch needs camera access",
                        detail: "Grant it in System Settings › Privacy & Security › Camera."
                    )
                    // The way to undo a refusal, not just its name: the panel
                    // closes the moment the cursor leaves to go looking.
                    Button("Open System Settings") {
                        if let url = Self.privacySettingsURL { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.ink(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.hairline(0.16)))
                }
            case .unavailable:
                message("No camera found", detail: "This Mac has no built-in camera.")
            case .idle, .previewing, .recording:
                CameraPreview(session: session, isMirrored: true)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            controls
        }
        // Fills what the tab bar left, rather than taking its intrinsic size.
        // `CameraPreview` is an `NSViewRepresentable` with no intrinsic
        // content size, so without this the ZStack can collapse and the
        // controls lose the space their Spacers need -- which is how the
        // close button ended up somewhere the user could not reach it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private func message(_ title: String, detail: String) -> some View {
        // Styled explicitly, as every other view in the panel is: a semantic
        // colour here resolves against whatever appearance the host has, and
        // in the offscreen renderer that is black on black.
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.ink(0.92))
            Text(detail)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.ink(0.55))
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                // The way out, since the tab bar is suppressed.
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.ink(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close camera")
            }
            Spacer()
            HStack(spacing: 18) {
                Button(action: onShutter) {
                    Image(systemName: "circle.inset.filled")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take a photo")
                .disabled(state == .denied || state == .unavailable)

                Button(action: onToggleRecording) {
                    Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.largeTitle)
                        .foregroundStyle(isRecording ? .red : .white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecording ? "Stop recording" : "Record a clip")
                .disabled(state == .denied || state == .unavailable)
            }
            .padding(.bottom, 4)
        }
    }
}
