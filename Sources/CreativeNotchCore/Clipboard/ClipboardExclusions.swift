import Foundation

/// Apps whose copies clipboard history never records (2026-10-24).
///
/// Empty by default. Password managers mostly mark their entries with
/// `org.nspasteboard.ConcealedType`, which is skipped before any content is
/// read whatever this list says; the list is for the apps that do not --
/// a terminal full of tokens, a banking app, a password manager that ignores
/// the convention.
///
/// Stored as bundle identifiers, never names or paths: an app renamed or
/// moved out of `/Applications` is still the same app.
public enum ClipboardExclusions {

    /// Whether a copy is refused.
    ///
    /// Two witnesses, and either is enough:
    ///
    /// - `source`, the `org.nspasteboard.source` type a well-behaved app
    ///   writes alongside its copy. The copying app's own word, and the only
    ///   one when it is not frontmost -- a menu bar password manager, a
    ///   background helper.
    /// - `frontmost`, the app in front when the poller noticed the change.
    ///   Read only then, never on a clock; it can be wrong only if the user
    ///   switched apps within one poll interval of copying.
    ///
    /// "Either" rather than "source first": the list is a privacy promise,
    /// and a false positive costs a copy that is not in the history.
    ///
    /// Case-insensitive, as Launch Services treats bundle identifiers.
    public static func excludes(source: String?, frontmost: String?, excluded: [String]) -> Bool {
        guard !excluded.isEmpty else { return false }
        let list = Set(excluded.map { $0.lowercased() }.filter { !$0.isEmpty })
        return [source, frontmost].contains { id in
            guard let id, !id.isEmpty else { return false }
            return list.contains(id.lowercased())
        }
    }

    /// `list` with `ids` appended, in order, skipping blanks and anything
    /// already present under any casing.
    public static func adding(_ ids: [String], to list: [String]) -> [String] {
        var result = list
        var seen = Set(list.map { $0.lowercased() })
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id.lowercased()).inserted else { continue }
            result.append(id)
        }
        return result
    }

    public static func removing(_ id: String, from list: [String]) -> [String] {
        list.filter { $0.lowercased() != id.lowercased() }
    }

    /// What a raw defaults value means. Absent, or not an array, reads as
    /// empty and is left in place -- the policy `PreferenceKeys.resolveEnabled`
    /// sets out. Non-strings, blanks and repeats inside the array are dropped.
    public static func resolve(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return adding(array.compactMap { $0 as? String }, to: [])
    }
}
