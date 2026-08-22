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

    private static var swiftFiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: coreDirectory, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "swift" } ?? []
    }

    @Test func theCoreSourcesAreWhereWeThinkTheyAre() {
        // Guards against the check silently passing on an empty list.
        #expect(Self.swiftFiles.count >= 5)
    }

    @Test func theCoreImportsNoUIFramework() throws {
        let banned = ["AppKit", "SwiftUI", "UIKit", "Cocoa"]
        var offences: [String] = []

        for file in Self.swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed
                    .replacingOccurrences(of: "import ", with: "")
                    .replacingOccurrences(of: "@preconcurrency ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if banned.contains(module) {
                    offences.append("\(file.lastPathComponent) imports \(module)")
                }
            }
        }

        #expect(offences.isEmpty, "CreativeNotchCore must stay UI-free: \(offences)")
    }
}
