import Foundation

/// A release version, compared as numbers (2026-10-24).
///
/// **Never compared as text.** "0.12.10" sorts before "0.12.9" as a string,
/// so an updater comparing tags that way would offer a downgrade the day a
/// patch number reached two digits — and would stop offering anything
/// newer, silently, until the minor number moved.
///
/// Deliberately narrow: one to three dot-separated ASCII numbers, with an
/// optional leading "v" because that is how the release workflow tags
/// (`v0.13.0`) and how `CoreInfo.version` is not (`0.13.0`). A pre-release
/// or build suffix ("-rc1", "+sha") is refused rather than half-understood:
/// `releases/latest` never returns a pre-release, and a tag this cannot read
/// is "no update", which fails in the harmless direction.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `nil` for anything that is not one to three numbers. Missing
    /// components are zero, so "0.13" and "0.13.0" are the same release.
    public init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // ASCII digits only: `Int.init` would take a sign, and
            // `Character.isNumber` would take full-width and other scripts'
            // digits, none of which a tag ever contains.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Whether a release is newer than the running copy.
public enum UpdateAvailability {
    /// The release, when its tag is a newer version than `current`;
    /// otherwise `nil`. Either side unreadable is `nil` — "no update" is the
    /// only safe reading of a version this cannot parse.
    public static func newer(_ release: Release?, than current: String) -> Release? {
        guard let release,
              let latest = release.version,
              let running = SemanticVersion(current),
              latest > running else { return nil }
        return release
    }
}
