import SwiftUI
import CreativeNotchCore

/// Settings → Updates (2026-10-24): the running version, what the updater
/// last found, and what can be done about it.
///
/// Every sentence here is `UpdateStatus.line` or `UpdateInstallEligibility`'s
/// notes, from Core, where they are tested; what is left is arrangement, in
/// the shape of the other rows — a tinted tile, a title over a caption, the
/// controls indented under it.
///
/// No spinner while it checks or installs: the line says "Checking…",
/// "Downloading…", and a spinner is a repeating animation the one rule would
/// have to make an exception for.
struct UpdatesSection: View {
    let controller: UpdateController
    /// Tinted like a module row when "Check for Updates…" lands here.
    var highlighted = false

    private var status: UpdateStatus { controller.status }
    private var eligibility: UpdateInstallEligibility { controller.eligibility }

    /// Failures in orange, as the module rows' warnings are.
    private var isFailure: Bool {
        switch status {
        case .checkFailed, .installFailed: return true
        default: return false
        }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CreativeNotch \(controller.currentVersion)", bundle: .creativeNotch)
                            .font(.body.weight(.medium))
                        Text(status.line(now: controller.environment.now()))
                            .font(.caption)
                            .foregroundStyle(isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.green)
                        )
                }

                buttons
                    .padding(.leading, 36)

                if status.release != nil, let note = eligibility.note {
                    command(note)
                        .padding(.leading, 36)
                } else if let note = eligibility.idleNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 36)
                }
            }
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .padding(-6)
                }
            }

            Toggle(isOn: Binding(
                get: { controller.automatic },
                set: { controller.setAutomatic($0) }
            )) {
                Text("Automatically check for updates", bundle: .creativeNotch)
            }
        } header: {
            Text(PreferencesSection.updates.title)
        } footer: {
            if let footer = PreferencesSection.updates.footer {
                Text(footer)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if status.installableRelease != nil, eligibility.canInstall {
                Button(String(localized: "Update Now", bundle: .creativeNotch)) { controller.installUpdate() }
                    .keyboardShortcut(.defaultAction)
            }
            Button(String(localized: "Check Now", bundle: .creativeNotch)) { controller.check(.manual) }
                .disabled(status.isBusy)
            if status.release != nil {
                Button(String(localized: "Release Notes", bundle: .creativeNotch)) { controller.openReleaseNotes() }
                    .buttonStyle(.link)
            }
        }
        .controlSize(.small)
    }

    /// Why this copy will not replace itself, and the line that will.
    private func command(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(UpdateInstallEligibility.installCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Copy", bundle: .creativeNotch)) { controller.copyInstallCommand() }
                    .controlSize(.small)
            }
        }
    }
}
