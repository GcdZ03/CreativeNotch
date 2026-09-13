import SwiftUI

/// The dot that says the camera is on.
///
/// **This is what makes the camera's exemption from the activity gate
/// defensible.** A recording that outlives the panel runs with the green
/// camera light on and nothing else to explain it; this is the explanation.
/// Without it the module would be doing exactly what this project exists to
/// prevent -- capturing while nobody is looking at anything that says so.
///
/// It shows no elapsed time, deliberately. A duration would need the
/// once-a-second redraw that `TimerSchedule` was carefully built to avoid, and
/// what this has to communicate is "the camera is on", which a dot says
/// completely.
struct RecordingBadgeView: View {
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .padding(.trailing, 9)
            .accessibilityLabel("Recording")
    }
}
