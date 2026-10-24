import Foundation
import Testing

/// Every delegate a test builds by hand is kept off the user's real shelf
/// and real Trash (2026-10-24).
///
/// `install(metrics:)` runs the launch purge, and the defaults a test uses
/// are isolated, so the purge runs at the default expiry: a delegate left on
/// `ShelfTrash.system` and the real Application Support shelf moves the
/// developer's own old shelf files into `~/.Trash`. Two restore-on-relaunch
/// tests did exactly that; a source scan is the only way to catch the next
/// one before it runs.
struct TestIsolationScanTests {

    @Test func everyHandBuiltDelegateUsesATemporaryShelfAndTheTestTrash() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "TestIsolationScanTests.swift" }
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard let range = line.range(of: #"let (\w+) = AppDelegate\(\)"#, options: .regularExpression) else { continue }
                let name = line[range].dropFirst(4).prefix { $0 != " " }
                // The setup that follows, up to `install` or the end of the block.
                let setup = lines[(index + 1)...].prefix { !$0.contains("\(name).install(") && !$0.hasPrefix("    }") }
                let trash = setup.contains { $0.contains("\(name).shelfTrash = ") }
                let directory = setup.contains { $0.contains("\(name).shelfDirectory = ") }
                if !trash || !directory {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "set shelfTrash and shelfDirectory before install: \(offenders)")
    }
}
