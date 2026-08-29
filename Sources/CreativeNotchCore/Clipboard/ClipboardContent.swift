import Foundation

/// One thing that was on the pasteboard.
///
/// Text and images only. File URLs are the shelf's job, and the shelf does
/// that job by *copying* — a URL held here would go stale the moment the
/// original moved, which is the exact failure the shelf was built to avoid.
///
/// `Hashable` because promotion in `ClipboardStore` is keyed on content
/// equality: re-copying a value already in the ring has to find it.
public enum ClipboardContent: Equatable, Hashable, Sendable {
    case text(String)
    case image(Data, ext: String)

    /// What this costs the ring, in bytes.
    ///
    /// UTF-8 rather than `String.count`: a string of emoji is four bytes
    /// per character, and counting characters would under-report it
    /// fourfold — enough to let a 4 MB paste through a 1 MB cap.
    public var byteCount: Int {
        switch self {
        case .text(let string):   return string.utf8.count
        case .image(let data, _): return data.count
        }
    }

    /// Nothing worth a ring slot.
    ///
    /// Whitespace-only text is what a stray select-and-copy produces;
    /// `Pasteboard+Drop` already refuses it for the shelf, and a fifty-slot
    /// history that can fill with blank lines is worse than useless.
    public var isBlank: Bool {
        switch self {
        case .text(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image(let data, _):
            return data.isEmpty
        }
    }
}
