import Foundation

/// What a drag delivered, with AppKit already stripped away.
///
/// The pasteboard is converted at the boundary in `CreativeNotchUI` so the
/// store — and everything that can destroy a file — stays testable
/// headlessly.
public enum DropPayload: Equatable, Sendable {
    case file(URL)
    case text(String)
    case image(Data, ext: String)

    /// The name to write it under, before collision handling.
    public var suggestedName: String {
        switch self {
        case .file(let url):     return url.lastPathComponent
        case .text:              return "Dropped Text.txt"
        case .image(_, let ext): return "Dropped Image.\(ext)"
        }
    }
}
