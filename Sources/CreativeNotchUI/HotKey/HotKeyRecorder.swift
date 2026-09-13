import AppKit
import SwiftUI
import CreativeNotchCore

/// Captures the next combination the user presses.
///
/// **This installs a LOCAL event monitor, not a global one**, and only while
/// actively recording. The distinction is the same one this module is built
/// on: a local monitor sees only events already destined for this app, and it
/// is removed the moment a combination lands or recording is cancelled.
/// `ARCHITECTURE.md`'s prohibition is on *permanently-installed global*
/// monitors, and nothing here is either.
///
/// It is an `NSView` rather than a SwiftUI `onKeyPress` because it must see
/// modifier state and raw keycodes, and because it has to swallow the
/// keystroke -- a ⌘W that reaches the window while recording would close it.
@MainActor
final class HotKeyRecorder: ObservableObject {

    @Published private(set) var isRecording = false

    private var monitor: Any?
    private let onCapture: (HotKeyCombo) -> Void

    /// Installing and removing the monitor, behind seams -- the shape
    /// `ClipboardPoller` uses for its timer, and for the same reason.
    ///
    /// Without them nothing can observe the monitor's lifetime: a `start()`
    /// that stacked two monitors, or a `stop()` that removed a stale token,
    /// would leave `isRecording` reading exactly the same. Mutation found both
    /// of those surviving before these existed.
    var installMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any? = { handler in
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: handler)
    }
    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    init(onCapture: @escaping (HotKeyCombo) -> Void) {
        self.onCapture = onCapture
    }

    /// `isolated deinit`, because the monitor must be removed on the main
    /// actor and an ordinary `deinit` is nonisolated -- Swift 6 refuses to
    /// let it touch the stored monitor at all.
    ///
    /// Dropping the cleanup instead would leak a local event monitor every
    /// time the settings window is closed mid-recording. Small, but it is
    /// precisely the class of cost this project exists to refuse.
    isolated deinit {
        if let monitor { removeMonitor(monitor) }
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        monitor = installMonitor { [weak self] event in
            guard let self else { return event }
            // Escape cancels without recording, which is the only way out that
            // does not involve binding a key you did not mean to.
            if event.keyCode == 53 {
                self.stop()
                return nil
            }
            let combo = HotKeyCombo(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: HotKeyModifier.carbon(
                    fromCocoaRawValue: event.modifierFlags.rawValue
                )
            )
            self.stop()
            self.onCapture(combo)
            // Swallowed: a ⌘W that reached the window while recording would
            // close it, and the user would have bound a key and lost the pane
            // in one keystroke.
            return nil
        }
    }

    func stop() {
        isRecording = false
        // `monitor` is the guard, not a flag. `NSEvent.removeMonitor` on a
        // token already removed is unsafe, and nilling it here is what makes a
        // second `stop()` a genuine no-op.
        //
        // An `isRecording` guard used to sit above this and was removed:
        // mutation showed it unobservable, because the optional binding
        // already does the work. A second check that cannot fail is a second
        // thing to keep true.
        if let monitor { removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether a monitor is currently installed. Exposed for the same reason
    /// `PowerObserver.registrationCount` is: `isRecording` is a flag this type
    /// sets itself, and a flag is not evidence.
    var isMonitoring: Bool { monitor != nil }
}

/// The settings row: what the shortcut is, and whether it has been proved.
struct HotKeyRow: View {
    let controller: HotKeyController
    @ObservedObject var recorder: HotKeyRecorder
    let label: String?

    var body: some View {
        HStack(spacing: 12) {
            Button(recorder.isRecording ? "Press a key…" : (label ?? "Record…")) {
                recorder.isRecording ? recorder.stop() : recorder.start()
            }
            .frame(minWidth: 120)

            if controller.combo != nil, !recorder.isRecording {
                Button("Clear") { controller.setCombo(nil) }
                    .buttonStyle(.borderless)
            }

            Spacer()

            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.status {
        case .unset:
            EmptyView()
        case .awaitingConfirmation:
            // The whole point of the module's honesty: registration succeeding
            // is not the feature, and this says so until the user proves it.
            Text("Press it now to confirm")
                .font(.caption)
                .foregroundStyle(.orange)
        case .confirmed:
            Label("Confirmed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
