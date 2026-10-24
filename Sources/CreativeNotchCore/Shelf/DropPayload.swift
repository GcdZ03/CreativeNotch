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
        case .text:              return String(localized: "Dropped Text", bundle: .creativeNotch, comment: "File name for dropped text, before .txt") + ".txt"
        case .image(_, let ext): return String(localized: "Dropped Image", bundle: .creativeNotch, comment: "File name for a dropped image, before its extension") + ".\(ext)"
        }
    }
}
