import Foundation
import Testing
@testable import CreativeNotchCore

/// Every user-facing string goes through the one String Catalog,
/// `Sources/CreativeNotchCore/Localizable.xcstrings` (2026-10-24).
///
/// Localization fails silently in both directions, which is why this is
/// checked mechanically rather than by review:
///
/// - A literal that skips the catalog still *shows*, in English, so nobody
///   notices until a translator's work fails to appear for that one label.
///   The scan below flags prose in a string literal that is not inside
///   `String(localized:bundle:)` or `Text(_:bundle:)`.
/// - A key that is in the source but not in the catalog also still shows —
///   lookups fall back to the key — so a missing entry is only ever
///   discovered in another language. The second scan matches every
///   localized literal against a catalog key.
/// - A catalog that is shipped but not *compiled* (SwiftPM copies `.xcstrings`
///   as is, and `Bundle` cannot read it) resolves every plain string
///   correctly by the same fallback and gets only the plurals wrong: "1
///   files". The bundle tests read the compiled tables directly.
///
/// The scans are line-based, like `CorePurityTests`: a localized string is
/// written on one line, and a multi-line literal is not user-facing text
/// anywhere in this app.
struct LocalizationTests {

    // MARK: - The compiled bundle

    @Test func theBundleShipsEnglishTables() throws {
        let bundle = Bundle.creativeNotch
        #expect(bundle.localizations.contains("en"))
        #expect(bundle.developmentLocalization == "en")
        let lproj = try #require(bundle.url(forResource: "en", withExtension: "lproj"))
        let files = try FileManager.default.contentsOfDirectory(atPath: lproj.path)
        #expect(files.contains("Localizable.strings"))
        #expect(files.contains("Localizable.stringsdict"))
    }

    /// Every catalog entry resolves from the compiled English tables — not
    /// merely by falling back to its key, which is what a raw, uncompiled
    /// catalog would do for all of them.
    @Test func everyCatalogEntryResolvesInEnglish() throws {
        let sentinel = "\u{0}missing"
        for key in try Self.catalog().keys {
            let resolved = Bundle.creativeNotch.localizedString(forKey: key, value: sentinel, table: nil)
            #expect(resolved != sentinel, "\(key.debugDescription) is in the catalog but not in the compiled English table")
        }
    }

    /// The point of a catalog over hand-rolled `n == 1 ? "" : "s"`: the
    /// plural rule belongs to the language. English needs `one` and
    /// `other`, and both must be there or the missing one falls back to the
    /// key.
    @Test func everyPluralHasEnglishOneAndOther() throws {
        var plurals = 0
        for (key, entry) in try Self.catalog() {
            guard let english = Self.english(entry), let plural = Self.plural(english) else { continue }
            plurals += 1
            #expect(plural["one"] != nil, "\(key.debugDescription) has no English 'one' form")
            #expect(plural["other"] != nil, "\(key.debugDescription) has no English 'other' form")
        }
        #expect(plurals > 0, "the catalog has no plurals; the hand-rolled ones were meant to move into it")
    }

    @Test func everyEntryHasAnEnglishValue() throws {
        let catalog = try Self.catalogRoot()
        #expect(catalog["sourceLanguage"] as? String == "en")
        for (key, entry) in try Self.catalog() {
            #expect(Self.english(entry) != nil, "\(key.debugDescription) has no English value")
        }
    }

    /// A plural that resolves from the compiled table, end to end through
    /// `String(localized:)` — the exact call the app makes.
    @Test func pluralsComeFromTheCompiledCatalog() {
        #expect(String(localized: "\(1) items", bundle: .creativeNotch) == "1 item")
        #expect(String(localized: "\(2) items", bundle: .creativeNotch) == "2 items")
        #expect(String(localized: "\(0) items", bundle: .creativeNotch) == "0 items")
    }

    /// In the packaged app the strings live in `Contents/Resources`, where
    /// `bundle.sh` puts them — not beside `Contents/`, where SwiftPM's own
    /// accessor looks and where anything breaks the signature.
    @Test func theShippedBundleIsFoundInTheAppsResources() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalizationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: resources) }

        #expect(Bundle.shipped(in: resources) == nil)
        #expect(Bundle.shipped(in: nil) == nil)

        let bundle = resources.appendingPathComponent(Bundle.stringsBundleName)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let found = try #require(Bundle.shipped(in: resources))
        #expect(found.bundleURL.standardizedFileURL == bundle.standardizedFileURL)
    }

    /// `bundle.sh` copies the bundle SwiftPM built, by this name.
    @Test func theBundleNameIsWhatSwiftPMBuilds() {
        #expect(Bundle.creativeNotch.bundleURL.lastPathComponent == Bundle.stringsBundleName)
    }

    /// The permission prompts -- camera, Bluetooth, Calendars, Reminders,
    /// the Downloads folder -- are shown by macOS from the app's own
    /// `.lproj` folders, so they have their own catalog,
    /// `Resources/InfoPlist.xcstrings`. Every usage description must be in
    /// it, with the English Info.plist says, or that prompt is never
    /// translated, or changes the moment a translation lands.
    @Test func everyUsageDescriptionIsInTheInfoPlistCatalog() throws {
        let plistData = try Data(contentsOf: Self.repoRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let catalogData = try Data(contentsOf: Self.repoRoot.appendingPathComponent("Resources/InfoPlist.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])

        let usage = plist.filter { $0.key.hasSuffix("UsageDescription") }
        #expect(!usage.isEmpty)
        for (key, value) in usage {
            let english = Self.english(strings[key] ?? [:])
            let unit = english?["stringUnit"] as? [String: Any]
            #expect(unit?["value"] as? String == value as? String, "\(key) in InfoPlist.xcstrings does not match Info.plist")
        }
    }

    /// macOS picks a nested bundle's language from the languages the *main*
    /// app bundle has `.lproj` folders for — and the main bundle's only
    /// `.lproj` folders are the ones `bundle.sh` compiles from
    /// `Resources/InfoPlist.xcstrings`. A language added to
    /// `Localizable.xcstrings` alone is compiled, shipped, and never chosen:
    /// the app stays English even with `-AppleLanguages (fr)`, and nothing
    /// else fails. So every language in the strings catalog must be in the
    /// Info.plist catalog too.
    @Test func everyLanguageIsAlsoInTheInfoPlistCatalog() throws {
        let strings = Self.languages(in: try Self.catalogRoot())
        let infoPlist = Self.languages(in: try Self.infoPlistCatalogRoot())
        #expect(strings.contains("en"))
        let missing = strings.subtracting(infoPlist).sorted()
        #expect(missing.isEmpty, "in Localizable.xcstrings but not Resources/InfoPlist.xcstrings, so macOS would never choose them: \(missing)")
    }

    /// The helper behind the check above sees a language that only some
    /// entries have, including one that has only plural variations.
    @Test func languagesAreReadFromEveryEntry() {
        let catalog: [String: Any] = [
            "sourceLanguage": "en",
            "strings": [
                "Hello": ["localizations": ["en": [:], "fr": [:]]],
                "%lld items": ["localizations": ["de": ["variations": ["plural": [:]]]]],
                "Untranslated": [:],
            ],
        ]
        #expect(Self.languages(in: catalog) == ["en", "fr", "de"])
    }

    // MARK: - The source scans

    /// Every literal handed to `String(localized:)` or `Text(_:bundle:)` is
    /// a key in the catalog, so adding a language is only ever adding
    /// entries — never discovering strings the catalog never had.
    @Test func everyLocalizedLiteralIsInTheCatalog() throws {
        let patterns = try Self.catalog().keys.map(Self.pattern(forKey:))
        var missing: [String] = []
        var found = 0
        for (file, line, literal) in try Self.localizedLiterals() {
            found += 1
            let key = Self.keyShape(of: literal)
            if !patterns.contains(where: { key.wholeMatch(of: $0) != nil }) {
                missing.append("\(file):\(line) \(literal.debugDescription)")
            }
        }
        #expect(found > 150, "the scan found only \(found) localized literals; is it still reading the sources?")
        #expect(missing.isEmpty, "not in Localizable.xcstrings:\n\(missing.joined(separator: "\n"))")
    }

    /// No prose in a string literal outside the localized forms.
    ///
    /// "Prose" is two letters in a row and either a space or a leading
    /// capital — which is every label, hint and announcement in the app,
    /// and almost no identifier. What is left is the allowlist below, each
    /// with its reason, and lines that are plainly not user-facing (logs,
    /// symbol names, defaults keys, paths, raw values).
    ///
    /// The known gap: a lone lowercase word ("empty", "min") reads exactly
    /// like an identifier, so it is not flagged. Those few are localized
    /// all the same; the scan exists to catch the common case cheaply, not
    /// to prove a negative.
    @Test func noUserFacingLiteralBypassesTheCatalog() throws {
        var offences: [String] = []
        for (file, number, line) in try Self.sourceLines() {
            if Self.notUserFacing.contains(where: { line.contains($0) }) { continue }
            if line.firstMatch(of: /case\s+\w+\s*=\s*"/) != nil { continue }
            for literal in Self.literals(in: line) where !literal.isLocalized {
                if Self.notTextArguments.contains(where: { literal.before.hasSuffix($0) }) { continue }
                // `Text("…")` with no bundle is a lookup in the *main*
                // bundle, which has no strings: wrong whatever it says.
                let bareText = literal.before.hasSuffix("Text(") && literal.text.contains(where: \.isLetter)
                guard bareText || Self.looksLikeProse(literal.text) else { continue }
                if Self.allowedLiterals.contains(literal.text) { continue }
                offences.append("\(file):\(number) \(literal.text.debugDescription)")
            }
        }
        #expect(offences.isEmpty, """
            user-facing text must go through the catalog — \
            String(localized: "…", bundle: .creativeNotch) or Text("…", bundle: .creativeNotch):
            \(offences.joined(separator: "\n"))
            """)
    }

    /// The scan above, pointed at a line that bypasses the catalog, must
    /// catch it — a guard that cannot fail protects nothing.
    @Test func theBypassScanCatchesABareLabel() {
        let bare = Self.literals(in: #"    .accessibilityLabel("Close camera")"#)
        #expect(bare.count == 1 && !bare[0].isLocalized && Self.looksLikeProse(bare[0].text))

        let localized = Self.literals(in: #"    .accessibilityLabel(String(localized: "Close camera", bundle: .creativeNotch))"#)
        #expect(localized.count == 1 && localized[0].isLocalized)

        let text = Self.literals(in: #"    Text("Nothing copied yet", bundle: .creativeNotch)"#)
        #expect(text.count == 1 && text[0].isLocalized)

        let textWithoutBundle = Self.literals(in: #"    Text("Nothing copied yet")"#)
        #expect(textWithoutBundle.count == 1 && !textWithoutBundle[0].isLocalized)
    }

    @Test func keyShapesMatchWhatTheCompilerExtracts() {
        #expect(Self.keyShape(of: #"Remove \(item.displayName)"#) == "Remove \u{1}")
        #expect(Self.keyShape(of: #"\(level)%"#) == "\u{1}%%")
        #expect(Self.keyShape(of: #"100%"#) == "100%")
        #expect(Self.keyShape(of: #"what\u{2019}s"#) == "what\u{2019}s")
        let key = Self.keyShape(of: #"Battery \(level) percent"#)
        #expect(key.wholeMatch(of: Self.pattern(forKey: "Battery %lld percent")) != nil)
    }

    // MARK: - Allowlist

    /// Fragments that mark a whole line as not user-facing: logs, and the
    /// calls whose every string is an identifier or a path.
    private static let notUserFacing = [
        "NSLog(", "Logger(", "logger.", "fatalError(", "precondition", "assert",
        "dlsym(", "dlopen(", "PasteboardType(", "DispatchQueue(label:", "appendingPathComponent(",
        "fileURLWithPath:", "NSDeviceDescriptionKey(", "matchedGeometryEffect(",
        "suiteName", "symbol(\"",
    ]

    /// Arguments whose literal is a name, not text — matched against what
    /// immediately precedes the literal, so the label beside a symbol name
    /// on the same line is still checked.
    private static let notTextArguments = [
        "systemName:", "symbolName:", "systemSymbolName:", "systemImage:", "forKey:",
        // A translator's note is English for the translator, by design.
        "comment:",
        // A date template is a pattern, localized by the formatter itself.
        "setLocalizedDateFormatFromTemplate(",
    ]

    /// Literals that read as prose and are deliberately not translated.
    private static let allowedLiterals: Set<String> = [
        // The app's name, and the name it reads in its own Info.plist.
        "CreativeNotch",
        "NSCameraUsageDescription",
        // Keys in the dictionary `CGSCopyManagedDisplaySpaces` returns.
        "Display Identifier", "Current Space", "Main",
        // The resource bundle's file name (`Bundle.stringsBundleName`).
        "CreativeNotch_CreativeNotchCore.bundle",
        // Apple's product names, which are not translated, and the
        // lowercased forms a device's name is matched against
        // (`BluetoothAudioKind.named`).
        "AirPods", "AirPods Pro", "AirPods Max", "Beats", "airpods max", "airpods pro",
        // A picked colour as CSS or Swift source (`ColorFormat`): code to
        // paste, the same in every language, and the framework it names.
        #"rgb(\(color.red8), \(color.green8), \(color.blue8))"#,
        #"hsl(\(hue), \(saturation)%, \(lightness)%)"#,
        "Color(red: %.3f, green: %.3f, blue: %.3f)",
        "SwiftUI",
    ]

    // MARK: - Helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func catalogRoot() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("Sources/CreativeNotchCore/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func catalog() throws -> [String: [String: Any]] {
        let strings = try #require(try catalogRoot()["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        return strings
    }

    private static func infoPlistCatalogRoot() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("Resources/InfoPlist.xcstrings")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The source language plus every language any entry has a value for.
    static func languages(in catalog: [String: Any]) -> Set<String> {
        var languages: Set<String> = []
        if let source = catalog["sourceLanguage"] as? String { languages.insert(source) }
        for entry in (catalog["strings"] as? [String: [String: Any]] ?? [:]).values {
            languages.formUnion((entry["localizations"] as? [String: Any] ?? [:]).keys)
        }
        return languages
    }

    private static func english(_ entry: [String: Any]) -> [String: Any]? {
        (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
    }

    private static func plural(_ english: [String: Any]) -> [String: Any]? {
        (english["variations"] as? [String: Any])?["plural"] as? [String: Any]
    }

    /// Every non-comment line of every Swift file under the two targets that
    /// hold UI strings. The executable target has none and must keep it that
    /// way — it is unreachable by tests.
    private static func sourceLines() throws -> [(String, Int, String)] {
        var lines: [(String, Int, String)] = []
        for target in ["CreativeNotchCore", "CreativeNotchUI", "CreativeNotch"] {
            let directory = repoRoot.appendingPathComponent("Sources/\(target)")
            guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in source.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                    lines.append(("\(target)/\(url.lastPathComponent)", index + 1, line))
                }
            }
        }
        #expect(lines.count > 1000)
        return lines
    }

    private static func localizedLiterals() throws -> [(String, Int, String)] {
        try sourceLines().flatMap { file, number, line in
            literals(in: line).filter(\.isLocalized).map { (file, number, $0.text) }
        }
    }

    struct Literal {
        /// The literal as written, escapes and interpolations included.
        let text: String
        /// Directly inside `String(localized:` or `Text(` with the app's
        /// bundle on the same line.
        let isLocalized: Bool
        /// The line up to the opening quote, trimmed.
        let before: String
    }

    /// The string literals on one line, as written. Walks the characters
    /// rather than using a regex so an interpolation — which can itself
    /// contain parentheses — is skipped as a unit.
    static func literals(in line: String) -> [Literal] {
        let chars = Array(line)
        var result: [Literal] = []
        var i = 0
        let hasBundle = line.contains("bundle: .creativeNotch")
        while i < chars.count {
            guard chars[i] == "\"" else { i += 1; continue }
            if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { return result }
            let start = i
            i += 1
            var text = ""
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if depth == 0, c == "\"" { break }
                if c == "\\", i + 1 < chars.count {
                    text.append(c); text.append(chars[i + 1])
                    if chars[i + 1] == "(" { depth += 1 }
                    i += 2
                    continue
                }
                if depth > 0 {
                    if c == "(" { depth += 1 }
                    if c == ")" { depth -= 1 }
                }
                text.append(c)
                i += 1
            }
            let before = String(chars[..<start]).trimmingCharacters(in: .whitespaces)
            let localized = before.hasSuffix("String(localized:")
                || (hasBundle && before.hasSuffix("Text("))
            result.append(Literal(text: text, isLocalized: localized, before: before))
            i += 1
        }
        return result
    }

    static func looksLikeProse(_ text: String) -> Bool {
        // Interpolations are code, not words.
        let words = text.replacing(/\\\((?:[^()]|\([^()]*\))*\)/, with: "")
        guard words.firstMatch(of: /[A-Za-z]{2,}/) != nil else { return false }
        if words.contains(" ") { return true }
        return words.firstMatch(of: /^[A-Z][a-z]+/) != nil
    }

    /// The key the compiler extracts for a literal: escapes resolved, each
    /// interpolation a placeholder (`\u{1}` here), and — when there are
    /// interpolations — a literal `%` doubled, since the key is then a
    /// format string.
    static func keyShape(of literal: String) -> String {
        let chars = Array(literal)
        var out = ""
        var hasInterpolation = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else { out.append(c); i += 1; continue }
            let next = chars[i + 1]
            switch next {
            case "(":
                hasInterpolation = true
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if chars[i] == "(" { depth += 1 }
                    if chars[i] == ")" { depth -= 1 }
                    i += 1
                }
                out.append("\u{1}")
            case "u":
                let close = chars[(i + 3)...].firstIndex(of: "}") ?? chars.count - 1
                let hex = String(chars[(i + 3)..<close])
                out.unicodeScalars.append(Unicode.Scalar(UInt32(hex, radix: 16) ?? 0x3F) ?? "?")
                i = close + 1
            case "n": out.append("\n"); i += 2
            case "t": out.append("\t"); i += 2
            default: out.append(next); i += 2
            }
        }
        return hasInterpolation ? out.replacingOccurrences(of: "%", with: "%%") : out
    }

    /// A catalog key as a pattern over `keyShape`: each format specifier
    /// matches the placeholder an interpolation became.
    static func pattern(forKey key: String) -> Regex<Substring> {
        var pattern = ""
        var rest = Substring(key)
        while let match = rest.firstMatch(of: /%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|@|lf|f)/) {
            pattern += NSRegularExpression.escapedPattern(for: String(rest[..<match.range.lowerBound]))
            pattern += "\u{1}"
            rest = rest[match.range.upperBound...]
        }
        pattern += NSRegularExpression.escapedPattern(for: String(rest))
        return try! Regex(pattern).matchingSemantics(.unicodeScalar)
    }
}
