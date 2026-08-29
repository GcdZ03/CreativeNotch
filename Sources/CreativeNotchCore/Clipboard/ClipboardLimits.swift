import Foundation

/// The per-entry size caps, and the one predicate that applies them.
///
/// Spec section 5.3. Over-cap content is **skipped, never truncated**: a
/// half-written string pastes back as corrupt data, which is a worse
/// outcome than the entry simply not being there.
///
/// One predicate, two call sites. `NSPasteboard.clipboardCapture()` applies
/// it to what will actually be stored — after transcoding, so an
/// uncompressed screenshot is judged at its PNG size rather than its TIFF
/// one — and `ClipboardStore.record` applies it again as the ring's own
/// invariant. Two callers of one function is not duplication; two
/// independent size checks would be.
public enum ClipboardLimits {

    /// 1 MB.
    public static let maxTextBytes = 1_000_000

    /// 10 MB. Applied to the PNG the ring will hold, not to whatever the
    /// pasteboard offered — see `NSPasteboard.clipboardCapture()`.
    public static let maxImageBytes = 10_000_000

    public static func acceptsText(byteCount: Int) -> Bool {
        byteCount <= maxTextBytes
    }

    public static func acceptsImage(byteCount: Int) -> Bool {
        byteCount <= maxImageBytes
    }

    /// The caps differ by an order of magnitude, so the kind chooses the
    /// cap here rather than at each call site, where applying the image
    /// cap to text would compile and quietly allow ten times too much.
    public static func accepts(_ content: ClipboardContent) -> Bool {
        guard !content.isBlank else { return false }
        switch content {
        case .text:  return acceptsText(byteCount: content.byteCount)
        case .image: return acceptsImage(byteCount: content.byteCount)
        }
    }
}
