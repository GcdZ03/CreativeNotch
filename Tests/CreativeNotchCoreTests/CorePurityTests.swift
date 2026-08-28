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

    @Test func theCoreSourcesAreWhereWeThinkTheyAre() {
        // >= 5 alone is satisfied by the top-level directory by itself, so
        // it would not have noticed the subdirectories going unscanned. A
        // higher count that only a recursive walk reaches, plus asserting
        // that files which live *only* in a subdirectory are among those
        // scanned, together pin the walk to actually being recursive.
        #expect(Self.swiftFiles.count >= 10)

        let names = Set(Self.swiftFiles.map(\.lastPathComponent))
        #expect(names.contains("HUDAttribution.swift"))
        #expect(names.contains("ShelfStore.swift"))
    }

    @Test func theCoreImportsNoUIFramework() throws {
        let banned = ["AppKit", "SwiftUI", "UIKit", "Cocoa"]
        var offences: [String] = []

        for file in Self.swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                var candidate = line.trimmingCharacters(in: .whitespaces)

                // Strip any leading attributes (`@preconcurrency`,
                // `@_implementationOnly`, `@testable`, …) before deciding
                // whether this line is an import at all. Attributed imports
                // are the house idiom (see Permissions.swift), so checking
                // `hasPrefix("import ")` before stripping them let
                // `@preconcurrency import AppKit` sail straight through.
                while candidate.hasPrefix("@") {
                    guard let spaceIndex = candidate.firstIndex(of: " ") else { break }
                    candidate = String(candidate[candidate.index(after: spaceIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                }

                guard candidate.hasPrefix("import ") else { continue }
                let module = candidate
                    .replacingOccurrences(of: "import ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if banned.contains(module) {
                    offences.append("\(file.lastPathComponent) imports \(module)")
                }
            }
        }

        #expect(offences.isEmpty, "CreativeNotchCore must stay UI-free: \(offences)")
    }
}
