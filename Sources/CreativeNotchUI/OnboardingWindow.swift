import AppKit
import SwiftUI

/// Shown once, on first launch, to explain why Accessibility access is
/// useful and to let the user grant it (or skip). Reopenable at any time
/// from the menu bar item.
@MainActor
public final class OnboardingController {

    private static let seenKey = "hasCompletedOnboarding"
    private let defaults: UserDefaults
    private var window: NSWindow?

    /// `defaults` is injectable so the "show only if not yet seen" decision
    /// below can be tested against an isolated `UserDefaults` suite instead
    /// of the real `.standard` domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to CreativeNotch"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            self?.defaults.set(true, forKey: Self.seenKey)
            window.close()
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
        VStack(alignment: .leading, spacing: 16) {
            Text("CreativeNotch needs Accessibility access")
                .font(.title2.weight(.semibold))

            Text("""
                 Two features depend on it:

                 • The HUD reads volume and brightness key presses so it can \
                 show them in the notch.
                 • The file shelf notices when you pick up a file, so it can \
                 open as a drop target.

                 The clipboard and the shelf's drop area work without it.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        .frame(width: 460, height: 320)
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
}
