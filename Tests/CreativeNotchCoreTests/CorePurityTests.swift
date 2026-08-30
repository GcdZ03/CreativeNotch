import Foundation
import Testing

/// `CreativeNotchCore` importing AppKit or SwiftUI is a mistake, not a
/// tradeoff: its independence from them is what lets the geometry, the
/// hit-test shapes, the state machine and the peek arbiter run headlessly
/// in CI in about a second.
///
/// Until now that rule was upheld by review discipline alone. This checks
/// it mechanically, so a stray import fails the build rather than waiting
/// for someone to notice. (Follow-up F10.)
struct CorePurityTests {

    /// `Sources/CreativeNotchCore`, located from this file rather than from
    /// a working directory, which `swift test` does not guarantee.
    private static var coreDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/CreativeNotchCoreTests/CorePurityTests.swift
            .deletingLastPathComponent()          // .../Tests/CreativeNotchCoreTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Sources/CreativeNotchCore")
    }

    /// Recursive: `contentsOfDirectory` only lists the top level, which
    /// silently stopped covering `HUD/` and `Shelf/` the moment those
    /// subdirectories appeared — the purity check kept passing, but it had
    /// stopped scanning most of the module.
    private static var swiftFiles: [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: coreDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// The same directory, listed *non*-recursively — i.e. exactly the bug
    /// that failure mode 1 regressed to. Used only as a control value below.
    private static var topLevelSwiftFiles: [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: coreDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.pathExtension == "swift" }
    }

    @Test func theCoreSourcesAreWhereWeThinkTheyAre() {
        let files = Self.swiftFiles
        let names = Set(files.map(\.lastPathComponent))

        // A bare count floor drifts: add enough root-level files over time
        // and a silently-non-recursive scan clears it without ever
        // touching a subdirectory again. Comparing against the *actual*
        // non-recursive listing of the same directory, right now, can't
        // drift the same way — if someone reintroduces
        // `contentsOfDirectory` in `swiftFiles` itself, this becomes `0 >
        // 0` and fails regardless of how many root files exist.
        #expect(files.count > Self.topLevelSwiftFiles.count)

        // Every file known to live only inside a subdirectory, not just
        // one per directory — a walk that recurses one level but not
        // further, or that mis-skips a sibling file, still shows up here.
        let expectedInSubdirectories = [
            "HUDAttribution.swift",
            "HUDCoalescer.swift",
            "HUDSignificanceGate.swift",
            "DropPayload.swift",
            "ShelfItem.swift",
            "ShelfStore.swift",
            "ClipboardContent.swift",
            "ClipboardEntry.swift",
            "ClipboardLimits.swift",
            "ClipboardPollSchedule.swift",
            "ClipboardStore.swift",
            "MediaCommand.swift",
            "MediaPayload.swift",
        ]
        for name in expectedInSubdirectories {
            #expect(names.contains(name), "expected recursive scan to find \(name)")
        }
    }

    /// **This check is line-based.** It scans one physical line (split on
    /// `;`) at a time, so it cannot see an `import` whose module name lands
    /// on a following line -- e.g. `import` and `AppKit` separated by a
    /// line break, however that got past `swift build` formatting-wise.
    /// That is a known, deliberate limit, not a fifth silent hole: this
    /// check has already failed four times in four different ways, each
    /// silently, and a previous report claimed every legal spelling was
    /// caught when two were not. Stated here so the next person doesn't
    /// have to rediscover the boundary by mutation, and so nobody repeats
    /// the claim of completeness this comment is deliberately not making.
    @Test func theCoreImportsNoUIFramework() throws {
        let banned = ["AppKit", "SwiftUI", "UIKit", "Cocoa"]
        var offences: [String] = []

        for file in Self.swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                // Swift allows multiple statements per line separated by
                // `;`, including `import Foundation; import AppKit` — a
                // whole-line prefix check never sees the second import.
                // Splitting first, then running every fragment through the
                // same pipeline below, catches it regardless of position.
                for statement in line.split(separator: ";", omittingEmptySubsequences: true) {
                    try Self.scanPotentialImport(statement, in: file, banned: banned, offences: &offences)
                }
            }
        }

        #expect(offences.isEmpty, "CreativeNotchCore must stay UI-free: \(offences)")
    }

    /// Checks a single statement fragment (already split on `;`) for a
    /// banned import, appending a description to `offences` if it is one.
    ///
    /// Tokenizes on whitespace rather than matching literal substrings,
    /// because every earlier version of this check assumed a single space
    /// in a specific place — `hasPrefix("import ")`, `firstIndex(of: " ")`
    /// — and each of those assumptions turned out to be a place a legal
    /// spelling could hide: a tab (`import\tAppKit`) instead of a space, or
    /// a `//` comment with no space before it (`import AppKit//comment`).
    /// Tokenizing first and comparing whole tokens is immune to both.
    private static func scanPotentialImport(
        _ statement: Substring,
        in file: URL,
        banned: [String],
        offences: inout [String]
    ) throws {
        var text = String(statement)

        // Strip block comments *before* tokenizing, and before cutting a
        // trailing `//` comment below. `/* c */ import AppKit` tokenized
        // first has `/*` as its leading token, which is not "import" --
        // the guard on `tokens.first == "import"` then returned early and
        // let a genuine import hide behind the comment. Only a block
        // comment that opens and closes on this same line/statement is
        // removed here, consistent with this check being line-based (see
        // the doc comment on `theCoreImportsNoUIFramework`): one that
        // opens without closing has everything from `/*` onward dropped,
        // since none of it can be trusted as real code on this line.
        //
        // Done ahead of the `//` cut, not after: a block comment can
        // itself contain `//` (e.g. `/* see http://x */ import AppKit`),
        // and cutting at the first `//` before removing the block comment
        // would chop the import off along with it.
        while let start = text.range(of: "/*") {
            if let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text = String(text[..<start.lowerBound])
                break
            }
        }

        // Cut a trailing comment from the raw text *before* tokenizing —
        // `import AppKit//comment` has no whitespace to split on, so a
        // token-level check for a `//`-prefixed token would miss it.
        if let commentRange = text.range(of: "//") {
            text = String(text[..<commentRange.lowerBound])
        }

        // Backticks only ever escape an identifier that would otherwise be
        // read as a keyword — `` import `AppKit` `` is exactly
        // `import AppKit` as far as the compiler and the module system are
        // concerned. None of the banned names are Swift keywords, so
        // stripping backticks unconditionally can only remove noise, never
        // manufacture a false match.
        text.removeAll(where: { $0 == "`" })

        // Split on *any* whitespace, not just " " — a literal-space check
        // is exactly what let a tab slip through.
        var tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        // Drop any leading attributes (`@preconcurrency`,
        // `@_implementationOnly`, `@testable`, `@_spi(Name)`, …). None of
        // them take an argument containing whitespace, so each is exactly
        // one token.
        while let first = tokens.first, first.hasPrefix("@") {
            tokens.removeFirst()
        }

        guard tokens.first == "import" else { return }
        tokens.removeFirst()
        guard var head = tokens.first else { return }

        // A scoped import — `import class AppKit.NSObject`,
        // `import func AppKit.NSBeep` — names the module *after* a
        // declaration kind, not first.
        let declarationKinds: Set<String> = [
            "class", "struct", "enum", "protocol", "func", "var", "let", "typealias",
        ]
        if declarationKinds.contains(head) {
            guard tokens.count > 1 else { return }
            head = tokens[1]
        }

        // A submodule import — `import AppKit.NSView` — also isn't
        // literally "AppKit"; the module is the first dot-separated
        // component of whatever's left, whether or not a declaration kind
        // was present.
        let module = head.split(separator: ".").first.map(String.init) ?? head

        if banned.contains(module) {
            offences.append("\(file.lastPathComponent) imports \(module)")
        }
    }
}
