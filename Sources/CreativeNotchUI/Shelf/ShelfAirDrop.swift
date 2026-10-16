import AppKit

/// What `ShelfAirDrop` needs from a sharing service, so a test can stand
/// in for AirDrop without a picker appearing on the machine running it.
protocol SharingPerforming {
    func canPerform(withItems items: [Any]?) -> Bool
    func perform(withItems items: [Any])
}

extension NSSharingService: SharingPerforming {}

/// Sends shelf files over AirDrop (spec 2026-10-17).
///
/// Uses the system's own AirDrop sharing service: no permission, no
/// network code of ours, and nothing running until it is asked. macOS shows
/// its usual picker of nearby devices.
enum ShelfAirDrop {
    /// Returns whether anything was handed to AirDrop.
    ///
    /// Files that are no longer on disk are left out rather than offered:
    /// AirDrop would show a picker for nothing.
    @discardableResult
    static func send(_ urls: [URL], via service: SharingPerforming?) -> Bool {
        let present = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let service, !present.isEmpty, service.canPerform(withItems: present) else {
            return false
        }
        service.perform(withItems: present)
        return true
    }

    /// The real service, looked up when needed rather than held.
    @MainActor
    static var airDrop: SharingPerforming? { NSSharingService(named: .sendViaAirDrop) }
}
