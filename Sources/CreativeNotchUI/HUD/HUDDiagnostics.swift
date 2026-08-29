import Foundation

/// Appends the HUD's decisions to a log file, so a peek that appeared when
/// nobody touched anything can be traced to the filter that let it
/// through — rather than reasoned about from the outside.
///
/// Opt-in and off by default:
///
///     defaults write com.gcdz.creativenotch HUDDiagnostics -bool YES
///
/// Writes to `~/Library/Logs/CreativeNotch-hud.log`.
final class HUDDiagnostics {

    private let handle: FileHandle
    private let formatter: DateFormatter

    /// Returns an instance only when the default is set, so the whole
    /// feature costs one boolean read at launch when it is off.
    static func enabledFromDefaults() -> HUDDiagnostics? {
        guard UserDefaults.standard.bool(forKey: "HUDDiagnostics") else { return nil }
        return HUDDiagnostics()
    }

    init?() {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CreativeNotch-hud.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
        self.formatter = DateFormatter()
        self.formatter.dateFormat = "HH:mm:ss.SSS"
        record("--- diagnostics started ---")
    }

    func record(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}
