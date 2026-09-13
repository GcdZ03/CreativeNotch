import Foundation

/// What a clipboard row's leading tile says about its entry (spec §5.6).
///
/// Display only. The stored content is untouched; this decides a glyph.
public enum ClipboardKind: Equatable, Sendable {
    case text, link, code, image

    public static func classify(_ content: ClipboardContent) -> ClipboardKind {
        switch content {
        case .image:
            return .image
        case .text(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            // A link is the *whole* entry being one URL with a scheme and a
            // host. Prose that mentions a URL is prose.
            if !trimmed.contains(where: \.isWhitespace),
               let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
                return .link
            }
            if trimmed.contains("\n") || trimmed.contains("{") || trimmed.contains("}") {
                return .code
            }
            return .text
        }
    }

    public var symbolName: String {
        switch self {
        case .text:  return "text.alignleft"
        case .link:  return "link"
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        }
    }
}
