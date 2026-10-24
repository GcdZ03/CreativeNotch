import Foundation

/// What a search typed into the clipboard pane keeps.
///
/// Pure and in Core for the usual reason — it is the one part of the search
/// with a right answer, and it is testable without a field to type into.
///
/// The filter runs over the whole entry, not its row preview: the preview
/// stops at eighty characters, and a word past that would otherwise be
/// unfindable in an entry the person can see. It runs only when the query
/// changes or the ring does, both of which redraw the pane anyway — there is
/// no index to keep, because a hundred entries is not a search problem.
public enum ClipboardSearch {

    /// Case and diacritics both ignored: "cafe" finds "Café". Typing an
    /// accent is a dead-key chord on most layouts, and nobody searching
    /// their own clipboard means the difference.
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Whether `query` filters anything. Whitespace alone does not: a stray
    /// space emptying the list would read as a lost history.
    public static func isActive(_ query: String) -> Bool {
        !words(in: query).isEmpty
    }

    /// Whether `content` answers `query`: every word of the query appears
    /// somewhere in it, in any order. An inactive query matches everything.
    public static func matches(_ content: ClipboardContent, query: String) -> Bool {
        let haystack = searchableText(for: content)
        return words(in: query).allSatisfy { haystack.range(of: $0, options: options) != nil }
    }

    /// `entries` narrowed to those matching `query`, in the order given — so
    /// pins stay on top of a filtered list exactly as they do of a whole one.
    public static func filter(_ entries: [ClipboardEntry], query: String) -> [ClipboardEntry] {
        guard isActive(query) else { return entries }
        return entries.filter { matches($0.content, query: query) }
    }

    /// An image has no text, so it answers to what its row says — "PNG
    /// image" — which is the only name a person has seen it by.
    static func searchableText(for content: ClipboardContent) -> String {
        switch content {
        case .text(let string):      return string
        case .image(_, let ext):     return "\(ext.uppercased()) image"
        }
    }

    private static func words(in query: String) -> [Substring] {
        query.split(whereSeparator: \.isWhitespace)
    }
}
