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

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var body: some View {
        ZStack {
            switch state {
            case .denied:
                message(
                    "CreativeNotch needs camera access",
                    detail: "Grant it in System Settings › Privacy & Security › Camera."
                )
            case .unavailable:
                message("No camera found", detail: "This Mac has no built-in camera.")
            case .idle, .previewing, .recording:
                CameraPreview(session: session, isMirrored: true)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            controls
        }
        .padding(12)
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
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
                        .foregroundStyle(.white.opacity(0.8))
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
