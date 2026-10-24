import AppKit
import UniformTypeIdentifiers

/// One app on clipboard history's excluded list, as Settings shows it
/// (2026-10-24).
///
/// Only the bundle identifier is stored; the name and icon are looked up
/// from Launch Services each time the row is drawn, so a renamed or updated
/// app shows as it is now. An app that is no longer installed is listed by
/// its identifier rather than dropped -- it is still excluded if it comes
/// back, and the row is how to remove it.
struct ExcludedApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let url: URL?

    var id: String { bundleID }

    init(bundleID: String) {
        self.bundleID = bundleID
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        self.url = url
        self.name = url.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? bundleID
    }

    /// The app's own icon, or the generic application icon when it is not
    /// installed.
    var icon: NSImage {
        if let url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    /// "+": an open panel on `/Applications` that accepts only apps, and the
    /// bundle identifiers of what was chosen -- empty when cancelled, or for
    /// a bundle with no identifier, which nothing could ever match.
    @MainActor
    static func chooseWithOpenPanel() -> [String] {
        let panel = NSOpenPanel()
        panel.title = "Ignore Copies From"
        panel.prompt = "Ignore"
        panel.message = "Copies made in these apps will not be added to clipboard history."
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}
