import AppKit
import SwiftUI

/// Shown once, on first launch, to explain why Accessibility access is
/// useful and to let the user grant it (or skip). Reopenable at any time
/// from the menu bar item.
@MainActor
public final class OnboardingController {

    private static let seenKey = "hasCompletedOnboarding"
    private let defaults: UserDefaults

    /// Reached whenever `show()` runs — whether it reuses an existing
    /// window or creates a fresh one. Bound to `presentRealWindow` by the
    /// public initializer; overridable only through the internal
    /// test-only initializer below, so `showIfNeeded()`'s "don't reach the
    /// window-presenting path once already seen" guarantee can be verified
    /// from a test without ever creating or presenting a real `NSWindow`.
    private let presenter: (OnboardingController) -> Void

    private var window: NSWindow?

    /// `defaults` is injectable so the "show only if not yet seen" decision
    /// below can be tested against an isolated `UserDefaults` suite instead
    /// of the real `.standard` domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Not `{ [weak self] in self?.presentRealWindow() }` — that would
        // capture `self` before all stored properties (including this one)
        // have initial values. Taking the instance as a parameter instead
        // sidesteps that entirely.
        self.presenter = { $0.presentRealWindow() }
    }

    /// Test-only seam: substitutes a spy for the real window-presenting
    /// path. Deliberately not `public` — reached from tests only via
    /// `@testable import`, so it can never be used to bypass the real
    /// presentation logic from production code.
    init(defaults: UserDefaults, presenter: @escaping (OnboardingController) -> Void) {
        self.defaults = defaults
        self.presenter = presenter
    }

    /// The pure "have we already shown onboarding" read `showIfNeeded()`
    /// gates on — separated out so it can be exercised in a test without
    /// ever creating or presenting the real window.
    public var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: Self.seenKey)
    }

    public func showIfNeeded() {
        guard !hasCompletedOnboarding else { return }
        show()
    }

    public func show() {
        presenter(self)
    }

    private func presentRealWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to CreativeNotch"
        window.center()
        window.isReleasedWhenClosed = false
        // `[weak window]`: the window transitively owns this closure
        // (window -> contentView -> rootView -> onDone), so capturing
        // `window` strongly would close a retain cycle and leak it.
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self, weak window] in
            self?.defaults.set(true, forKey: Self.seenKey)
            window?.close()
        })
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

struct OnboardingView: View {
    let onDone: () -> Void
    @State private var trusted = Permissions.isAccessibilityTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("One permission, to stay quiet")
                    .font(.title2.weight(.semibold))
                Text("CreativeNotch asks for Accessibility access for a single reason.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                point(
                    "keyboard",
                    "It notices the volume and brightness keys.",
                    "That is the only thing the permission is used for."
                )
                point(
                    "speaker.slash",
                    "So it can stand aside.",
                    "macOS already shows its own overlay for those keys. The notch speaks up only where macOS gives no feedback: Control Center, Siri, another app."
                )
                point(
                    "rectangle.on.rectangle",
                    "Without it, everything still works.",
                    "You will just see both indicators at once when you use the keys."
                )
            }

            Spacer()

            HStack {
                Label(
                    trusted ? "Granted" : "Not granted",
                    systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .foregroundStyle(trusted ? .green : .secondary)

                Spacer()

                if !trusted {
                    Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    Button("Grant Access") {
                        Permissions.requestAccessibility()
                    }
                    .keyboardShortcut(.defaultAction)
                }

                Button(trusted ? "Done" : "Skip for now", action: onDone)
                    .keyboardShortcut(trusted ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 360)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // Re-check when the user comes back from System Settings.
            // Event-driven, not polled.
            trusted = Permissions.isAccessibilityTrusted
        }
    }

    /// One reason, one line, one symbol.
    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
